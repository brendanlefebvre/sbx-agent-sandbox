# sbx — empirical findings (wslc preview; 2.9.3.0 unless a section says otherwise)

## Bind-mount source path syntax

Probed 2026-07-21 from **PowerShell** (the launcher's real invocation
environment), mounting a host dir containing `MARKER.txt` at `/work` and running
`ls -la /work`.

| Candidate | `-v` source form | Result |
|-----------|------------------|--------|
| A | `C:\Users\user\src\sbx\.probe` (Windows, backslash) | ✅ `MARKER.txt` visible |
| B | `/mnt/c/Users/user/src/sbx/.probe` (WSL `/mnt` view) | ❌ empty `/work` (no marker) |
| C | `C:/Users/user/src/sbx/.probe` (Windows, forward-slash) | ✅ `MARKER.txt` visible |

**Winner:** the **host Windows drive-letter path** — both backslash (A) and
forward-slash (C) bind correctly. The `/mnt/c` WSL-view form (B) does **not**
bind the host dir: it silently mounts an empty anonymous location. This is the
dangerous failure mode — it looks like it works but writes nowhere — so the
launcher must never emit the `/mnt` form.

**Decision for `ConvertTo-SbxMountPath` (Task 6):** emit the **forward-slash
Windows path** (`C:/Users/user/src/foo`). Forward slashes survive the
`wt.exe → pwsh -Command "wslc …"` string hop without backslash-escape hazards,
and bind identically to the backslash form. The resulting arg
`-v C:/Users/user/src/foo:/work` parses correctly — wslc distinguishes the
drive colon from the `:/work` separator colon (candidate C proves both coexist).

**✅ Verified — SSH `:ro` with a Windows source.** The `--ssh` mount's 3-colon
arg `C:/Users/.../.ssh:/home/agent/.ssh:ro` parses correctly: a probe mounted a
dummy dir and confirmed the contents were visible **and** writes were rejected
(`touch` → `Read-only file system`). So `Build-SbxRunArgs`' ssh branch works as
written. See the SSH key-permissions caveat under "Image / runtime behaviour".

## `wslc list --all --format json` field names (Task 9)

Verified live against a real `sbx:latest`-image container list (image built
out-of-order during Task 3; confirmed independently by re-running
`wslc list --all --format json` against existing containers):

```json
[
  {
    "CreatedAt": 1782837665,
    "Id": "b7a3c87a...",
    "Image": "ghcr.io/ggml-org/llama.cpp:server",
    "Name": "rugged_laramie",
    "Ports": [],
    "State": 3,
    "StateChangedAt": 1783523053
  }
]
```

Fields are **PascalCase**: `Name`, `Image`, `State` (int enum) — not the
lowercase `name`/`image`/`status` assumed in the Task 9 brief. There is no
`status` string field at all. Observed `State` values: `2` = running,
`3` = stopped/exited.

**Decision for `Get-SbxList` (Task 9):** filter on `$_.Name -like 'sbx-*'`,
select `Name`, `Image`, and a computed `Status` string mapped from the int
`State` (2→`running`, 3→`exited`, else `state:<n>`). PowerShell's
case-insensitive member access means code written against `name`/`image`
still happens to work, but a literal `status` property does not exist and
would resolve to `$null` — so the mapped-column approach is required, not
optional.

## Image / runtime behaviour (Task 3)

Built `sbx:latest` from the `Sandboxfile`: Debian bookworm-slim, Node 24.18.0
(NodeSource LTS), `@anthropic-ai/claude-code@2.1.216`, non-root `agent`
(uid 1000). `claude --version` → `2.1.216 (Claude Code)`.

**npm `allow-scripts` warning is benign — postinstall DID run.** `claude-code`
is a wrapper package; the real CLI is a ~264 MB native binary shipped as the
platform `optionalDependency` (`@anthropic-ai/claude-code-linux-arm64`). The
`install.cjs` postinstall hardlinks that binary over `bin/claude.exe`. Verified
in the image: `bin/claude.exe` is 264 MB with link count 2 (the hardlink), the
native optional dep is present, and `claude --help` prints full usage — so
nothing was skipped. npm 11's `allow-scripts` hardening only blocks *transitive*
dependency scripts; the explicitly-installed top-level package still runs its
own postinstall.

**Git "dubious ownership" — fixed in the image.** wslc Windows bind-mounts
present as `root:root` mode `0777`, but the container runs as `agent`, so
`git status` in `/work` failed with *"detected dubious ownership in repository
at '/work'"*. Fixed by `RUN git config --system --add safe.directory '*'` in the
`Sandboxfile` — safe in a throwaway sandbox whose only writable surface is the
one mounted repo. Verified: after the fix `git status` works on a mounted repo.

**SSH key permissions + host keys — RESOLVED via an image entrypoint.** Two
things broke `--ssh` git-over-SSH, both confirmed live against a real droplet
remote:
1. The `0777` bind-mount ownership makes a mounted private key world-readable,
   and `ssh` refuses such keys (*"UNPROTECTED PRIVATE KEY FILE"*); being
   read-only it can't be `chmod`ed in place.
2. The mounted `known_hosts` didn't contain the remote host, so ssh failed at
   *host key verification* before ever using the key.

Fix (in the `Sandboxfile`): `--ssh` now bind-mounts `~/.ssh` read-only at
`/home/agent/.ssh-ro`, and an **entrypoint** (`/usr/local/bin/sbx-entrypoint`)
copies it into `~/.ssh` at `0600` (ephemeral, per-container) before exec-ing the
command; the image also sets `StrictHostKeyChecking accept-new` system-wide.
Verified end-to-end: the key becomes `-rw-------` and `git ls-remote` fetches
`HEAD`/`refs/heads/main` from `ssh://…@droplet/…`. `accept-new` still honors the
copied `known_hosts` (known hosts stay verified; a *changed* key is still
rejected) and only auto-accepts genuinely new hosts (TOFU) — acceptable for a
sandbox reaching the user's own remotes. The spec's v2 ssh-agent forwarding
remains the stronger long-term option (no key material in the container).

**Cross-OS line endings — fixed in the image.** Mounting a Windows-checked-out
repo (CRLF working tree) into the Linux container made `git status` report every
tracked file as modified (CRLF working tree vs. LF index — 14/14 files in this
repo). Fixed by `core.autocrlf input` in the `Sandboxfile`: git normalizes
CRLF→LF when hashing the working tree for comparison, so a mounted Windows repo
reads clean (verified 14→0 modified). Repos with their own `.gitattributes`
still override this.

## Named-volume vs bind-mount disambiguation (Task 4)

Verified: `-v <name>:/path` where `<name>` is a `wslc volume` (no drive colon)
mounts the **named volume**, distinct from `-v C:/host:/path` which binds a host
dir. The `sbx-claude-auth` volume (driver `guest`):

- **persists** across containers (a file written in one container is present in
  the next — confirmed), and
- mounts **owned by the container user** (`agent:agent`, writable with no chown —
  unlike Docker named volumes, which mount as root).

So mounting it at `/home/agent/.claude` on every run gives Claude a persistent,
agent-writable login store with no ownership fix-ups needed.

## Per-repo Claude session history (design refinement, Task 4)

The shared `sbx-claude-auth` volume persists the login — but Claude stores
per-project session transcripts under `~/.claude/projects/<cwd>/`, and every repo
mounts at `/work`. With only the shared volume, all repos would collide in one
`projects/-work/` bucket and `claude --resume` in one repo would list another
repo's sessions. Fixed by mounting a **per-repo volume** over `projects/` on real
runs:

    -v sbx-claude-auth:/home/agent/.claude \
    -v sbx-proj-<basename>-<md5-of-abspath>:/home/agent/.claude/projects

Verified live:

- **auto-create** — `-v <newname>:/path` creates the volume on first use; no
  pre-create step in the launcher.
- **nested mount + ownership** — a volume mounted at `~/.claude/projects` (inside
  the `~/.claude` volume mount) works and comes up **agent-owned** *because the
  image now pre-creates `.claude/projects` agent-owned*. Without that image fix
  the nested mount defaulted to `root:root` and the agent could not write it.
- **isolation** — a session written under repo-X's volume is absent when repo-Y's
  volume is mounted; the shared credentials remain visible in both.
- **`--tmpfs` is NOT usable here** — a tmpfs mount comes up `root:root` and the
  agent cannot write it. So **scratch** runs (no repo) get no `projects/` override
  and just use the shared auth volume's `projects/` (throwaway sessions, nothing
  to bleed into).

`Get-SbxProjectVolumeName` keys the volume on an MD5 of the absolute path, so two
different repos that share a basename don't collide. Note: these per-repo volumes
accumulate over time (one per repo ever run); a future `sbx` prune could reap
volumes for repos no longer present.

## wslc volume-mount ceiling (preview quirk, Windows)

Hit 2026-07-22 on Windows while running the macOS-port non-regression gate —
launching a second sandbox (`sbx <repoB>`) failed with:

```
Too many volumes have been mounted (limit: 15). Restart the session to mount
more volumes. This will be fixed in a future release.
Error code: 0x8007000e
```

It is a **cumulative count of mount operations**, not a live-resource count, and
the counter lives in the **Windows-side WSL service process**, not in any VM or
distro. Established by elimination — each of these was tested and disproved:

| Hypothesis | Disproof |
|---|---|
| Number of volumes that exist | Failed at 9 volumes, and still failed after pruning to **6** |
| Stale containers holding mounts | `wslc list --all` was **empty** |
| Distro session | `wsl --terminate Ubuntu-22.04` did not clear it (it appeared to work once — coincidence, not causation) |
| The WSL2 VM | `wsl --shutdown` did not clear it |
| **WSL service process** | **Restarting the WSL service cleared it immediately** ✅ |

Each real run mounts the shared auth volume, the per-repo `sbx-proj-*` volume,
and the repo itself (plus `~/.ssh` under `--ssh`) — roughly 3 against the
ceiling — so expect **~5 runs per service lifetime**. (Which of those three
increment the counter was not measured individually.)

**A failed attempt still burns budget.** The run that hits the limit has already
created its `sbx-proj-*` volume before failing, so retrying makes things strictly
worse. Reset rather than retry.

No documentation or community report of this limit could be found (searched
2026-07-22); treat it as undocumented preview behavior and re-check on wslc
upgrades — the error text itself says "This will be fixed in a future release."

**Not caused by the macOS port.** `Build-SbxRunArgs`' mount set is unchanged by
that work (it only gained the `-Posix` switch); this is a wslc preview
limitation that the verification checklist simply made easy to hit, since the
checklist launches many sandboxes back to back.

**Workaround:** restart the WSL service from an **elevated** PowerShell, then
relaunch:

```powershell
Get-Service *wsl*, *Lxss* | Format-Table -Auto   # confirm the service name
Restart-Service -Name WslService -Force
```

A Windows reboot works too. `wsl --shutdown` and `wsl --terminate <distro>` do
**not** — don't bother with them.

⚠️ **Do not use `wslc volume prune` to reclaim space.** With no container
running, `sbx-claude-auth` counts as unused, so prune would delete the persisted
Claude login. Remove specific `sbx-proj-*` volumes by name instead (cost: that
repo's `claude --resume` history). Note this does *not* fix the ceiling — it was
tested and doesn't help — it's only for genuine cleanup.

If the ceiling becomes routine rather than an artifact of bulk testing, the
per-repo `projects/` volume is the obvious thing to trade away for short-lived
runs: making it optional would cut the per-run mount cost by roughly a third, at
the price of the session-history isolation it buys (see "Per-repo Claude session
history" above).

## macOS (OrbStack 29.4.0, arm64)

**Runtime identity — read this before generalizing anything below.** The macOS
runtime here is **OrbStack**, not Docker Desktop. It provides the standard
`docker` CLI (`/usr/local/bin/docker` →
`/Applications/OrbStack.app/Contents/MacOS/xbin/docker`), the active context is
`orbstack`, `docker info` reports `Name=orbstack` / `OS=OrbStack`, and the
bridge network is `192.168.215.0/24` (Docker Desktop uses `192.168.65.x`).
Everything below was observed on OrbStack; Docker Desktop is **untested**. The
volume-ownership result (P2/P3) depends on standard Docker-engine copy-on-init
semantics, which Docker Desktop should share — but that is an inference, not a
measurement. Re-run P2/P3 before trusting the "no `gosu` needed" decision on
Docker Desktop.

Probed 2026-07-21 on the Mac (`pwsh` 7.6.4 already installed; OrbStack
server 29.4.0, daemon reachable). Built `sbx:latest` from the current
`Sandboxfile` unmodified — image builds cleanly on arm64 (Debian bookworm,
Node 24.18.0, `@anthropic-ai/claude-code@2.1.217`); `claude --version` →
`2.1.217 (Claude Code)`.

**P1 — bind-mount visibility + writability.** `docker run --rm -v
/tmp/sbx-probe:/work -w /work sbx:latest bash -c 'ls -la /work; id; touch
/work/_w && echo WRITE_OK && rm /work/_w'`:

```
total 4
drwxr-xr-x 1 agent agent 96 Jul 22 01:59 .
drwxr-xr-x 1 root  root  12 Jul 22 01:59 ..
-rw-r--r-- 1 agent agent  3 Jul 22 01:59 MARKER.txt
uid=1000(agent) gid=1000(agent) groups=1000(agent)
WRITE_OK
```

`MARKER.txt` visible, owned `agent:agent` inside the container (OrbStack's
macOS filesystem-sharing layer maps the host bind-mount to the container's
uid/gid rather than surfacing host uid/gid or `root:root` the way wslc's
Windows bind does), and writable. **Bind mounts need no ownership fix-up on
macOS/OrbStack.**

**P2/P3 — named-volume ownership (decision gate).** Ran the brief's literal
probe (`su agent -c '...'` against `sbx-claude-auth:/home/agent/.claude` +
a scratch `sbx-proj-probe` volume at `.../projects`); `su` failed with
`Authentication failure` on both write attempts. That failure is a probe-script
artifact, not a permissions signal: the `Sandboxfile` sets `USER agent` as the
image's default (unlike a root-default image), so the container process was
already running as `agent` (confirmed via `id` inside the container), and a
non-root user's `su` to any target — including itself — demands a password
that the `agent` account doesn't have. Re-ran the same probe writing directly
as the container's actual default user instead of shelling out through `su`:

```
uid=1000(agent) gid=1000(agent) groups=1000(agent)
agent:agent /home/agent/.claude
agent:agent /home/agent/.claude/projects
CLAUDE_WRITE_OK
PROJ_WRITE_OK
```

Both mounts come up owned `agent:agent` and both `touch`es succeed as `agent`.
This matches the Windows/wslc finding above (`sbx-claude-auth` mounts
agent-owned, no chown needed) and confirms OrbStack's copy-on-init on
macOS also preserves the image's pre-created `agent:agent` ownership of
`/home/agent/.claude` and `.../projects` (the same mechanism documented in
"Named-volume vs bind-mount disambiguation" and "Per-repo Claude session
history" above, which pre-create those directories agent-owned in the image
specifically so a fresh named-volume copy-in inherits that ownership).

**DECISION: Task 2's image change is NOT needed (verified on OrbStack).** Both
`/home/agent/.claude` and `/home/agent/.claude/projects` come up `agent:agent`
and both are agent-writable with the current, unmodified `Sandboxfile` — there
is no root-owned mount to work around, so no `gosu`/privilege-drop entrypoint
change is required for macOS/OrbStack. This decision is what kept the shared
image (and therefore the working Windows path) untouched by the macOS port. If
you ever switch the macOS runtime to Docker Desktop, podman, or colima via
`SBX_RUNTIME`, re-run P2/P3 first: a runtime whose named volumes come up
`root:root` would need the `gosu` privilege-drop entrypoint after all.

**P5 — `docker ps` JSON field shape.** `docker run -d --name sbx-probe-ls
--label sbx=1 sbx:latest sleep 60` then `docker ps -a --filter label=sbx=1
--format '{{json .}}'`:

```json
{"Command":"\"/usr/local/bin/sbx-…\"","CreatedAt":"2026-07-21 22:04:01 -0400 EDT","ID":"7bff6bab0ce1","Image":"sbx:latest","Labels":"sbx=1","LocalVolumes":"0","Mounts":"","Names":"sbx-probe-ls","Networks":"bridge","Platform":null,"Ports":"","RunningFor":"Less than a second ago","Size":"220kB (virtual 799MB)","State":"running","Status":"Up Less than a second"}
```

Fields are the standard Docker CLI JSON keys, all present: `Names` (plural,
comma-joinable — here a single name), `Image`, `State` (string, e.g.
`"running"`), and `Status` (human string, e.g. `"Up Less than a second"`).
**`.State` exists** as documented — Task 5's parser can rely on `.State`
directly with `.Status` as a fallback/display string; no field-name surprise
here (unlike the wslc `PascalCase`-int-enum case above — Docker's own CLI
format matches its own docs).

**P6 — macOS Local Network permission gates ALL LAN access from the sandbox.**
Discovered 2026-07-22 while verifying `--ssh` against the NAS. The sandbox runs
on OrbStack's isolated `192.168.215.0/24` network and reaches the LAN only
through OrbStack's NAT. macOS gates that path per-app via the **Local Network**
privacy permission (System Settings → Privacy & Security → Local Network). Until
OrbStack is granted it, the container has **working internet egress but every
LAN host times out on every port**.

Confirmed live: `git ls-remote origin` against the NAS
(`user@nas`, `a LAN address`, ssh port 2xxxx) timed out from
inside the sandbox while public internet was reachable and DNS resolved the NAS
name fine. Approving the OrbStack Local Network dialog on the Mac desktop fixed
it immediately — **no config change of any kind**.

Two things make this expensive to diagnose:

1. **The symptom impersonates an SSH problem.** It looks like a wrong port, a
   missing/ill-permissioned key, or a dead NAS. It is none of those —
   `~/.ssh/config` (`Port 2xxxx`), the ed25519 key, and `known_hosts` are all
   provisioned into the container correctly by the `--ssh` entrypoint.
2. **The prompt is invisible over SSH.** Driving this Mac from a Termius/SSH
   session means the macOS permission dialog sits unanswered on a GUI desktop
   nobody is looking at, so the only observable signal is a timeout.

**Triage rule:** if a remote is unreachable from a sandbox, first check whether
*any* LAN port answers while the public internet works (e.g. `nc -zv <nas> 2xxxx`
inside the container vs. on the host). If the host connects and the container
does not, it is the Local Network permission — go approve the GUI prompt. Do
**not** "fix" it by editing ssh config or adding a `ProxyJump` through the host;
that would route the sandbox's traffic through the host and undercut the very
isolation sbx exists to provide.

## Reparse points and live mounts inside wslc bind mounts (unified-workspace probes)

Probed 2026-07-22 on Windows (wslc **2.9.4.0** — note: WSL auto-updated from
2.9.3.0, on which all earlier findings in this file were measured; re-verify
2.9.3-era quirks like the volume-mount ceiling before relying on them) for the
unified-workspace design.
Host workspace dir bind-mounted at `/work` with the standard forward-slash
Windows path form.

**NTFS junctions and directory symlinks inside a bind-mounted dir are BROKEN
in the container.** Both a junction (`New-Item -ItemType Junction`) and a
directory symlink (`New-Item -ItemType SymbolicLink`, Developer Mode, no admin)
pointing at a host dir *outside* the mount surface inside the container as
**zero-length dangling symlinks**; traversal fails with `Operation not
permitted`. wslc does not resolve reparse points server-side (no drvfs-style
Windows-side resolution). Conclusion: **"symlink projects into a mounted
workspace" cannot work** — matching the macOS/Linux bind-mount behavior where
symlink resolution happens client-side in the container namespace. Any live
add/remove scheme must put *real* directories in the workspace.

**Real directories created under the mount AFTER container start appear live.**
With a container already running against the workspace mount, a new real dir +
file created host-side was immediately visible via `wslc exec` (no restart), was
readable, and a file `touch`ed from inside the container appeared host-side.
Live add/remove of real dirs works in both directions.

**The junction-back trick (host-side) still works.** Windows junctions are
resolved by NTFS for *host* accessors, so moving a repo into the workspace and
leaving `~/src/<name>` as a junction pointing at it keeps host editors, host
git, and absolute host paths working. Only the *container-side* view of reparse
points is broken, and the container sees the real dir directly. This asymmetry
is what the unified-workspace `sbx add`/`sbx rm` design is built on.

## wslc `exec -it` / `start` (unified-workspace probes, 2.9.4.0)

Probed 2026-07-22 against a detached container anchored by `sleep infinity`
(`wslc run -d --name sbx-probe-main -v sbx-claude-auth:/home/agent/.claude
sbx:latest sleep infinity`).

- **`wslc exec` supports `-i`/`-t`** (per `--help` and live use); also `-d`,
  `-e`/`--env-file`, `-u`, `-w`. **`wslc start` exists**, with `-a`/`-i`.
- **Interactive TTY through `exec -it` is fully functional** (human-verified
  in a real Windows Terminal window): `wslc exec -it sbx-probe-main tmux
  new-session -A -s probe -c /tmp bash` renders the tmux UI, honors `Ctrl-b d`
  detach, re-attaches to the same session on re-run (`-A`), and redraws on
  window resize. This is the primitive the v2 attach model
  (`Build-SbxAttachArgs`) is built on.
- **stop → start → exec round-trip works**: after `wslc stop` + `wslc start`,
  `wslc exec sbx-probe-main sh -c "echo alive"` prints `alive`. (tmux sessions
  do not survive the cycle — expected; the anchor process restarts fresh.)

## tmux + POSIX locale renders every non-ASCII glyph as "_"

Found live in the v2 verification run (checklist item 2): claude inside a tmux
session showed underscores in place of its logo art, warning glyphs, and
status-line characters. Cause: debian-slim leaves `LANG` unset (`locale` in
the container: `LANG=`, `LC_CTYPE="POSIX"`), and tmux draws any character not
representable in the current locale as `_`. v1 never showed this because
claude ran without tmux in the middle. `C.utf8` ships with glibc — no
`locales` package needed — so the fix is just `ENV LANG=C.UTF-8
LC_ALL=C.UTF-8` in the Sandboxfile. (Same image change sets
`DISABLE_AUTOUPDATER=1`: the root-owned npm prefix made in-container
self-update fail noisily on every start; updates come from image rebuilds.)

## Silent tool degradation in slim images: no procps, no anonymous volumes

Two more from the v2 verification run:

- **debian-slim ships no `ps`.** sbx-agent-status.sh's process-tree claude
  detection ran its one `ps` call with stderr suppressed, got an empty
  table, and reported every live claude session as `shell` — no error
  anywhere. It worked on the droplet (procps installed) and silently
  degraded in the container. Fixed by adding `procps` to the image and a
  loud `command -v ps` guard in the script. Rule: when a script's data
  source can be absent, guard for it — `2>/dev/null` on the data call turns
  a missing dependency into wrong-but-plausible output.
- **wslc rejects anonymous volumes** (`-v /container/path` →
  `E_INVALIDARG: Expected format: <host path | named volume>:<container
  path>[:mode]`). Docker's anonymous-volume idiom is not available; the
  scratch throwaway projects volume is a named `<container>-proj` volume
  reaped in the cleanup path instead.

## Self-hosting probes: pwsh-on-slim needs libicu; Junction on Linux is a silent no-op

Two from adding pwsh+Pester to the image (in-container test runs for
self-hosted sbx development):

- **pwsh SIGABRTs at startup on debian-slim without ICU.** The GitHub-release
  tarball extracts fine, then `pwsh -Command …` dies `Aborted (core dumped)`
  (exit 134) in `UnmanagedPSEntry.Start` — .NET globalization needs libicu,
  which slim omits. Fix: `libicu72` in the apt layer (chosen over
  `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` so in-container string semantics
  match the hosts). Also: Microsoft's apt repo is x64-only — arm64 must use
  the release tarball.
- **`New-Item -ItemType Junction` on Linux silently creates a PLAIN
  DIRECTORY** — no error, even with `-ErrorAction Stop`; discovered when the
  in-container suite ran `New-SbxLink`'s Windows branch and every link
  assertion failed with `LinkType = $null`. `New-SbxLink` now branches on
  `$IsWindows` (junction) vs everything else (symlink) instead of `$IsMacOS`.

## PowerShell refuses to move/remove the session's current directory

Found live in the macOS acceptance run: `sbx add ~/src/mac-demo` from a shell
sitting INSIDE that repo fails with `Cannot move item because the item at
'…' is in use.` This is PowerShell's FileSystemProvider guarding the
session's current location (and anything containing it) — it fires even on
Unix, where a bare `rename(2)` of a process's cwd would succeed. Since
adding the repo you're standing in is the most natural `sbx add` flow, the
launcher now steps out to the source's parent, performs the move+link, and
returns to the same logical path (which then resolves through the new
link, so the prompt never appears to move). `Invoke-SbxOutsidePath` wraps
both `add` and `rm` mutations.

## PowerShell appends \r\n when piping a string to a native command

Found live via `sbx status` (checklist item 9): after correct output, bash
reported `line 64: $'\r': command not found` — one line past the 63-line
script. The piped body was CRLF-normalized, but PowerShell terminates a
string piped into a native command with the PLATFORM newline (`\r\n` on
Windows), handing bash a trailing line containing a lone `\r`. Fix in
`Get-SbxStatusScriptBody`: end the body with `exit 0` so bash exits before
reading past the real script. Remember this for ANY future "pipe text into a
container shell" path on Windows.

## Volume-mount ceiling FIXED in 2.9.4.0

Re-checked 2026-07-22 during the v2 verification run (checklist item 10): 16
consecutive `wslc run --rm -v …` mount operations in one WSL session — on top
of ~10 prior mounts from probes/rebuilds that session — all succeeded with no
"Too many volumes (limit: 15)" error. The 2.9.3.0 ceiling (see "wslc
volume-mount ceiling" above) is gone in 2.9.4.0, matching the error message's
"will be fixed in a future release" promise. The WSL-service-restart
workaround is no longer needed; the earlier section is retained as history.

## P7 — c-heavy sync: container→host sshd callback is viable (Windows + macOS)

Probed 2026-07-23 on Windows (wslc **2.9.4.0**, Win32-OpenSSH) AND macOS
(OrbStack, Remote Login), via `probes/probe-host.ps1` (see
`docs/probes/c-heavy-sync-probes.md`). The Windows half rests on wslc-specific
transport behavior — the bridge gateway, the absent `host.docker.internal` — so
the version matters here more than most: re-measure it after a preview bump
rather than assuming this section still holds.
**Verdict: GO on both** — the SSH forced-command callback works end to end and
the security invariants hold. Windows details below; macOS notes further down.

Full matrix passed: reachability; dedicated key accepted + forced command
fired; `push`/`pull`/`fetch` each ran host-side git (`Everything up-to-date`
/ `Already up to date.` / `sbx-sync-exec: OK`); and every validator negative was
refused — `clone` (verb), `push --force` (extra token), `../secret` (traversal),
`ghost` (not in workspace), `; sh` (extra token).

**Correction (2026-07-24), forwarding.** The original run also recorded "`-L`/`-D`
forwarding killed by `restrict`", and that evidence does not hold: the harness
wrote `-L …` *inside* the quoted remote command, where ssh never parsed it as an
option, and then asserted the absence of a string that only appears under `-v`.
The check could not fail. Two things follow. First, a bare `-L` is not refusable
at request time anyway — a local forward is a client-side listener until traffic
flows through it, so `-R` (which needs a server-side `tcpip-forward` request) is
the testable direction. Second, the underlying property is almost certainly
intact: `restrict` implies `no-port-forwarding`, which OpenSSH applies to both
directions. The harness now tests it with `-R` and asserts the refusal; treat
forwarding as **argued from `restrict` semantics, re-measured on the next probe
run** rather than as measured on 2026-07-23. Everything else in P7 stands.

**Reachability.** The container reached host sshd over the host's **Tailscale**
address (`100.x`); an earlier run also reached it via the **WSL vEthernet
gateway** `172.20.240.1` (got to publickey auth). Refused/timed-out: the wslc
bridge gateway `172.17.0.1`, the LAN IP `192.168.1.x` (refused — sshd not
answering the container on the LAN adapter, a *good* sign for isolation), the
router, and `host.docker.internal` (wslc does not inject it). **Auto-discovery
of the host address is unreliable** — `/proc/net/route` yields the wslc bridge
gw, not the host — so the build should let the user pin the address (the WSL
gateway is the clean host-only path; prefer it over Tailscale).

**Key placement.** The host account is a local Administrator, but
`C:\ProgramData\ssh\administrators_authorized_keys` does **not exist** and
sshd reads the per-user `~/.ssh/authorized_keys` (the existing ECDSA key there
authenticates). So the `administrators_authorized_keys` quirk did not bite
here — but note the auto-detector would target that (nonexistent) file for an
admin account, so the per-user file had to be pinned with `-AuthorizedKeysFile`.
Do NOT "fix" this by creating `administrators_authorized_keys`: once it exists
it takes precedence for admins and can lock out normal logins.

**macOS (OrbStack) — also GO (2026-07-23).** Same harness (`probe-host.ps1` is
cross-platform), same full-matrix pass. macOS-specific notes for the build:
- Reachability is via **`host.docker.internal`** (OrbStack provides it, unlike
  wslc). The OrbStack bridge gateway `192.168.215.1` (the mac host) *refused*
  port 22 from the container — sshd wasn't answering on that interface — so
  `host.docker.internal` is the path to use. Local Network permission (P6) must
  be granted or every attempt silently times out.
- The forced command must invoke pwsh via the **Homebrew env wrapper**
  `/opt/homebrew/bin/pwsh`, NOT the resolved Cellar apphost
  (`/opt/homebrew/Cellar/.../libexec/pwsh`), which fails "missing runtime" in
  sshd's minimal environment. (Get-Command resolves through the wrapper, so the
  probe pins the unresolved bin path.)
- Per-user `~/.ssh/authorized_keys` is read directly — no admin-file quirk.

**Two harness bugs found the hard way (both fixed; relevant to the build):**
1. **authorized_keys newline merge.** Appending our entry to a file whose last
   line had no trailing newline MERGED it onto the prior key — the old key
   stayed valid (longer comment), ours vanished → `Permission denied
   (publickey)` with no obvious cause. Any code that appends to authorized_keys
   must ensure a separating newline first.
2. **Teardown data loss.** The first harness version rewrote authorized_keys by
   line-filtering, which blanked a user's real key. Fixed to snapshot the exact
   bytes (+ a `.bak` sidecar) before writing and restore verbatim. Never
   line-edit a file that may hold real keys.

**LAN exposure (probe #4) — resolved with nuance, not a blocker.** Checked
2026-07-23: the Windows host's sshd IS reachable from a second LAN device (the
Mac) at its `192.168` address. That is fine *for this deployment*, because the
host already runs sshd for the owner's own use — c-heavy does not introduce the
listening server or its LAN exposure, it rides on the existing one. The
roadmap's "firewall sshd away from the LAN" concern applies to the different
case where sshd is stood up *solely* for the callback. What matters is that
c-heavy does not WIDEN exposure: the dedicated key is `restrict,command=`-pinned,
so reaching the port with that key yields only the three git verbs on workspace
repos — no shell, no forwarding — regardless of who can reach it. So probe #4's
real question is "does c-heavy widen exposure beyond the existing sshd?" →
**no**, not "is sshd unreachable from the LAN" (which contradicts the owner
already using it). Separate, pre-existing hygiene item (independent of c-heavy):
a `Failed password` line in the log suggests `PasswordAuthentication` may be on;
a LAN-reachable sshd should prefer key-only auth.

## P8 — c-heavy build: the SSH allowlist is not the whole boundary; host-side git is

Found 2026-07-24 while building c-heavy (ROADMAP item 1). P7 probed the *SSH*
surface and it held. What P7 never exercised is what happens **after** the
validator says OK: `git -C <workspace repo> <verb>` runs on the host, inside a
repository the agent can write. git is not a passive file format — it executes
programs named by `.git/hooks/*` and by a long tail of config keys.

Demonstrated on this repo's own rig, all three before mitigation:

1. **Hooks = host RCE.** An agent-written `.git/hooks/pre-push` ran host-side as
   the host user on `sbx sync push`. No config key involved — `.git/hooks/` is
   the default path. This is the big one.
2. **Config = host RCE.** A repo-local `core.sshCommand` ran on fetch. The same
   shape exists for `credential.helper`, `filter.*.clean`, `merge.*.driver`,
   `remote.*.receivepack`, `diff.*.textconv`, `sequence.editor`, `gpg.program`, …
3. **Symlink escape.** The old direct-child guard used `(Get-Item $dir).Parent`,
   which for a *symlink* in the workspace is the workspace — so a link planted by
   the container (which has the workspace mounted read-write) passed the check and
   aimed host git at any directory on the host.

**This was never c-heavy-only.** (1) and (2) apply to shipped c-lite as well: an
agent plants the hook and waits for the human to run `sbx sync` themselves.
c-heavy changes it from "agent can set a trap" to "agent springs it on demand".

Fixed:
- `Get-SbxGitHardeningArgs` — command-line `-c` pins on every sync:
  `core.hooksPath` → an empty host-side dir, plus `core.fsmonitor`,
  `protocol.ext.allow`, `protocol.file.allow`, `core.sshCommand`, `gpg.program`,
  `core.editor`, `core.askPass`, and a reset of the multi-valued
  `credential.helper` list — plus `--no-pager`, which is the pager's pin: `cat`
  doesn't exist on Windows, so `-c core.pager=cat` isn't portable.
  **Raceless** — command-line config outranks every
  file and the container can't edit our argv. Where the host legitimately sets one
  of these, the value is read from global/system scope and re-pinned, so hardening
  costs the user nothing.
- `Get-SbxUnsafeGitConfig` — refuses a repo whose local/worktree config sets an
  exec key whose name can't be pinned in advance (arbitrary middle segment).
  **Advisory only**: the container can rewrite `.git/config` between our read and
  git's. Recorded as a speed bump, not a boundary.
- `Resolve-SbxSyncRequest` now rejects any workspace entry that is a link. `sbx
  add` only ever creates real directories in the workspace (the link it leaves
  points the other way, at the origin), so nothing legitimate is refused.

Verified after the fix: the pre-push hook stays on disk and executable, the push
succeeds, and the hook does not fire.

**Residual, documented in `docs/SYNC.md` rather than papered over:** the denylist
is racy and a denylist can miss a key; and `push` sends wherever
`remote.origin.url` points, which the agent also controls — so c-heavy means an
agent can push repo contents to a remote of its choosing. That last one is
inherent to autonomous sync, not a transport bug: it *is* the review gate the
feature deliberately gives up.

**Method note worth keeping:** the probe pass asked "is the transport viable?"
and answered it well. It did not ask "what does the thing at the far end of the
transport execute?" When probing a hole shaped like a command allowlist, probe
the *program the allowlist calls*, not just the allowlist.

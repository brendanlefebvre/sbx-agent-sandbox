# Sync: getting commits out of the sandbox

sbx ships two ways to move commits between a workspace repo and its remote. They
run the *same* host-side git through the *same* validator; they differ only in
**who is allowed to pull the trigger**.

| | **c-lite** (default) | **c-heavy** (opt-in, `sbx sync-setup`) |
|---|---|---|
| Who runs it | you, on the host | an agent, from inside the sandbox |
| Command | `sbx sync <name> <op>` | `sbx sync [<name>] <op>` in the container |
| Container holds a key | no | yes — a dedicated one, pinned to a forced command |
| Review gate | **yes** — nothing leaves without you | **no**, deliberately surrendered |

c-lite is on by default and needs no setup. Everything below is c-heavy.

## What c-heavy actually grants

The container gets a dedicated ed25519 keypair. Its line in the host's
`authorized_keys` is pinned:

```text
restrict,command="pwsh -NoProfile -File /path/to/sbx-sync-exec.ps1 -WorkspaceDir /Users/you/sbx-ws" ssh-ed25519 AAAA… sbx-sync
```

`restrict` removes pty, agent forwarding, X11 and **port forwarding** (`-L`/`-D`
would otherwise be a tunnel around the whole design). `command=` means a
connection with that key runs *only* `sbx-sync-exec.ps1`, whatever the client
asks for — the request survives as `SSH_ORIGINAL_COMMAND`, which the validator
requires to be exactly two tokens, `<project> <push|pull|fetch>`.

So the key buys three verbs against direct children of the workspace. It does not
buy a shell, other repos on the host, or the reach of your own SSH keys — which
is why agent-socket forwarding stays rejected (ROADMAP: it would grant the keys'
full authority).

## Setup

### 1. A host sshd the container can reach

**Windows (Win32-OpenSSH)**

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd; Set-Service sshd -StartupType Automatic
```

`pwsh` and `git` must be on the PATH sshd hands the session.

If your account is in local **Administrators**, the stock `sshd_config` has a
`Match Group administrators` block redirecting to
`C:\ProgramData\ssh\administrators_authorized_keys`. `sbx sync-setup` writes
there **only if that file already exists**, and never creates it — creating it
takes precedence for every admin from then on and can lock you out. If the file
exists it must be ACL'd to Administrators + SYSTEM only, or sshd ignores it
silently:

```powershell
icacls "$env:ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
```

**macOS (Remote Login)**

System Settings → General → Sharing → **Remote Login** on. Then grant your
container runtime the **Local Network** permission (System Settings → Privacy &
Security → Local Network → OrbStack): without it every connection from the
container times out and looks exactly like an SSH failure (FINDINGS P6).

### 2. Find the address the *container* should dial

There is no reliable auto-discovery (FINDINGS P7) — pin it yourself:

- **Windows:** the WSL vEthernet gateway, e.g. `172.20.240.1`. Prefer it: it's a
  host-only path. (A Tailscale `100.x` address also worked; the wslc bridge
  gateway `172.17.0.1` and `host.docker.internal` did **not**.)
- **macOS:** `host.docker.internal`. (The OrbStack bridge gateway
  `192.168.215.1` refused port 22.)

### 3. Provision

```powershell
sbx sync-setup --address 172.20.240.1     # --user/--port if they differ from your login/22
sbx rebuild                                # so sbx-main picks up the key mount
```

That generates `~/.sbx/sync/id_sbx_sync`, installs the pinned `authorized_keys`
line (backing the file up to `<file>.sbx.bak` first), and writes
`~/.sbx/sync/sync.conf`. Re-running replaces the line rather than stacking
duplicates, and reuses the existing keypair.

Useful flags: `--print-only` emits the line for you to paste instead of writing
it; `--authorized-keys <path>` forces which file to write; `--remove` revokes —
it drops the line and destroys the key material.

### 4. Use it

Inside the sandbox, from a project directory:

```text
agent@sbx-main:/work/myrepo$ sbx sync push
sbx-sync-exec: RUN myrepo push
sbx-sync-exec: OK myrepo push
```

The project defaults to the one containing your cwd; `sbx sync <name> <op>`
names another. Every other `sbx` verb is host-side only.

Three status lines, all on stderr, all single-line by design — an agent can
branch on them without parsing a stack trace:

| Line | Means |
|---|---|
| `RUN <name> <op>` | validated; the git operation is starting |
| `OK <name> <op>` | the git operation **completed successfully** |
| `REJECT <reason>` | the validator refused; nothing ran |
| `FAILED <message>` | it started and did not finish (git exited non-zero, the lock timed out, or the config check refused the repo) |

`RUN` without a following `OK` or `FAILED` means the connection died mid-operation
— distinguishable from a key that never got in, which produces no line at all.
Exit status is `0` / `2` / `3` for OK / REJECT / FAILED.

## Troubleshooting

The failure mode tells you where to look:

| Symptom | Cause |
|---|---|
| `Connection timed out` / `refused` | routing or sshd — wrong address, or (macOS) missing Local Network permission |
| `Permission denied (publickey)` | the key landed in a file *this* sshd doesn't read, or the ACL is wrong — not a reachability problem |
| key accepted, no `sbx-sync-exec:` line | the host can't launch pwsh in sshd's minimal environment (macOS: the Homebrew *wrapper* `/opt/homebrew/bin/pwsh`, not the Cellar apphost) |
| `RUN` but no `OK`/`FAILED` | the connection died mid-operation; the git op may have completed host-side |
| `REJECT` | the validator refused the request; the reason is on the line |
| `FAILED` | the validator accepted, git or the config check failed |

`probes/probe-host.ps1` re-runs the whole matrix end to end against the shipped
validator — the fastest way to qualify a new host (see
`docs/probes/c-heavy-sync-probes.md`).

## Security model, and its limits

**Read this before enabling c-heavy on a machine where host compromise matters.**

The SSH surface is tight and was probed end to end (FINDINGS P7): the three verbs,
the workspace-child guard, and every negative (extra args, traversal, non-workspace
repo, shell, forwarding) hold.

The **git** surface is the harder half, and it is not the SSH layer's problem.
Host-side git runs *inside a repository the agent can write*, and git is not a
passive file format — it executes programs named by `.git/hooks/*` and by a set
of config keys. Verified on this repo's own rig: without mitigation an
agent-written `.git/hooks/pre-push` runs **on the host, as you**, the moment a
push is triggered, and a repo-local `core.sshCommand` does the same on fetch.
That is host code execution, and it applies to c-lite too — an agent could plant
the hook and wait for you to run `sbx sync` yourself.

What sbx does about it, in two tiers that are *not* equally strong:

1. **Raceless pins.** Every sync runs git with command-line `-c` overrides:
   `core.hooksPath` aimed at an empty directory (this is the big one —
   `.git/hooks/*` fires with no config key at all), plus `core.fsmonitor`,
   `protocol.ext.allow`, `protocol.file.allow`, `core.sshCommand`, `gpg.program`,
   `core.editor`, `core.askPass`, and a reset of the multi-valued
   `credential.helper` list. The pager is suppressed with `--no-pager` rather
   than a `-c core.pager=` pin — there is no portable no-op value, since `cat`
   doesn't exist on Windows — which outranks config just the same. Command-line
   config outranks every config file and
   the container cannot edit our argv, so these hold. Where you legitimately
   configure the same key, sbx reads your **global/system** value and re-pins it,
   so hardening never costs you your own setup.
2. **An advisory denylist.** Before running, sbx reads the repo's local +
   worktree config and refuses if it sets a key git would execute whose name it
   can't pin in advance (`filter.*.clean`, `diff.*.textconv`, `merge.*.driver`,
   `remote.*.receivepack`, …). This is a **speed bump, not a boundary**: the
   container can rewrite `.git/config` between our read and git's. It catches
   accidents and lazy attacks.

Residual risk, stated plainly:

- The denylist is racy (above), and a denylist can miss a key.
- `push` sends wherever `remote.origin.url` points, and the agent controls that
  file. c-heavy means an agent can push your repo's contents to a remote of its
  choosing. This is inherent to autonomous sync, not a bug in the transport —
  it is the review gate you gave up.
- The key is unencrypted on disk under `~/.sbx/sync`, by necessity. Its authority
  is bounded by the forced command, not by secrecy.

Concurrency is handled: syncs of the same project serialize on a host-side lock
under `~/.sbx/locks` (outside the workspace, so the container can't touch it), so
several agents pushing at once queue instead of colliding on git's index locks.

If that trade isn't one you want on a given machine, don't run `sync-setup` —
c-lite remains the default and the container holds no key at all.

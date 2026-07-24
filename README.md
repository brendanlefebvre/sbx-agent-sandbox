# sbx

Run `claude --dangerously-skip-permissions` inside a shared sandbox container
(`wslc` on Windows, `docker` on macOS) whose only writable host surface is the
projects you've explicitly added to its workspace.

Skipping permission prompts is what makes agents actually autonomous — and what
makes them dangerous, so the container puts a hard boundary around the worst
case: a rogue command can wreck the added projects (each git-recoverable) and
nothing else. One shared workspace rather than one sandbox per repo is the
point, not a convenience: agents that can see every project at once can work
*across* them — the substrate for climbing from single-agent coding toward
orchestrated fleets.

## Install

    wslc build -t sbx:latest -f Sandboxfile .   # build the image (once)
    wslc volume create sbx-claude-auth          # create the auth volume (once)
    # log in once — see docs/LOGIN.md
    pwsh -File install.ps1                        # wire sbx into $PROFILE + user PATH
    # open a NEW shell; `sbx` then works from PowerShell AND cmd.exe

PowerShell uses an in-session function; cmd.exe uses the `sbx.cmd` shim on PATH.

### macOS (Docker)

    brew install powershell                       # pwsh runtime for the launcher
    docker build -t sbx:latest -f Sandboxfile .   # build the image (once)
    docker volume create sbx-claude-auth          # auth volume (once)
    # log in once — see docs/LOGIN.md
    pwsh -NoProfile -File install.ps1             # drops an `sbx` shim into ~/.local/bin
    # ensure ~/.local/bin is on your PATH, then open a new shell

macOS is **foreground-only** (no new-window/tab): every `sbx` invocation runs in the
current terminal. Run several sessions side by side by opening several terminal/tmux
panes. `--new-window`/`--window`/`--win` and `--tab` are rejected on macOS; foreground
is the default (and only) mode there.
Developed and verified against **OrbStack**'s `docker` CLI; set `SBX_RUNTIME` to use
podman/colima/Docker Desktop instead (see `docs/FINDINGS.md` — the volume-ownership
result that lets us ship an unmodified image was only measured on OrbStack).

> **Troubleshooting — LAN/NAS unreachable from the sandbox.** If the container has
> working internet but *every* LAN host times out on *every* port (e.g. `git ls-remote`
> against a NAS hangs), it is almost certainly macOS's **Local Network** privacy
> permission, not SSH. Grant it to your container runtime in System Settings → Privacy
> & Security → Local Network. If you're driving this Mac over SSH, the prompt may be
> sitting unanswered on the GUI desktop. Details: `docs/FINDINGS.md` (P6).

## Usage

sbx v2 is a **unified workspace**: one long-lived container (`sbx-main`) holds every
project you've added, instead of a fresh throwaway container per repo.

| Invocation             | Behavior                                                                                       |
| ----------------------- | ----------------------------------------------------------------------------------------------- |
| `sbx add <path>`        | Move the repo into the workspace; leave a junction/symlink at the original path. Live — no restart. |
| `sbx <name>`            | Current terminal (foreground) attached to tmux session `<name>` at `/work/<name>`, running `claude --dangerously-skip-permissions`. Starts `sbx-main` if stopped. Add `--new-window` for a separate WT window (Windows only). |
| `sbx`                   | Same, for the `hub` session at `/work` (cross-project orchestration vantage point).             |
| `sbx ls`                | Workspace projects: name, original host path, whether a tmux session is live.                   |
| `sbx rm <name>`         | Kill the project's tmux session; move the repo back to its origin; remove the link.              |
| `sbx sync <name> <op>`  | **Host-side** git `push`/`pull`/`fetch` in the project's workspace dir, with host credentials.   |
| `sbx sync-setup --address <addr>` | Opt in to **c-heavy**: provision the container's dedicated key so agents can trigger those same three verbs themselves. `--print-only`, `--remove`. See `docs/SYNC.md`. |
| `sbx rebuild`           | Confirm, then destroy and recreate `sbx-main` from `sbx:latest` (workspace/history survive).     |
| `sbx stop`              | Stop the `sbx-main` container.                                                                    |
| `sbx status`            | One-glance fleet view: per tmux window, idle time, claude liveness, live status line (stalest first). `SBX_IDLE_WARN=<min>` flags stale sessions. See `docs/sbx-agent-status.md`. |
| `sbx scratch`           | v1-style: fresh `--rm` container, auth volume only, no workspace.                                |
| `--new-window` / `--window` / `--win` | Spawn a separate WT **window** instead of running in the current terminal (Windows only — an 'unsupported' error elsewhere). Only apply to `sbx <name>`/`sbx` (attach) and `sbx scratch` — silently ignored on every other subcommand. |
| `--tab`                 | Spawn a new WT **tab** instead of running in the current terminal (Windows only). Same scope as `--new-window`. |

Retired from v1: `sbx <path>` (per-repo container — run `sbx add <path>` once, then
`sbx <name>`), `--ssh`, `--name`, per-repo `sbx-proj-*` history volumes, and
per-container `sbx stop <name>` (there's one container now; `sbx rm <name>` removes a
project, `sbx stop` stops `sbx-main`).

Also retired: `--here`. Foreground is now the **default** on every platform, so an SSH
session never needs a flag — use `--new-window` (`--window`/`--win`) on Windows to opt
into a separate WT window instead.

### The workspace and the junction-back trick

`sbx add <path>` moves the repo into a single host **workspace dir** — default
`~/sbx-ws`, override with `SBX_WORKSPACE` — which is the only thing bind-mounted into
`sbx-main`, at `/work`. A junction (Windows, via `New-Item -ItemType Junction`, no admin
needed) or symlink (macOS) is left at the original path pointing at the new workspace
location, so `~/src/<repo>` keeps working for host editors and host `git`. The move-back
target is recorded in a host-side manifest, `~/.sbx/origins.json` — outside the
workspace, so the container can never influence where `sbx rm` sends a repo back to.
`sbx rm <name>` reverses all of it: kills the project's tmux session, moves the real
directory back to its origin, and removes the link.

Junctions/symlinks do **not** resolve *inside* the container (see `docs/FINDINGS.md`) —
the container only ever sees the real directory under `/work`, live in both directions,
with no restart needed for `add`/`rm` to take effect.

### Sessions

`sbx-main`'s anchor process is `sleep infinity`, not tmux — sessions are created on
demand so the container doesn't die when the last one closes. Each project gets its own
**tmux session** named after the project, created on first `sbx <name>` and reattached on
every later one. A **`hub` session** at `/work` (plain `sbx`, no name) is the
cross-project vantage point for orchestration. Two terminals attached to the same tmux
session mirror each other — one terminal per session, many tmux windows within it, is the
intended flow.

### Working the fleet

The hub is more than an observability perch — it has three levers, today, with no
extra machinery:

1. **The shared filesystem.** The hub sits at `/work` with every added project
   writable. For cross-project work (a refactor spanning two repos, moving code
   between them), the hub agent just does it directly — the filesystem *is* the
   communication channel.
2. **Its own subagents.** The hub's claude can fan out parallel workers with its
   Task tool and get results back in its own context. For "orchestrate a few
   things at once," reach for this first: structured, no plumbing.
3. **tmux as a bus.** Every session lives in the tmux server the hub runs inside,
   so the hub can spawn a worker session
   (`tmux new-session -d -s foo -c /work/foo claude --dangerously-skip-permissions`),
   type into it (`tmux send-keys -t foo "…" Enter`), and read its screen
   (`tmux capture-pane -t foo -p`). You can `sbx foo` from the host and attach to a
   session the hub started. Powerful but brittle — it's driving a TUI blind; the
   roadmap's status-hooks item is the structural fix.

In-container observability: the hub can run the status script directly if the
sbx-dev clone is in the workspace (`/work/sbx-dev/sbx-agent-status.sh`); host-side,
`sbx status`.

**Suggested pattern:** live in the hub and let it use subagents for cross-project
work; promote a workstream to its own `sbx <name>` session only when it's
long-running and independent; peek with `sbx status`.

**Hazard:** the hub and a project session share the same working tree — two agents
editing one project simultaneously is two agents in one checkout. Manage it with
discipline for now; `sbx add --clone` (roadmap) is the structural fix. What's
deliberately missing at this rung — structured messaging, a task queue, reliable
blocked/done signals — is the stage-8 material in `docs/ROADMAP.md`.

### Sync: agents commit, human pushes

By default the container never holds SSH keys or git credentials.
`sbx sync <name> push|pull|fetch` runs the git operation **host-side**, in the project's
workspace directory, with your host credentials — exactly those three verbs, nothing
wider. Agents inside the sandbox can commit freely; only a host-side `sbx sync` moves
anything to or from a remote, which is a deliberate review gate on everything leaving
the machine.

**Opting out of the gate (c-heavy).** `sbx sync-setup --address <addr>` gives the
container a *dedicated* key whose `authorized_keys` line is pinned
`restrict,command="…sbx-sync-exec.ps1…"`, so agents can trigger those same three verbs
on workspace repos themselves — and nothing else: no shell, no forwarding, no reach for
your own keys. Read `docs/SYNC.md` first. It covers host sshd setup per platform, and
the part that isn't obvious: host-side git runs *inside a repo the agent can write*, and
git executes hooks and config-named programs. sbx pins those off with raceless
command-line config, but the residual risk is real and documented there. c-lite stays
the default; `sbx sync-setup --remove` revokes.

### Blast radius

Every project currently added to the workspace is writable by every session in the
container at once — wider than v1's "exactly one mounted repo," accepted in exchange for
cross-project orchestration. Each project stays git-recoverable, and adding a repo is an
explicit act of exposure. Unchanged from v1: no path from the container to the host OS or
to any repo that hasn't been added; no SSH keys in the container **unless you opt into
c-heavy** (`sbx sync-setup`), which adds one forced-command-bounded key and its
documented trade-offs. `sbx scratch` remains the maximally-contained, no-workspace
option.

## Self-hosted development (hacking on sbx from inside sbx)

Never add `~/src/sbx` itself to the workspace: `$PROFILE` dot-sources `sbx.ps1`
from that checkout on every shell start, so a sandboxed agent editing it would be
writing code the **host** executes automatically — a review-free host-execution
path. sbx is a *privileged repo* (as are dotfiles); the workspace is not the
place for it.

Instead, work on a dev clone:

    git clone ~/src/sbx ~/src/sbx-dev
    sbx add ~/src/sbx-dev
    sbx sbx-dev          # agent iterates, runs the unit suite in-container:
                         #   pwsh -NoProfile -Command "Invoke-Pester tests"

The image ships `pwsh` + Pester for exactly this; Windows- and macOS-gated tests
skip inside the Linux container, the cross-platform core runs. Landing changes is
host-side and human-reviewed, per the sync philosophy:

    git -C ~/src/sbx fetch ~/sbx-ws/sbx-dev <branch>   # then diff, merge, push

Live-runtime integration (`verify/CHECKLIST.md`) still runs on the host — there
is no nested container runtime.

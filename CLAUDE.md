# sbx — project memory

Launcher for running Claude Code with `--dangerously-skip-permissions` inside a
throwaway sandbox container — `wslc` (WSL Containers) on Windows, `docker` on
macOS. See `docs/superpowers/specs/` for the design and `docs/superpowers/plans/`
for the implementation plan.

## Build / run
- Windows: build the image with `wslc build -t sbx:latest -f Sandboxfile .`; create the
  auth volume once with `wslc volume create sbx-claude-auth`.
- macOS: build the image with `docker build -t sbx:latest -f Sandboxfile .`; create the
  auth volume once with `docker volume create sbx-claude-auth`. The verified macOS
  runtime is **OrbStack** (its `docker` CLI); see `docs/FINDINGS.md` for what that
  scopes — notably the volume-ownership result that lets us ship an unmodified image.
- The container runtime is `wslc` on Windows / `docker` on macOS, overridable via
  `SBX_RUNTIME` (e.g. podman/colima/orbstack). The override is honored everywhere,
  including the Windows `--new-window`/`--tab` spawn modes (the runtime and its
  remove verb are baked into the spawned window's command by `Build-SbxWtBody`).
- Launcher lives in `sbx.ps1`; `$PROFILE` dot-sources it (see README / Task 10).

## Test
- Unit (pure builder fns):  `pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"`
- Integration (live container):  run `verify/CHECKLIST.md` by hand on this machine.
- After any `sbx.ps1` change or merge, open host terminals still hold the old dot-sourced
  functions — start live testing from a fresh terminal or re-dot-source `sbx.ps1` first,
  or you'll debug phantom failures.

## Conventions
- Git: feature branches `feat/<slug>`, granular commits, merge to `main` with `--no-ff`; push `main` to the `origin` sync remote. No PRs.
- All launcher logic is PowerShell 7 (`pwsh`): native Windows paths on Windows (not MSYS
  bash), absolute POSIX paths on macOS.
- `wslc` is public preview, currently **2.9.4.0** (auto-updated from 2.9.3.0 mid-project);
  treat CLI surprises as preview quirks and record them in `docs/FINDINGS.md`, which
  covers findings from both versions and flags which is which.
- Foreground (`here`) is the default on every platform, so an SSH session never needs a
  flag regardless of host OS. `--new-window` (aliases `--window`/`--win`) opts into a WT
  window and `--tab` into a WT tab — both Windows-only; on non-Windows they raise an
  'unsupported' error (for `--new-window`, deliberately "for now"). macOS is
  foreground-only: every spawn flag is rejected there.
- **Unified workspace (v2):** one long-lived container `sbx-main` holds every added
  project, not one container per repo. `sbx add <path>` moves the repo into the workspace
  dir (default `~/sbx-ws`, override `SBX_WORKSPACE`) and leaves a junction (Windows) /
  symlink (macOS) at the original path so host tooling keeps working; `sbx rm <name>`
  reverses it. The move-back target is recorded in a host-side manifest,
  `~/.sbx/origins.json` (outside the workspace, so the container can't tamper with where
  `rm` moves things). Claude session history and memory are NOT per-repo volumes anymore —
  they live in the single shared `sbx-claude-auth` volume, keyed naturally by cwd
  (`/work/<name>`) under Claude's own `~/.claude/projects` layout. Orphaned `sbx-proj-*`
  volumes from the v1 per-repo model are retired; reap them by hand
  (`wslc volume remove <name>`) and don't recreate the pattern.
- **Sync has two rungs.** *c-lite* (default): the human runs `sbx sync <name> <op>`
  host-side, no keys in the container. *c-heavy* (opt-in, `sbx sync-setup`): a
  dedicated container key pinned `restrict,command="…sbx-sync-exec.ps1…"` lets agents
  trigger the same three verbs themselves. Both go through ONE validator
  (`Resolve-SbxSyncRequest`) — never add a second allowlist. Read `docs/SYNC.md`
  ("Security model, and its limits") and `docs/FINDINGS.md` P8 before touching
  either: host-side git runs in an
  agent-writable repo and executes hooks and config-named programs, so
  `Get-SbxGitHardeningArgs` (raceless `-c` pins) is load-bearing security, not
  tidiness. Adding a verb, or dropping a pin, widens a boundary.
- Changing the in-container `sbx sync` client means changing the image
  (`Sandboxfile`) — rebuild the image and `sbx rebuild`, or you'll test the old one.

Now say: "I've reviewed the project memory."

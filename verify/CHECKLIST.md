# sbx v2 verification checklist (manual, live runtime)

Run on Windows (wslc) unless marked; re-run the mirrored items on macOS.

1. **Live add:** with `sbx` (hub) already open: `sbx add ~/src/<some-repo>`;
   in the hub session `ls /work/<name>` shows it IMMEDIATELY (no restart).
   Host-side: `Get-Item ~/src/<some-repo>` shows LinkType Junction and
   `git -C ~/src/<some-repo> status` works through the link.
2. **Session:** `sbx <name>` runs in the CURRENT terminal (foreground default)
   attached to tmux session `<name>` cwd `/work/<name>` running claude; `sbx ls`
   shows Session=True. `sbx <name> --new-window` (or `--window`/`--win`) instead
   opens a separate WT window for the same session.
3. **History isolation:** run claude briefly in two projects; `claude --resume`
   in each lists only its own sessions.
4. **rm:** `sbx rm <name>` → repo back at origin as a REAL dir, link gone,
   tmux session gone, `sbx ls` no longer lists it.
5. **rebuild:** `sbx rebuild` → container replaced; workspace intact; step-3
   histories still resumable; login still valid (no re-auth). Git identity
   survives: `git config --global --get user.name`/`user.email` inside the new
   container still return the host identity (it lives in the auth volume via
   `GIT_CONFIG_GLOBAL`, not the container layer), and a hand-set identity is not
   re-clobbered by the seed.
6. **Blast radius:** in the hub: `ls /home/agent/.ssh` absent; `/work` shows
   only added projects; no `C:` anywhere.
7. **sync:** `sbx sync <name> fetch` (NAS-remoted repo) succeeds host-side;
   `git fetch` INSIDE the container fails (no keys) — confirming c-lite.
7a. **sync options:** `sbx sync <name> fetch --prune --tags` runs (the options
   reach git, after the verb); `sbx sync <name> pull --recurse-submodules`
   behaves as plain `pull` on a repo without submodules; and
   `sbx sync <name> push --force` is refused with `option '--force' is not
   allowed for push`, git never invoked. Also `sbx --tab sync <name> push` →
   `'sync' takes no sbx options`.
8. **scratch:** `sbx scratch` → throwaway, `--rm` cleanup verified via
   `sbx ls` after exit; no `/work` inside. A SECOND consecutive scratch has an
   EMPTY `/resume` menu (per-run `<container>-proj` volume isolates it from hub
   and prior-scratch history — both key on cwd `/work`), and no
   `sbx-scratch-*-proj` volume lingers in `wslc volume list` after exit.
   **Identity (first-container case):** even with NO `sbx-main` yet, a `git
   commit` inside a scratch container attributes to the host identity, not
   "Author identity unknown" — `sbx scratch` seeds the shared `sbx-claude-auth`
   volume (one-shot `run --rm`) before launching the throwaway, so the identity
   is present the first time too. (Verify with a throwaway `git init` in `/tmp`.)
9. **Concurrency:** `sbx foo --new-window` + `sbx --new-window` (hub) windows open
   simultaneously; hub edits a file in `/work/foo`, project session sees it instantly.
10. **wslc 15-mount ceiling re-check (2.9.4.0):** after the runs above, note
    whether the "Too many volumes (limit: 15)" error still occurs on repeated
    scratch launches; update docs/FINDINGS.md either way.

## c-heavy sync (only if you ran `sbx sync-setup`)

Steps 6 and 7 above describe the DEFAULT (c-lite) posture and stay true until
you opt in. After `sbx sync-setup --address <addr>` + `sbx rebuild`:

11. **Provisioning:** `~/.sbx/sync/` holds `id_sbx_sync` + `sync.conf`; your
    `authorized_keys` gained exactly ONE line ending `sbx-sync`, and a
    `.sbx.bak` sidecar of the pre-edit file sits next to it. Any key you already
    had is byte-identical — diff against the `.bak`.
12. **Round trip:** in the sandbox, in a project with a reachable remote:
    `sbx sync fetch` prints `sbx-sync-exec: OK <name> fetch`. Then `sbx sync push`
    against a scratch branch actually lands on the remote.
13. **Name inference:** `sbx sync push` from `/work/<name>` targets `<name>`;
    from `/work` (hub cwd) it refuses and asks you to name a project.
13a. **Options over the wire:** `sbx sync fetch --prune` prints
    `sbx-sync-exec: RUN <name> fetch --prune` and then `OK` with the same suffix,
    and `sbx sync pull --rebase` works from a project dir.
14. **Negatives, from inside the container** — each must be refused, not run:
    `sbx sync clone`, `sbx sync ../secret push`, `sbx sync push --force`,
    `sbx sync fetch --upload-pack=/tmp/x`, `sbx sync fetch --depth 1` (value on a
    separate token → `same token` reason), `ssh -i ~/.ssh/id_sbx_sync
    <user>@<addr> "myrepo push --force"`, `ssh … <user>@<addr> "myrepo push; sh"`
    (the shape gate replaced the old two-token count — this must still REJECT),
    `ssh … <user>@<addr> "myrepo push origin main"`, and a bare
    `ssh … <user>@<addr>` (no shell). For forwarding use a **remote** forward,
    `ssh -R 19999:127.0.0.1:22 -i ~/.ssh/id_sbx_sync <user>@<addr> "myrepo fetch"`,
    which must report `remote port forwarding failed` / `administratively
    prohibited`. Not `-L`/`-D`: those are client-side listeners until something
    connects through them, so a bare flag can never fail and the check would pass
    whether `restrict` were there or not. `restrict` implies `no-port-forwarding`
    and covers every direction — the assertion just has to use the one direction
    the server gets a say in.
15. **Hook containment (P8):** in the container,
    `h=/work/<name>/.git/hooks/pre-push; printf '#!/bin/sh\necho HOOK-RAN >&2\n'
    > "$h"; chmod +x "$h"` — then `sbx sync push`. The push must succeed and
    `HOOK-RAN` must NOT appear. `rm "$h"` afterward.
16. **Config denylist (P8):** set the key **from the host**, not the container —
    a repo-local `git config` write fails inside the sandbox on a wslc bind mount
    (it can't chmod `config.lock`; see ROADMAP). Host-side:
    `git -C ~/sbx-ws/<name> config core.sshCommand 'sh -c id'`, then `sbx sync
    fetch` from the container → refused with a `FAILED … executes as a program`
    line naming the key. `git -C ~/sbx-ws/<name> config --unset core.sshCommand`
    afterward.
17. **Concurrency:** trigger `sbx sync push` from two sessions on the SAME
    project at once — both complete, serialized, neither reports a git index
    lock error.
18. **Revocation:** `sbx sync-setup --remove` on the host → the tagged line is
    gone (and only that line), `~/.sbx/sync` is gone; after `sbx rebuild`,
    `sbx sync fetch` in the container reports sync is not provisioned.

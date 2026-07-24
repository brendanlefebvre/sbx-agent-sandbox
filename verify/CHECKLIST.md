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
   histories still resumable; login still valid (no re-auth).
6. **Blast radius:** in the hub: `ls /home/agent/.ssh` absent; `/work` shows
   only added projects; no `C:` anywhere.
7. **sync:** `sbx sync <name> fetch` (NAS-remoted repo) succeeds host-side;
   `git fetch` INSIDE the container fails (no keys) — confirming c-lite.
8. **scratch:** `sbx scratch` → throwaway, `--rm` cleanup verified via
   `sbx ls` after exit; no `/work` inside. A SECOND consecutive scratch has an
   EMPTY `/resume` menu (per-run `<container>-proj` volume isolates it from hub
   and prior-scratch history — both key on cwd `/work`), and no
   `sbx-scratch-*-proj` volume lingers in `wslc volume list` after exit.
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
14. **Negatives, from inside the container** — each must be refused, not run:
    `sbx sync clone`, `sbx sync ../secret push`, `ssh -i ~/.ssh/id_sbx_sync
    <user>@<addr> "myrepo push --force"`, and a bare `ssh … <user>@<addr>` (no
    shell). Also `ssh -L 9999:127.0.0.1:22 …` must be refused by `restrict`.
15. **Hook containment (P8):** `printf '#!/bin/sh\necho HOOK-RAN >&2\n' >
    /work/<name>/.git/hooks/pre-push; chmod +x` it, then `sbx sync push`. The
    push must succeed and `HOOK-RAN` must NOT appear. Delete the hook afterward.
16. **Config denylist (P8):** `git -C /work/<name> config core.sshCommand
    'sh -c id'` then `sbx sync fetch` → refused with a `FAILED … executes as a
    program` line naming the key. `git config --unset` it afterward.
17. **Concurrency:** trigger `sbx sync push` from two sessions on the SAME
    project at once — both complete, serialized, neither reports a git index
    lock error.
18. **Revocation:** `sbx sync-setup --remove` on the host → the tagged line is
    gone (and only that line), `~/.sbx/sync` is gone; after `sbx rebuild`,
    `sbx sync fetch` in the container reports sync is not provisioned.

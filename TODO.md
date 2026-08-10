# TODO — pick up here

Written 2026-08-10, mid-task. Branch **`feat/sync-option-passthrough`**, 4 commits,
**not pushed**. Working tree clean; `Invoke-Pester tests` is 272 passed / 0 failed
in-container.

## What landed

Git-option passthrough for `sbx sync`, per-verb allowlist, both rungs (c-lite and
c-heavy share the one validator). Full rationale is in `docs/SYNC.md` → "Git
options" and in the commit messages; the code is `$script:SbxSyncOptions` +
`Get-SbxSyncOptionDenial` in `sbx.ps1`.

```text
38cd301 test(client): mark the fake ssh/gh executable so the suite runs off-Windows
ef8130d feat(sync): per-verb git-option allowlist for sbx sync
440fef6 feat(sync): carry git options over the c-heavy path too
f2d4d35 docs(sync): document the git-option allowlist and probe P11
```

## Blocking, before this is trustworthy

0. **Get the branch onto the host first — nothing below works without it.**
   Two *separate* copies of this code run, and the image rebuild only refreshes
   one of them:
   - the **in-container client** (`sbx-client.sh` → `/usr/local/bin/sbx`), which
     ships in the image → fixed by item 1;
   - the **host-side validator** (`sbx.ps1` + `sbx-sync-exec.ps1`), which runs
     from the host's own checkout — the one `$PROFILE` dot-sources and the one
     the `authorized_keys` forced command names by absolute path (the `prod`
     remote, `C:\Users\brend\src\sbx`). An image rebuild does **not** touch it.

   So until the branch is merged and pulled into that checkout, host-side
   `sbx sync <name> <op> --opt` still runs the OLD validator and will reject
   every option — which looks exactly like a bug in the new code. Order: land the
   branch in the prod checkout → rebuild the image → verify.
1. **Rebuild the image.** `sbx-client.sh` changed, so the in-container `sbx sync`
   is stale until `./rebuild-image.ps1` runs. Test c-heavy from a fresh terminal
   (host terminals still hold the old dot-sourced functions).
2. **Run the new checklist items** in `verify/CHECKLIST.md`: **7a** (c-lite
   options + the `sbx --tab sync` error), **13a** (options over the wire, RUN/OK
   echo), and the widened **14** negatives — `push --force`,
   `fetch --upload-pack=/tmp/x`, `fetch --depth 1`, and over raw ssh
   `"myrepo push; sh"` / `"myrepo push origin main"`. The last two are the ones
   that used to be caught by the two-token count and are now caught by the option
   shape gate; they are the regression that matters most.
3. **Re-run `probes/probe-host.ps1`** — it gained one allow case and four
   negatives for the same reason.
3a. **Expect to re-pin the sync address before any of 2/3 will run.** From inside
   `sbx-main` on 2026-08-10, the pinned `host=172.25.96.1` (`~/.sbx/sync/sync.conf`)
   **timed out** — not refused, timed out, i.e. nothing is listening at that
   address any more. The WSL vEthernet gateway moves across reboots, so this is
   the expected decay, not a regression from this branch. Fix with
   `sbx sync-setup --address <current gateway>` + `sbx rebuild`, and don't spend
   time on sshd or the ACLs until the address answers.

## Should do, not blocking

4. **Re-probe P11 on the host's git 2.52.** `docs/FINDINGS.md` P11 (does
   `pull --recurse-submodules` reach `submodule.<name>.update = !cmd`?) was
   answered on **git 2.39.5 in-container**, and it says so. Answer was no — pull
   passes `--checkout` — with a control proving the key is otherwise live. The
   key is on the advisory denylist regardless, so a different 2.52 result would
   not be a hole, but it would be worth recording.
5. **Open the PR** against `main` on the `github` remote, per the repo convention
   (rebase onto `main`, don't merge locally). NAS `origin` mirrors after merge.

## Decisions already made — don't relitigate without a reason

- `--force` / `--force-with-lease` are **out** on push (user's explicit choice: an
  agent can fetch first, which satisfies a lease).
- `--prune` is **out on push only** — it deletes remote branches over refs
  `remote.<name>.push` names, and the container writes that config. It stays on
  pull/fetch, where it only tidies local remote-tracking refs.
- `--set-upstream` is **out**: it needs the `origin <branch>` positionals the
  shape rules refuse, so it could only ever produce a confusing git error. A
  first push of a new branch still needs a host shell — **this is the known gap**
  if it turns out to bite in practice, and the way to close it is the
  "constrained positional pair" option (remote must be an already-configured
  remote *name*, refspec restricted to `[A-Za-z0-9._/-]` with one optional `:`),
  which was considered and deferred.
- The in-container client deliberately does **not** filter options. It is not the
  boundary, and a second allowlist there could drift from the host's.

## Done since this file was written

- ~~`Invoke-Client`'s unused `-Cwd` parameter~~ — **deleted** (commit below), with
  a comment recording why it can't be implemented portably: the client infers the
  project from `/work/<name>`, a path that exists only inside the container, so a
  cwd-driven assertion would pass or fail depending on which host ran the suite.
  The parse side is covered by the "lone verb" test; the real inference is
  CHECKLIST item 13, live.

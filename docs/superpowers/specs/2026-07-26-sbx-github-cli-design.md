# sbx GitHub CLI support — PR creation + CodeRabbit response cycle

**Date:** 2026-07-26
**Status:** Implemented on `feat/gh-cli-support`; revised same-day after the
implementing agent finished and Brendan reviewed the result (see "Revision"
below).

## Revision (post-implementation review, same day)

Two corrections made after Tasks 1-7 of the implementation plan had already
been executed and committed:

1. **Dropped `sbx pr create`.** It was `exec gh pr create --fill "$@"` — a
   pure pass-through with no logic of its own. `gh` is on `PATH` inside the
   container regardless; a wrapper adds nothing. The agent runs
   `gh pr create --fill` directly.
2. **Split push out of the comment-listing verb, and renamed it.** The
   original `sbx pr respond` pushed local commits *and* listed CodeRabbit's
   comments in one call — named "respond" even though it never posted
   anything back (an actual reply is still a manual `gh pr comment`). Worse,
   conflating push-and-check is actively wrong: CodeRabbit takes several
   minutes to review a new push, so a call that pushes and immediately checks
   will only ever see nothing or CodeRabbit's bare "review started"
   acknowledgement, never the real feedback. Push doesn't need a wrapper
   either — plain `git push` already works once `gh auth setup-git` has run.
   What's left, and what's actually worth wrapping, is the non-obvious
   `gh api .../comments --jq` incantation to filter down to CodeRabbit's
   comments specifically. That's now its own read-only, no-side-effects verb:
   **`sbx pr check`**.

The rest of this document is otherwise unchanged — "Scope of authority
granted" is unaffected (Contents/Pull-requests permissions still cover it;
`sbx pr check` only reads).

## Goal

Let the sandboxed agent open PRs and iterate with CodeRabbit's automated
review — fetch its comments, push fixes, and reply — without a human running
`gh` on its behalf every round. This is a deliberate widening of the sandbox's
authority: a new opt-in tier, **c-gh**, alongside the existing c-lite/c-heavy
sync split.

## Why this differs from c-heavy sync

c-heavy's containment is a **host-side forced command**: the container's SSH
key can trigger exactly three verbs (`push`/`pull`/`fetch`) on workspace-child
repos, validated server-side by `sbx-sync-exec.ps1`; the actual git process
runs on the host, with host credentials. The in-container `sbx sync` client is
explicitly *not* the security boundary (see its own comment header) — the far
end's forced command is.

GitHub's REST/GraphQL API has no equivalent "forced command" primitive. A
token's scope **is** the boundary, full stop. That reframes the design:
instead of building a validator, the job is to get the *token itself* scoped
as tightly as GitHub allows, and to document — plainly, the way `docs/SYNC.md`
documents sync's residual risk — where that scoping stops being a real
boundary.

## Scope of authority granted

- Fine-grained GitHub PAT, scoped on github.com to the specific repos you
  choose to allow.
- Permissions: **Contents: Read & write**, **Pull requests: Read & write**.
  (Issues was suspected to also be needed for PR-conversation comments —
  live verification on 2026-07-27 showed it isn't; see "Open questions".)
- Explicitly NOT granted: Actions, Administration, Secrets, Workflows.
  Denying Workflows has a useful side effect: GitHub rejects any push that
  touches `.github/workflows/*` from a token lacking it, so CI configs stay
  unreachable regardless of what the agent attempts.
- Merge is intentionally left reachable by the token (`Pull requests: write`
  includes merge; fine-grained PATs have no separate no-merge sub-permission).
  It is blocked instead by a **GitHub branch protection rule** — require at
  least one human approval before merge on the target branch(es). This is a
  required setup step, not optional, and belongs in the same doc that
  documents token setup.

## Components

1. **`sbx gh-setup`** (host-side PowerShell verb, mirrors `sync-setup`)
   - Takes a PAT you created on github.com (paste, `--token-file`, or stdin —
     exact UX to be decided in the implementation plan) and writes it to
     `~/.sbx/gh/token`, mode 600 — same tree shape as `~/.sbx/sync/`.
   - `--remove` deletes the local copy. It **cannot revoke the token on
     GitHub's side** — unlike sync's `--remove`, which destroys the actual key
     material, this only stops sbx from presenting it. Revoking the PAT itself
     is a manual step on github.com. Document this asymmetry explicitly.
   - `--print-only` is not meaningful here the way it is for sync (there is no
     line to paste into an `authorized_keys` file); omit it.

2. **Container provisioning** (Sandboxfile + entrypoint)
   - `~/.sbx/gh` bind-mounts read-only at container-create time, staged the
     same way `.ssh-ro` is (0777 host bind-mount ownership problem applies
     equally here — the entrypoint must copy/consume it rather than use it
     in place).
   - On container start, the entrypoint feeds the token to
     `gh auth login --with-token` and runs `gh auth setup-git`, so both `gh`
     and plain `git push`/`git fetch` authenticate through it. This is a
     second, independent path to pushing workspace repos alongside the
     c-heavy sync SSH key — both are already scoped to Contents:write in their
     respective models, so this isn't a new capability, just a second route
     to the same one. Worth a one-line note in FINDINGS.md so it isn't
     "discovered" later as a surprise.
   - Only mounted/activated when `sbx gh-setup` has been run — mirrors sync's
     "absent unless provisioned" default.

3. **In-container `sbx pr check`** (extends the existing in-container client,
   renamed `sbx-client.sh`)
   - Read-only, no side effects: lists CodeRabbit's outstanding review
     comments on the PR for the current branch. Does NOT push — see
     "Revision" above for why push and check must not be conflated.
   - PR creation (`gh pr create --fill`), pushing (`git push`), and replying
     (`gh pr comment` / `gh api`) are all just `gh`/`git` directly, already
     authenticated — no wrapper needed for any of them.
   - Unlike `sbx sync`, this wrapper is genuinely just UX sugar — there is no
     validator behind it, so the docs should say so plainly rather than imply
     a boundary that isn't there.

## Residual risk (state plainly, `docs/SYNC.md`-style)

- The PAT can push (including force-push) or delete branches, and
  open/comment/merge PRs, on every repo it's scoped to — bounded by *repo
  list*, not by *action*. Branch protection mitigates merge; nothing in this
  design mitigates force-push or branch deletion within the granted repos.
- The token lives in the container in plaintext (needed for `gh` and git to
  present it) — same exposure class as the c-heavy sync private key.
- Revocation is two-step and easy to forget: `sbx gh-setup --remove` only
  stops sbx from mounting it; the PAT must also be revoked on github.com or it
  remains valid wherever else it was copied.
- `gh` push and `sbx sync` push are two independent authenticated paths to the
  same repos once both are provisioned. Neither narrows the other's blast
  radius.

## Testing

- Pester unit tests for the host-side `gh-setup` write path (token file
  perms, mount-arg construction), following the existing `sync-setup` test
  pattern in `tests/`.
- Live verification (inline, per this project's subagent-driven-plan
  convention — empirical/interactive steps stay in the main session with
  Brendan in the loop): provision a real fine-grained PAT against a throwaway
  repo, confirm `gh pr create --fill` and `sbx pr check` work end-to-end
  against a real CodeRabbit review, and confirm the Workflows-permission push
  rejection with a real attempt (don't just assume GitHub's documented
  behavior holds).

## Open questions for the implementation plan

- Exact `sbx gh-setup` token-input UX (paste/stdin/`--token-file`) — resolved:
  `--token-file`.
- Whether `Issues: Read & write` is actually required — resolved by live
  verification (2026-07-27): not required. `Pull requests: Read & write`
  alone covers `sbx pr check` and `gh pr comment`.
- Naming/location of the in-container script once it covers both sync and PR
  verbs — resolved: renamed `sbx-sync-client.sh` → `sbx-client.sh`.

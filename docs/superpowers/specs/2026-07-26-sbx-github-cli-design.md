# sbx GitHub CLI support — PR creation + CodeRabbit response cycle

**Date:** 2026-07-26
**Status:** Design approved by Brendan; awaiting implementation plan.

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
  Possibly also **Issues: Read & write** — PR conversation-level comments use
  the Issues API under the hood in GitHub's REST model; validate empirically
  during implementation rather than assuming either way.
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

3. **In-container `sbx pr` verb** (extends the existing in-container client,
   `sbx-sync-client.sh` or a sibling script)
   - `sbx pr create` — thin wrapper over `gh pr create --fill` from the
     current branch/cwd's repo.
   - `sbx pr respond` — pushes any local commits on the current branch, then
     lists CodeRabbit's outstanding review comments on the PR for the
     current branch. No state machine, no auto-reply: the agent reads the
     list, either pushes a fix (re-run `sbx pr respond` next round — the
     push is visible to CodeRabbit, which re-reviews on its own) or replies
     directly with raw `gh pr comment` / `gh api` (already authenticated, no
     wrapper needed for that case).
   - Unlike `sbx sync`, this wrapper is genuinely just UX sugar — there is no
     validator behind it in either case, so the docs should say so plainly
     rather than imply a boundary that isn't there.

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
  repo, confirm `gh pr create` and `sbx pr respond` work end-to-end against a
  real CodeRabbit review, and confirm the Workflows-permission push rejection
  with a real attempt (don't just assume GitHub's documented behavior holds).

## Open questions for the implementation plan

- Exact `sbx gh-setup` token-input UX (paste/stdin/`--token-file`).
- Whether `Issues: Read & write` is actually required (validate empirically).
- Naming/location of the in-container script once it covers both sync and PR
  verbs — keep `sbx-sync-client.sh`'s name, or rename to something that
  doesn't imply sync-only.

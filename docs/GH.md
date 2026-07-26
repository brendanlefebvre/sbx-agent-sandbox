# GitHub CLI (c-gh): PR creation + CodeRabbit response cycle

sbx can provision a fine-grained GitHub token into the sandbox so an agent can
open PRs and iterate with CodeRabbit's automated review without a human
running `gh` on its behalf every round. This is opt-in, off by default, and —
unlike c-heavy sync — has no host-side validator behind it: the token's own
github.com scopes are the entire boundary. Read this before enabling it on a
repo where an over-broad push or an unreviewed merge would matter.

## Setup

### 1. Create a scoped token

At https://github.com/settings/personal-access-tokens/new, create a
**fine-grained personal access token**:

- **Repository access:** only the specific repos you want the agent to work
  against — never "All repositories".
- **Permissions:** exactly
  - Contents: **Read and write**
  - Pull requests: **Read and write**
  - Leave Actions, Administration, Secrets, and Workflows at **No access**.
    Denying Workflows has a side benefit: GitHub rejects any push touching
    `.github/workflows/*` from a token that lacks it, so CI configs stay
    unreachable regardless of what the agent tries.
  - `sbx pr respond` itself only reads PR review comments (Pull requests
    permission covers that). If the agent also uses raw `gh pr comment` to
    reply — GitHub's PR-conversation-comment API sits under the Issues
    permission in its REST model — add **Issues: Read and write** too if you
    see a 403 from that call. Task 8 checks this empirically; this doc will be
    updated once it's confirmed one way or the other.

Save the token to a local file (not into a chat, not into a repo).

### 2. Add branch protection

Fine-grained PATs have no separate "no-merge" permission — `Pull requests:
write` includes merge. To keep merge a human action, add a **branch
protection rule** on the target branch(es) of each repo requiring at least one
approving review before merge. Do this on every repo the token is scoped to;
sbx cannot enforce it for you.

### 3. Provision it

```powershell
sbx gh-setup --token-file C:\path\to\token.txt
sbx rebuild
```

`--remove` deletes sbx's local copy of the token — it does **not** revoke the
token on GitHub. Revoke it at https://github.com/settings/tokens if it's no
longer needed.

## Use it

From inside a project directory in the sandbox:

```text
agent@sbx-main:/work/myrepo$ sbx pr create
agent@sbx-main:/work/myrepo$ sbx pr respond
```

- `sbx pr create` opens a PR from the current branch (`gh pr create --fill`).
- `sbx pr respond` pushes any local commits, then lists CodeRabbit's review
  comments on the PR for the current branch. It shows every comment
  CodeRabbit has left, not just new ones since the last round — GitHub's REST
  review-comments endpoint doesn't expose resolved-thread state (that's
  GraphQL-only), so there's no "already addressed" filtering yet. The agent
  reads the list, pushes fixes (re-running `sbx pr respond` shows the updated
  set once CodeRabbit re-reviews the new commit), or replies directly with raw
  `gh pr comment` / `gh api` — both already authenticated, no wrapper needed.

## Security model, and its limits

The token can push (including force-push) or delete branches, and
open/comment/merge PRs, on every repo it's scoped to — bounded by *repo
list*, not by *action*. Concretely, this design does NOT stop the agent from:

- Force-pushing or deleting a branch within a granted repo.
- Merging its own PR, unless you've added the branch protection rule above.

It DOES stop the agent from (enforced by GitHub, not by sbx):

- Touching any repo not explicitly listed on the token.
- Running Actions workflows, reading secrets, or changing repo administration.
- Modifying `.github/workflows/*` at all (no Workflows permission).

Other residual risk, stated plainly:

- The token lives in the container in plaintext (`gh`/git need to present it)
  — same exposure class as the c-heavy sync private key.
- `sbx gh-setup --remove` only stops sbx from mounting the token locally; it
  remains valid on GitHub until you revoke it there.
- `gh`/git push (this doc) and `sbx sync push` (`docs/SYNC.md`) are two
  independent authenticated paths to the same repos once both are
  provisioned. Neither narrows the other's blast radius.

See `docs/superpowers/specs/2026-07-26-sbx-github-cli-design.md` for the full
design rationale.

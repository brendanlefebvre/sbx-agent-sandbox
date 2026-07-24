# sbx roadmap

Post-v2 direction, consolidated from the spec's out-of-scope list, the
agent-status design notes, and final-review triage. Ordered roughly by
readiness, not priority — reshuffle at will.

## Next up (design exists, needs probes or a decision)

### 1. `sbx help`
A `help` subcommand listing every sbx command with its invocation signature (and
the `--here`/`--tab` modifiers, which only apply to attach/scratch). Today the
command surface only exists in the README table — there is nothing to type. Keep
it generated from, or checked against, that table so the two can't drift.

### 2. OpenCode support via `sbx --opencode <project>`
First cut of item 6's "alternate harnesses", scoped to one harness and one flag.
`sbx --opencode <name>` attaches the session running OpenCode instead of
`claude --dangerously-skip-permissions`. Needs: a per-harness launch command +
yolo-flag in `Build-SbxAttachArgs`, OpenCode in the image, and its own persisted
auth mount (`~/.config/opencode`) alongside `sbx-claude-auth` — see item 6 for
the full cost breakdown. **Sequenced after c-heavy** (done), before the rest of
item 6.

### 3. Agent-status, authoritative half (hooks)
`sbx-agent-status.sh` is the liveness *cross-check*; the authoritative
blocked/finished signal must come from Claude Code's Notification/Stop hooks
writing `/work/.sbx/status/<session>.json` (see `docs/sbx-agent-status.md`).
Includes: re-scoping notify-ntfy hooks (permission-prompt hooks are silent
inside sbx by design — silence currently reads as "all agents working");
aggregate-condition push alerts ("4 sessions stale >10min"), never per-agent;
open observation task: watch what `pane_title` renders when an agent actually
blocks before building any matcher on it. This is the first component of a
stage-8 orchestrator (assignment logic, task queues, checkpointing follow).

### 4. `sbx add --clone`
Clone into the workspace instead of moving — same container model, enables
same-repo parallel agents (per-agent checkouts merged via git) and native-fs
performance for build-heavy work. Additive to the existing CLI surface.

## Research (worth-it unknown — evaluate before designing)

### 5. Yegge beads at the orchestration level
Evaluate incorporating beads (Steve Yegge's git-backed, agent-first issue/task
graph) as the work-item substrate for the hub-orchestrator model. Questions to
answer when picked up (verify beads' current state first — it moves fast):
- Where does the db live? Per-repo beads travel with the repo through the sync
  gate; a workspace-level db for cross-project orchestration would need its own
  home (and is inside the container's writable surface — tamper model?).
- Does it earn its keep vs. the hub agent just reading/writing a plain
  `TASKS.md` per project? The pitch is durable agent memory across sessions +
  dependency structure; the test is whether hub→worker handoffs actually use it.
- Runs in-container? (single binary + git; should be image-friendly.)
- Interplay with item 3: beads as the task queue, status hooks as the health
  layer — together they're most of stage 8.

### 6. Alternate coding harnesses (OpenCode, Pi, …)
Support agents other than Claude Code in the same workspace/session model.
What's Claude-specific today, roughly in cost order:
- `Build-SbxAttachArgs` hardcodes `claude --dangerously-skip-permissions` →
  per-harness launch command + yolo-mode flag (and a per-project or per-flag
  harness choice, e.g. `sbx <name> --agent opencode`).
- Image bakes only `@anthropic-ai/claude-code` → either a fat image with all
  harnesses or per-harness image variants.
- Auth: the `sbx-claude-auth` volume maps to Claude's `~/.claude` layout —
  each harness needs its own persisted-auth mount (`~/.config/opencode`, etc.).
- `sbx-agent-status.sh` marks liveness by `comm == claude` → generalize to a
  process-name set; the hooks half (item 3) is Claude-specific and needs
  per-harness equivalents or graceful absence.
- Session-history isolation assumptions (cwd-keyed under the auth volume) are
  Claude behavior — verify per harness.
Candidates named so far: OpenCode, Pi. (Codex CLI / others: same shape, add
when wanted.)

## Shipped

### Autonomous sync: SSH forced-command callback ("c-heavy") — done 2026-07-24
The container gets a *dedicated* keypair whose host `authorized_keys` entry is
pinned `restrict,command="sbx-sync-exec …"` — agents gain exactly three verbs
(push/pull/fetch) against workspace repos, not host execution. Surrenders the
"agents commit, human pushes" review gate deliberately; c-lite remains the
default and c-heavy is opt-in via `sbx sync-setup`. **(d) agent-socket forwarding
stays demoted** — it grants the keys' full authority and is strictly wider.

Probes passed 2026-07-23 on Windows/wslc and macOS/OrbStack (FINDINGS P7); built
2026-07-24. Shipped surface: `Resolve-SbxSyncRequest`/`Resolve-SbxSyncCommand`
(one validator shared by both sync paths), `sbx-sync-exec.ps1` (the forced
command), `sbx sync-setup` (keygen + pinned authorized_keys line + `sync.conf`,
with `--print-only`/`--remove`), the in-container `sbx sync` client baked into
the image, a per-project host-side lock for concurrent pushes, and
`docs/SYNC.md`. The probe kit now exercises the shipped validator rather than a
copy.

**The build turned up a class of hole the probes never covered — see FINDINGS
P8.** The SSH surface was never the whole boundary: host-side git runs inside an
agent-writable repo, and git executes `.git/hooks/*` and config-named programs.
Mitigated with raceless `-c` pins plus an advisory local-config denylist;
residual risk is documented in `docs/SYNC.md` rather than papered over. Two
follow-ups worth considering if c-heavy sees heavy use:
- Sync from a host-side mirror instead of the agent's worktree (fetch the agent's
  refs into a clean repo, push from there), which would make the git surface a
  real boundary rather than a hardened one.
- A `--dry-run`/notification mode so a push still tells the human what left.

## Deferred minors (from final-review triage — fix opportunistically)
- Pre-configure the image with a git user name/email so agent commits from
  inside the sandbox don't fail with "Author identity unknown" (hit in
  practice: a commit from within sbx aborted until `user.name`/`user.email`
  were set repo-locally by hand). Decide where the identity comes from —
  a baked default vs. injecting the host's `git config user.*` at container
  create/attach time (latter avoids a wrong-author footgun and dovetails with
  the "agents commit, human pushes" gate). **Worse than first recorded:** the
  documented workaround (set `user.name`/`user.email` repo-locally by hand) can
  itself fail inside sbx — `git config` writes via a `config.lock` whose chmod
  is refused on a wslc bind mount ("Operation not permitted"), so `.git/config`
  is effectively read-only there. The working fallback is per-invocation
  `git -c user.name=… -c user.email=… commit`, which is a miserable thing to ask
  an agent to remember. Raises the priority of injecting identity at container
  create time.
- `Get-SbxVolumeRoot` OrdinalIgnoreCase prefix match (case-sensitive-APFS nit).
- `Add-SbxProject` creates the workspace dir before the cross-volume check.
- `Invoke-SbxSync` allowlist is case-insensitive (`-cnotin` if touched).
- `Get-SbxContainerName` `-Path`/`-Override` params are vestigial post-v2.
- Attach containment check would null-ref on a plain *file* in the workspace
  (`-PathType Container` tweak when next touched).

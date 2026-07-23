# sbx roadmap

Post-v2 direction, consolidated from the spec's out-of-scope list, the
agent-status design notes, and final-review triage. Ordered roughly by
readiness, not priority — reshuffle at will.

## Next up (design exists, needs probes or a decision)

### 1. Autonomous sync: SSH forced-command callback ("c-heavy")
The container gets a *dedicated* keypair whose host `authorized_keys` entry is
pinned `restrict,command="sbx-sync-exec …"` — agents gain exactly three verbs
(push/pull/fetch) against workspace repos, not host execution. Surrenders the
"agents commit, human pushes" review gate deliberately.
Windows probes required first: host reachability from inside a wslc container,
Win32-OpenSSH `administrators_authorized_keys` quirk, binding/firewalling sshd
away from the LAN. **(d) agent-socket forwarding stays demoted** — it grants the
keys' full authority and is strictly wider than the callback.
**Probe kit (probe-first pass, not yet run on a host):** `probes/` holds the
validator prototype `sbx-sync-exec.ps1` (+ unit tests, green off-host) and the
host harness `probe-host.ps1`; runbook + go/no-go ordering in
`docs/probes/c-heavy-sync-probes.md`. Results land in FINDINGS as P7. The full
build (container-side caller, `sbx sync-setup` key provisioning, host sshd setup,
concurrency) is gated on these probes passing.

### 2. Agent-status, authoritative half (hooks)
`sbx-agent-status.sh` is the liveness *cross-check*; the authoritative
blocked/finished signal must come from Claude Code's Notification/Stop hooks
writing `/work/.sbx/status/<session>.json` (see `docs/sbx-agent-status.md`).
Includes: re-scoping notify-ntfy hooks (permission-prompt hooks are silent
inside sbx by design — silence currently reads as "all agents working");
aggregate-condition push alerts ("4 sessions stale >10min"), never per-agent;
open observation task: watch what `pane_title` renders when an agent actually
blocks before building any matcher on it. This is the first component of a
stage-8 orchestrator (assignment logic, task queues, checkpointing follow).

### 3. `sbx add --clone`
Clone into the workspace instead of moving — same container model, enables
same-repo parallel agents (per-agent checkouts merged via git) and native-fs
performance for build-heavy work. Additive to the existing CLI surface.

## Research (worth-it unknown — evaluate before designing)

### 4. Yegge beads at the orchestration level
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
- Interplay with item 2: beads as the task queue, status hooks as the health
  layer — together they're most of stage 8.

### 5. Alternate coding harnesses (OpenCode, Pi, …)
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
  process-name set; the hooks half (item 2) is Claude-specific and needs
  per-harness equivalents or graceful absence.
- Session-history isolation assumptions (cwd-keyed under the auth volume) are
  Claude behavior — verify per harness.
Candidates named so far: OpenCode, Pi. (Codex CLI / others: same shape, add
when wanted.)

## Deferred minors (from final-review triage — fix opportunistically)
- Pre-configure the image with a git user name/email so agent commits from
  inside the sandbox don't fail with "Author identity unknown" (hit in
  practice: a commit from within sbx aborted until `user.name`/`user.email`
  were set repo-locally by hand). Decide where the identity comes from —
  a baked default vs. injecting the host's `git config user.*` at container
  create/attach time (latter avoids a wrong-author footgun and dovetails with
  the "agents commit, human pushes" gate in item 1).
- `Get-SbxVolumeRoot` OrdinalIgnoreCase prefix match (case-sensitive-APFS nit).
- `Add-SbxProject` creates the workspace dir before the cross-volume check.
- `Invoke-SbxSync` allowlist is case-insensitive (`-cnotin` if touched).
- `Get-SbxContainerName` `-Path`/`-Override` params are vestigial post-v2.
- Attach containment check would null-ref on a plain *file* in the workspace
  (`-PathType Container` tweak when next touched).

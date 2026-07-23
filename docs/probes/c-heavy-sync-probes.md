# c-heavy autonomous sync — probe runbook

**Status:** probe-first pass (ROADMAP item 1). This validates whether the
SSH-forced-command callback design is viable on a real host **before** we build
it. Nothing here is wired into `sbx`; the whole kit lives under `probes/` and is
deletable if the approach proves dead.

**Background.** Today only *c-lite* ships: the human runs `sbx sync <name> push`
host-side, container holds no keys ("agents commit, human pushes"). *c-heavy*
lets the container push/pull/fetch autonomously by SSH-ing back to an sshd on the
host, where a dedicated key's `authorized_keys` line is pinned
`restrict,command="sbx-sync-exec …"` so it can only invoke the validator
(`probes/sbx-sync-exec.ps1`) for the three verbs against a workspace repo. See
`docs/superpowers/specs/2026-07-22-sbx-unified-workspace-design.md:90-109`.

## Go/no-go ordering

Run in this order and **stop at the first hard failure** — later probes are
moot if an earlier one fails:

1. **Reachability (the gate).** Can a sandbox container open TCP to an sshd on
   *this* host? If no address works, the SSH-callback transport is dead — record
   it and stop. **Do not** "fix" it by routing container traffic through the host
   or adding a `ProxyJump` (FINDINGS P6 triage rule) — that undercuts the
   isolation sbx exists for, and we would redesign the transport instead.
2. **Forced command fires + rejects.** With the pinned key, the three verbs run
   and everything else (unknown verb, extra args, traversal, shell, forwarding)
   is refused.
3. **Key placement surface.** Where the `authorized_keys` line had to live
   (per-user vs Windows `administrators_authorized_keys`) and the ACL it needed.
4. **LAN exposure (manual).** The new host sshd must be reachable from the
   container but **not** from the LAN.

## Prerequisites (manual, need admin — the harness does NOT do these)

### Windows (Win32-OpenSSH)
- Install + start the server:
  `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` then
  `Start-Service sshd; Set-Service sshd -StartupType Automatic`.
- Ensure `pwsh` and `git` are on PATH for the sshd session.
- If your account is a local **Administrator**, Win32-OpenSSH ignores
  `~/.ssh/authorized_keys` and reads `C:\ProgramData\ssh\administrators_authorized_keys`,
  which must be ACL'd to Administrators + SYSTEM only or sshd silently refuses
  the key:
  ```powershell
  $f = "$env:ProgramData\ssh\administrators_authorized_keys"
  icacls $f /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
  ```
  The harness detects the admin case and writes to the right file, but this ACL
  is on you.

### macOS (Remote Login)
- Enable the built-in sshd: System Settings → General → Sharing → **Remote
  Login** on (or `sudo systemsetup -setremotelogin on`).
- **Grant the container runtime the Local Network permission first** (FINDINGS
  P6): without it every LAN/host connection from the container times out and
  *looks like* an SSH failure. System Settings → Privacy & Security → Local
  Network → enable OrbStack.

## Running the harness

From the repo root, on the host (not inside a container):

```powershell
pwsh -NoProfile -File probes/probe-host.ps1
```

Useful switches: `-Address 172.x.y.z` to force a host address (skip
auto-discovery), `-SshUser <name>`, `-Port <n>`, `-KeepArtifacts` to leave the
throwaway key/line in place for manual poking (undo by hand afterward), and
`-AuthorizedKeysFile <path>` to force which file the key line is written to.

By default the harness auto-detects the Win32-OpenSSH admin-file quirk: if your
account is in local Administrators it targets `administrators_authorized_keys`
(and needs an elevated shell). **If you've disabled that Match block in
`sshd_config`** so sshd reads the per-user file for everyone, pass
`-AuthorizedKeysFile "$HOME\.ssh\authorized_keys"` (no elevation needed).

The harness prechecks the `sshd` service + local port and prints each
candidate's SSH error, so a failure is legible: `Connection timed out`/`refused`
= routing/sshd; `Permission denied (publickey)` = the key landed in a file this
sshd doesn't read (wrong authorized_keys file or ACL), not a reachability
problem.

What it does, all throwaway and removed in `finally`: generates an ed25519
keypair in a temp dir, creates a bare git remote + a working repo as `myrepo` in
a temp workspace, appends **one** `authorized_keys` line tagged `sbx-cheavy-probe`
with the forced command (workspace baked in, so your real `~/sbx-ws` is never
touched), then launches containers that SSH back and run the test matrix. It
prints a PASS/FAIL table.

It does **not** touch your real `~/.ssh` keys, and it assumes sshd is already
running (see prerequisites). If interrupted, delete any `authorized_keys` line
containing `sbx-cheavy-probe` and remove the temp dir it named on startup.

## Test matrix (asserted by the harness)

| Case | Expected |
|------|----------|
| `myrepo push` / `pull` / `fetch` | validator prints `OK`, git op runs |
| `myrepo clone` | `REJECT` (verb not allowed) |
| `myrepo push --force` | `REJECT` (extra token) |
| `../secret push` | `REJECT` (traversal) |
| `ghost push` | `REJECT` (not in workspace) |
| `myrepo; sh` | `REJECT` (extra token / no shell) |
| `-L`/`-D` forwarding | refused by `restrict` |

The reject invariants are also unit-tested off-host: `Invoke-Pester probes` on
any platform exercises `Resolve-SbxSyncExecRequest` directly.

## Manual check the harness can't do: LAN exposure

Confirm the host sshd is reachable from the container but **not** from another
device on the LAN.

- From a *second* machine on the same LAN: `nc -zv <host-lan-ip> 22` should
  **fail/refuse**. From inside the sandbox it should succeed (the harness proves
  the container side).
- Windows: bind/firewall sshd away from the LAN, e.g. scope the inbound rule to
  the container subnet only:
  ```powershell
  New-NetFirewallRule -Name sshd-sbx -DisplayName "sshd (sbx container only)" `
    -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 `
    -Action Allow -RemoteAddress <container-subnet>/24
  ```
  (and ensure no broader "allow 22 from Any" rule shadows it).
- macOS: restrict Remote Login to specific users, and/or add a `pf` rule scoping
  port 22 to the OrbStack bridge (`192.168.215.0/24`) only.

## Recording results — FINDINGS.md P7 template

Paste into `docs/FINDINGS.md` (next free P-number), filling the blanks:

```
**P7 — c-heavy sync: container→host sshd callback.** Probed <date> on
<Windows wslc | macOS OrbStack>, host sshd <Win32-OpenSSH | Remote Login>.

Reachability: <address that worked, e.g. WSL default gateway 172.x.x.1 |
host.docker.internal | FAILED — nothing reachable>.
Forced command: <fired; all negatives rejected | notes>.
Key placement: <~/.ssh/authorized_keys | administrators_authorized_keys + ACL
needed>.
LAN exposure: <sshd not reachable from a second LAN device after <firewall/pf
rule> | still exposed — TODO>.

Verdict: <GO — build c-heavy | NO-GO — transport not viable, redesign> because …
```

## If probes pass → next session (the build)

Fold the validator into a shared core with `Invoke-SbxSync` (same allowlist +
workspace-child guard), add the container-side caller (a `GIT_SSH_COMMAND` /
`sbx sync` wrapper that runs *inside* the container), the key-provisioning step
(`sbx sync-setup`: keygen + install the pinned `authorized_keys` line), host sshd
setup guidance, and concurrency handling for simultaneous pushes. All of that is
out of scope for this probe pass.

# c-heavy autonomous sync — probe runbook

**Status: c-heavy is BUILT** (2026-07-24) — see `docs/SYNC.md` for the shipped
feature and `sbx sync-setup` for provisioning. This runbook survives its
probe-first origins as the way to **qualify a new host**: it stands up throwaway
key/repo/workspace artifacts, runs the full accept/reject matrix against the
*shipped* validator (`sbx-sync-exec.ps1`), and tears everything down. Run it when
you move to a new machine, change sshd, or suspect the transport.

The prototype validator and its unit tests that used to live here are gone: the
validator shipped into `sbx.ps1` (`Resolve-SbxSyncRequest` /
`Resolve-SbxSyncCommand`) and its tests into `tests/Sync.Tests.ps1`, so this
harness now exercises the real thing rather than a copy.

**Note P8.** These probes cover the SSH surface only. They do NOT cover what the
forced command *executes* — host-side git inside an agent-writable repo, which
runs hooks and config-named programs. That hole was found during the build, not
here; see FINDINGS P8 and the checklist steps 15–16 in `verify/CHECKLIST.md`.

**Background.** *c-lite* is the default: the human runs `sbx sync <name> push`
host-side, container holds no keys ("agents commit, human pushes"). *c-heavy*
lets the container push/pull/fetch autonomously by SSH-ing back to an sshd on the
host, where a dedicated key's `authorized_keys` line is pinned
`restrict,command="sbx-sync-exec …"` so it can only invoke the validator
(`sbx-sync-exec.ps1`) for the three verbs against a workspace repo. See
`docs/SYNC.md` and
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
- If your account is a local **Administrator** *and*
  `C:\ProgramData\ssh\administrators_authorized_keys` exists, Win32-OpenSSH reads
  that file instead of `~/.ssh/authorized_keys`. It must be ACL'd to
  Administrators + SYSTEM only or sshd silently refuses the key:
  ```powershell
  $f = "$env:ProgramData\ssh\administrators_authorized_keys"
  icacls $f /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
  ```
  Creating that file is a **host-wide** decision — from then on sshd prefers it
  for every admin account — so neither the harness nor `sbx sync-setup` will
  create it, and neither changes its ACL. Both are on you.

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

The harness picks the target file with the shipped `Get-SbxAuthorizedKeysPath`,
so it qualifies the file `sbx sync-setup` would actually write. On Windows that
means `C:\ProgramData\ssh\administrators_authorized_keys` **only if that file
already exists** (then an elevated shell is needed); otherwise the per-user
`~/.ssh/authorized_keys`.

It will not create the admin file, and it does not touch ACLs — it only warns if
the existing ACL looks wrong. Creating that file is not a local choice: from then
on Win32-OpenSSH prefers it for *every* member of local Administrators, which can
lock out logins that relied on a per-user file. If your account is an admin and
the file is absent, the harness says so and continues against the per-user file.
Should auth then fail with `Permission denied (publickey)`, this host has the
stock `Match Group administrators` block in force; create the admin file yourself
with the ACL recipe above and re-run, or pass `-AuthorizedKeysFile <path>`.

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

The reject invariants are also unit-tested off-host: `Invoke-Pester tests` on
any platform exercises `Resolve-SbxSyncRequest` / `Resolve-SbxSyncCommand`
directly, plus the git-surface hardening from P8.

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

## After a green run

Nothing further to build — c-heavy shipped. A green matrix means this host can
run it: `sbx sync-setup --address <the address that worked>` then `sbx rebuild`,
and work through `verify/CHECKLIST.md` steps 11–18 (which include the P8
hook/config containment checks this harness does not cover).

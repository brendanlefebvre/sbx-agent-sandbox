#!/usr/bin/env pwsh
# sbx-sync-exec — the forced command behind c-heavy autonomous sync.
#
# This is the ONLY thing the container's dedicated key can run. `sbx sync-setup`
# pins it in the host's authorized_keys:
#
#   restrict,command="pwsh -NoProfile -File <abs>/sbx-sync-exec.ps1 -WorkspaceDir <ws>" ssh-ed25519 AAAA... sbx-sync
#
# so a connection with that key gets neither a shell nor forwarding — only this
# script, with the client's requested command arriving in SSH_ORIGINAL_COMMAND as
# "<name> <op>". Everything else the client passes on its command line is
# discarded by OpenSSH.
#
# The validation itself lives in sbx.ps1 (Resolve-SbxSyncCommand ->
# Resolve-SbxSyncRequest), shared verbatim with the human-run `sbx sync` — one
# allowlist, one workspace-child guard, no chance of the two drifting apart.
# See docs/SYNC.md, ROADMAP item 1, and FINDINGS P7 for the probe results.

[CmdletBinding()]
param(
    # Both overridable for tests; live values come from SSH and the pinned line.
    [string]$OriginalCommand = $env:SSH_ORIGINAL_COMMAND,
    [string]$WorkspaceDir
)

. "$PSScriptRoot/sbx.ps1"

if (-not $WorkspaceDir) { $WorkspaceDir = Get-SbxWorkspacePath }

$decision = Resolve-SbxSyncCommand -OriginalCommand $OriginalCommand -WorkspaceDir $WorkspaceDir
if (-not $decision.Ok) {
    # Structured, single-line, on stderr: the in-container client greps for it and
    # the probe harness asserts on it. Never echo the request back — a rejected
    # command is attacker-controlled text.
    [Console]::Error.WriteLine("sbx-sync-exec: REJECT $($decision.Reason)")
    exit 2
}
[Console]::Error.WriteLine("sbx-sync-exec: OK $($decision.Name) $($decision.Operation)")
try {
    # Locked: concurrent agents (and the human's own `sbx sync`) serialize per repo.
    Invoke-SbxSyncGit -Dir $decision.Dir -Operation $decision.Operation
}
catch {
    # A PowerShell error record over SSH is a wall of ANSI-coloured stack trace the
    # agent then has to interpret. Emit the same one-line shape as a REJECT.
    [Console]::Error.WriteLine("sbx-sync-exec: FAILED $($_.Exception.Message)")
    exit 3
}
exit $LASTEXITCODE

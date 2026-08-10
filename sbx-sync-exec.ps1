#!/usr/bin/env pwsh
# sbx-sync-exec - the forced command behind c-heavy autonomous sync.
#
# This is the ONLY thing the container's dedicated key can run. `sbx sync-setup`
# pins it in the host's authorized_keys:
#
#   restrict,command="pwsh -NoProfile -File <abs>/sbx-sync-exec.ps1 -WorkspaceDir <ws>" ssh-ed25519 AAAA... sbx-sync
#
# so a connection with that key gets neither a shell nor forwarding - only this
# script, with the client's requested command arriving in SSH_ORIGINAL_COMMAND as
# "<name> <op> [git options]". Everything else the client passes on its command
# line is discarded by OpenSSH.
#
# The validation itself lives in sbx.ps1 (Resolve-SbxSyncCommand ->
# Resolve-SbxSyncRequest), shared verbatim with the human-run `sbx sync` - one
# verb allowlist, one git-option allowlist, one workspace-child guard, no chance
# of any of them drifting apart.
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
    # the probe harness asserts on it. Never echo the request back - a rejected
    # command is attacker-controlled text.
    [Console]::Error.WriteLine("sbx-sync-exec: REJECT $($decision.Reason)")
    exit 2
}
# RUN, not OK: the validator has accepted, but nothing has been attempted yet.
# Emitted before the work so a client that hangs or dies mid-git can still tell
# "the forced command fired" from "the key never got in" - the two failure modes
# look identical from the container otherwise.
#
# The options are echoed because they have PASSED the allowlist - they are drawn
# from a fixed ASCII set, not arbitrary request text - and because a sync whose
# effect depends on them should say so in the line the human reads.
$suffix = if ($decision.Options.Count) { ' ' + ($decision.Options -join ' ') } else { '' }
[Console]::Error.WriteLine("sbx-sync-exec: RUN $($decision.Name) $($decision.Operation)$suffix")
try {
    # Locked: concurrent agents (and the human's own `sbx sync`) serialize per repo.
    # -WorkspaceDir is not decoration: Invoke-SbxSyncGit re-checks containment once
    # it holds the lock, because the container can swap the validated directory for
    # a link in the window between. It must measure against the workspace this
    # request was validated in.
    Invoke-SbxSyncGit -Dir $decision.Dir -Operation $decision.Operation `
                      -Options $decision.Options -WorkspaceDir $WorkspaceDir
}
catch {
    # A PowerShell error record over SSH is a wall of ANSI-coloured stack trace the
    # agent then has to interpret. Emit the same one-line shape as a REJECT.
    # Reaches here for a failed git too - Invoke-SbxSyncGit throws on a non-zero
    # exit - so FAILED means what docs/SYNC.md says it means.
    [Console]::Error.WriteLine("sbx-sync-exec: FAILED $($_.Exception.Message)")
    exit 3
}
# Only now: OK means the git operation actually completed.
[Console]::Error.WriteLine("sbx-sync-exec: OK $($decision.Name) $($decision.Operation)$suffix")
exit 0

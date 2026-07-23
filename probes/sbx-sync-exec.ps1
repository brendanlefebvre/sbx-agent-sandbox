#!/usr/bin/env pwsh
# sbx-sync-exec — PROTOTYPE forced-command validator for the "c-heavy" autonomous
# sync probe (ROADMAP item 1; see docs/probes/c-heavy-sync-probes.md).
#
# This is the command pinned in the host authorized_keys line:
#   restrict,command="pwsh -NoProfile -File <abs>/sbx-sync-exec.ps1" ssh-ed25519 AAAA...
# so a connection with the dedicated container key can ONLY run this script,
# never a shell. The client's requested command arrives in SSH_ORIGINAL_COMMAND
# as "<name> <op>"; everything else the client passes is ignored by OpenSSH.
#
# The security invariants are copied verbatim from the shipped c-lite
# Invoke-SbxSync (sbx.ps1:634-654): exactly the verbs {push,pull,fetch}, and the
# repo must be a DIRECT CHILD of the workspace (not merely somewhere under it).
# A wider surface would turn this into a host-command proxy, which it must never
# become. This prototype is for PROBING only — it is not wired into `sbx` yet.

[CmdletBinding()]
param(
    # Overridable for tests; defaults to the live SSH-injected command / workspace.
    [string]$OriginalCommand = $env:SSH_ORIGINAL_COMMAND,
    [string]$WorkspaceDir    = $(if ($env:SBX_WORKSPACE) { $env:SBX_WORKSPACE } else { Join-Path $HOME 'sbx-ws' })
)

$AllowedOps = @('push', 'pull', 'fetch')

function Resolve-SbxSyncExecRequest {
    # PURE validator (touches the filesystem to confirm the repo, but never
    # invokes git or ssh) — returns a decision object the caller acts on.
    # Ok=$true means the request is safe to run; otherwise Reason explains the
    # rejection. Kept side-effect-free so Probe.Tests.ps1 can exercise every
    # accept/reject path directly.
    [CmdletBinding()]
    param(
        [string]$OriginalCommand,
        [Parameter(Mandatory)][string]$WorkspaceDir
    )
    $deny = { param($r) [pscustomobject]@{ Ok = $false; Name = $null; Operation = $null; Dir = $null; Reason = $r } }

    if ([string]::IsNullOrWhiteSpace($OriginalCommand)) {
        return (& $deny 'no command (bare connection) — expected "<name> <op>"')
    }
    # Split on runs of whitespace. Requiring EXACTLY two tokens is itself a guard:
    # it rejects "push --force", "name; sh", "name op extra", and shell operators
    # that would smuggle in a second word.
    $tokens = $OriginalCommand.Trim() -split '\s+'
    if ($tokens.Count -ne 2) {
        return (& $deny "expected exactly two tokens '<name> <op>', got $($tokens.Count)")
    }
    $name = $tokens[0]
    $op   = $tokens[1]

    # Verb allowlist — case-insensitive like the shipped -notin (roadmap:79), but
    # canonicalize to the lowercase form actually handed to git so a "PUSH" can't
    # reach git as an invalid verb.
    $canonical = $AllowedOps | Where-Object { $_ -eq $op } | Select-Object -First 1
    if (-not $canonical) {
        return (& $deny "operation must be one of: $($AllowedOps -join ', ')")
    }
    $op = $canonical

    # Reject obvious traversal / separators before touching the filesystem.
    if ($name -in @('.', '..') -or $name -match '[\\/]') {
        return (& $deny "invalid project name: $name")
    }

    $dir = Join-Path $WorkspaceDir $name
    if (-not (Test-Path -LiteralPath $dir)) {
        return (& $deny "no project '$name' in the workspace")
    }
    # Direct-child gate: the resolved repo's parent must BE the workspace, not
    # merely contain it somewhere up the tree — the same check the attach/sync
    # paths use (sbx.ps1:185-186, 650-651). Defeats symlink/`..` escapes that
    # survive the lexical check above.
    if ((Get-Item -LiteralPath $dir).Parent.FullName -ne (Get-Item -LiteralPath $WorkspaceDir).FullName) {
        return (& $deny "no project '$name' in the workspace")
    }
    return [pscustomobject]@{ Ok = $true; Name = $name; Operation = $op; Dir = $dir; Reason = $null }
}

# When dot-sourced (by the tests) do nothing else — just expose the function.
if ($MyInvocation.InvocationName -eq '.') { return }

$decision = Resolve-SbxSyncExecRequest -OriginalCommand $OriginalCommand -WorkspaceDir $WorkspaceDir
if (-not $decision.Ok) {
    # Single structured stderr line the probe harness asserts on.
    [Console]::Error.WriteLine("sbx-sync-exec: REJECT $($decision.Reason)")
    exit 2
}
[Console]::Error.WriteLine("sbx-sync-exec: OK $($decision.Name) $($decision.Operation)")
& git -C $decision.Dir $decision.Operation
exit $LASTEXITCODE

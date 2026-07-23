#!/usr/bin/env pwsh
# probe-host.ps1 — host-side harness for the "c-heavy" autonomous-sync probes
# (ROADMAP item 1). Answers the three flagged unknowns end-to-end WITHOUT
# building the real feature:
#
#   1. reachability  — can a sandbox container open TCP to an sshd on THIS host?
#   2. forced cmd    — does `restrict,command="sbx-sync-exec"` fire and reject
#                      everything outside {push,pull,fetch} on a workspace repo?
#   3. (surface)     — reports where the authorized_keys line had to go (per-user
#                      vs Win32-OpenSSH administrators_authorized_keys).
#
# It stands up ONLY throwaway artifacts (a temp dir, an ed25519 keypair, a bare
# git remote + working repo, one tagged authorized_keys line) and removes them
# all in `finally`. It NEVER reads or modifies your real ~/.ssh keys.
#
# PREREQUISITES you must set up first (they need admin and are OS-specific — see
# docs/probes/c-heavy-sync-probes.md): a host sshd must already be listening
# (Win32-OpenSSH / macOS Remote Login), and `pwsh` + `git` on PATH. This harness
# does NOT install or start sshd.
#
# Cannot be validated from the Linux dev sandbox — expect to iterate on your
# host. The runbook is the authoritative guide; this automates the mechanical
# parts and prints a PASS/FAIL table.

[CmdletBinding()]
param(
    [string]$SshUser  = $(if ($env:USERNAME) { $env:USERNAME } else { $env:USER }),
    [string]$Runtime,   # resolved below, after sbx.ps1 is dot-sourced
    [int]$Port        = 22,
    [string[]]$Address = @(),   # force specific host addresses; else auto-discover
    [switch]$KeepArtifacts      # skip teardown (debugging)
)

. "$PSScriptRoot/../sbx.ps1"    # reuse ConvertTo-SbxMountPath / Resolve-SbxRuntime
$ErrorActionPreference = 'Stop'
if (-not $Runtime) { $Runtime = Resolve-SbxRuntime }   # param defaults run before the dot-source

$TAG      = 'sbx-cheavy-probe'
$ExecPath = (Resolve-Path "$PSScriptRoot/sbx-sync-exec.ps1").Path
$results  = [System.Collections.Generic.List[object]]::new()
function Add-Result { param($Probe, $Pass, $Detail)
    $results.Add([pscustomobject]@{ Probe = $Probe; Result = $(if ($Pass) {'PASS'} else {'FAIL'}); Detail = $Detail })
    $c = if ($Pass) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1} — {2}" -f $results[-1].Result, $Probe, $Detail) -ForegroundColor $c
}

function Get-AuthorizedKeysTarget {
    # Where the pubkey line must live so THIS sshd will honor it. On Windows,
    # Win32-OpenSSH ignores per-user authorized_keys for members of the local
    # Administrators group and reads C:\ProgramData\ssh\administrators_authorized_keys
    # instead (with strict ACLs — see runbook). Elsewhere: ~/.ssh/authorized_keys.
    if ($IsWindows) {
        $admin = ([Security.Principal.WindowsPrincipal] `
                  [Security.Principal.WindowsIdentity]::GetCurrent()
                 ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($admin) {
            return [pscustomobject]@{
                Path  = (Join-Path $env:ProgramData 'ssh/administrators_authorized_keys')
                Admin = $true
            }
        }
    }
    return [pscustomobject]@{ Path = (Join-Path $HOME '.ssh/authorized_keys'); Admin = $false }
}

function New-ProbeArtifacts {
    # Temp keypair + a local bare remote + a working repo placed as 'myrepo' in a
    # throwaway workspace, so push/pull/fetch have a real (host-local) target. The
    # git op runs host-side (that's the whole point) — no network for git itself.
    $root = Join-Path ([IO.Path]::GetTempPath()) "$TAG-$PID"
    $ws   = Join-Path $root 'ws'
    $key  = Join-Path $root 'id_ed25519'
    New-Item -ItemType Directory -Force $ws | Out-Null

    & ssh-keygen -t ed25519 -N '' -C $TAG -f $key -q
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed" }

    $bare = Join-Path $root 'remote.git'
    & git init --bare -q $bare
    $repo = Join-Path $ws 'myrepo'
    & git clone -q $bare $repo
    & git -C $repo -c user.email=probe@sbx -c user.name=probe commit --allow-empty -q -m 'probe seed'
    & git -C $repo push -q origin HEAD 2>&1 | Out-Null

    return [pscustomobject]@{ Root = $root; Ws = $ws; Key = $key; Pub = "$key.pub"; Repo = $repo }
}

function Install-AuthorizedKey {
    param([Parameter(Mandatory)]$Art, [Parameter(Mandatory)]$Target)
    # One tagged line: restrict (no pty/forwarding/agent/X11) + a forced command
    # pinned to the validator with the throwaway workspace baked in, so the probe
    # can never touch your real ~/sbx-ws.
    $pub = (Get-Content -Raw $Art.Pub).Trim()
    $forced = "pwsh -NoProfile -File `"$ExecPath`" -WorkspaceDir `"$($Art.Ws)`""
    $line = "restrict,command=`"$forced`" $pub"
    $dir = Split-Path -Parent $Target.Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    Add-Content -Path $Target.Path -Value $line
    Write-Host "  wrote forced-command line (tag '$TAG') to $($Target.Path)" -ForegroundColor Yellow
    if ($Target.Admin) {
        Write-Host "  NOTE: administrators_authorized_keys must be ACL'd to Administrators+SYSTEM only;" -ForegroundColor Yellow
        Write-Host "        if auth is refused, apply the icacls recipe from the runbook and re-run." -ForegroundColor Yellow
    }
}

function Remove-AuthorizedKey {
    param([Parameter(Mandatory)]$Target)
    if (-not (Test-Path $Target.Path)) { return }
    $kept = Get-Content $Target.Path | Where-Object { $_ -notmatch [regex]::Escape($TAG) }
    Set-Content -Path $Target.Path -Value $kept
}

function Get-CandidateHostAddresses {
    if ($Address.Count) { return $Address }
    $cands = [System.Collections.Generic.List[string]]::new()
    # Addresses as the CONTAINER sees them: default-route gateway + DNS nameserver
    # (in WSL2 NAT these are typically the host).
    try {
        $seen = & $Runtime run --rm sbx:latest bash -lc `
            "ip route show default 2>/dev/null | awk '{print \$3; exit}'; awk '/nameserver/{print \$2; exit}' /etc/resolv.conf 2>/dev/null"
        foreach ($l in @($seen)) { if ($l -and $l.Trim()) { $cands.Add($l.Trim()) } }
    } catch { Write-Warning "container address discovery failed: $($_.Exception.Message)" }
    # Names the runtime may inject, plus host-enumerated IPv4s.
    $cands.Add('host.docker.internal')
    try {
        [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.ToString().StartsWith('127.') } |
            ForEach-Object { $cands.Add($_.ToString()) }
    } catch { }
    return ($cands | Select-Object -Unique)
}

function Invoke-ContainerSsh {
    # Run `ssh <user>@<addr> "<remoteCmd>"` from inside a throwaway container with
    # the probe key mounted read-only (entrypoint copies it to ~/.ssh at 0600).
    param([string]$Addr, [string]$RemoteCmd, $Art)
    $keydir = Split-Path -Parent $Art.Key
    $mount  = ConvertTo-SbxMountPath -HostPath $keydir -Posix:$IsMacOS
    $inner  = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 " +
              "-i /home/agent/.ssh/id_ed25519 -p $Port $SshUser@$Addr '$RemoteCmd'"
    $out = & $Runtime run --rm -v "${mount}:/home/agent/.ssh-ro:ro" sbx:latest bash -lc $inner 2>&1
    return [pscustomobject]@{ Exit = $LASTEXITCODE; Output = ($out -join "`n") }
}

# ---- run ----------------------------------------------------------------------
Write-Host "sbx c-heavy sync probe — runtime=$Runtime user=$SshUser port=$Port" -ForegroundColor Cyan
Write-Host "If interrupted, undo by hand: delete lines tagged '$TAG' from your authorized_keys and remove the temp dir under $([IO.Path]::GetTempPath())." -ForegroundColor DarkGray

$target = Get-AuthorizedKeysTarget
$art = $null
try {
    $art = New-ProbeArtifacts
    Install-AuthorizedKey -Art $art -Target $target

    # Probe 1 — reachability: find an address the container can SSH to.
    $reachable = $null
    foreach ($addr in (Get-CandidateHostAddresses)) {
        Write-Host "  trying host address $addr ..." -ForegroundColor DarkGray
        $r = Invoke-ContainerSsh -Addr $addr -RemoteCmd 'myrepo fetch' -Art $art
        if ($r.Output -match 'sbx-sync-exec: (OK|REJECT)') { $reachable = $addr; break }
    }
    if (-not $reachable) {
        Add-Result 'reachability' $false 'no candidate host address reachable from the container (see runbook; do NOT proxy via host)'
        return
    }
    Add-Result 'reachability' $true "container reached sshd at $reachable"

    # Probe 2 — forced command: positives run the op, negatives are refused.
    foreach ($op in @('push','pull','fetch')) {
        $r = Invoke-ContainerSsh -Addr $reachable -RemoteCmd "myrepo $op" -Art $art
        Add-Result "allow:$op" ($r.Output -match 'sbx-sync-exec: OK') $r.Output.Split("`n")[-1]
    }
    $deny = @(
        @{ n='deny:clone';     c='myrepo clone' },
        @{ n='deny:force';     c='myrepo push --force' },
        @{ n='deny:traversal'; c='../secret push' },
        @{ n='deny:ghost';     c='ghost push' },
        @{ n='deny:shell';     c='myrepo; sh' }
    )
    foreach ($d in $deny) {
        $r = Invoke-ContainerSsh -Addr $reachable -RemoteCmd $d.c -Art $art
        # Refused == validator said REJECT (or the connection produced no OK).
        Add-Result $d.n (($r.Output -match 'REJECT') -or ($r.Output -notmatch 'sbx-sync-exec: OK')) $r.Output.Split("`n")[-1]
    }
    # Forwarding must be killed by `restrict`, independent of the command.
    $r = Invoke-ContainerSsh -Addr $reachable -RemoteCmd 'myrepo fetch" -L 9999:127.0.0.1:22 "' -Art $art
    Add-Result 'deny:forwarding' ($r.Output -notmatch 'Local forwarding listening') 'restrict should refuse -L/-D'
}
finally {
    if ($KeepArtifacts) {
        Write-Host "  --KeepArtifacts: leaving temp + authorized_keys line in place (undo by hand)." -ForegroundColor Yellow
    } else {
        Remove-AuthorizedKey -Target $target
        if ($art -and (Test-Path $art.Root)) { Remove-Item -Recurse -Force $art.Root }
        Write-Host "  cleaned up throwaway key, authorized_keys line, and temp repo." -ForegroundColor DarkGray
    }
    Write-Host "`n== c-heavy probe results ==" -ForegroundColor Cyan
    $results | Format-Table -AutoSize | Out-Host
    Write-Host "Record these in docs/FINDINGS.md as P7 (template in the runbook)." -ForegroundColor Cyan
}

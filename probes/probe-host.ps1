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
    # Force the authorized_keys file. Default auto-detects the Win32-OpenSSH
    # admin-file quirk; pass e.g. "$HOME\.ssh\authorized_keys" if you've disabled
    # the administrators_authorized_keys Match block in sshd_config.
    [string]$AuthorizedKeysFile,
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
    if ($AuthorizedKeysFile) {
        # Explicit override — caller knows which file THIS sshd honors.
        return [pscustomobject]@{ Path = $AuthorizedKeysFile; Admin = $false; Elevated = $true }
    }
    if ($IsWindows) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        # MEMBERSHIP, not elevation: sshd picks the file by whether the account is
        # in local Administrators, regardless of the current token's elevation.
        # IsInRole() only reports elevation, so it wrongly sends an unelevated
        # admin shell to the per-user file (which sshd then ignores).
        $adminSid = [Security.Principal.SecurityIdentifier]::new(
            [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $memberOfAdmins = @($id.Groups) -contains $adminSid
        $elevated = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($memberOfAdmins) {
            return [pscustomobject]@{
                Path     = (Join-Path $env:ProgramData 'ssh/administrators_authorized_keys')
                Admin    = $true
                Elevated = $elevated
            }
        }
    }
    return [pscustomobject]@{ Path = (Join-Path $HOME '.ssh/authorized_keys'); Admin = $false; Elevated = $true }
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
    & git clone -q $bare $repo 2>&1 | Out-Null   # "cloned an empty repository" is expected here
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
    # authorized_keys command="..." escaping: inner double quotes MUST be written
    # as \" or sshd stops parsing at the first one and silently ignores the key
    # (symptom: "Permission denied (publickey)"). Use forward slashes in paths so
    # no stray backslash confuses sshd's quote parser; pwsh accepts them on Windows.
    $exec = ($ExecPath  -replace '\\', '/')
    $ws   = ($Art.Ws    -replace '\\', '/')
    $forced = 'pwsh -NoProfile -File \"' + $exec + '\" -WorkspaceDir \"' + $ws + '\"'
    $line = 'restrict,command="' + $forced + '" ' + $pub
    $dir = Split-Path -Parent $Target.Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    Add-Content -Path $Target.Path -Value $line
    Write-Host "  wrote forced-command line (tag '$TAG') to $($Target.Path)" -ForegroundColor Yellow
    if ($Target.Admin) {
        # sshd silently ignores administrators_authorized_keys unless it is owned
        # by / writable only by Administrators + SYSTEM. Apply that ACL now so the
        # probe doesn't fail for a reason unrelated to what we're testing.
        & icacls $Target.Path /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARN: could not set ACL on $($Target.Path) — apply the runbook icacls recipe by hand." -ForegroundColor Yellow
        } else {
            Write-Host "  applied Administrators+SYSTEM-only ACL to administrators_authorized_keys" -ForegroundColor DarkGray
        }
    }
}

function Backup-AuthorizedKeys {
    # Snapshot the file EXACTLY (content, or the fact that it didn't exist) so
    # teardown can restore it verbatim. Never do line-surgery on a file that may
    # hold the user's real keys — that risked wiping them.
    param([Parameter(Mandatory)]$Target)
    if (Test-Path -LiteralPath $Target.Path) {
        # Also drop a physical .bak next to it, so a HARD kill that skips `finally`
        # still leaves the user a copy to restore from by hand.
        $bak = "$($Target.Path).sbxprobe.bak"
        Copy-Item -LiteralPath $Target.Path -Destination $bak -Force
        Write-Host "  backed up your authorized_keys to $bak (removed on clean exit)" -ForegroundColor DarkGray
        return [pscustomobject]@{ Existed = $true; Content = (Get-Content -Raw -LiteralPath $Target.Path); Bak = $bak }
    }
    return [pscustomobject]@{ Existed = $false; Content = $null; Bak = $null }
}

function Restore-AuthorizedKeys {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Backup)
    if ($Backup.Existed) {
        # -NoNewline: write back the captured bytes without adding/stripping a
        # trailing newline.
        Set-Content -LiteralPath $Target.Path -Value $Backup.Content -NoNewline
        if ($Backup.Bak -and (Test-Path -LiteralPath $Backup.Bak)) { Remove-Item -LiteralPath $Backup.Bak -Force }
    } elseif (Test-Path -LiteralPath $Target.Path) {
        Remove-Item -LiteralPath $Target.Path -Force
    }
}

function Get-CandidateHostAddresses {
    if ($Address.Count) { return $Address }
    $cands = [System.Collections.Generic.List[string]]::new()
    # Addresses as the CONTAINER sees them: default-route gateway + DNS nameserver
    # (in WSL2 NAT these are typically the host). The slim image has no `ip`, so
    # read /proc/net/route (always present) and /etc/resolv.conf; parse host-side.
    try {
        $raw = & $Runtime run --rm sbx:latest bash -lc 'cat /proc/net/route 2>/dev/null; echo ===; cat /etc/resolv.conf 2>/dev/null'
        $text = @($raw) -join "`n"
        foreach ($ln in ($text -split "`n")) {
            $f = $ln -split '\s+'
            # Default route: Destination 00000000; Gateway is little-endian hex.
            if ($f.Count -ge 3 -and $f[1] -eq '00000000' -and $f[2] -match '^[0-9A-Fa-f]{8}$') {
                $g = $f[2]
                $octets = for ($i = 6; $i -ge 0; $i -= 2) { [Convert]::ToInt32($g.Substring($i, 2), 16) }
                if (($octets -join '.') -ne '0.0.0.0') { $cands.Add($octets -join '.') }
            }
        }
        foreach ($m in [regex]::Matches($text, 'nameserver\s+(\d+\.\d+\.\d+\.\d+)')) { $cands.Add($m.Groups[1].Value) }
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

function Test-LocalPort {
    # Is anything listening on 127.0.0.1:<port> here? Distinguishes "sshd down"
    # from "container can't route to the host".
    param([int]$Port)
    $c = [Net.Sockets.TcpClient]::new()
    try {
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        return $iar.AsyncWaitHandle.WaitOne(1500) -and $c.Connected
    } catch { return $false } finally { $c.Close() }
}

function Get-LastLine {
    param([string]$Text)
    $l = @($Text -split "`n" | Where-Object { $_ -match '\S' })
    if ($l.Count) { $l[-1] } else { '(no output)' }
}

# ---- run ----------------------------------------------------------------------
Write-Host "sbx c-heavy sync probe — runtime=$Runtime user=$SshUser port=$Port" -ForegroundColor Cyan
Write-Host "If interrupted, undo by hand: delete lines tagged '$TAG' from your authorized_keys and remove the temp dir under $([IO.Path]::GetTempPath())." -ForegroundColor DarkGray

$target = Get-AuthorizedKeysTarget
Write-Host "  authorized_keys target: $($target.Path)$(if ($target.Admin) { ' (Win32-OpenSSH admin file)' })" -ForegroundColor DarkGray
# Elevation gate: only the admin-file path needs it (writing under ProgramData\ssh
# + setting its ACL). The per-user file and any -AuthorizedKeysFile override don't.
if ($target.Admin -and -not $target.Elevated) {
    throw "This account is a local Administrator, so sshd reads administrators_authorized_keys — re-run pwsh elevated, or if you disabled that Match block in sshd_config pass -AuthorizedKeysFile `"$HOME\.ssh\authorized_keys`"."
}

# sshd sanity BEFORE we blame reachability.
if ($IsWindows) {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $svc)                       { Write-Host "  WARN: no 'sshd' service — install Win32-OpenSSH (runbook)" -ForegroundColor Yellow }
    elseif ($svc.Status -ne 'Running')   { Write-Host "  WARN: sshd service is $($svc.Status), not Running" -ForegroundColor Yellow }
    else                                 { Write-Host "  sshd service: Running" -ForegroundColor DarkGray }
}
if (Test-LocalPort -Port $Port) { Write-Host "  sshd is listening on 127.0.0.1:$Port (host-local)" -ForegroundColor DarkGray }
else { Write-Host "  WARN: nothing answering on 127.0.0.1:$Port — start sshd before expecting reachability" -ForegroundColor Yellow }

$akBackup = Backup-AuthorizedKeys -Target $target   # snapshot BEFORE any write
$art = $null
try {
    $art = New-ProbeArtifacts
    Install-AuthorizedKey -Art $art -Target $target

    # Probe 1 — reachability: did the container reach the host sshd at all? An
    # auth-layer response ("Permission denied", forced-command OK/REJECT) proves
    # reachability; only "timed out"/"refused"/"could not resolve" mean no route.
    # This is separate from whether our KEY was accepted (probe 2).
    $sshdSeen = 'sbx-sync-exec: (OK|REJECT)|Permission denied|authentication failures|Too many authentication'
    $reachable = $null; $reachOut = $null
    foreach ($addr in (Get-CandidateHostAddresses)) {
        Write-Host "  trying host address $addr ..." -ForegroundColor DarkGray
        $r = Invoke-ContainerSsh -Addr $addr -RemoteCmd 'myrepo fetch' -Art $art
        Write-Host "    -> $(Get-LastLine $r.Output)" -ForegroundColor DarkGray
        if ($r.Output -match $sshdSeen) { $reachable = $addr; $reachOut = $r.Output; break }
    }
    if (-not $reachable) {
        Add-Result 'reachability' $false 'no candidate reached host sshd (routing/sshd; see per-address errors; do NOT proxy via host)'
        return
    }
    Add-Result 'reachability' $true "container reached host sshd at $reachable"

    # Probe 2 — auth + forced command: was our key honored and did the forced
    # command fire? If we only got "Permission denied", the key never landed in a
    # file this sshd reads (wrong authorized_keys file / ACL) — not a reachability
    # problem, so stop here with that verdict rather than run a meaningless matrix.
    if ($reachOut -notmatch 'sbx-sync-exec: (OK|REJECT)') {
        Add-Result 'auth/forced-command' $false "reached sshd but key/forced-command not honored: $(Get-LastLine $reachOut)"
        return
    }
    Add-Result 'auth/forced-command' $true 'dedicated key accepted; forced command fired'

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
        if ($akBackup) { Restore-AuthorizedKeys -Target $target -Backup $akBackup }
        if ($art -and (Test-Path $art.Root)) { Remove-Item -Recurse -Force $art.Root }
        Write-Host "  restored $($target.Path) to its pre-probe state; removed temp key + repo." -ForegroundColor DarkGray
    }
    Write-Host "`n== c-heavy probe results ==" -ForegroundColor Cyan
    $results | Format-Table -AutoSize | Out-Host
    Write-Host "Record these in docs/FINDINGS.md as P7 (template in the runbook)." -ForegroundColor Cyan
}

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
# The SHIPPED validator, not a copy: c-heavy is built now (ROADMAP 1 closed), so
# re-running this harness on a new host must exercise the real forced command.
$ExecPath = (Resolve-Path "$PSScriptRoot/../sbx-sync-exec.ps1").Path
# How the forced command invokes pwsh — the shipped rule (Windows: bare `pwsh`
# off sshd's PATH; macOS: the Homebrew bin WRAPPER, not the Cellar apphost).
$PwshInvoke = Get-SbxPwshCommand
$results  = [System.Collections.Generic.List[object]]::new()
function Add-Result { param($Probe, $Pass, $Detail)
    $results.Add([pscustomobject]@{ Probe = $Probe; Result = $(if ($Pass) {'PASS'} else {'FAIL'}); Detail = $Detail })
    $c = if ($Pass) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1} — {2}" -f $results[-1].Result, $Probe, $Detail) -ForegroundColor $c
}

function Test-InAdministrators {
    if (-not $IsWindows) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    return @($id.Groups) -contains $sid
}

function Get-AuthorizedKeysTarget {
    # Decided by the SHIPPED resolver, so the probe qualifies the file the
    # launcher will actually write. Win32-OpenSSH reads
    # C:\ProgramData\ssh\administrators_authorized_keys instead of the per-user
    # file for members of local Administrators — but only where that file EXISTS,
    # and sbx never creates it: creating it takes precedence for every admin on
    # the host from then on and can lock out logins that relied on
    # ~/.ssh/authorized_keys (see Get-SbxAuthorizedKeysPath, and P7, where this
    # host had no admin file and sshd honored the per-user one).
    #
    # An earlier version of this probe picked the admin file for any admin member
    # and created it. That both mutated the host and qualified a configuration
    # `sbx sync-setup` would never produce.
    $path = Get-SbxAuthorizedKeysPath -Override $AuthorizedKeysFile
    $admin = [IO.Path]::GetFileName($path) -eq 'administrators_authorized_keys'
    $elevated = $true
    if ($IsWindows) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $elevated = ([Security.Principal.WindowsPrincipal]$id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        # MEMBERSHIP, not elevation, is what sshd keys off. Warn rather than act:
        # if this host's sshd_config carries the stock `Match Group administrators`
        # block, an admin account's per-user file is ignored and auth will fail
        # below — with a fix the operator must choose, not one we impose.
        if (-not $admin -and (Test-InAdministrators)) {
            Write-Host "  NOTE: this account is in local Administrators and $($env:ProgramData)\ssh\administrators_authorized_keys does not exist." -ForegroundColor Yellow
            Write-Host "        Using the per-user file (what sbx would use). If auth fails with 'Permission denied (publickey)'," -ForegroundColor Yellow
            Write-Host "        this sshd has the stock Match-Group-administrators block: create that file by hand with the runbook" -ForegroundColor Yellow
            Write-Host "        ACL recipe, or re-run with -AuthorizedKeysFile. The probe will not create it for you." -ForegroundColor Yellow
        }
    }
    return [pscustomobject]@{ Path = $path; Admin = $admin; Elevated = $elevated }
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
    # Built by the SHIPPED line builder, so the probe validates the exact format
    # `sbx sync-setup` installs — only the comment tag differs, keeping the
    # throwaway line distinguishable from a real one.
    $line = Build-SbxAuthorizedKeysLine -PublicKey (Get-Content -Raw $Art.Pub) `
                                        -ExecPath $ExecPath -WorkspaceDir $Art.Ws `
                                        -PwshCommand $PwshInvoke -Tag $TAG
    $dir = Split-Path -Parent $Target.Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    # Newline safety: if the file doesn't end in a newline, Add-Content would
    # MERGE our entry onto the last existing line — the prior key stays valid with
    # a longer comment, ours vanishes → "Permission denied (publickey)". Add a
    # separating newline first when needed.
    if ((Test-Path -LiteralPath $Target.Path) -and
        ((Get-Content -Raw -LiteralPath $Target.Path) -match '[^\r\n]$')) {
        Add-Content -Path $Target.Path -Value ''
    }
    Add-Content -Path $Target.Path -Value $line
    Write-Host "  wrote forced-command line (tag '$TAG') to $($Target.Path)" -ForegroundColor Yellow
    if ($Target.Admin) { Test-AdminKeyFileAcl -Path $Target.Path }
}

function Test-AdminKeyFileAcl {
    # CHECK, never change. sshd silently ignores administrators_authorized_keys
    # unless only Administrators + SYSTEM can write it, so a wrong ACL would make
    # the probe fail for a reason unrelated to what it tests — but the file
    # belongs to the host, and the probe restores contents only. Rewriting the ACL
    # (the old `icacls /inheritance:r`) left the host permanently altered after a
    # successful, "clean" run.
    param([Parameter(Mandatory)][string]$Path)
    $writers = @()
    try {
        $acl = Get-Acl -LiteralPath $Path
        foreach ($ace in $acl.Access) {
            if ($ace.AccessControlType -ne 'Allow') { continue }
            if (-not ($ace.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)) { continue }
            $sid = try { $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
                   catch { "$($ace.IdentityReference)" }
            if ($sid -notin @('S-1-5-32-544', 'S-1-5-18')) { $writers += "$($ace.IdentityReference)" }
        }
    }
    catch {
        Write-Host "  WARN: could not read the ACL on $Path — if auth fails, check it by hand." -ForegroundColor Yellow
        return
    }
    if ($writers) {
        Write-Host "  WARN: $Path is writable by $(($writers | Select-Object -Unique) -join ', ')." -ForegroundColor Yellow
        Write-Host "        sshd ignores this file unless only Administrators and SYSTEM can write it, so auth will likely fail." -ForegroundColor Yellow
        Write-Host "        Apply the runbook icacls recipe by hand — the probe will not change ACLs on your host." -ForegroundColor Yellow
    } else {
        Write-Host "  admin key file ACL looks correct (Administrators + SYSTEM only)" -ForegroundColor DarkGray
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
                # Skip 0.x (invalid) and multicast/reserved (>=224) — malformed or
                # non-default route rows can yield garbage like 0.250.250.200.
                if ($octets[0] -ne 0 -and $octets[0] -lt 224) { $cands.Add($octets -join '.') }
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
    # $SshOpts are real CLIENT options, placed before the destination. They must
    # never be smuggled into $RemoteCmd: that string is single-quoted below, so a
    # flag written there stays part of the remote command and ssh never sees it.
    param([string]$Addr, [string]$RemoteCmd, $Art, [string[]]$SshOpts = @())
    $keydir = Split-Path -Parent $Art.Key
    $mount  = ConvertTo-SbxMountPath -HostPath $keydir -Posix:$IsMacOS
    $opts   = if ($SshOpts.Count) { ($SshOpts -join ' ') + ' ' } else { '' }
    $inner  = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 " +
              "-i /home/agent/.ssh/id_ed25519 -p $Port $opts$SshUser@$Addr '$RemoteCmd'"
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

function Show-SshdAuthLog {
    # On a publickey rejection, sshd almost always logged WHY. Surface it so we
    # can tell StrictModes/ACL ("bad ownership or modes") from a parse problem
    # ("key_read"/"error parsing") from a plain no-match.
    if ($IsMacOS) {
        Write-Host "  --- recent sshd log (macOS unified log) ---" -ForegroundColor DarkGray
        try {
            $lines = & log show --style compact --last 5m --predicate 'process == "sshd"' 2>$null
            @($lines | Where-Object { $_ -match 'refus|publickey|Accepted|Failed|authoriz|modes' } | Select-Object -Last 6) |
                ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        } catch { Write-Host "  (couldn't read the unified log: $($_.Exception.Message))" -ForegroundColor DarkGray }
        return
    }
    if (-not $IsWindows) {
        Write-Host "  check the sshd log for the reason (e.g. journalctl -u ssh / /var/log/auth.log)" -ForegroundColor DarkGray
        return
    }
    try {
        $ev = Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 50 -ErrorAction Stop |
              Where-Object { $_.Message -match 'authoriz|refus|publickey|modes|ownership|Failed|Accepted|parsing|key_read' } |
              Select-Object -First 6
        if ($ev) {
            Write-Host "  --- recent sshd log (OpenSSH/Operational) ---" -ForegroundColor DarkGray
            foreach ($e in $ev) { Write-Host "    $($e.TimeCreated.ToString('HH:mm:ss')) $(($e.Message -split "`n")[0])" -ForegroundColor DarkGray }
        } else {
            Write-Host "  (no matching OpenSSH/Operational events — the log may be disabled; set 'SyslogFacility LOCAL0'/'LogLevel VERBOSE' in sshd_config)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  (couldn't read OpenSSH/Operational log: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
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
elseif ($IsMacOS) {
    Write-Host "  macOS host: ensure Remote Login is ON (System Settings > General > Sharing)." -ForegroundColor DarkGray
    Write-Host "  P6 reminder: grant the container runtime (OrbStack) the Local Network permission, else every host/LAN connection from the container SILENTLY TIMES OUT and looks like an SSH failure." -ForegroundColor Yellow
    Write-Host "  forced command will invoke: $PwshInvoke" -ForegroundColor DarkGray
}
if (Test-LocalPort -Port $Port) { Write-Host "  sshd is listening on 127.0.0.1:$Port (host-local)" -ForegroundColor DarkGray }
else { Write-Host "  WARN: nothing answering on 127.0.0.1:$Port — start sshd before expecting reachability" -ForegroundColor Yellow }

$akBackup = Backup-AuthorizedKeys -Target $target   # snapshot BEFORE any write
$art = $null
try {
    $art = New-ProbeArtifacts
    Install-AuthorizedKey -Art $art -Target $target

    # Probe 1 — reachability: did the container reach the host sshd at all?
    # Reachability = the absence of a CONNECTION-level failure. Anything past that
    # (auth denial, or the forced command running — even erroring) proves we got
    # to sshd. Only these mean "no route":
    $connFail = 'connect to host|Could not resolve hostname|Connection refused|Connection timed out|Operation timed out|No route to host|Network is unreachable'
    $reachable = $null; $reachOut = $null
    foreach ($addr in (Get-CandidateHostAddresses)) {
        Write-Host "  trying host address $addr ..." -ForegroundColor DarkGray
        $r = Invoke-ContainerSsh -Addr $addr -RemoteCmd 'myrepo fetch' -Art $art
        Write-Host "    -> $(Get-LastLine $r.Output)" -ForegroundColor DarkGray
        if ($r.Output -notmatch $connFail) { $reachable = $addr; $reachOut = $r.Output; break }
    }
    if (-not $reachable) {
        Add-Result 'reachability' $false 'no candidate reached host sshd (all connection-level failures; see per-address errors; do NOT proxy via host)'
        return
    }
    Add-Result 'reachability' $true "container reached host sshd at $reachable"

    # Probe 2 — auth + forced command, with the three reached-states distinguished:
    if ($reachOut -match 'Permission denied') {
        # Reached sshd, KEY rejected — wrong authorized_keys file/ACL/format.
        Add-Result 'auth/forced-command' $false "reached sshd but the key was rejected (authorized_keys file/ACL/format): $(Get-LastLine $reachOut)"
        Show-SshdAuthLog
        return
    }
    if ($reachOut -notmatch 'sbx-sync-exec: (RUN|OK|REJECT)') {
        # Key ACCEPTED (no denial) but the forced command didn't run the validator
        # — almost always the host can't launch pwsh in sshd's minimal env.
        Add-Result 'auth/forced-command' $false "key accepted, but the forced command didn't run the validator (host pwsh/PATH?): $(Get-LastLine $reachOut)"
        Show-SshdAuthLog
        return
    }
    Add-Result 'auth/forced-command' $true 'dedicated key accepted; forced command fired'

    # Probe 2 — forced command: positives run the op, negatives are refused.
    # Assert the OUTCOME, not just that a line was printed. `OK` is emitted only
    # after git succeeds (see sbx-sync-exec.ps1), and exit 0 comes with it — an
    # earlier version matched `OK` alone, which the pre-git `OK` made unfalsifiable.
    foreach ($op in @('push','pull','fetch')) {
        $r = Invoke-ContainerSsh -Addr $reachable -RemoteCmd "myrepo $op" -Art $art
        $ok = ($r.Exit -eq 0) -and ($r.Output -match 'sbx-sync-exec: OK')
        Add-Result "allow:$op" $ok "exit $($r.Exit): $(Get-LastLine $r.Output)"
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
        # Refused == the validator SAID SO. The old `-or (no OK)` arm passed on any
        # unrelated ssh failure, which would score a broken probe run as a clean
        # sweep of denials — exactly backwards for a qualification harness.
        $refused = ($r.Output -match 'sbx-sync-exec: REJECT') -and
                   ($r.Output -notmatch 'sbx-sync-exec: (RUN|OK)')
        Add-Result $d.n $refused "exit $($r.Exit): $(Get-LastLine $r.Output)"
    }
    # Forwarding must be killed by `restrict`, independent of the command.
    #
    # Tested with -R, not -L, because only -R is refusable at request time: a
    # remote forward needs a server-side tcpip-forward request, which `restrict`
    # denies outright and ssh reports. A -L forward is a purely client-side
    # listener until something connects through it, so a bare -L can't fail —
    # the previous check passed unconditionally, and worse, wrote the flag inside
    # the quoted remote command where ssh never saw it as an option at all.
    # `restrict` implies no-port-forwarding, which covers both directions.
    $r = Invoke-ContainerSsh -Addr $reachable -RemoteCmd 'myrepo fetch' -Art $art `
                             -SshOpts @('-R', '19999:127.0.0.1:22')
    $refusedFwd = $r.Output -match 'remote port forwarding failed|administratively prohibited|forwarding.*(refused|disabled|not permitted)'
    Add-Result 'deny:forwarding' $refusedFwd "exit $($r.Exit): $(Get-LastLine $r.Output)"
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

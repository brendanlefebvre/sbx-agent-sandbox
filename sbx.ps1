function ConvertFrom-SbxArgs {
    [CmdletBinding()]
    param([string[]]$Arguments = @())

    # Default is foreground ('here'): a bare `sbx` runs in the current terminal so
    # SSH users never have to remember a flag. `--new-window` (aka `--window`/`--win`)
    # opts into spawning a GUI window — Windows-only (see Resolve-SbxWindow).
    $opts = [ordered]@{
        Command = 'attach'; Target = $null; Operation = $null; Window = 'here'
        # sync-setup only (see Invoke-SbxSyncSetup); null means "use the default".
        Address = $null; SshUser = $null; Port = $null; AuthorizedKeysFile = $null
        PrintOnly = $false; Remove = $false
    }
    $positional = [System.Collections.Generic.List[string]]::new()

    # Options that consume the NEXT argument as their value. Kept as a table so the
    # loop below stays a plain if/elseif chain — `continue` inside a `switch` inside
    # a `for` is ambiguous in PowerShell (switch-arm vs enclosing-loop), and getting
    # it wrong here would silently swallow a value as a positional.
    $valueOpts = @{
        '--address'         = 'Address'
        '--user'            = 'SshUser'
        '--port'            = 'Port'
        '--authorized-keys' = 'AuthorizedKeysFile'
    }
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($valueOpts.ContainsKey($arg)) {
            if ($i + 1 -ge $Arguments.Count) { throw "sbx: $arg expects a value" }
            $opts[$valueOpts[$arg]] = $Arguments[++$i]
        }
        elseif ($arg -eq '--new-window') { $opts.Window = 'window' }
        elseif ($arg -eq '--window')     { $opts.Window = 'window' }
        elseif ($arg -eq '--win')        { $opts.Window = 'window' }
        elseif ($arg -eq '--tab')        { $opts.Window = 'tab' }
        elseif ($arg -eq '--print-only') { $opts.PrintOnly = $true }
        elseif ($arg -eq '--remove')     { $opts.Remove = $true }
        elseif ($arg -like '--*')        { throw "Unknown option: $arg" }
        else                             { $positional.Add($arg) }
    }
    if ($opts.Port -and $opts.Port -notmatch '^\d+$') { throw "sbx: --port expects a number, got '$($opts.Port)'" }
    if ($positional.Count -eq 0) { return [pscustomobject]$opts }

    switch ($positional[0]) {
        'add' {
            if ($positional.Count -lt 2) { throw "sbx: 'add' expects a path" }
            $opts.Command = 'add'; $opts.Target = $positional[1]
        }
        'rm' {
            if ($positional.Count -lt 2) { throw "sbx: 'rm' expects a project name" }
            if ($positional[1] -in @('.', '..')) { throw "sbx: invalid project name" }
            $opts.Command = 'rm'; $opts.Target = $positional[1]
        }
        'sync' {
            if ($positional.Count -lt 3) { throw "sbx: 'sync' expects <name> <push|pull|fetch>" }
            if ($positional[1] -in @('.', '..')) { throw "sbx: invalid project name" }
            $opts.Command = 'sync'; $opts.Target = $positional[1]; $opts.Operation = $positional[2]
        }
        'sync-setup' { $opts.Command = 'sync-setup' }
        'ls'      { $opts.Command = 'ls' }
        'rebuild' { $opts.Command = 'rebuild' }
        'stop'    { $opts.Command = 'stop' }
        'scratch' { $opts.Command = 'scratch' }
        'status'  { $opts.Command = 'status' }
        default {
            if ($positional[0] -match '[\\/]') {
                throw "sbx: '$($positional[0])' looks like a path — v2 takes project names; run 'sbx add <path>' once, then 'sbx <name>'"
            }
            if ($positional[0] -in @('.', '..')) { throw "sbx: invalid project name" }
            $opts.Command = 'attach'; $opts.Target = $positional[0]
        }
    }
    return [pscustomobject]$opts
}

function ConvertTo-SbxMountPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HostPath, [switch]$Posix)

    if ($Posix) {
        if ($HostPath -notmatch '^/') {
            throw "Unsupported host path (need an absolute POSIX path): $HostPath"
        }
        $t = $HostPath.TrimEnd('/')
        return ($(if ($t) { $t } else { '/' }))   # never collapse root to empty
    }

    $p = $HostPath -replace '/', '\'          # normalize to backslashes
    $p = $p.TrimEnd('\')                       # drop trailing slash
    if ($p -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Unsupported host path (need a drive-letter path): $HostPath"
    }
    # WINNING FORM per docs/FINDINGS.md: host Windows drive-letter path,
    # forward-slash normalized (backslash also binds, but forward slashes are
    # safe across the wt.exe -> pwsh -Command string hop). The /mnt/c form
    # was tested and mounts an empty location — never emit it.
    $drive = $matches[1].ToUpper()
    $rest  = $matches[2] -replace '\\', '/'
    return "${drive}:/$rest"
}

function Get-SbxContainerName {
    [CmdletBinding()]
    param([string]$Path, [string]$Override, [string]$Suffix)
    if ($Override) { return $Override }
    if (-not $Suffix) {
        $Suffix = -join ((48..57 + 97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { $base = 'scratch' }
    else { $base = Split-Path -Leaf ($Path -replace '[\\/]+$','') }
    return "sbx-$base-$Suffix"
}

function Build-SbxWtBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$RunArgs,
        [string]$Name,
        [string]$Runtime = (Resolve-SbxRuntime)
    )
    # Build a pwsh script that SPLATS the run args (`& <runtime> @a`) instead of
    # re-parsing a flat command string. Passing it via -EncodedCommand means the
    # inner pwsh never re-interprets the tokens, so a path or name containing '$'
    # (a legal Windows dir name), a space, or a quote can't mangle the mount or
    # the cleanup. Each element is emitted as a single-quoted literal.
    $lit    = { "'" + ("$($args[0])" -replace "'", "''") + "'" }
    $argExpr = '@(' + (($RunArgs | ForEach-Object { & $lit $_ }) -join ',') + ')'
    $rt = & $lit $Runtime
    # Best-effort cleanup: when the container exits (claude quits) or the window
    # is closed, stop+remove it so it doesn't linger in `sbx ls`. wslc keeps the
    # container running when the client disconnects, and a forced window close
    # only gives pwsh a brief window to run `finally`, so this is best-effort —
    # if it's ever skipped, clean up by hand (see Remove-SbxContainer).
    $body = "`$a = $argExpr; "
    if ($Name) {
        $rm = Get-SbxRemoveVerb $Runtime
        $n  = & $lit $Name
        $np = & $lit "$Name-proj"
        # Volume remove is a no-op for containers without a -proj volume; kept
        # unconditional so windowed scratch cleanup reaps its throwaway
        # projects volume (see Build-SbxScratchArgs / Remove-SbxScratchLeftovers).
        $body += "try { & $rt @a } finally { & $rt stop $n 2>`$null; & $rt $rm $n 2>`$null; & $rt volume $rm $np 2>`$null }"
    } else {
        $body += "& $rt @a"
    }
    return $body
}

function Start-WtSbx {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$RunArgs,
        [string]$Name,
        [switch]$NewTab,
        [string]$Runtime = (Resolve-SbxRuntime)
    )
    $body = Build-SbxWtBody -RunArgs $RunArgs -Name $Name -Runtime $Runtime
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $wt = [System.Collections.Generic.List[string]]::new()
    if ($NewTab) {
        $wt.Add('-w'); $wt.Add('0'); $wt.Add('new-tab')
    }
    else {
        # -w -1 forces a NEW window; without it Windows Terminal may "glom" the
        # invocation into the most-recently-used window as a tab, violating the
        # new-window contract of --new-window/--window/--win.
        $wt.Add('-w'); $wt.Add('-1')
    }
    $wt.Add('pwsh'); $wt.Add('-NoExit'); $wt.Add('-EncodedCommand'); $wt.Add($encoded)
    Start-Process wt.exe -ArgumentList $wt.ToArray()
}

function Test-SbxBenignRuntimeError {
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return $Text -match '(?i)no such container|no such object|not found|is not running'
}

function Resolve-SbxRuntime {
    [CmdletBinding()]
    param([bool]$IsMac = $IsMacOS, [string]$Override = $env:SBX_RUNTIME)
    if ($Override) { return $Override }
    if ($IsMac)    { return 'docker' }
    return 'wslc'
}

function Invoke-Sbx {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments = @())
    $runtime = Resolve-SbxRuntime
    $o = ConvertFrom-SbxArgs -Arguments $Arguments
    switch ($o.Command) {
        'ls'      { return Get-SbxProjects -Runtime $runtime }
        'add'     { return Add-SbxProject -Path $o.Target }
        'rm'      { return Remove-SbxProject -Name $o.Target -Runtime $runtime }
        'sync'    { return Invoke-SbxSync -Name $o.Target -Operation $o.Operation }
        'sync-setup' {
            $p = @{ PrintOnly = [bool]$o.PrintOnly; Remove = [bool]$o.Remove }
            foreach ($k in 'Address', 'SshUser', 'AuthorizedKeysFile') {
                if ($o.$k) { $p[$k] = $o.$k }
            }
            if ($o.Port) { $p.Port = [int]$o.Port }
            return Invoke-SbxSyncSetup @p
        }
        'rebuild' { return Invoke-SbxRebuild -Runtime $runtime }
        'stop'    { return Stop-SbxMain -Runtime $runtime }
        'status'  { return Invoke-SbxStatus -Runtime $runtime }
        'scratch' {
            $name    = Get-SbxContainerName -Path $null
            $runArgs = Build-SbxScratchArgs -Name $name
            $window  = Resolve-SbxWindow -OnWindows:$IsWindows -Requested $o.Window
            switch ($window) {
                'here'  { try { & $runtime @runArgs } finally { Remove-SbxScratchLeftovers -Name $name -Runtime $runtime } }
                'tab'   { Start-WtSbx -RunArgs $runArgs -Name $name -Runtime $runtime -NewTab }
                default { Start-WtSbx -RunArgs $runArgs -Name $name -Runtime $runtime }
            }
            return
        }
        'attach' {
            Start-SbxMain -Runtime $runtime
            if ($o.Target) {
                $workspaceDir = Get-SbxWorkspacePath
                $projectDir = Join-Path $workspaceDir $o.Target
                if (-not (Test-Path -LiteralPath $projectDir)) {
                    throw "sbx: no project '$($o.Target)' in the workspace — 'sbx add <path>' first (or 'sbx ls')"
                }
                # Guard against traversal (`sbx ..`): the resolved dir must be a DIRECT
                # CHILD of the workspace, not merely *somewhere under* it.
                if ((Get-Item -LiteralPath $projectDir).Parent.FullName -ne (Get-Item -LiteralPath $workspaceDir).FullName) {
                    throw "sbx: no project '$($o.Target)' in the workspace — 'sbx add <path>' first (or 'sbx ls')"
                }
                $session = Get-SbxSessionName $o.Target
                $workdir = "/work/$($o.Target)"
            }
            else { $session = 'hub'; $workdir = '/work' }
            $attachArgs = Build-SbxAttachArgs -Session $session -WorkDir $workdir
            $window = Resolve-SbxWindow -OnWindows:$IsWindows -Requested $o.Window
            switch ($window) {
                'here'  { & $runtime @attachArgs }        # persistent container: no cleanup
                'tab'   { Start-WtSbx -RunArgs $attachArgs -Runtime $runtime -NewTab }
                default { Start-WtSbx -RunArgs $attachArgs -Runtime $runtime }
            }
            return
        }
    }
}

Set-Alias -Name sbx -Value Invoke-Sbx

function ConvertFrom-DockerPs {
    [CmdletBinding()] param([string[]]$Lines)
    # Skip anything that isn't a JSON object: a runtime invoked with flags it
    # doesn't understand prints usage text to stdout, and parsing that line-by-line
    # produces a cascade of useless ConvertFrom-Json errors.
    foreach ($line in ($Lines | Where-Object { $_ -and $_.TrimStart().StartsWith('{') })) {
        $o = $line | ConvertFrom-Json
        $status = switch -Regex ("$($o.State)") {
            '^running' { 'running'; break }
            '^exited'  { 'exited';  break }
            '^created' { 'created'; break }
            default    { if ($o.State) { "$($o.State)" } else { "$($o.Status)" } }
        }
        [pscustomobject]@{ Name = ($o.Names -split ',')[0]; Image = $o.Image; Status = $status }
    }
}

function ConvertFrom-WslcList {
    # $Json is [string[]], NOT [string]: `& wslc list --all --format json` returns one
    # array element per output line. Parameter binding refuses to convert a string[]
    # to a [string] parameter (unlike an explicit [string] cast, which joins) — that
    # mismatch broke `sbx ls` on Windows with "Cannot convert value to type
    # System.String". Join the lines back before parsing.
    [CmdletBinding()] param([string[]]$Json)
    if (-not $Json) { return }
    $raw = ($Json -join "`n").Trim()
    if (-not $raw) { return }
    @($raw | ConvertFrom-Json) |
        Where-Object { $_.Name -like 'sbx-*' } |
        Select-Object Name, Image, @{
            Name = 'Status'
            Expression = {
                switch ($_.State) { 2 { 'running' } 3 { 'exited' } default { "state:$_" } }
            }
        }
}

function Get-SbxList {
    [CmdletBinding()] param([string]$Runtime = (Resolve-SbxRuntime))
    # Explicit if/else, not if-with-return-then-fallthrough: a non-terminating error
    # in the wslc branch used to skip its `return` and drop into the docker branch,
    # which then ran `wslc ps --filter ... --format ...` (flags wslc doesn't have) and
    # spewed parse errors over wslc's usage text. The branches must be exclusive.
    if ($Runtime -eq 'wslc') {
        $global:LASTEXITCODE = 0
        $raw = & $Runtime list --all --format json 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "sbx: '$Runtime list' failed (exit $LASTEXITCODE); cannot list sandboxes"
            return
        }
        return ConvertFrom-WslcList -Json $raw
    }
    else {
        $global:LASTEXITCODE = 0
        $lines = & $Runtime ps -a --filter 'label=sbx=1' --format '{{json .}}' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "sbx: '$Runtime ps' failed (exit $LASTEXITCODE); cannot list sandboxes"
            return
        }
        return ConvertFrom-DockerPs -Lines @($lines)
    }
}

function Get-SbxRemoveVerb {
    param([string]$Runtime)
    if ($Runtime -eq 'wslc') { 'remove' } else { 'rm' }
}

function Remove-SbxContainer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Runtime = (Resolve-SbxRuntime))
    $rm = Get-SbxRemoveVerb $Runtime
    # a --rm container may already be gone; both idempotent. Assign stdout to a
    # variable (not just redirect stderr) so the container name doesn't get
    # echoed twice, but still check the exit code so a real runtime failure
    # (daemon down, etc.) surfaces instead of being silently swallowed. An
    # "already gone" failure (Test-SbxBenignRuntimeError) stays silent.
    $global:LASTEXITCODE = 0
    $out = & $Runtime stop $Name 2>&1
    if ($LASTEXITCODE -ne 0 -and -not (Test-SbxBenignRuntimeError ($out -join ' '))) {
        Write-Warning "sbx: '$Runtime stop $Name' failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
    $global:LASTEXITCODE = 0
    $out = & $Runtime $rm $Name 2>&1
    if ($LASTEXITCODE -ne 0 -and -not (Test-SbxBenignRuntimeError ($out -join ' '))) {
        Write-Warning "sbx: '$Runtime $rm $Name' failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
}

function Remove-SbxVolume {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Runtime = (Resolve-SbxRuntime))
    $verb = if ($Runtime -eq 'wslc') { 'remove' } else { 'rm' }
    $global:LASTEXITCODE = 0
    $out = & $Runtime volume $verb $Name 2>&1
    if ($LASTEXITCODE -ne 0 -and -not (Test-SbxBenignRuntimeError ($out -join ' '))) {
        Write-Warning "sbx: '$Runtime volume $verb $Name' failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
}

function Resolve-SbxWindow {
    [CmdletBinding()]
    param([bool]$OnWindows = $IsWindows, [string]$Requested = 'here')
    if ($OnWindows) { return $Requested }
    # Non-Windows: there is no wt.exe backend, so GUI window/tab spawning is
    # unsupported — fall back to (or, for an explicit request, reject in favor of)
    # foreground. `--new-window`/`--window`/`--win` are Windows-only for now.
    if ($Requested -eq 'window') { throw "sbx: --new-window is not supported on this platform (Windows only, for now)" }
    if ($Requested -eq 'tab')    { throw "sbx: --tab is not supported on this platform (foreground only)" }
    return 'here'
}

function Install-SbxShim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string]$BinDir,
        [bool]$Executable = ($IsMacOS -or $IsLinux)
    )
    if (-not (Test-Path $BinDir)) { New-Item -ItemType Directory -Force $BinDir | Out-Null }
    $shim = Join-Path $BinDir 'sbx'
    $body = @(
        '#!/bin/sh'
        '# sbx launcher shim (macOS) — execs the pwsh CLI entry point.'
        "exec pwsh -NoProfile -File `"$RepoDir/sbx-cli.ps1`" `"`$@`""
    ) -join "`n"
    Set-Content -Path $shim -Value $body
    if ($Executable) { & chmod +x $shim }
    return $shim
}

function Get-SbxWorkspacePath {
    [CmdletBinding()]
    param([string]$Override = $env:SBX_WORKSPACE)
    if ($Override) { return $Override }
    return (Join-Path $HOME 'sbx-ws')
}

function Get-SbxSessionName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # tmux rejects '.' and ':' in session names (window/pane addressing syntax).
    return ($Name -replace '[.:]', '-')
}

function Get-SbxVolumeRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # Longest mount-root prefix wins: C:\ on Windows; / vs /Volumes/X on macOS.
    # The path need not exist (add validates existence separately).
    $full = [System.IO.Path]::GetFullPath($Path)
    $best = ''
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        $root = $d.RootDirectory.FullName
        if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and
            $root.Length -gt $best.Length) { $best = $root }
    }
    if (-not $best) { throw "sbx: cannot determine volume for: $Path" }
    return $best
}

function Get-SbxOriginsPath {
    [CmdletBinding()] param()
    # Host-side, OUTSIDE the workspace: the container must not be able to edit
    # where `sbx rm` moves repos back to.
    return (Join-Path $HOME '.sbx/origins.json')
}

function Get-SbxOrigins {
    [CmdletBinding()]
    param([string]$ManifestPath = (Get-SbxOriginsPath))
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return @{} }
    try {
        $parsed = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "sbx: origins manifest at $ManifestPath is corrupt ($($_.Exception.Message)) — fix or delete it, then re-run"
    }
    if ($parsed -is [hashtable]) { return $parsed }
    return @{}
}

function Save-SbxOrigins {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Origins,
          [string]$ManifestPath = (Get-SbxOriginsPath))
    $dir = Split-Path -Parent $ManifestPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $Origins | ConvertTo-Json | Set-Content -LiteralPath $ManifestPath
}

function New-SbxLink {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LinkPath,
          [Parameter(Mandatory)][string]$TargetPath,
          [bool]$IsWin = $IsWindows)
    # Junction ONLY on Windows (no admin / Developer Mode needed; resolved by
    # NTFS for every local accessor); symlink everywhere else — macOS host AND
    # the Linux container, where self-hosted test runs execute this code and
    # `New-Item -ItemType Junction` silently yields a plain directory. The
    # container never traverses these links either way — it sees the REAL dir
    # in the workspace (FINDINGS 2026-07-22).
    if (-not $IsWin) { $null = New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath -ErrorAction Stop }
    else        { $null = New-Item -ItemType Junction     -Path $LinkPath -Target $TargetPath -ErrorAction Stop }
}

function Stop-SbxSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,
          [string]$Runtime = (Resolve-SbxRuntime))
    # Best-effort: session may not exist, sbx-main may be down, or runtime may be
    # missing from PATH. Never fatal — swallow all errors including CommandNotFoundException.
    try { $null = & $Runtime exec sbx-main tmux kill-session -t (Get-SbxSessionName $Name) 2>$null } catch { }
}

function Add-SbxProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [string]$WorkspaceDir = (Get-SbxWorkspacePath),
          [string]$ManifestPath = (Get-SbxOriginsPath))
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { throw "sbx: path not found: $Path" }
    $src  = $resolved.Path.TrimEnd('\', '/')
    $item = Get-Item -LiteralPath $src
    if ($item.LinkType) { throw "sbx: $src is already a link — was it added already?" }
    $name = Split-Path -Leaf $src
    if ($name -eq 'hub') { throw "sbx: 'hub' is reserved for the orchestrator session" }
    $dest = Join-Path $WorkspaceDir $name
    if (Test-Path -LiteralPath $dest) { throw "sbx: '$name' already exists in the workspace ($dest)" }
    # Session names are derived from the project name (tmux-hostile chars folded
    # to '-'), so two DIFFERENT project names can collide on the SAME tmux
    # session (e.g. 'foo-bar' and 'foo.bar'). Catch it before we move anything.
    $newSession = Get-SbxSessionName $name
    if (Test-Path -LiteralPath $WorkspaceDir) {
        foreach ($existing in Get-ChildItem -LiteralPath $WorkspaceDir -Directory) {
            if ((Get-SbxSessionName $existing.Name) -eq $newSession) {
                throw "sbx: '$name' collides with existing project '$($existing.Name)' (tmux session '$newSession')"
            }
        }
    }
    if (-not (Test-Path -LiteralPath $WorkspaceDir)) {
        New-Item -ItemType Directory -Force $WorkspaceDir | Out-Null
    }
    if ((Get-SbxVolumeRoot $src) -ne (Get-SbxVolumeRoot $WorkspaceDir)) {
        throw "sbx: $src is on a different volume than the workspace ($WorkspaceDir); a cross-volume add would copy instead of rename — not supported"
    }
    Invoke-SbxOutsidePath -Path @($src) -Action {
        Move-Item -LiteralPath $src -Destination $dest -ErrorAction Stop
        New-SbxLink -LinkPath $src -TargetPath $dest
    }
    # Manifest write happens ONLY after both the move and the link succeed — a
    # failure in either throws (ErrorAction Stop) before we reach here, so we
    # never record an entry the filesystem doesn't back up.
    $origins = Get-SbxOrigins -ManifestPath $ManifestPath
    $origins[$name] = $src
    Save-SbxOrigins -Origins $origins -ManifestPath $ManifestPath
    return [pscustomobject]@{ Name = $name; Workspace = $dest; Origin = $src }
}

function Invoke-SbxOutsidePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Path,
          [Parameter(Mandatory)][scriptblock]$Action)
    # PowerShell's FileSystemProvider refuses Move-Item/Remove-Item on an item
    # that is (or contains) the session's current location ("Cannot move item
    # because the item ... is in use") — even on Unix, where a bare rename(2)
    # would succeed. Since `sbx add` is most naturally run from inside the very
    # repo being added, step out to the first path's parent for the duration,
    # then return to the SAME logical path — which, post-move, resolves through
    # the freshly created link, so the caller's location never appears to move.
    $here = (Get-Location).Path
    $sep  = [IO.Path]::DirectorySeparatorChar
    $inside = $false
    foreach ($p in $Path) {
        $full = [IO.Path]::GetFullPath($p)
        if ($here.Equals($full, [StringComparison]::OrdinalIgnoreCase) -or
            $here.StartsWith($full + $sep, [StringComparison]::OrdinalIgnoreCase)) {
            $inside = $true; break
        }
    }
    if (-not $inside) { return (& $Action) }
    Set-Location -LiteralPath (Split-Path -Parent ([IO.Path]::GetFullPath($Path[0])))
    try     { return (& $Action) }
    finally {
        # If the action failed partway the original path may be gone; fall back
        # to the nearest existing ancestor rather than throwing from finally.
        $back = $here
        while ($back -and -not (Test-Path -LiteralPath $back)) { $back = Split-Path -Parent $back }
        if ($back) { Set-Location -LiteralPath $back }
    }
}

function Remove-SbxProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,
          [string]$WorkspaceDir = (Get-SbxWorkspacePath),
          [string]$ManifestPath = (Get-SbxOriginsPath),
          [string]$Runtime = (Resolve-SbxRuntime))
    $dest = Join-Path $WorkspaceDir $Name
    if (-not (Test-Path -LiteralPath $dest)) { throw "sbx: no project '$Name' in the workspace" }
    $origins = Get-SbxOrigins -ManifestPath $ManifestPath
    $origin  = $origins[$Name]
    if (-not $origin) {
        throw "sbx: no recorded origin for '$Name' — move it back by hand from $dest and reconcile $ManifestPath"
    }
    # SAFETY GATE: the manifest names the move-back target, but the LINK is the
    # proof. Only proceed if the origin path is currently a link pointing at the
    # workspace copy — anything else means the world changed under us.
    $link = Get-Item -LiteralPath $origin -ErrorAction SilentlyContinue
    $wantTarget = (Get-Item -LiteralPath $dest).FullName
    $gotTarget  = if ($link -and $link.LinkType) { @($link.Target)[0] } else { $null }
    if (-not $gotTarget -or
        ([IO.Path]::GetFullPath($gotTarget) -ne [IO.Path]::GetFullPath($wantTarget))) {
        throw "sbx: origin check failed for '$Name': expected $origin to be a link to $dest — refusing to move anything. Reconcile by hand."
    }
    Stop-SbxSession -Name $Name -Runtime $Runtime
    # pwsh 7 Remove-Item on a junction/symlink dir removes the REPARSE POINT only
    # (no recursion into the target) — but never pass -Recurse here.
    # -ErrorAction Stop on both: under default ErrorActionPreference a failed
    # Remove-Item/Move-Item is non-terminating, so execution would otherwise fall
    # through to the manifest write below and manufacture the "no recorded
    # origin" state the safety gate above exists to prevent.
    Invoke-SbxOutsidePath -Path @($dest, $origin) -Action {
        Remove-Item -LiteralPath $origin -Force -ErrorAction Stop
        Move-Item -LiteralPath $dest -Destination $origin -ErrorAction Stop
    }
    $origins.Remove($Name)
    Save-SbxOrigins -Origins $origins -ManifestPath $ManifestPath
}

function Build-SbxMainCreateArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath,
          [string]$Image = 'sbx:latest',
          [string]$AuthVolume = 'sbx-claude-auth',
          [string]$Name = 'sbx-main',
          [string]$SyncDir = (Get-SbxProvisionedSyncDir),
          [switch]$Posix)
    $ws = ConvertTo-SbxMountPath -HostPath $WorkspacePath -Posix:$Posix
    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('run','-d','--name',$Name,'--label','sbx=1',
                            '-v',"${AuthVolume}:/home/agent/.claude"))
    # c-heavy: the dedicated sync key, read-only, ONLY when sync-setup has run.
    # Lands at the image's existing .ssh-ro staging point, whose entrypoint copies
    # it to ~/.ssh at 0600 — bind mounts arrive 0777 and ssh refuses such a key.
    if ($SyncDir) {
        $sd = ConvertTo-SbxMountPath -HostPath $SyncDir -Posix:$Posix
        $a.AddRange([string[]]@('-v',"${sd}:/home/agent/.ssh-ro:ro"))
    }
    $a.AddRange([string[]]@('-v',"${ws}:/work",'-w','/work',$Image,'sleep','infinity'))
    return $a.ToArray()
    # Anchor is `sleep infinity`, NOT the tmux server: tmux exits when its last
    # session closes, which would kill the container. Sessions are created on
    # demand through exec (Build-SbxAttachArgs).
}

function Build-SbxAttachArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Session,
          [string]$WorkDir = '/work',
          [string]$Name = 'sbx-main')
    # `new-session -A` attaches if the session exists, creates it (running
    # claude) if not — one verb for both cases.
    return @('exec','-it',$Name,'tmux','new-session','-A',
             '-s',$Session,'-c',$WorkDir,
             'claude','--dangerously-skip-permissions')
}

function Build-SbxScratchArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,
          [string]$Image = 'sbx:latest',
          [string]$AuthVolume = 'sbx-claude-auth')
    return @('run','--rm','-i','-t','--name',$Name,'--label','sbx=1',
             '-v',"${AuthVolume}:/home/agent/.claude",
             # Throwaway per-run projects volume: scratch cwd is /work (image
             # WORKDIR), the same history key the hub session uses in the shared
             # auth volume — without this override a scratch /resume menu shows
             # hub and prior-scratch sessions. wslc rejects anonymous volumes
             # (E_INVALIDARG, see FINDINGS), so it's named after the container
             # and reaped in the same best-effort cleanup.
             '-v',"${Name}-proj:/home/agent/.claude/projects",
             $Image,'claude','--dangerously-skip-permissions')
}

function Remove-SbxScratchLeftovers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Runtime = (Resolve-SbxRuntime))
    Remove-SbxContainer -Name $Name -Runtime $Runtime
    # Volume removal must follow container removal. Remove-SbxVolume tolerates
    # "already gone" but surfaces real runtime failures (Test-SbxBenignRuntimeError).
    Remove-SbxVolume -Name "${Name}-proj" -Runtime $Runtime
}

function Get-SbxMainState {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime), [string]$Name = 'sbx-main')
    $row = @(Get-SbxList -Runtime $Runtime) | Where-Object { $_.Name -eq $Name }
    if (-not $row) { return 'absent' }
    if (@($row)[0].Status -eq 'running') { return 'running' }
    return 'stopped'
}

function Start-SbxMain {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime),
          [string]$WorkspaceDir = (Get-SbxWorkspacePath))
    switch (Get-SbxMainState -Runtime $Runtime) {
        'running' { return }
        'stopped' { $null = & $Runtime start sbx-main; return }
        'absent'  {
            if (-not (Test-Path -LiteralPath $WorkspaceDir)) {
                New-Item -ItemType Directory -Force $WorkspaceDir | Out-Null
            }
            $createArgs = Build-SbxMainCreateArgs -WorkspacePath $WorkspaceDir -Posix:$IsMacOS
            $null = & $Runtime @createArgs
        }
    }
}

function Invoke-SbxRebuild {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime), [switch]$Force)
    if (-not $Force) {
        $answer = Read-Host "sbx: rebuild destroys sbx-main and every running session (workspace and history survive). Continue? [y/N]"
        if ($answer -notmatch '^[Yy]') { return }
    }
    Remove-SbxContainer -Name 'sbx-main' -Runtime $Runtime
    Start-SbxMain -Runtime $Runtime
}

function Stop-SbxMain {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime))
    $null = & $Runtime stop sbx-main 2>$null
}

$script:SbxSyncOps = @('push', 'pull', 'fetch')

function Resolve-SbxSyncRequest {
    [CmdletBinding()]
    param([string]$Name,
          [string]$Operation,
          [Parameter(Mandatory)][string]$WorkspaceDir)
    # THE security core of both sync paths — c-lite (`sbx sync`, host-side, run by
    # the human) and c-heavy (the SSH forced command, run by an agent in the
    # container). One implementation so the two can never drift: whatever the
    # container can ask for is exactly what the human's own command allows.
    #
    # Returns a decision object rather than throwing so the forced command can
    # answer with a structured REJECT line while the CLI throws. Side-effect free
    # apart from reading the filesystem to confirm the repo — it never runs git.
    $deny = { param($r) [pscustomobject]@{ Ok = $false; Name = $null; Operation = $null; Dir = $null; Reason = $r } }

    # Verb allowlist. A wider surface (arbitrary git args) would turn this into a
    # host-command proxy, which it must never become. Canonicalize to the lowercase
    # form actually handed to git so a "PUSH" can't reach git as an invalid verb.
    $canonical = $script:SbxSyncOps | Where-Object { $_ -eq $Operation } | Select-Object -First 1
    if (-not $canonical) {
        return (& $deny "sync operation must be one of: $($script:SbxSyncOps -join ', ')")
    }
    # Reject traversal / separators lexically before touching the filesystem.
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in @('.', '..') -or $Name -match '[\\/]') {
        return (& $deny "no project '$Name' in the workspace")
    }
    $dir = Join-Path $WorkspaceDir $Name
    if (-not (Test-Path -LiteralPath $dir)) {
        return (& $deny "no project '$Name' in the workspace")
    }
    $item = Get-Item -LiteralPath $dir -Force
    # A LINK in the workspace is never a project. `sbx add` puts real directories
    # here (the link it leaves behind points the other way, at the origin), so
    # nothing legitimate is refused — while a symlink planted by the container
    # (which has the workspace mounted read-write) would otherwise pass the
    # parent check below and aim host-side git at any directory on the host.
    if ($item.LinkType) {
        return (& $deny "'$Name' is a link, not a workspace project — refusing to sync through it")
    }
    # Direct-child gate: the repo's parent must BE the workspace, not merely
    # contain it somewhere up the tree. Catches `..` escapes that survive the
    # lexical check above. Both sides stay in the caller's spelling — resolving
    # only one of them would break any user whose workspace path crosses a link.
    if ($item.Parent.FullName -ne (Get-Item -LiteralPath $WorkspaceDir).FullName) {
        return (& $deny "no project '$Name' in the workspace")
    }
    return [pscustomobject]@{ Ok = $true; Name = $Name; Operation = $canonical; Dir = $dir; Reason = $null }
}

function Resolve-SbxSyncCommand {
    [CmdletBinding()]
    param([string]$OriginalCommand,
          [Parameter(Mandatory)][string]$WorkspaceDir)
    # Parses the one string SSH hands the forced command (SSH_ORIGINAL_COMMAND)
    # into the two fields Resolve-SbxSyncRequest validates.
    if ([string]::IsNullOrWhiteSpace($OriginalCommand)) {
        return [pscustomobject]@{ Ok = $false; Name = $null; Operation = $null; Dir = $null
                                  Reason = 'no command (bare connection) — expected "<name> <op>"' }
    }
    # Requiring EXACTLY two whitespace-separated tokens is itself a guard: it
    # rejects "push --force", "name; sh", "name op extra", and any shell operator
    # that would smuggle in a second word.
    $tokens = $OriginalCommand.Trim() -split '\s+'
    if ($tokens.Count -ne 2) {
        return [pscustomobject]@{ Ok = $false; Name = $null; Operation = $null; Dir = $null
                                  Reason = "expected exactly two tokens '<name> <op>', got $($tokens.Count)" }
    }
    return (Resolve-SbxSyncRequest -Name $tokens[0] -Operation $tokens[1] -WorkspaceDir $WorkspaceDir)
}

# ---- hardening the host-side git call -----------------------------------------
#
# Both sync paths run git ON THE HOST inside a repo the AGENT can write. git is
# not a passive file format: `.git/hooks/*` and a dozen config keys name programs
# git executes. Verified on this repo's own test rig: an agent-written
# `.git/hooks/pre-push` runs host-side as the host user on `sbx sync push`, and a
# repo-local `core.sshCommand` does the same on fetch. So the allowlist of three
# verbs is NOT by itself a boundary — the git invocation has to be shut down too.
#
# Two tiers, and the difference matters:
#   * `-c` pins below are RACELESS — command-line config beats every file, and the
#     container cannot edit our argv. This is the part to rely on.
#   * the local-config denylist is ADVISORY: the container can rewrite
#     .git/config after we read it and before git does. It catches accidents and
#     the lazy attack, not a determined one.
# Residual risk is real and documented in docs/SYNC.md — read it before enabling
# c-heavy on a machine where host compromise matters.

function Get-SbxNoHooksDir {
    [CmdletBinding()] param()
    # An empty directory to aim core.hooksPath at. Host-side and outside the
    # workspace so the container cannot fill it with hooks of its own.
    $d = Join-Path $HOME '.sbx/no-hooks'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
    return $d
}

function Get-SbxGitHardeningArgs {
    [CmdletBinding()]
    param([string]$NoHooksDir = (Get-SbxNoHooksDir))
    # Every pin here overrides whatever the repo's own config says, unraceably.
    # Where the host legitimately configures the same key (an ssh command, a
    # credential helper), we read the HOST's value and re-pin it, so hardening
    # never costs the user their own working setup.
    $a = [System.Collections.Generic.List[string]]::new()
    # Not a `-c core.pager=cat` pin: `cat` doesn't exist on Windows. --no-pager is
    # the portable form and outranks config just the same.
    $a.Add('--no-pager')
    $a.AddRange([string[]]@('-c', "core.hooksPath=$NoHooksDir"))   # .git/hooks/* — the default path, no config key needed
    $a.AddRange([string[]]@('-c', 'core.fsmonitor=false'))          # names a program git spawns
    $a.AddRange([string[]]@('-c', 'protocol.ext.allow=never'))      # ext:: URLs ARE a command line
    $a.AddRange([string[]]@('-c', 'protocol.file.allow=user'))      # submodule-from-local-path exec path

    # Single-valued: pin the host's own value, or a safe default if unset.
    # core.editor has no portable no-op ('true' is not a Windows command). That is
    # acceptable: these verbs only reach an editor for an interactive merge, where
    # failing an unattended sync is the outcome we want anyway — and far better
    # than running the editor the repo names.
    foreach ($k in @(@{ Key = 'core.sshCommand'; Fallback = 'ssh' },
                     @{ Key = 'gpg.program';     Fallback = 'gpg' },
                     @{ Key = 'core.editor';     Fallback = 'true' },
                     @{ Key = 'core.askPass';    Fallback = '' })) {
        $v = Get-SbxHostGitConfig -Key $k.Key
        if ($null -eq $v) { $v = $k.Fallback }
        $a.AddRange([string[]]@('-c', "$($k.Key)=$v"))
    }
    # credential.helper is MULTI-valued: a `-c` would append to the repo's list
    # rather than replace it. An empty value resets the list, so reset first, then
    # re-add the host's own helpers in order.
    $a.AddRange([string[]]@('-c', 'credential.helper='))
    foreach ($h in @(Get-SbxHostGitConfig -Key 'credential.helper' -All)) {
        if ($h) { $a.AddRange([string[]]@('-c', "credential.helper=$h")) }
    }
    return $a.ToArray()
}

function Get-SbxHostGitConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, [switch]$All)
    # The HOST's own setting for $Key — global and system scope only, never the
    # repo's. Reading --local here would import exactly what we are defending
    # against.
    $getter = if ($All) { '--get-all' } else { '--get' }
    $out = @()
    try {
        $global:LASTEXITCODE = 0
        $out = @(& git config --global $getter $Key 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $out) {
            $global:LASTEXITCODE = 0
            $out = @(& git config --system $getter $Key 2>$null)
            if ($LASTEXITCODE -ne 0) { $out = @() }
        }
    }
    catch { $out = @() }   # git absent entirely: fall back to the safe defaults
    $global:LASTEXITCODE = 0
    if ($All) { return @($out | Where-Object { $_ }) }
    if ($out.Count) { return $out[0] }
    return $null
}

# Repo-local config keys naming a program git will execute, which we cannot pin
# by name because the middle segment is arbitrary (filter.<name>.clean and
# friends). Matched case-insensitively against `git config --list --show-scope`
# restricted to local + worktree scope.
$script:SbxUnsafeGitConfigPatterns = @(
    '^core\.(hookspath|sshcommand|fsmonitor|editor|pager|askpass|gitproxy|alternaterefscommand|externaldiff)$'
    '^credential(\..*)?\.helper$'
    '^gpg(\..*)?\.program$'
    '^protocol(\..*)?\.allow$'
    '^remote\..*\.(uploadpack|receivepack|proxy|vcs)$'
    '^filter\..*\.(clean|smudge|process)$'
    '^(diff|difftool)\..*\.(command|textconv|cmd)$'
    '^(merge|mergetool)\..*\.(driver|cmd)$'
    '^sequence\.editor$'
    '^trailer\..*\.command$'
    '^(uploadpack|receive)\..*hook.*$'
    '^pager\..*$'
    '^(browser\..*\.cmd|web\.browser)$'
    '^init\.templatedir$'
)

function Get-SbxUnsafeGitConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir)
    # Advisory only — see the tier note above. --show-scope covers .git/config AND
    # config.worktree, which --local alone would miss. A key whose VALUE contains
    # newlines can inject extra output lines, but only ever adding false
    # positives: it cannot hide a line that git itself will honor.
    try {
        $global:LASTEXITCODE = 0
        $lines = @(& git -C $Dir config --list --show-scope 2>$null)
    }
    catch { $global:LASTEXITCODE = 0; return @() }
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; return @() }
    $bad = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in $lines) {
        if ($ln -notmatch '^(local|worktree)\s+([^=]+)=') { continue }
        # Capture BEFORE the inner -match, which clobbers $matches.
        $raw = $matches[2].Trim()
        $key = $raw.ToLowerInvariant()
        foreach ($p in $script:SbxUnsafeGitConfigPatterns) {
            if ($key -match $p) { $bad.Add($raw); break }
        }
    }
    return @($bad | Select-Object -Unique)
}

function Get-SbxLockDir {
    [CmdletBinding()] param()
    # Host-side and OUTSIDE the workspace, for the same reason as origins.json:
    # the container must not be able to touch the coordination state.
    return (Join-Path $HOME '.sbx/locks')
}

function Invoke-SbxSyncGit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Dir,
          [Parameter(Mandatory)][string]$Operation,
          [string]$LockDir = (Get-SbxLockDir),
          [string[]]$HardeningArgs = (Get-SbxGitHardeningArgs),
          [int]$TimeoutSec = 120)
    # Serializes syncs of the SAME project across callers. With c-heavy live, N
    # agents can trigger a push concurrently and the human can run `sbx sync` on
    # top; two `git push`es racing in one worktree otherwise collide on git's own
    # index/ref locks and surface as spurious failures. Different projects never
    # contend — the lock is per repo dir.
    if (-not (Test-Path -LiteralPath $LockDir)) { New-Item -ItemType Directory -Force $LockDir | Out-Null }
    $lockFile = Join-Path $LockDir (((Split-Path -Leaf $Dir) -replace '[^A-Za-z0-9._-]', '_') + '.lock')
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $stream = $null
    while (-not $stream) {
        try {
            $stream = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate,
                                      [IO.FileAccess]::Write, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ((Get-Date) -gt $deadline) {
                throw "sbx: timed out after ${TimeoutSec}s waiting for another sync of '$(Split-Path -Leaf $Dir)' to finish"
            }
            Start-Sleep -Milliseconds 250
        }
    }
    try {
        $unsafe = Get-SbxUnsafeGitConfig -Dir $Dir
        if ($unsafe) {
            throw ("sbx: refusing to sync '$(Split-Path -Leaf $Dir)' — its repo-local git config sets " +
                   "$($unsafe -join ', '), which git executes as a program on THIS host. " +
                   "Inspect it (git -C `"$Dir`" config --list --show-scope) and remove the key if you did not set it.")
        }
        # One flat array rather than a splat: splatting an EMPTY $HardeningArgs
        # slips an empty-string argument into git's argv.
        $gitArgs = @('-C', $Dir) + @($HardeningArgs | Where-Object { $null -ne $_ }) + @($Operation)
        # Reset first: a native command sets $LASTEXITCODE, but a stale value from
        # an earlier call (or a mocked git in tests) must not read as a failure.
        $global:LASTEXITCODE = 0
        & git @gitArgs
        # git's own stderr already told the human what went wrong; this makes the
        # FAILURE ITSELF programmatic. Without it a rejected push returns cleanly:
        # c-lite reports nothing amiss, and the forced command's catch — the only
        # thing that emits the documented FAILED line — never fires.
        if ($LASTEXITCODE -ne 0) {
            throw "sbx: git $Operation failed (exit $LASTEXITCODE) in '$(Split-Path -Leaf $Dir)'"
        }
    }
    finally { $stream.Dispose() }
}

function Invoke-SbxSync {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name,
          [Parameter(Mandatory)][string]$Operation,
          [string]$WorkspaceDir = (Get-SbxWorkspacePath))
    # c-lite sync (see spec): host-side git with host credentials, run by the
    # human. c-heavy (`sbx sync-setup`) lets an agent reach the SAME core through
    # an SSH forced command — see sbx-sync-exec.ps1.
    $d = Resolve-SbxSyncRequest -Name $Name -Operation $Operation -WorkspaceDir $WorkspaceDir
    if (-not $d.Ok) { throw "sbx: $($d.Reason)" }
    Invoke-SbxSyncGit -Dir $d.Dir -Operation $d.Operation
}

# ---- c-heavy: SSH forced-command callback (ROADMAP 1; probed in FINDINGS P7) ---
#
# `sbx sync-setup` provisions a DEDICATED keypair for the container and pins it in
# the host's authorized_keys with `restrict,command="… sbx-sync-exec.ps1 …"`. A
# connection with that key can only invoke the validator for {push,pull,fetch} on
# a workspace repo — never a shell, never forwarding, never another key's reach.
# This deliberately trades away the c-lite "agents commit, human pushes" gate.

$script:SbxSyncTag = 'sbx-sync'

function Get-SbxSyncDir {
    [CmdletBinding()]
    param([string]$Override = $env:SBX_SYNC_DIR)
    # Holds the container's dedicated private key + sync.conf. Bind-mounted
    # read-only into sbx-main; deliberately NOT under ~/.ssh, so nothing here can
    # be confused with (or widen the reach of) the host's own keys.
    if ($Override) { return $Override }
    return (Join-Path $HOME '.sbx/sync')
}

function Get-SbxSyncKeyPath {
    [CmdletBinding()]
    param([string]$SyncDir = (Get-SbxSyncDir))
    # Named id_* on purpose: the image entrypoint chmods /home/agent/.ssh/id_* to
    # 0600 after copying from the read-only mount, and ssh refuses a key that is
    # group/world readable (bind mounts land 0777).
    return (Join-Path $SyncDir 'id_sbx_sync')
}

function Get-SbxProvisionedSyncDir {
    [CmdletBinding()]
    param([string]$SyncDir = (Get-SbxSyncDir))
    # $null unless c-heavy is actually provisioned — callers use it to decide
    # whether sbx-main gets the key mount at all. No setup, no key in the sandbox.
    if (Test-Path -LiteralPath (Get-SbxSyncKeyPath -SyncDir $SyncDir)) { return $SyncDir }
    return $null
}

function New-SbxSyncKey {
    [CmdletBinding()]
    param([string]$SyncDir = (Get-SbxSyncDir), [switch]$Force)
    $key = Get-SbxSyncKeyPath -SyncDir $SyncDir
    if ((Test-Path -LiteralPath $key) -and -not $Force) { return $key }
    if (-not (Test-Path -LiteralPath $SyncDir)) { New-Item -ItemType Directory -Force $SyncDir | Out-Null }
    Remove-Item -LiteralPath $key, "$key.pub" -Force -ErrorAction SilentlyContinue
    # No passphrase: the container must use it unattended. That is the whole
    # threat model — the key's authority is bounded by the forced command, not by
    # secrecy of use.
    & ssh-keygen -t ed25519 -N '' -C $script:SbxSyncTag -f $key -q
    if ($LASTEXITCODE -ne 0) { throw "sbx: ssh-keygen failed (exit $LASTEXITCODE)" }
    return $key
}

function Get-SbxPwshCommand {
    [CmdletBinding()]
    param([bool]$IsWin = $IsWindows)
    # How the forced command launches pwsh, under sshd's MINIMAL environment.
    # Windows: bare `pwsh` resolves via sshd's PATH, and the absolute path
    # ("C:\Program Files\PowerShell\...") carries a space we'd have to re-quote.
    # macOS: the login shell's PATH usually lacks Homebrew, so pin an absolute
    # path — but the BIN WRAPPER, not the Cellar apphost it resolves to: the
    # apphost fails "missing runtime" without the wrapper's DOTNET_ROOT (P7).
    if ($IsWin) { return 'pwsh' }
    $cand = @('/opt/homebrew/bin/pwsh', '/usr/local/bin/pwsh', '/usr/bin/pwsh') |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($cand) { return $cand }
    $src = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ($src) { return $src }
    return 'pwsh'
}

function ConvertTo-SbxSshCommandArg {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # A path going INSIDE the double-quoted command="..." of an authorized_keys
    # line. Forward slashes throughout (pwsh accepts them on Windows) so we never
    # have to reason about backslash escaping; a path containing spaces gets an
    # inner \"-escaped\" pair, which is what sshd's option parser understands.
    $p = $Path -replace '\\', '/'
    if ($p -match '\s') { return "\`"$p\`"" }
    return $p
}

function Build-SbxAuthorizedKeysLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PublicKey,
          [Parameter(Mandatory)][string]$ExecPath,
          [Parameter(Mandatory)][string]$WorkspaceDir,
          [string]$PwshCommand = (Get-SbxPwshCommand),
          [string]$Tag = $script:SbxSyncTag)
    # `restrict` disables pty, X11, agent and PORT FORWARDING (a `-L`/`-D` tunnel
    # would otherwise hand the container a way around the whole allowlist);
    # `command=` pins the only thing this key can ever run. Both are load-bearing.
    $fields = ($PublicKey.Trim() -split '\s+')
    if ($fields.Count -lt 2) { throw "sbx: not a public key: $PublicKey" }
    # Rewrite the comment to exactly our tag — that comment is how Update-SbxAuthorizedKeys
    # finds OUR line later, so it must be ours alone and stable across rotations.
    $pub = "$($fields[0]) $($fields[1]) $Tag"
    $cmd = "$PwshCommand -NoProfile -File $(ConvertTo-SbxSshCommandArg $ExecPath)" +
           " -WorkspaceDir $(ConvertTo-SbxSshCommandArg $WorkspaceDir)"
    return "restrict,command=`"$cmd`" $pub"
}

function Get-SbxAuthorizedKeysPath {
    [CmdletBinding()]
    param([string]$Override, [bool]$IsWin = $IsWindows)
    if ($Override) { return $Override }
    if ($IsWin) {
        # Win32-OpenSSH reads administrators_authorized_keys instead of the
        # per-user file for members of local Administrators — but ONLY when the
        # sshd_config Match block is in force. Use it if it EXISTS; never create
        # it (P7: creating it takes precedence for admins from then on and can
        # lock out normal logins). Absent → the per-user file, which is what the
        # probed host actually honored.
        $adminFile = Join-Path $env:ProgramData 'ssh/administrators_authorized_keys'
        if (Test-Path -LiteralPath $adminFile) { return $adminFile }
    }
    return (Join-Path $HOME '.ssh/authorized_keys')
}

function Update-SbxAuthorizedKeys {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
          [string]$Line,
          [string]$Tag = $script:SbxSyncTag,
          [switch]$Remove)
    # Edits ONE line — ours, identified by the trailing comment $Tag — and leaves
    # every other byte of the file alone. Two P7 lessons are baked in:
    #  1. a file whose last line lacks a newline MERGES an appended entry onto it
    #     (the old key survives with a longer comment, ours silently vanishes);
    #  2. never line-edit a real key file without an exact snapshot first — an
    #     early harness rewrite blanked a user's real key.
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force $dir | Out-Null
        if (-not $IsWindows) { & chmod 700 $dir }
    }
    $existed = Test-Path -LiteralPath $Path
    $raw = if ($existed) { Get-Content -Raw -LiteralPath $Path } else { '' }
    if ($null -eq $raw) { $raw = '' }
    if ($existed) { Copy-Item -LiteralPath $Path -Destination "$Path.sbx.bak" -Force }

    # Preserve the file's own line endings rather than imposing ours.
    $eol = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $kept = [System.Collections.Generic.List[string]]::new()
    $tagRe = "\s$([regex]::Escape($Tag))\s*$"
    $replaced = $false
    foreach ($ln in ($raw -split "`r?`n")) {
        if ($ln -match $tagRe) { $replaced = $true; continue }
        $kept.Add($ln)
    }
    while ($kept.Count -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
        $kept.RemoveAt($kept.Count - 1)
    }
    if (-not $Remove) {
        if (-not $Line) { throw "sbx: Update-SbxAuthorizedKeys needs -Line unless -Remove" }
        $kept.Add($Line)
    }
    # Always terminate the final line: the next tool to append (ours or anyone
    # else's) must not merge onto it. WriteAllText for byte-exact control —
    # Out-File would add a BOM that sshd treats as part of the first key.
    $text = if ($kept.Count) { ($kept -join $eol) + $eol } else { '' }
    # Write beside it and swap, rather than truncating in place: an interrupted
    # write (or a full disk) would otherwise leave a HALF a key file, and this is
    # the file the user's own sshd logins depend on. The .sbx.bak sidecar only
    # helps someone who still has a session open.
    $tmp = "$Path.sbx.tmp"
    [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { & chmod 600 $tmp }
    try {
        if ($existed) {
            # Replace, not Move: it preserves the DESTINATION's ACL and attributes.
            # A move would hand the new file the directory's inherited ACL — and
            # for administrators_authorized_keys, an ACL sshd doesn't like means
            # it silently ignores every key in it (see Set-SbxAdminKeysAcl).
            [IO.File]::Replace($tmp, $Path, $null)
        }
        else { [IO.File]::Move($tmp, $Path) }
    }
    catch {
        # Some filesystems don't support atomic replace. Losing the swap is worse
        # than the torn-write window it protects against, so fall back rather than
        # leaving the user with no authorized_keys at all.
        [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
    if (-not $IsWindows) { & chmod 600 $Path }
    return [pscustomobject]@{ Path = $Path; Replaced = $replaced; Backup = $(if ($existed) { "$Path.sbx.bak" }) }
}

function Set-SbxAdminKeysAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    # sshd SILENTLY ignores administrators_authorized_keys unless it is writable
    # only by Administrators + SYSTEM — a rejected key with no visible cause.
    # Well-known SIDs, not names: the groups are localized.
    & icacls $Path /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "sbx: could not tighten the ACL on $Path — sshd may ignore it. Run (elevated): icacls `"$Path`" /inheritance:r /grant `"Administrators:F`" /grant `"SYSTEM:F`""
    }
}

function Write-SbxSyncConf {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Address,
          [Parameter(Mandatory)][string]$SshUser,
          [int]$Port = 22,
          [string]$SyncDir = (Get-SbxSyncDir))
    # Read LIVE by the in-container client off the read-only mount, so changing
    # the host address doesn't need a container rebuild. Deliberately not env
    # vars baked into `run` args, which would.
    if (-not (Test-Path -LiteralPath $SyncDir)) { New-Item -ItemType Directory -Force $SyncDir | Out-Null }
    $path = Join-Path $SyncDir 'sync.conf'
    # LF endings and no BOM: this is parsed by /bin/sh inside the container.
    $body = (@("# written by sbx sync-setup — read by the in-container `sbx sync` client",
               "host=$Address", "user=$SshUser", "port=$Port") -join "`n") + "`n"
    [IO.File]::WriteAllText($path, $body, [Text.UTF8Encoding]::new($false))
    return $path
}

function Get-SbxSyncConf {
    [CmdletBinding()]
    param([string]$SyncDir = (Get-SbxSyncDir))
    $path = Join-Path $SyncDir 'sync.conf'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $conf = @{}
    foreach ($ln in (Get-Content -LiteralPath $path)) {
        if ($ln -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $conf[$matches[1]] = $matches[2] }
    }
    return $conf
}

function Invoke-SbxSyncSetup {
    [CmdletBinding()]
    param([string]$Address,
          [string]$SshUser = $(if ($env:USERNAME) { $env:USERNAME } else { $env:USER }),
          [int]$Port = 22,
          [string]$AuthorizedKeysFile,
          [switch]$PrintOnly,
          [switch]$Remove,
          [string]$SyncDir = (Get-SbxSyncDir),
          [string]$WorkspaceDir = (Get-SbxWorkspacePath),
          [string]$ExecPath = (Join-Path $PSScriptRoot 'sbx-sync-exec.ps1'))
    $akPath = Get-SbxAuthorizedKeysPath -Override $AuthorizedKeysFile

    if ($Remove) {
        $r = Update-SbxAuthorizedKeys -Path $akPath -Remove
        Remove-Item -LiteralPath $SyncDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "sbx: c-heavy sync revoked — key material removed from $SyncDir$(if ($r.Replaced) { "; authorized_keys line dropped from $akPath" } else { "; no tagged line found in $akPath" })" -ForegroundColor Yellow
        Write-Host "sbx: run 'sbx rebuild' to drop the key mount from the running sandbox." -ForegroundColor Yellow
        return
    }
    if (-not $Address) {
        throw @"
sbx: sync-setup needs the host address the CONTAINER should dial: sbx sync-setup --address <addr>
     Auto-discovery is unreliable (FINDINGS P7) — pin it yourself:
       Windows: the WSL vEthernet gateway (e.g. 172.20.240.1) — host-only, preferred
       macOS:   host.docker.internal
     Check it from inside the sandbox first:  ssh -p $Port $SshUser@<addr>
"@
    }
    if (-not (Test-Path -LiteralPath $ExecPath)) { throw "sbx: forced-command validator not found at $ExecPath" }
    $ExecPath = (Resolve-Path -LiteralPath $ExecPath).Path

    $key  = New-SbxSyncKey -SyncDir $SyncDir
    $line = Build-SbxAuthorizedKeysLine -PublicKey (Get-Content -Raw "$key.pub") `
                                        -ExecPath $ExecPath -WorkspaceDir $WorkspaceDir
    if ($PrintOnly) {
        Write-Host "sbx: add this single line to $akPath (one line, no wrapping):`n" -ForegroundColor Cyan
        Write-Output $line
        return
    }
    $r = Update-SbxAuthorizedKeys -Path $akPath -Line $line
    if ($IsWindows -and $akPath -like '*administrators_authorized_keys') { Set-SbxAdminKeysAcl -Path $akPath }
    elseif ($IsWindows -and (Test-SbxInAdministrators)) {
        Write-Warning "sbx: this account is in local Administrators. If sshd_config still has the 'Match Group administrators' block, sshd reads administrators_authorized_keys and will IGNORE $akPath. Verify a sync before trusting it."
    }
    $conf = Write-SbxSyncConf -Address $Address -SshUser $SshUser -Port $Port -SyncDir $SyncDir

    Write-Host "sbx: c-heavy sync provisioned." -ForegroundColor Green
    Write-Host "  key         $key (mounted read-only into sbx-main)"
    Write-Host "  config      $conf  ->  $SshUser@${Address}:$Port"
    Write-Host "  authorized  $akPath $(if ($r.Replaced) { '(replaced the previous sbx-sync line)' } else { '(appended)' }); backup at $($r.Backup)"
    Write-Host "  agents get  push / pull / fetch on workspace repos — nothing else." -ForegroundColor DarkGray
    Write-Host "sbx: run 'sbx rebuild' so sbx-main picks up the key, then 'sbx sync push' from inside a project." -ForegroundColor Cyan
    return [pscustomobject]@{ Key = $key; Config = $conf; AuthorizedKeys = $akPath; Address = $Address }
}

function Test-SbxInAdministrators {
    [CmdletBinding()] param()
    # MEMBERSHIP, not elevation: sshd picks the authorized_keys file by whether the
    # account is in local Administrators, regardless of the current token. (An
    # IsInRole() check reports elevation and would answer the wrong question.)
    if (-not $IsWindows) { return $false }
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    return @($id.Groups) -contains $sid
}

function Get-SbxLiveSessions {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime))
    if ((Get-SbxMainState -Runtime $Runtime) -ne 'running') { return @() }
    return @(& $Runtime exec sbx-main tmux list-sessions -F '#S' 2>$null | Where-Object { $_ })
}

function Get-SbxProjects {
    [CmdletBinding()]
    param([string]$WorkspaceDir = (Get-SbxWorkspacePath),
          [string]$ManifestPath = (Get-SbxOriginsPath),
          [string]$Runtime = (Resolve-SbxRuntime))
    if (-not (Test-Path -LiteralPath $WorkspaceDir)) { return }
    $origins = Get-SbxOrigins -ManifestPath $ManifestPath
    $live    = Get-SbxLiveSessions -Runtime $Runtime
    # Dot-dirs are infrastructure, not projects (e.g. the planned /work/.sbx
    # status dir from docs/sbx-agent-status.md) — never list them.
    foreach ($d in (Get-ChildItem -LiteralPath $WorkspaceDir -Directory | Where-Object { $_.Name -notlike '.*' })) {
        [pscustomobject]@{
            Name    = $d.Name
            Origin  = $origins[$d.Name]
            Session = ((Get-SbxSessionName $d.Name) -in $live)
        }
    }
}

function Invoke-SbxStatus {
    [CmdletBinding()]
    param([string]$Runtime = (Resolve-SbxRuntime),
          [string]$ScriptPath = (Join-Path $PSScriptRoot 'sbx-agent-status.sh'))
    # Fleet oversight cross-check (docs/sbx-agent-status.md): the script needs
    # tmux, which lives inside sbx-main, so pipe it in over exec's stdin — no
    # image change, nothing written to the workspace. Read-only by design: if
    # the container isn't up there is nothing to report, so don't start it.
    if ((Get-SbxMainState -Runtime $Runtime) -ne 'running') {
        return "sbx: sbx-main is not running — nothing to report"
    }
    $execArgs = [System.Collections.Generic.List[string]]::new()
    $execArgs.Add('exec'); $execArgs.Add('-i')
    if ($env:SBX_IDLE_WARN) {
        $execArgs.Add('-e'); $execArgs.Add("SBX_IDLE_WARN=$($env:SBX_IDLE_WARN)")
    }
    $execArgs.Add('sbx-main'); $execArgs.Add('bash'); $execArgs.Add('-s')
    $a = $execArgs.ToArray()
    # The script's output is UTF-8 (tmux pane titles carry claude's glyphs);
    # PowerShell decodes native stdout with [Console]::OutputEncoding, which
    # defaults to the legacy OEM codepage on Windows and mojibakes them
    # (observed: "Γ£│" for "✳"). Pin UTF-8 for the duration of the call.
    $prevEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        Get-SbxStatusScriptBody -ScriptPath $ScriptPath | & $Runtime @a
    }
    finally { [Console]::OutputEncoding = $prevEnc }
}

function Get-SbxStatusScriptBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptPath)
    # Two CRLF hazards between here and bash: (1) a Windows checkout can hand
    # us the script with CRLF endings, which bash rejects line by line
    # ($'\r': command not found) — normalize. (2) PowerShell appends a
    # PLATFORM newline (\r\n on Windows) when piping a string into a native
    # command, so bash would see one trailing line containing just \r — end
    # the body with `exit 0` so bash never reads past the real script.
    $body = (Get-Content -LiteralPath $ScriptPath -Raw) -replace "`r`n", "`n"
    return $body.TrimEnd("`n") + "`nexit 0`n"
}

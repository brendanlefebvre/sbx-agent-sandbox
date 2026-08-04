#requires -Version 7
# Wire the `sbx` launcher into the user's PowerShell profile by dot-sourcing
# sbx.ps1 from this repo. Idempotent: re-running does not duplicate the line.
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$repo/sbx.ps1"

if ($IsMacOS) {
    $bin  = Join-Path $HOME '.local/bin'
    $shim = Install-SbxShim -RepoDir $repo -BinDir $bin
    Write-Host "Installed sbx shim at $shim"
    if (($env:PATH -split ':') -notcontains $bin) {
        Write-Host "NOTE: $bin is not on your PATH. Add:  export PATH=`"$bin`:`$PATH`""
    }
    Write-Host "Open a new shell, then try:  sbx <name>   (runs in the current terminal)"
    return
}
# --- Windows wiring below (unchanged) ---

$line = ". '$repo\sbx.ps1'"

$profilePath = $PROFILE.CurrentUserAllHosts
$dir = Split-Path -Parent $profilePath
if (-not (Test-Path $dir))         { New-Item -ItemType Directory -Force $dir | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force $profilePath | Out-Null }

# Null-safe literal check: Get-Content -Raw returns $null for an empty profile,
# and `$null -notmatch <pattern>` yields a falsy empty array (not $true), which
# would wrongly skip the append. Use IsNullOrEmpty + a literal Contains.
$existing = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($existing) -or -not $existing.Contains($line)) {
    Add-Content $profilePath "`n# sbx launcher`n$line"
    Write-Host "Added sbx to $profilePath"
} else {
    Write-Host "sbx already present in $profilePath"
}
# Add the repo to the user PATH so `sbx` (via sbx.cmd) works from cmd.exe too.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';' | Where-Object { $_ }) -notcontains $repo) {
    $newPath = if ([string]::IsNullOrEmpty($userPath)) { $repo } else { "$($userPath.TrimEnd(';'));$repo" }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "Added $repo to your user PATH (for cmd.exe) - restart shells to pick it up"
} else {
    Write-Host "$repo already on your user PATH"
}

Write-Host "Open a new pwsh session, then try:  sbx <name>   (add --new-window for a separate WT window)"

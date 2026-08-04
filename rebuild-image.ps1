#requires -Version 7
# Rebuild the sbx:latest image from the Sandboxfile, then recreate sbx-main
# from it (Invoke-SbxRebuild) so the running sandbox actually picks it up.
# Runtime is wslc on Windows / docker on macOS, override via $env:SBX_RUNTIME.
param([switch]$Force)
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$repo/sbx.ps1"

$runtime = Resolve-SbxRuntime
Write-Host "sbx: building image with $runtime..." -ForegroundColor Cyan
& $runtime build -t sbx:latest -f "$repo/Sandboxfile" $repo
if ($LASTEXITCODE -ne 0) {
    throw "sbx: image build failed (exit $LASTEXITCODE) — sbx-main left untouched."
}

Invoke-SbxRebuild -Runtime $runtime -Force:$Force

BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

# Windows-only where wslc is mocked. Each mock is preceded by an empty
# `function wslc {}` - Mock cannot attach to a command that does not exist, and
# wslc is absent from a stock CI runner as well as from macOS.
Describe 'Invoke-SbxStatus' -Skip:(-not $IsWindows) {
    BeforeEach { $script:scriptPath = "$PSScriptRoot/../sbx-agent-status.sh" }
    It 'reports when sbx-main is not running without touching the runtime' {
        Mock -CommandName Get-SbxMainState -MockWith { 'absent' }
        function wslc {}
        Mock -CommandName wslc -MockWith { throw 'must not run' }
        Invoke-SbxStatus -Runtime 'wslc' -ScriptPath $script:scriptPath |
            Should -BeLike '*not running*'
    }
    It 'pipes the script into bash -s inside sbx-main' {
        Mock -CommandName Get-SbxMainState -MockWith { 'running' }
        function wslc {}
        Mock -CommandName wslc -MockWith { $script:seen = $args }
        Invoke-SbxStatus -Runtime 'wslc' -ScriptPath $script:scriptPath
        ($script:seen -join ' ') | Should -Be 'exec -i sbx-main bash -s'
    }
    It 'normalizes CRLF out of the piped script body and ends with exit 0' {
        $p = Join-Path $TestDrive 'crlf.sh'
        [System.IO.File]::WriteAllText($p, "#!/bin/bash`r`necho hi`r`n")
        $body = Get-SbxStatusScriptBody -ScriptPath $p
        $body.Contains("`r") | Should -BeFalse
        # exit 0 guard: PowerShell appends \r\n when piping to a native
        # command; bash must exit before reading that trailing line.
        $body | Should -Be "#!/bin/bash`necho hi`nexit 0`n"
    }
    It 'forwards SBX_IDLE_WARN into the container environment when set' {
        Mock -CommandName Get-SbxMainState -MockWith { 'running' }
        function wslc {}
        Mock -CommandName wslc -MockWith { $script:seen = $args }
        $env:SBX_IDLE_WARN = '5'
        try     { Invoke-SbxStatus -Runtime 'wslc' -ScriptPath $script:scriptPath }
        finally { Remove-Item Env:SBX_IDLE_WARN -ErrorAction SilentlyContinue }
        ($script:seen -join ' ') | Should -Be 'exec -i -e SBX_IDLE_WARN=5 sbx-main bash -s'
    }
}

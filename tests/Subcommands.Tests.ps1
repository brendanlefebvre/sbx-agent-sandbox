BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

# Windows-only: these exercise the live `wslc` runtime path. The cross-platform
# docker/wslc list PARSERS are covered pure in tests/List.Tests.ps1; the docker
# path is covered there and by verify/CHECKLIST.md.
#
# Every wslc mock is preceded by an empty `function wslc {}`, exactly as the
# docker cases below do it. Mock cannot attach to a command that does not exist,
# and wslc is absent from a stock windows-latest runner - without the stub these
# pass only on a machine that happens to have wslc installed, which is how they
# went green locally and red the first time CI ran them.
Describe 'Get-SbxList' -Skip:(-not $IsWindows) {
    It 'returns only sbx-* containers from wslc list json (real PascalCase/State-int shape, per docs/FINDINGS.md)' {
        function wslc {}
        Mock -CommandName wslc -MockWith {
            '[{"Name":"sbx-foo-abc123","Image":"sbx:latest","State":2},
              {"Name":"unrelated","Image":"debian","State":2}]'
        }
        $r = Get-SbxList
        @($r).Count  | Should -Be 1
        $r[0].Name   | Should -Be 'sbx-foo-abc123'
        $r[0].Status | Should -Be 'running'
    }
    It 'maps State 3 to exited and an unknown State to a state label' {
        function wslc {}
        Mock -CommandName wslc -MockWith {
            '[{"Name":"sbx-x-1","Image":"sbx:latest","State":3},
              {"Name":"sbx-y-2","Image":"sbx:latest","State":9}]'
        }
        $r = Get-SbxList
        ($r | Where-Object Name -eq 'sbx-x-1').Status | Should -Be 'exited'
        ($r | Where-Object Name -eq 'sbx-y-2').Status | Should -Be 'state:9'
    }
}

Describe 'Get-SbxList surfaces runtime failures' -Skip:(-not $IsWindows) {
    It 'warns and returns nothing when the runtime call fails' {
        function wslc {}
        Mock -CommandName wslc -MockWith { $global:LASTEXITCODE = 1; 'daemon unreachable' }
        $warnings = @()
        $r = Get-SbxList -WarningAction SilentlyContinue -WarningVariable warnings
        $r | Should -BeNullOrEmpty
        $warnings.Count | Should -BeGreaterThan 0
    }
    It 'does not warn when the runtime call succeeds' {
        function wslc {}
        Mock -CommandName wslc -MockWith { $global:LASTEXITCODE = 0; '[]' }
        $warnings = @()
        $null = Get-SbxList -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings.Count | Should -Be 0
    }
}

Describe 'Remove-SbxContainer surfaces non-benign runtime failures' -Skip:(-not $IsWindows) {
    It 'stays silent (exit 0) when the container is already gone' {
        function wslc {}
        Mock -CommandName wslc -MockWith { $global:LASTEXITCODE = 1; 'Error: No such container: sbx-foo' }
        $warnings = @()
        Remove-SbxContainer -Name 'sbx-foo' -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings.Count | Should -Be 0
    }
    It 'warns when the runtime call fails for a real reason' {
        function wslc {}
        Mock -CommandName wslc -MockWith { $global:LASTEXITCODE = 1; 'daemon unreachable' }
        $warnings = @()
        Remove-SbxContainer -Name 'sbx-foo' -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings.Count | Should -BeGreaterThan 0
    }
    It 'does not double-echo the container name to stdout on success' {
        function wslc {}
        Mock -CommandName wslc -MockWith { $global:LASTEXITCODE = 0; 'sbx-foo' }
        $out = Remove-SbxContainer -Name 'sbx-foo' -WarningAction SilentlyContinue 6>&1
        $out | Should -BeNullOrEmpty
    }
}

Describe 'Get-SbxList surfaces runtime failures (macOS/docker)' -Skip:(-not $IsMacOS) {
    It 'warns and returns nothing when the runtime call fails' {
        function docker {}
        Mock -CommandName docker -MockWith { $global:LASTEXITCODE = 1; 'daemon unreachable' }
        $warnings = @()
        $r = Get-SbxList -Runtime 'docker' -WarningAction SilentlyContinue -WarningVariable warnings
        $r | Should -BeNullOrEmpty
        $warnings.Count | Should -BeGreaterThan 0
    }
    It 'does not warn when the runtime call succeeds' {
        function docker {}
        Mock -CommandName docker -MockWith { $global:LASTEXITCODE = 0; '[]' }
        $warnings = @()
        $null = Get-SbxList -Runtime 'docker' -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings.Count | Should -Be 0
    }
}

Describe 'Remove-SbxContainer surfaces non-benign runtime failures (macOS/docker)' -Skip:(-not $IsMacOS) {
    It 'stays silent (exit 0) when the container is already gone' {
        function docker {}
        Mock -CommandName docker -MockWith { $global:LASTEXITCODE = 1; 'Error: No such container: sbx-foo' }
        $warnings = @()
        Remove-SbxContainer -Name 'sbx-foo' -Runtime 'docker' -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings.Count | Should -Be 0
    }
    It 'warns when the runtime call fails for a real reason' {
        function docker {}
        Mock -CommandName docker -MockWith { $global:LASTEXITCODE = 1; 'daemon unreachable' }
        $warnings = @()
        Remove-SbxContainer -Name 'sbx-foo' -Runtime 'docker' -WarningAction SilentlyContinue -WarningVariable warnings
        $warnings.Count | Should -BeGreaterThan 0
    }
    It 'does not double-echo the container name to stdout on success' {
        function docker {}
        Mock -CommandName docker -MockWith { $global:LASTEXITCODE = 0; 'sbx-foo' }
        $out = Remove-SbxContainer -Name 'sbx-foo' -Runtime 'docker' -WarningAction SilentlyContinue 6>&1
        $out | Should -BeNullOrEmpty
    }
}

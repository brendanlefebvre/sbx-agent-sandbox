BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'ConvertFrom-DockerPs' {
    It 'maps Names/Image/State into Name/Image/Status (running)' {
        $line = '{"Names":"sbx-foo-abc123","Image":"sbx:latest","State":"running","Status":"Up 2 minutes"}'
        $r = ConvertFrom-DockerPs -Lines @($line)
        $r.Name   | Should -Be 'sbx-foo-abc123'
        $r.Image  | Should -Be 'sbx:latest'
        $r.Status | Should -Be 'running'
    }
    It 'maps an exited container' {
        $line = '{"Names":"sbx-foo-x","Image":"sbx:latest","State":"exited","Status":"Exited (0) 1 min ago"}'
        (ConvertFrom-DockerPs -Lines @($line)).Status | Should -Be 'exited'
    }
    It 'ignores blank lines' {
        ConvertFrom-DockerPs -Lines @('', '') | Should -BeNullOrEmpty
    }
    It 'skips non-JSON junk lines instead of erroring (e.g. a runtime printing usage text)' {
        $lines = @('Usage: wslc [OPTIONS]', 'Commands:', '  list', '')
        { ConvertFrom-DockerPs -Lines $lines -ErrorAction Stop } | Should -Not -Throw
        ConvertFrom-DockerPs -Lines $lines | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-WslcList' {
    It 'filters to sbx-* and maps State int to Status' {
        $json = '[{"Name":"sbx-foo-abc","Image":"sbx:latest","State":2},' +
                '{"Name":"other","Image":"x","State":3}]'
        $r = ConvertFrom-WslcList -Json $json
        @($r).Count | Should -Be 1
        $r.Name     | Should -Be 'sbx-foo-abc'
        $r.Status   | Should -Be 'running'
    }
    # Regression: `& wslc list --all --format json` returns a string[] (one element
    # per output line). A [string] PARAMETER refuses that outright - unlike an
    # explicit [string] cast, parameter binding does not join arrays - so `sbx ls`
    # blew up on Windows with "Cannot convert value to type System.String".
    It 'accepts wslc''s multi-line string[] output' {
        $lines = @('[{"Name":"sbx-foo-abc","Image":"sbx:latest","State":2},',
                   ' {"Name":"other","Image":"x","State":3}]')
        $r = ConvertFrom-WslcList -Json $lines
        @($r).Count | Should -Be 1
        $r.Name     | Should -Be 'sbx-foo-abc'
        $r.Status   | Should -Be 'running'
    }
    It 'returns nothing for empty or whitespace output without throwing' {
        { ConvertFrom-WslcList -Json @() -ErrorAction Stop }   | Should -Not -Throw
        { ConvertFrom-WslcList -Json @('','') -ErrorAction Stop } | Should -Not -Throw
        ConvertFrom-WslcList -Json @()     | Should -BeNullOrEmpty
        ConvertFrom-WslcList -Json @('','') | Should -BeNullOrEmpty
    }
}

BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

# Windows-only: mocks the `wslc` runtime and asserts WT spawning (both Windows-only).
Describe 'Invoke-Sbx dispatch (v2)' -Skip:(-not $IsWindows) {
    BeforeEach {
        Mock -CommandName Start-SbxMain -MockWith { }
        Mock -CommandName Get-SbxWorkspacePath -MockWith { Join-Path $TestDrive 'ws' }
        New-Item -ItemType Directory -Force (Join-Path $TestDrive 'ws\foo') | Out-Null
    }
    It 'sbx foo (default) ensures sbx-main then execs the tmux attach in-process' {
        function wslc {}
        Mock -CommandName wslc -MockWith { $script:seen = $args }
        Invoke-Sbx @('foo')
        Should -Invoke Start-SbxMain -Times 1
        ($script:seen -join ' ') | Should -Be 'exec -it sbx-main tmux new-session -A -s foo -c /work/foo claude --dangerously-skip-permissions'
    }
    It 'sbx (no args, default) attaches the hub at /work' {
        function wslc {}
        Mock -CommandName wslc -MockWith { $script:seen = $args }
        Invoke-Sbx @()
        ($script:seen -join ' ') | Should -BeLike '*-s hub -c /work claude*'
    }
    It 'sbx foo --new-window spawns a NEW WT window with the encoded attach, no cleanup' {
        Mock -CommandName Start-Process -MockWith { $script:file = "$FilePath"; $script:wt = $ArgumentList }
        function wslc {}
        Mock -CommandName wslc -MockWith { throw 'should not run in-process' }
        Invoke-Sbx @('foo', '--new-window')
        $script:file | Should -Be 'wt.exe'
        $script:wt   | Should -Contain '-1'
        $ix = [array]::IndexOf($script:wt, '-EncodedCommand')
        $decoded = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:wt[$ix + 1]))
        $decoded | Should -BeLike "*& 'wslc' @a*"
        $decoded | Should -BeLike "*'exec'*'sbx-main'*"
        $decoded | Should -Not -BeLike '*finally*'      # never reap the persistent container
    }
    It 'sbx ghost throws when the project is not in the workspace' {
        { Invoke-Sbx @('ghost') } | Should -Throw '*no project*'
    }
    It 'scratch (default) runs --rm with cleanup and no /work' {
        $script:calls = @()
        function wslc {}
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        Invoke-Sbx @('scratch')
        ($script:calls -join '|') | Should -BeLike '*run --rm*'
        ($script:calls -join '|') | Should -Not -BeLike '*:/work *'
        ($script:calls -join '|') | Should -BeLike '*stop sbx-scratch-*'
        ($script:calls -join '|') | Should -BeLike '*volume remove sbx-scratch-*-proj*'
    }
    It 'add / rm / sync / ls / rebuild / stop route to their handlers' {
        Mock -CommandName Add-SbxProject    -MockWith { }
        Mock -CommandName Remove-SbxProject -MockWith { }
        Mock -CommandName Invoke-SbxSync    -MockWith { }
        Mock -CommandName Get-SbxProjects   -MockWith { }
        Mock -CommandName Invoke-SbxRebuild -MockWith { }
        Mock -CommandName Stop-SbxMain      -MockWith { }
        Invoke-Sbx @('add', 'C:\src\foo');  Should -Invoke Add-SbxProject    -Times 1
        Invoke-Sbx @('rm', 'foo');          Should -Invoke Remove-SbxProject -Times 1
        Invoke-Sbx @('sync', 'foo', 'push'); Should -Invoke Invoke-SbxSync   -Times 1
        Invoke-Sbx @('ls');                 Should -Invoke Get-SbxProjects   -Times 1
        Mock -CommandName Invoke-SbxStatus  -MockWith { }
        Invoke-Sbx @('rebuild');            Should -Invoke Invoke-SbxRebuild -Times 1
        Invoke-Sbx @('status');             Should -Invoke Invoke-SbxStatus  -Times 1
        Invoke-Sbx @('stop');               Should -Invoke Stop-SbxMain      -Times 1
    }
}

Describe 'Get-SbxRemoveVerb' {
    It 'wslc uses remove' { Get-SbxRemoveVerb 'wslc'   | Should -Be 'remove' }
    It 'docker uses rm'   { Get-SbxRemoveVerb 'docker' | Should -Be 'rm' }
}

Describe 'Resolve-SbxWindow' {
    It 'passes the request through on Windows' {
        Resolve-SbxWindow -OnWindows:$true -Requested 'here'   | Should -Be 'here'
        Resolve-SbxWindow -OnWindows:$true -Requested 'window' | Should -Be 'window'
        Resolve-SbxWindow -OnWindows:$true -Requested 'tab'    | Should -Be 'tab'
    }
    It 'defaults to foreground (here) off Windows and rejects --new-window/--tab' {
        Resolve-SbxWindow -OnWindows:$false -Requested 'here'    | Should -Be 'here'
        { Resolve-SbxWindow -OnWindows:$false -Requested 'window' } | Should -Throw '*new-window*'
        { Resolve-SbxWindow -OnWindows:$false -Requested 'tab' }    | Should -Throw '*tab*'
    }
}

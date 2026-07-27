BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

# -SyncDir $null and -GhDir $null in both: without them these read the REAL
# ~/.sbx/sync and ~/.sbx/gh and describe whatever this host happens to be,
# so they passed only until someone ran `sbx sync-setup` / `sbx gh-setup`.
# The c-heavy mount has its own coverage in SyncSetup.Tests.ps1; the c-gh
# mount has its own coverage in GhSetup.Tests.ps1.
Describe 'Build-SbxMainCreateArgs' {
    It 'creates a detached sbx-main with exactly the workspace and auth mounts' {
        $a = Build-SbxMainCreateArgs -WorkspacePath 'C:\Users\user\sbx-ws' -SyncDir $null -GhDir $null
        ($a -join ' ') | Should -BeLike 'run -d --name sbx-main*'
        ($a -join ' ') | Should -BeLike '*--label sbx=1*'
        ($a -join ' ') | Should -BeLike '*-v sbx-claude-auth:/home/agent/.claude*'
        ($a -join ' ') | Should -BeLike '*-v C:/Users/user/sbx-ws:/work*'
        ($a -join ' ') | Should -BeLike '*-w /work*'
        (@($a) | Where-Object { $_ -eq '-v' }).Count | Should -Be 2      # exactly two mounts
        $a[-2..-1] | Should -Be @('sleep','infinity')                     # anchor process
        ($a -join ' ') | Should -Not -BeLike '*--rm*'                     # persistent
        ($a -join ' ') | Should -Not -BeLike '*.ssh*'                     # never keys
    }
    It 'passes a POSIX workspace path through verbatim with -Posix' {
        $a = Build-SbxMainCreateArgs -WorkspacePath '/Users/user/sbx-ws' -SyncDir $null -GhDir $null -Posix
        ($a -join ' ') | Should -BeLike '*-v /Users/user/sbx-ws:/work*'
    }
}

Describe 'Build-SbxAttachArgs' {
    It 'execs an attach-or-create tmux session running claude' {
        $a = Build-SbxAttachArgs -Session 'foo' -WorkDir '/work/foo'
        $a | Should -Be @('exec','-it','sbx-main','tmux','new-session','-A',
                          '-s','foo','-c','/work/foo',
                          'claude','--dangerously-skip-permissions')
    }
    It 'defaults to the hub vantage at /work' {
        $a = Build-SbxAttachArgs -Session 'hub'
        ($a -join ' ') | Should -BeLike '*-s hub -c /work claude*'
    }
}

Describe 'Build-SbxScratchArgs' {
    It 'is a --rm throwaway: auth volume + per-run projects volume, running claude' {
        $a = Build-SbxScratchArgs -Name 'sbx-scratch-abc123'
        ($a -join ' ') | Should -BeLike 'run --rm*--name sbx-scratch-abc123*'
        ($a -join ' ') | Should -BeLike '*-v sbx-claude-auth:/home/agent/.claude*'
        # Throwaway projects volume isolates scratch /resume from hub history
        # (both cwds are /work) and from prior scratch runs.
        ($a -join ' ') | Should -BeLike '*-v sbx-scratch-abc123-proj:/home/agent/.claude/projects*'
        (@($a) | Where-Object { $_ -eq '-v' }).Count | Should -Be 2
        ($a -join ' ') | Should -Not -BeLike '*:/work *'
        $a[-2..-1] | Should -Be @('claude','--dangerously-skip-permissions')
    }
}

Describe 'Get-SbxMainState' {
    It 'absent when no sbx-main row' {
        Mock -CommandName Get-SbxList -MockWith { @() }
        Get-SbxMainState -Runtime 'wslc' | Should -Be 'absent'
    }
    It 'running / stopped from the Status field' {
        Mock -CommandName Get-SbxList -MockWith { @([pscustomobject]@{ Name='sbx-main'; Status='running' }) }
        Get-SbxMainState -Runtime 'wslc' | Should -Be 'running'
        Mock -CommandName Get-SbxList -MockWith { @([pscustomobject]@{ Name='sbx-main'; Status='exited' }) }
        Get-SbxMainState -Runtime 'wslc' | Should -Be 'stopped'
    }
}

Describe 'Start-SbxMain' -Skip:(-not $IsWindows) {
    It 'no-ops when already running' {
        Mock -CommandName Get-SbxMainState -MockWith { 'running' }
        Mock -CommandName wslc -MockWith { throw 'should not be called' }
        Start-SbxMain -Runtime 'wslc' -WorkspaceDir (Join-Path $TestDrive 'ws')
    }
    It 'starts a stopped container' {
        Mock -CommandName Get-SbxMainState -MockWith { 'stopped' }
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        Start-SbxMain -Runtime 'wslc' -WorkspaceDir (Join-Path $TestDrive 'ws')
        $script:calls | Should -Contain 'start sbx-main'
    }
    It 'creates when absent, creating the workspace dir first' {
        Mock -CommandName Get-SbxMainState -MockWith { 'absent' }
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        $ws = Join-Path $TestDrive 'fresh-ws'
        Start-SbxMain -Runtime 'wslc' -WorkspaceDir $ws
        Test-Path $ws | Should -BeTrue
        ($script:calls -join '|') | Should -BeLike '*run -d --name sbx-main*sleep infinity*'
    }
}

Describe 'Invoke-SbxRebuild / Stop-SbxMain' -Skip:(-not $IsWindows) {
    It 'rebuild -Force removes then recreates without prompting' {
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        Mock -CommandName Get-SbxMainState -MockWith { 'absent' }
        Mock -CommandName Get-SbxWorkspacePath -MockWith { Join-Path $TestDrive 'ws' }
        Mock -CommandName Read-Host -MockWith { throw 'must not prompt with -Force' }
        Invoke-SbxRebuild -Runtime 'wslc' -Force
        ($script:calls -join '|') | Should -BeLike '*stop sbx-main*'
        ($script:calls -join '|') | Should -BeLike '*remove sbx-main*'
        ($script:calls -join '|') | Should -BeLike '*run -d --name sbx-main*'
    }
    It 'rebuild aborts on a non-y answer' {
        Mock -CommandName Read-Host -MockWith { 'n' }
        Mock -CommandName wslc -MockWith { throw 'should not touch the runtime' }
        Invoke-SbxRebuild -Runtime 'wslc'
    }
    It 'stop stops the container (but does not remove it)' {
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        Stop-SbxMain -Runtime 'wslc'
        $script:calls | Should -Contain 'stop sbx-main'
        ($script:calls -join '|') | Should -Not -BeLike '*remove*'
    }
}

Describe 'Get-SbxContainerName' {
    It 'uses the override verbatim when given' {
        Get-SbxContainerName -Path 'C:\x\repo' -Override 'myname' | Should -Be 'myname'
    }
    It 'builds sbx-<basename>-<suffix> for a real path' {
        Get-SbxContainerName -Path 'C:\x\my-repo' -Suffix 'abc123' | Should -Be 'sbx-my-repo-abc123'
    }
    It 'uses "scratch" as the basename when no path' {
        Get-SbxContainerName -Path $null -Suffix 'abc123' | Should -Be 'sbx-scratch-abc123'
    }
}

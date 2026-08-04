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

Describe 'Build-SbxGitIdentityArgs' {
    It 'seeds the global identity through exec, values as argv (no shell quoting)' {
        $a = Build-SbxGitIdentityArgs -UserName 'Ada Lovelace' -Email 'ada@example.com'
        $a[0..3] | Should -Be @('exec','sbx-main','bash','-c')
        # Values ride as positional args after the `--` $0 placeholder, never
        # interpolated into the script - a name with a quote or a newline in it
        # cannot become a second config key.
        $a[-3..-1] | Should -Be @('--','Ada Lovelace','ada@example.com')
        $a[4] | Should -BeLike '*git config --global user.name "$1"*'
        $a[4] | Should -BeLike '*git config --global user.email "$2"*'
    }
    It 'no-ops only when the container already has BOTH identity fields, non-empty' {
        $a = Build-SbxGitIdentityArgs -UserName 'x' -Email 'y@z'
        # The guard runs first and short-circuits, so re-running create/rebuild
        # never clobbers an identity set by hand. It requires BOTH fields AND
        # non-empty values: `git config --get` exits 0 for a present-but-blank
        # key, so a bare --get check would wrongly skip reseeding. Assert the
        # `[ -n "$(...)" ]` form guards user.name AND user.email before exit 0.
        $a[4] | Should -Match '-n "\$\(git config --global --get user\.name'
        $a[4] | Should -Match '-n "\$\(git config --global --get user\.email'
        $a[4] | Should -Match '\]\s*&&\s*exit 0'
    }
    It 'targets a named container' {
        (Build-SbxGitIdentityArgs -UserName 'a' -Email 'b@c' -Name 'sbx-other')[1] |
            Should -Be 'sbx-other'
    }
}

Describe 'Build-SbxGitIdentityVolumeArgs' {
    It 'seeds the shared auth volume via a one-shot run --rm, same script as exec' {
        $a = Build-SbxGitIdentityVolumeArgs -UserName 'Ada Lovelace' -Email 'ada@example.com'
        $a[0..1] | Should -Be @('run','--rm')
        ($a -join ' ') | Should -BeLike '*-v sbx-claude-auth:/home/agent/.claude*'
        ($a -join ' ') | Should -BeLike '*sbx:latest bash -c*'
        # Identical guard/seed script as the exec path (index differs: run args
        # are longer), and values as positional argv after the `--` placeholder.
        $exec = Build-SbxGitIdentityArgs -UserName 'x' -Email 'y@z'
        $a[7] | Should -Be $exec[4]
        $a[-3..-1] | Should -Be @('--','Ada Lovelace','ada@example.com')
    }
    It 'mounts ONLY the auth volume - never /work or a projects volume' {
        $a = Build-SbxGitIdentityVolumeArgs -UserName 'x' -Email 'y@z'
        (@($a) | Where-Object { $_ -eq '-v' }).Count | Should -Be 1
        ($a -join ' ') | Should -Not -BeLike '*:/work*'
        ($a -join ' ') | Should -Not -BeLike '*-proj:*'
    }
}

Describe 'Get-SbxHostGitIdentity' {
    AfterEach { $env:SBX_GIT_USER_NAME = $null; $env:SBX_GIT_USER_EMAIL = $null }
    It 'prefers SBX_GIT_USER_* over the host git config' {
        $env:SBX_GIT_USER_NAME  = 'Env Name'
        $env:SBX_GIT_USER_EMAIL = 'env@example.com'
        $id = Get-SbxHostGitIdentity
        $id.Name  | Should -Be 'Env Name'
        $id.Email | Should -Be 'env@example.com'
    }
    It 'returns null when either half is missing - a half identity is not usable' {
        $env:SBX_GIT_USER_NAME  = 'Only A Name'
        $env:SBX_GIT_USER_EMAIL = ''
        Mock -CommandName git -MockWith { }      # host config reads as empty
        Get-SbxHostGitIdentity | Should -BeNullOrEmpty
    }
    It 'reads host-level git config via Get-SbxHostGitConfig, never repo-local' {
        # Delegating to Get-SbxHostGitConfig (global/system scope only) is what
        # stops `sbx rebuild` run inside a repo from seeding that repo's local
        # user.email into the shared sandbox identity.
        Mock -CommandName Get-SbxHostGitConfig -MockWith {
            if ($Key -eq 'user.name') { 'Host Name' } else { 'host@example.com' }
        }
        $id = Get-SbxHostGitIdentity
        $id.Name  | Should -Be 'Host Name'
        $id.Email | Should -Be 'host@example.com'
        Should -Invoke Get-SbxHostGitConfig -Times 2 -Exactly
    }
}

Describe 'Set-SbxContainerGitIdentity' {
    It 'warns and stays non-fatal when no identity is available' {
        Mock -CommandName Write-Warning -MockWith { }
        { Set-SbxContainerGitIdentity -Runtime 'wslc' -Identity $null } | Should -Not -Throw
        Should -Invoke Write-Warning -Times 1
    }
}

Describe 'Set-SbxVolumeGitIdentity' {
    It 'warns and stays non-fatal when no identity is available' {
        Mock -CommandName Write-Warning -MockWith { }
        { Set-SbxVolumeGitIdentity -Runtime 'wslc' -Identity $null } | Should -Not -Throw
        Should -Invoke Write-Warning -Times 1
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
    It 'creates when absent, creating the workspace dir first, and seeds the identity' {
        Mock -CommandName Get-SbxMainState -MockWith { 'absent' }
        # Isolate: the seed has its own tests; here we only assert it is invoked.
        Mock -CommandName Set-SbxContainerGitIdentity -MockWith { }
        $script:calls = @()
        Mock -CommandName wslc -MockWith { $script:calls += ,($args -join ' ') }
        $ws = Join-Path $TestDrive 'fresh-ws'
        Start-SbxMain -Runtime 'wslc' -WorkspaceDir $ws
        Test-Path $ws | Should -BeTrue
        ($script:calls -join '|') | Should -BeLike '*run -d --name sbx-main*sleep infinity*'
        # The create path must seed the container identity - guards against a
        # regression that drops the Set-SbxContainerGitIdentity call.
        Should -Invoke Set-SbxContainerGitIdentity -Times 1 -Exactly -ParameterFilter { $Runtime -eq 'wslc' }
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

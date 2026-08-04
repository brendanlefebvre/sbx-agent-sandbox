BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Get-SbxWorkspacePath' {
    It 'defaults to $HOME/sbx-ws' {
        Get-SbxWorkspacePath -Override $null | Should -Be (Join-Path $HOME 'sbx-ws')
    }
    It 'honors the SBX_WORKSPACE override' {
        Get-SbxWorkspacePath -Override 'C:\elsewhere\ws' | Should -Be 'C:\elsewhere\ws'
    }
}

Describe 'Get-SbxSessionName' {
    It 'passes simple names through' { Get-SbxSessionName 'foo' | Should -Be 'foo' }
    It 'replaces tmux-hostile . and : with -' {
        Get-SbxSessionName 'foo.bar' | Should -Be 'foo-bar'
        Get-SbxSessionName 'a:b.c'  | Should -Be 'a-b-c'
    }
}

Describe 'Get-SbxVolumeRoot' {
    It 'returns the drive root on Windows' -Skip:(-not $IsWindows) {
        Get-SbxVolumeRoot 'C:\Users\user\src\foo' | Should -Be 'C:\'
    }
    It 'is equal for two paths on the same volume' {
        (Get-SbxVolumeRoot $HOME) | Should -Be (Get-SbxVolumeRoot (Join-Path $HOME 'anything'))
    }
    It 'resolves a relative path against cwd before matching' {
        { Get-SbxVolumeRoot 'relative\path' } | Should -Not -Throw
    }
}

Describe 'Sbx origins manifest' {
    It 'returns an empty hashtable when the manifest does not exist' {
        $m = Get-SbxOrigins -ManifestPath (Join-Path $TestDrive 'nope.json')
        $m | Should -BeOfType [hashtable]
        $m.Count | Should -Be 0
    }
    It 'round-trips a mapping (creating parent dirs)' {
        $p = Join-Path $TestDrive 'deep\origins.json'
        Save-SbxOrigins -Origins @{ foo = 'C:\src\foo' } -ManifestPath $p
        (Get-SbxOrigins -ManifestPath $p)['foo'] | Should -Be 'C:\src\foo'
    }
    It 'default path lives under $HOME/.sbx' {
        Get-SbxOriginsPath | Should -Be (Join-Path $HOME '.sbx/origins.json')
    }
    It 'throws a hand-reconcile hint when the manifest is corrupt JSON' {
        $p = Join-Path $TestDrive 'corrupt.json'
        Set-Content -LiteralPath $p -Value '{not valid json'
        { Get-SbxOrigins -ManifestPath $p } | Should -Throw '*corrupt*'
        { Get-SbxOrigins -ManifestPath $p } | Should -Throw "*$p*"
    }
}

Describe 'Add-SbxProject / Remove-SbxProject' {
    BeforeEach {
        $script:ws  = Join-Path $TestDrive 'ws'
        $script:src = Join-Path $TestDrive 'origin\myrepo'
        $script:man = Join-Path $TestDrive 'origins.json'
        # $TestDrive is shared across It blocks in this Describe (Pester does not
        # recreate it per-test), and `New-Item -Force` is a no-op on an existing
        # junction/symlink rather than replacing it - so a prior test's junction-back
        # would otherwise leak into the next test. Reset explicitly; never -Recurse a
        # link (see Remove-SbxProject's own comment on that gotcha).
        foreach ($p in @($script:src, $script:ws)) {
            $existing = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
            if ($existing -and $existing.LinkType) { Remove-Item -LiteralPath $p -Force }
            elseif ($existing) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        Remove-Item -LiteralPath $script:man -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $script:src | Out-Null
        Set-Content (Join-Path $script:src 'FILE.txt') 'hello'
        Mock -CommandName Stop-SbxSession -MockWith { }
    }
    It 'moves the repo into the workspace and leaves a link at the origin' {
        $expectedOrigin = (Resolve-Path -LiteralPath $script:src).Path
        $r = Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man
        $r.Name | Should -Be 'myrepo'
        Get-Content (Join-Path $script:ws 'myrepo\FILE.txt') | Should -Be 'hello'
        (Get-Item -LiteralPath $script:src).LinkType |
            Should -BeIn @('Junction','SymbolicLink')          # junction on Win, symlink on mac
        Get-Content (Join-Path $script:src 'FILE.txt') | Should -Be 'hello'   # host view via link
        (Get-SbxOrigins -ManifestPath $script:man)['myrepo'] | Should -Be $expectedOrigin
    }
    It 'refuses to add the same name twice' {
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $TestDrive 'other\myrepo') | Out-Null
        { Add-SbxProject -Path (Join-Path $TestDrive 'other\myrepo') -WorkspaceDir $script:ws -ManifestPath $script:man } |
            Should -Throw '*already exists*'
    }
    It 'refuses to add a path that is already a link' {
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        { Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man } |
            Should -Throw '*already a link*'
    }
    It 'rm reverses add exactly: real dir back at origin, link gone, manifest entry gone' {
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        Remove-SbxProject -Name 'myrepo' -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc'
        (Get-Item -LiteralPath $script:src).LinkType | Should -BeNullOrEmpty   # real dir again
        Get-Content (Join-Path $script:src 'FILE.txt') | Should -Be 'hello'
        Test-Path (Join-Path $script:ws 'myrepo') | Should -BeFalse
        (Get-SbxOrigins -ManifestPath $script:man).ContainsKey('myrepo') | Should -BeFalse
        Should -Invoke Stop-SbxSession -Times 1
    }
    It 'rm refuses when the origin link does not point at the workspace copy' {
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        Remove-Item -LiteralPath $script:src -Force            # delete the link
        New-Item -ItemType Directory -Force $script:src | Out-Null   # impostor real dir
        { Remove-SbxProject -Name 'myrepo' -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc' } |
            Should -Throw '*origin*'
    }
    It 'rm throws for an unknown project' {
        { Remove-SbxProject -Name 'ghost' -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc' } |
            Should -Throw '*no project*'
    }
    # Windows-only: FileShare.None is enforced by the OS there and blocks the
    # directory move. On Unix an open handle does NOT block rename(2) - the fd
    # follows the inode and Add-SbxProject legitimately succeeds - so the same
    # invariant gets a Unix-native provocation in the companion test below.
    It 'add throws (does not silently succeed) when a locked file blocks the move, and never writes the manifest entry' -Skip:(-not $IsWindows) {
        $lockedPath = Join-Path $script:src 'FILE.txt'
        $fs = [System.IO.File]::Open($lockedPath, 'Open', 'Read', 'None')   # exclusive: no other handle allowed
        try {
            { Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man } | Should -Throw
        }
        finally {
            $fs.Dispose()
        }
        # Move-Item on a directory with a locked file may PARTIALLY move on Windows -
        # -ErrorAction Stop makes the failure LOUD, not atomic/rolled-back. We assert
        # only the two invariants the fix actually guarantees: it throws, and the
        # manifest is never written (so `sbx ls` can't claim a project that isn't
        # really sitting in the workspace).
        (Get-SbxOrigins -ManifestPath $script:man).ContainsKey('myrepo') | Should -BeFalse
    }
    It 'add throws (does not silently succeed) when the source parent is unwritable, and never writes the manifest entry' -Skip:$IsWindows {
        # Unix provocation of the same invariant: rename(2) needs write
        # permission on BOTH parent directories; drop it on the source's parent.
        $parent = Split-Path -Parent $script:src
        & chmod u-w $parent
        try {
            { Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man } | Should -Throw
        }
        finally {
            & chmod u+w $parent
        }
        (Get-SbxOrigins -ManifestPath $script:man).ContainsKey('myrepo') | Should -BeFalse
        (Get-Item -LiteralPath $script:src).LinkType | Should -BeNullOrEmpty   # still a real dir at origin
    }
    It "refuses to add a project named 'hub' (reserved for the orchestrator session)" {
        $hubSrc = Join-Path $TestDrive 'origin\hub'
        New-Item -ItemType Directory -Force $hubSrc | Out-Null
        { Add-SbxProject -Path $hubSrc -WorkspaceDir $script:ws -ManifestPath $script:man } |
            Should -Throw '*hub*reserved*'
    }
    It 'refuses to add a project whose tmux session name collides with an existing one' {
        $srcA = Join-Path $TestDrive 'origin\foo.bar'
        $srcB = Join-Path $TestDrive 'origin\foo-bar'
        foreach ($p in @($srcA, $srcB)) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
            New-Item -ItemType Directory -Force $p | Out-Null
        }
        Add-SbxProject -Path $srcA -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null   # 'foo.bar'
        { Add-SbxProject -Path $srcB -WorkspaceDir $script:ws -ManifestPath $script:man } |         # 'foo-bar'
            Should -Throw '*collides*'
    }
}

Describe 'Stop-SbxSession best-effort' {
    BeforeEach {
        $script:ws  = Join-Path $TestDrive 'ws'
        $script:src = Join-Path $TestDrive 'origin\myrepo'
        $script:man = Join-Path $TestDrive 'origins.json'
        foreach ($p in @($script:src, $script:ws)) {
            $existing = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
            if ($existing -and $existing.LinkType) { Remove-Item -LiteralPath $p -Force }
            elseif ($existing) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        Remove-Item -LiteralPath $script:man -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $script:src | Out-Null
        Set-Content (Join-Path $script:src 'FILE.txt') 'hello'
    }
    It 'rm survives a missing runtime binary (Stop-SbxSession is best-effort)' {
        # Add project first, then remove with a nonexistent runtime command.
        # The real Stop-SbxSession should run against the bogus command and fail,
        # but Remove-SbxProject should still complete and move the dir back.
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        # Verify workspace state before remove
        Test-Path (Join-Path $script:ws 'myrepo') | Should -BeTrue
        (Get-Item -LiteralPath $script:src).LinkType | Should -BeIn @('Junction','SymbolicLink')

        # Remove with a nonexistent runtime; this should NOT throw
        { Remove-SbxProject -Name 'myrepo' -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'sbx-definitely-not-a-command' } |
            Should -Not -Throw

        # Verify the move-back succeeded despite the missing runtime
        (Get-Item -LiteralPath $script:src).LinkType | Should -BeNullOrEmpty   # real dir again
        Get-Content (Join-Path $script:src 'FILE.txt') | Should -Be 'hello'
        Test-Path (Join-Path $script:ws 'myrepo') | Should -BeFalse
        (Get-SbxOrigins -ManifestPath $script:man).ContainsKey('myrepo') | Should -BeFalse
    }
}

Describe 'add/rm from inside the affected directory (cwd dance)' {
    BeforeEach {
        $script:ws  = Join-Path $TestDrive 'ws'
        $script:src = Join-Path $TestDrive 'origin\myrepo'
        $script:man = Join-Path $TestDrive 'origins.json'
        foreach ($p in @($script:src, $script:ws)) {
            $existing = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
            if ($existing -and $existing.LinkType) { Remove-Item -LiteralPath $p -Force }
            elseif ($existing) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        Remove-Item -LiteralPath $script:man -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $script:src | Out-Null
        Set-Content (Join-Path $script:src 'FILE.txt') 'hello'
        Mock -CommandName Stop-SbxSession -MockWith { }
    }
    It 'add succeeds from inside the repo and the session location survives (via the link)' {
        Push-Location -LiteralPath $script:src
        try {
            $r = Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man
            $r.Name | Should -Be 'myrepo'
            (Get-Location).Path | Should -Be $script:src            # logical cwd unchanged
            (Get-Item -LiteralPath $script:src).LinkType | Should -Not -BeNullOrEmpty
            Get-Content (Join-Path $script:ws 'myrepo\FILE.txt') | Should -Be 'hello'
        }
        finally { Pop-Location }
    }
    It 'rm succeeds from inside the workspace copy' {
        Add-SbxProject -Path $script:src -WorkspaceDir $script:ws -ManifestPath $script:man | Out-Null
        $wsCopy = Join-Path $script:ws 'myrepo'
        Push-Location -LiteralPath $wsCopy
        try {
            Remove-SbxProject -Name 'myrepo' -WorkspaceDir $script:ws -ManifestPath $script:man -Runtime 'wslc'
            Test-Path -LiteralPath $wsCopy | Should -BeFalse
            (Get-Item -LiteralPath $script:src).LinkType | Should -BeNullOrEmpty   # real dir again
        }
        finally { Pop-Location }
    }
}

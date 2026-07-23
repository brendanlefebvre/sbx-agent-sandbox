BeforeAll {
    # Dot-source the validator to expose Resolve-SbxSyncExecRequest without
    # running its main body (guarded by the InvocationName '.' check).
    . "$PSScriptRoot/sbx-sync-exec.ps1"

    # A throwaway workspace with one legitimate direct-child repo. $TestDrive is
    # Pester's per-run temp dir, auto-removed afterwards.
    $script:ws = Join-Path $TestDrive 'ws'
    New-Item -ItemType Directory -Force (Join-Path $ws 'myrepo') | Out-Null
}

Describe 'Resolve-SbxSyncExecRequest' {
    Context 'accepts the three allowed verbs against a workspace repo' {
        It 'accepts <op>' -ForEach @(
            @{ op = 'push' }, @{ op = 'pull' }, @{ op = 'fetch' }
        ) {
            $r = Resolve-SbxSyncExecRequest -OriginalCommand "myrepo $op" -WorkspaceDir $ws
            $r.Ok        | Should -BeTrue
            $r.Name      | Should -Be 'myrepo'
            $r.Operation | Should -Be $op
            $r.Dir       | Should -Be (Join-Path $ws 'myrepo')
        }
    }

    It 'canonicalizes a mixed-case verb to lowercase for git' {
        $r = Resolve-SbxSyncExecRequest -OriginalCommand 'myrepo PUSH' -WorkspaceDir $ws
        $r.Ok        | Should -BeTrue
        $r.Operation | Should -Be 'push'
    }

    Context 'rejections (git is never reached)' {
        It 'rejects a bare / empty connection' {
            (Resolve-SbxSyncExecRequest -OriginalCommand ''    -WorkspaceDir $ws).Ok | Should -BeFalse
            (Resolve-SbxSyncExecRequest -OriginalCommand '   ' -WorkspaceDir $ws).Ok | Should -BeFalse
            (Resolve-SbxSyncExecRequest -OriginalCommand $null -WorkspaceDir $ws).Ok | Should -BeFalse
        }
        It 'rejects a single token (missing op)' {
            $r = Resolve-SbxSyncExecRequest -OriginalCommand 'myrepo' -WorkspaceDir $ws
            $r.Ok     | Should -BeFalse
            $r.Reason | Should -BeLike '*exactly two tokens*'
        }
        It 'rejects a disallowed verb' {
            $r = Resolve-SbxSyncExecRequest -OriginalCommand 'myrepo clone' -WorkspaceDir $ws
            $r.Ok     | Should -BeFalse
            $r.Reason | Should -BeLike '*push, pull, fetch*'
        }
        It 'rejects extra args smuggled after the verb (arg injection)' {
            (Resolve-SbxSyncExecRequest -OriginalCommand 'myrepo push --force'       -WorkspaceDir $ws).Ok | Should -BeFalse
            (Resolve-SbxSyncExecRequest -OriginalCommand 'myrepo push origin main'   -WorkspaceDir $ws).Ok | Should -BeFalse
        }
        It 'rejects shell-operator smuggling (extra token)' {
            (Resolve-SbxSyncExecRequest -OriginalCommand 'myrepo; sh'      -WorkspaceDir $ws).Ok | Should -BeFalse
            (Resolve-SbxSyncExecRequest -OriginalCommand 'myrepo push; sh' -WorkspaceDir $ws).Ok | Should -BeFalse
        }
        It 'rejects path traversal / separators in the name' {
            (Resolve-SbxSyncExecRequest -OriginalCommand '../secret push' -WorkspaceDir $ws).Ok | Should -BeFalse
            (Resolve-SbxSyncExecRequest -OriginalCommand 'foo/bar push'   -WorkspaceDir $ws).Ok | Should -BeFalse
            (Resolve-SbxSyncExecRequest -OriginalCommand 'foo\bar push'   -WorkspaceDir $ws).Ok | Should -BeFalse
            (Resolve-SbxSyncExecRequest -OriginalCommand '.. push'        -WorkspaceDir $ws).Ok | Should -BeFalse
            (Resolve-SbxSyncExecRequest -OriginalCommand '. push'         -WorkspaceDir $ws).Ok | Should -BeFalse
        }
        It 'rejects a repo that is not in the workspace' {
            $r = Resolve-SbxSyncExecRequest -OriginalCommand 'ghost push' -WorkspaceDir $ws
            $r.Ok     | Should -BeFalse
            $r.Reason | Should -BeLike "*no project 'ghost'*"
        }
    }
}

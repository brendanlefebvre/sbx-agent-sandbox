BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'Invoke-SbxSync' {
    BeforeEach {
        $script:ws = Join-Path $TestDrive 'ws'
        New-Item -ItemType Directory -Force (Join-Path $script:ws 'foo') | Out-Null
        # Keep lock files out of the real ~/.sbx/locks during unit runs, and keep
        # the git hardening out of the argv assertions below - it has its own tests.
        Mock -CommandName Get-SbxLockDir        -MockWith { Join-Path $TestDrive 'locks' }
        Mock -CommandName Get-SbxGitHardeningArgs -MockWith { @() }
        Mock -CommandName Get-SbxUnsafeGitConfig  -MockWith { @() }
    }
    It 'runs the allowlisted git op in the project workspace dir' {
        Mock -CommandName git -MockWith { $script:seen = $args }
        Invoke-SbxSync -Name 'foo' -Operation 'push' -WorkspaceDir $script:ws
        ($script:seen -join ' ') | Should -Be "-C $(Join-Path $script:ws 'foo') push"
    }
    It 'rejects a non-allowlisted operation' {
        Mock -CommandName git -MockWith { throw 'must not run' }
        { Invoke-SbxSync -Name 'foo' -Operation 'push --force' -WorkspaceDir $script:ws } | Should -Throw '*one of*'
        { Invoke-SbxSync -Name 'foo' -Operation 'status'       -WorkspaceDir $script:ws } | Should -Throw '*one of*'
    }
    It 'throws for a project not in the workspace' {
        { Invoke-SbxSync -Name 'ghost' -Operation 'push' -WorkspaceDir $script:ws } | Should -Throw '*no project*'
    }
    It 'throws for a traversal name even though the resolved parent dir exists' {
        # Join-Path $ws '..' resolves to $ws's OWN parent, which genuinely exists -
        # the naive Test-Path guard alone would let this through. The direct-child
        # containment check must catch it.
        Mock -CommandName git -MockWith { throw 'must not run' }
        { Invoke-SbxSync -Name '..' -Operation 'push' -WorkspaceDir $script:ws } | Should -Throw '*no project*'
    }
}

# The shared core behind BOTH sync paths: the human's `sbx sync` and the
# container's SSH forced command. Every reject here is a reject for an agent.
Describe 'Resolve-SbxSyncRequest' {
    BeforeAll {
        $script:ws = Join-Path $TestDrive 'core-ws'
        New-Item -ItemType Directory -Force (Join-Path $script:ws 'myrepo') | Out-Null
    }
    It 'accepts <op>' -ForEach @(@{ op = 'push' }, @{ op = 'pull' }, @{ op = 'fetch' }) {
        $r = Resolve-SbxSyncRequest -Name 'myrepo' -Operation $op -WorkspaceDir $script:ws
        $r.Ok        | Should -BeTrue
        $r.Operation | Should -Be $op
        $r.Dir       | Should -Be (Join-Path $script:ws 'myrepo')
    }
    It 'canonicalizes a mixed-case verb to lowercase for git' {
        (Resolve-SbxSyncRequest -Name 'myrepo' -Operation 'PUSH' -WorkspaceDir $script:ws).Operation |
            Should -Be 'push'
    }
    It 'rejects a disallowed verb' {
        $r = Resolve-SbxSyncRequest -Name 'myrepo' -Operation 'clone' -WorkspaceDir $script:ws
        $r.Ok     | Should -BeFalse
        $r.Reason | Should -BeLike '*push, pull, fetch*'
    }
    It 'rejects traversal / separators in the name' -ForEach @(
        @{ n = '..' }, @{ n = '.' }, @{ n = '../secret' }, @{ n = 'foo/bar' }, @{ n = 'foo\bar' }, @{ n = '' }
    ) {
        (Resolve-SbxSyncRequest -Name $n -Operation 'push' -WorkspaceDir $script:ws).Ok | Should -BeFalse
    }
    It 'rejects a project that is not in the workspace' {
        (Resolve-SbxSyncRequest -Name 'ghost' -Operation 'push' -WorkspaceDir $script:ws).Reason |
            Should -BeLike "*no project 'ghost'*"
    }
}

# What arrives in SSH_ORIGINAL_COMMAND. The two-token rule is the anti-injection
# guard: anything smuggling a second word ("; sh", "--force") lands here.
Describe 'Resolve-SbxSyncCommand' {
    BeforeAll {
        $script:ws = Join-Path $TestDrive 'cmd-ws'
        New-Item -ItemType Directory -Force (Join-Path $script:ws 'myrepo') | Out-Null
    }
    It 'accepts the canonical two-token form' {
        $r = Resolve-SbxSyncCommand -OriginalCommand 'myrepo fetch' -WorkspaceDir $script:ws
        $r.Ok   | Should -BeTrue
        $r.Name | Should -Be 'myrepo'
    }
    It 'tolerates surrounding and repeated whitespace' {
        (Resolve-SbxSyncCommand -OriginalCommand "  myrepo   push `t" -WorkspaceDir $script:ws).Ok |
            Should -BeTrue
    }
    It 'rejects a bare / empty connection' -ForEach @(@{ c = '' }, @{ c = '   ' }, @{ c = $null }) {
        (Resolve-SbxSyncCommand -OriginalCommand $c -WorkspaceDir $script:ws).Ok | Should -BeFalse
    }
    It 'rejects a single token (missing op)' {
        (Resolve-SbxSyncCommand -OriginalCommand 'myrepo' -WorkspaceDir $script:ws).Reason |
            Should -BeLike '*exactly two tokens*'
    }
    It 'rejects extra tokens / shell smuggling' -ForEach @(
        @{ c = 'myrepo push --force' }, @{ c = 'myrepo push origin main' },
        @{ c = 'myrepo; sh' },          @{ c = 'myrepo push; sh' },
        @{ c = 'myrepo push && sh' },   @{ c = '../secret push' }
    ) {
        (Resolve-SbxSyncCommand -OriginalCommand $c -WorkspaceDir $script:ws).Ok | Should -BeFalse
    }
}

Describe 'Invoke-SbxSyncGit locking' {
    BeforeEach {
        $script:lockDir = Join-Path $TestDrive "locks-$([guid]::NewGuid())"
        $script:repo    = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Force $script:repo | Out-Null
        Mock -CommandName Get-SbxGitHardeningArgs -MockWith { @() }
        Mock -CommandName Get-SbxUnsafeGitConfig  -MockWith { @() }
    }
    It 'runs the op and releases the lock so a second call succeeds' {
        Mock -CommandName git -MockWith { $script:calls++ }
        $script:calls = 0
        Invoke-SbxSyncGit -Dir $script:repo -Operation 'push' -WorkspaceDir $TestDrive -LockDir $script:lockDir
        Invoke-SbxSyncGit -Dir $script:repo -Operation 'push' -WorkspaceDir $TestDrive -LockDir $script:lockDir
        $script:calls | Should -Be 2
    }
    It 'times out instead of racing when the lock is already held' {
        # Simulates the other holder - a concurrent agent's forced command mid-push.
        $lock = Join-Path $script:lockDir 'repo.lock'
        New-Item -ItemType Directory -Force $script:lockDir | Out-Null
        $held = [IO.File]::Open($lock, 'OpenOrCreate', 'Write', 'None')
        try {
            Mock -CommandName git -MockWith { throw 'must not run while another sync holds the lock' }
            { Invoke-SbxSyncGit -Dir $script:repo -Operation 'push' -WorkspaceDir $TestDrive -LockDir $script:lockDir -TimeoutSec 1 } |
                Should -Throw '*timed out*'
        } finally { $held.Dispose() }
    }
}

# A rejected push used to return cleanly: c-lite reported nothing, and the forced
# command printed OK and exited non-zero with no FAILED line - the one shape
# docs/SYNC.md tells an agent to branch on.
Describe 'Invoke-SbxSyncGit propagates git failure' {
    BeforeEach {
        $script:lockDir = Join-Path $TestDrive "locks-fail-$([guid]::NewGuid())"
        $script:repo    = Join-Path $TestDrive 'repo-fail'
        New-Item -ItemType Directory -Force $script:repo | Out-Null
        Mock -CommandName Get-SbxGitHardeningArgs -MockWith { @() }
        Mock -CommandName Get-SbxUnsafeGitConfig  -MockWith { @() }
    }
    It 'throws when git exits non-zero' {
        Mock -CommandName git -MockWith { $global:LASTEXITCODE = 1 }
        { Invoke-SbxSyncGit -Dir $script:repo -Operation 'push' -WorkspaceDir $TestDrive -LockDir $script:lockDir } |
            Should -Throw '*git push failed (exit 1)*'
    }
    It 'still releases the lock, so the next sync is not blocked by a failure' {
        Mock -CommandName git -MockWith { $global:LASTEXITCODE = 1 }
        { Invoke-SbxSyncGit -Dir $script:repo -Operation 'push' -WorkspaceDir $TestDrive -LockDir $script:lockDir } | Should -Throw
        Mock -CommandName git -MockWith { $global:LASTEXITCODE = 0 }
        { Invoke-SbxSyncGit -Dir $script:repo -Operation 'push' -WorkspaceDir $TestDrive -LockDir $script:lockDir } | Should -Not -Throw
    }
    It 'does not throw on a clean exit' {
        Mock -CommandName git -MockWith { $global:LASTEXITCODE = 0 }
        { Invoke-SbxSyncGit -Dir $script:repo -Operation 'fetch' -WorkspaceDir $TestDrive -LockDir $script:lockDir } | Should -Not -Throw
    }
    It 'does not read a STALE exit code as a failure' {
        # A mock (or an earlier native call) that never touches $LASTEXITCODE must
        # not make the next sync look like it failed.
        $global:LASTEXITCODE = 9
        Mock -CommandName git -MockWith { }
        { Invoke-SbxSyncGit -Dir $script:repo -Operation 'pull' -WorkspaceDir $TestDrive -LockDir $script:lockDir } | Should -Not -Throw
    }
}

# The git call itself is a second security boundary: git executes .git/hooks/* and
# a set of config keys, and the repo it runs in is agent-writable. Verified live:
# an agent-written pre-push hook runs HOST-side without these pins.
Describe 'Get-SbxGitHardeningArgs' {
    BeforeAll { $script:h = (Get-SbxGitHardeningArgs -NoHooksDir '/var/empty-hooks') -join ' ' }
    It 'aims hooksPath at an empty dir - .git/hooks/* needs no config key to fire' {
        $script:h | Should -BeLike '*-c core.hooksPath=/var/empty-hooks*'
    }
    # Every pin, not a sample: CLAUDE.md calls dropping one a widened boundary, so
    # each must be able to fail a test on its own.
    It 'disables the config keys that name a program' -ForEach @(
        @{ pin = 'core.fsmonitor=false' }, @{ pin = 'protocol.ext.allow=never' },
        @{ pin = 'protocol.file.allow=user' }
    ) {
        $script:h | Should -BeLike "*-c $pin*"
    }
    # core.gitProxy CANNOT be pinned: it is multi-valued and first-match-wins, so a
    # repo-local value beats our -c even when ours is non-empty (probed, git
    # 2.52.0). It only applies to git://, so the reachable fix is to refuse the
    # transport - which IS single-valued and does obey the pin.
    It 'refuses the git:// transport, the only thing core.gitProxy can hook' {
        $script:h | Should -BeLike '*-c protocol.git.allow=never*'
    }
    It 'pins core.alternateRefsCommand empty - it runs host-side on fetch and pull' {
        # Empty is the right value here: git falls back to its internal ref listing
        # rather than executing anything. Asserted as an exact argv element, since
        # a -BeLike would also pass if some value crept in after the '='.
        @(Get-SbxGitHardeningArgs -NoHooksDir '/var/empty-hooks') |
            Should -Contain 'core.alternateRefsCommand='
    }
    It 'suppresses the pager with --no-pager (core.pager=cat is not portable: no cat on Windows)' {
        $script:h | Should -BeLike '*--no-pager*'
    }
    It 'pins <key>, whose value git executes' -ForEach @(
        @{ key = 'core.sshCommand' }, @{ key = 'gpg.program' },
        @{ key = 'core.editor' },     @{ key = 'core.askPass' }
    ) {
        $script:h | Should -BeLike "*-c $key=*"
    }
    It 'resets the multi-valued credential.helper list (a -c would only append to it)' {
        $script:h | Should -BeLike '*-c credential.helper=*'
        # The reset must come before any restored host helper.
        $a = @(Get-SbxGitHardeningArgs -NoHooksDir '/var/empty-hooks')
        $first = @($a | Where-Object { $_ -like 'credential.helper=*' })[0]
        $first | Should -Be 'credential.helper='
    }
    It 'emits -c as separate argv elements so a value with spaces cannot re-split' {
        $a = @(Get-SbxGitHardeningArgs -NoHooksDir '/some/dir with spaces')
        $a | Should -Contain 'core.hooksPath=/some/dir with spaces'
    }
}

Describe 'Get-SbxUnsafeGitConfig' {
    BeforeEach {
        $script:repo = Join-Path $TestDrive "cfg-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $script:repo | Out-Null
        & git init -q $script:repo
    }
    It 'passes a repo with only ordinary local config' {
        & git -C $script:repo config user.email 'a@b'
        & git -C $script:repo remote add origin https://example.invalid/x.git
        Get-SbxUnsafeGitConfig -Dir $script:repo | Should -BeNullOrEmpty
    }
    It 'flags <key>, which git executes host-side' -ForEach @(
        @{ key = 'core.sshCommand';          value = 'sh -c evil' }
        @{ key = 'core.hooksPath';           value = '/tmp/evil' }
        @{ key = 'credential.helper';        value = '!sh -c evil' }
        @{ key = 'filter.zip.clean';         value = 'sh -c evil' }
        @{ key = 'remote.origin.receivepack'; value = 'sh -c evil' }
        @{ key = 'diff.x.textconv';          value = 'sh -c evil' }
        @{ key = 'sequence.editor';          value = 'sh -c evil' }
        # Real key with NO middle segment, so the diff.*.textconv pattern misses
        # it. Not reachable through push/pull/fetch (probed: only `git diff` runs
        # it), but a denylist that silently omits a real exec key is worse than one
        # that over-matches.
        @{ key = 'diff.external';            value = 'sh -c evil' }
    ) {
        & git -C $script:repo config $key $value
        Get-SbxUnsafeGitConfig -Dir $script:repo | Should -Contain $key
    }
    It 'returns nothing rather than throwing when the dir is not a git repo' {
        $plain = Join-Path $TestDrive "plain-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $plain | Out-Null
        Get-SbxUnsafeGitConfig -Dir $plain | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-SbxSyncGit refuses an executable repo-local config' {
    It 'throws before running git when the repo sets an exec key' {
        $repo = Join-Path $TestDrive "unsafe-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $repo | Out-Null
        & git init -q $repo
        & git -C $repo config core.sshCommand 'sh -c evil'
        Mock -CommandName Get-SbxGitHardeningArgs -MockWith { @() }
        { Invoke-SbxSyncGit -Dir $repo -Operation 'push' -WorkspaceDir $TestDrive -LockDir (Join-Path $TestDrive 'l2') } |
            Should -Throw '*executes as a program*'
    }
}

Describe 'workspace entry that is not a directory' {
    BeforeEach {
        $script:ws = Join-Path $TestDrive "nd-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $script:ws | Out-Null
        $script:file = Join-Path $script:ws 'notarepo'
        Set-Content -LiteralPath $script:file -Value 'x'
    }
    It 'denies a plain file, without leaning on a property FileInfo does not have' {
        # It denied before this test existed - but only because FileInfo has no
        # .Parent, so the direct-child comparison saw $null. StrictMode exposes that
        # as the accident it was: the same call threw "The property 'Parent' cannot
        # be found on this object" instead of returning a denial. Live-observed on
        # wslc (FINDINGS P10): a container-planted reparse point whose target is
        # container-only comes back as exactly this shape.
        Set-StrictMode -Version Latest
        try {
            Get-SbxWorkspaceChildDenial -Dir $script:file -WorkspaceDir $script:ws |
                Should -BeLike '*no project*'
        }
        finally { Set-StrictMode -Off }
    }
    It 'still admits an ordinary directory under StrictMode' {
        $d = Join-Path $script:ws 'realrepo'
        New-Item -ItemType Directory -Force $d | Out-Null
        Set-StrictMode -Version Latest
        try { Get-SbxWorkspaceChildDenial -Dir $d -WorkspaceDir $script:ws | Should -BeNullOrEmpty }
        finally { Set-StrictMode -Off }
    }
}

Describe 'workspace symlink escape' {
    It 'refuses a link planted in the workspace, which would aim host git anywhere' {
        # The container has the workspace mounted read-write, so it can create this.
        $ws      = Join-Path $TestDrive "link-ws-$([guid]::NewGuid())"
        $outside = Join-Path $TestDrive "outside-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $ws, $outside | Out-Null
        New-SbxLink -LinkPath (Join-Path $ws 'escape') -TargetPath $outside
        $r = Resolve-SbxSyncRequest -Name 'escape' -Operation 'push' -WorkspaceDir $ws
        $r.Ok     | Should -BeFalse
        $r.Reason | Should -BeLike '*is a link*'
    }
}

# Validation happens BEFORE the lock; git runs after it. The container owns the
# workspace read-write throughout, so the directory it validated is not
# necessarily the directory git opens. The pre-flight check cannot close this on
# its own - only a re-check on the far side of the lock can.
Describe 'workspace path swapped between validation and use' {
    BeforeEach {
        $script:ws = Join-Path $TestDrive "race-ws-$([guid]::NewGuid())"
        $script:outside = Join-Path $TestDrive "race-out-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $script:ws, $script:outside | Out-Null
        $script:proj = Join-Path $script:ws 'myrepo'
        New-Item -ItemType Directory -Force $script:proj | Out-Null
        $script:lockDir = Join-Path $TestDrive "race-locks-$([guid]::NewGuid())"
    }
    It 'refuses after the swap, even though the pre-flight validator passed' {
        # The actual attack, in order: validate, swap, run.
        $r = Resolve-SbxSyncRequest -Name 'myrepo' -Operation 'push' -WorkspaceDir $script:ws
        $r.Ok | Should -BeTrue                       # pre-flight saw a real directory
        Remove-Item -Recurse -Force $script:proj     # ...and the container swaps it
        New-SbxLink -LinkPath $script:proj -TargetPath $script:outside

        # Sentinel, deliberately sharing no words with the guard's message: a mock
        # whose text could satisfy the assertion turns "git ran anyway" green.
        Mock -CommandName git -MockWith { throw 'SENTINEL-GIT-RAN' }
        Mock -CommandName Get-SbxGitHardeningArgs -MockWith { @() }
        { Invoke-SbxSyncGit -Dir $r.Dir -Operation 'push' -WorkspaceDir $script:ws -LockDir $script:lockDir } |
            Should -Throw '*is a link*'
    }
    It 'refuses a dir outside the workspace entirely, whatever the caller claims' {
        Mock -CommandName git -MockWith { throw 'SENTINEL-GIT-RAN' }
        Mock -CommandName Get-SbxGitHardeningArgs -MockWith { @() }
        { Invoke-SbxSyncGit -Dir $script:outside -Operation 'push' -WorkspaceDir $script:ws -LockDir $script:lockDir } |
            Should -Throw '*in the workspace*'
    }
    It 'still runs the op when the path is unchanged and legitimate' {
        # The guard must not cost the happy path - this is the regression that
        # would make the whole re-check unshippable.
        Mock -CommandName git -MockWith { $global:LASTEXITCODE = 0 }
        Mock -CommandName Get-SbxGitHardeningArgs -MockWith { @() }
        Mock -CommandName Get-SbxUnsafeGitConfig  -MockWith { @() }
        { Invoke-SbxSyncGit -Dir $script:proj -Operation 'push' -WorkspaceDir $script:ws -LockDir $script:lockDir } |
            Should -Not -Throw
    }
}

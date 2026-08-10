BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

Describe 'ConvertFrom-SbxArgs (v2)' {
    It 'no args = attach to the hub' {
        $o = ConvertFrom-SbxArgs @()
        $o.Command | Should -Be 'attach'
        $o.Target  | Should -BeNullOrEmpty
        $o.Window  | Should -Be 'here'
    }
    It 'bare name = attach to that project session' {
        $o = ConvertFrom-SbxArgs @('foo')
        $o.Command | Should -Be 'attach'
        $o.Target  | Should -Be 'foo'
    }
    It 'a path-looking arg errors with a pointer to add' {
        { ConvertFrom-SbxArgs @('C:\src\foo') } | Should -Throw '*sbx add*'
        { ConvertFrom-SbxArgs @('src/foo') }    | Should -Throw '*sbx add*'
    }
    It 'parses add <path>' {
        $o = ConvertFrom-SbxArgs @('add', 'C:\src\foo')
        $o.Command | Should -Be 'add'
        $o.Target  | Should -Be 'C:\src\foo'
    }
    It 'parses rm <name>' {
        $o = ConvertFrom-SbxArgs @('rm', 'foo')
        $o.Command | Should -Be 'rm'
        $o.Target  | Should -Be 'foo'
    }
    It 'parses sync <name> <op>' {
        $o = ConvertFrom-SbxArgs @('sync', 'foo', 'push')
        $o.Command    | Should -Be 'sync'
        $o.Target     | Should -Be 'foo'
        $o.Operation  | Should -Be 'push'
        $o.GitOptions | Should -BeNullOrEmpty
    }
    It 'carries git options after the verb through UNPARSED' {
        # The parser must not judge these - the per-verb allowlist in
        # Resolve-SbxSyncRequest is the only thing that decides what git sees.
        # What matters here is that they survive the trip instead of tripping the
        # "Unknown option" arm meant for sbx's own flags.
        $o = ConvertFrom-SbxArgs @('sync', 'foo', 'pull', '--recurse-submodules', '--rebase')
        $o.Operation  | Should -Be 'pull'
        $o.GitOptions | Should -Be @('--recurse-submodules', '--rebase')
    }
    It 'passes an option sbx would otherwise claim as its own to git, not to sbx' {
        # --remove is an sbx flag for sync-setup/gh-setup. After `sync <name> <op>`
        # it is git's problem (and the allowlist will refuse it) - it must never be
        # read as $opts.Remove.
        $o = ConvertFrom-SbxArgs @('sync', 'foo', 'push', '--remove')
        $o.Remove     | Should -BeFalse
        $o.GitOptions | Should -Be @('--remove')
    }
    It 'does not mangle the empty option list into a reversed range' {
        # $Arguments[3..2] yields @(3,2) in PowerShell, not @() - the guard against
        # that is easy to drop and silently forwards two bogus options.
        (ConvertFrom-SbxArgs @('sync', 'foo', 'fetch')).GitOptions.Count | Should -Be 0
    }
    It 'rejects an sbx option written in FRONT of sync rather than silently retargeting it' {
        # `sbx --tab sync foo push` used to reach the positional switch. sync is
        # parsed before the option loop now, so this form has to fail loudly - the
        # alternative is 'sync' being taken for a project name.
        { ConvertFrom-SbxArgs @('--tab', 'sync', 'foo', 'push') } | Should -Throw "*'sync' takes no sbx options*"
    }
    It 'parses ls / rebuild / stop / scratch / status' {
        (ConvertFrom-SbxArgs @('ls')).Command      | Should -Be 'ls'
        (ConvertFrom-SbxArgs @('rebuild')).Command | Should -Be 'rebuild'
        (ConvertFrom-SbxArgs @('stop')).Command    | Should -Be 'stop'
        (ConvertFrom-SbxArgs @('scratch')).Command | Should -Be 'scratch'
        (ConvertFrom-SbxArgs @('status')).Command  | Should -Be 'status'
    }
    It 'parses --new-window / --window / --win and --tab wherever they appear' {
        (ConvertFrom-SbxArgs @('--new-window')).Window          | Should -Be 'window'
        (ConvertFrom-SbxArgs @('foo', '--window')).Window       | Should -Be 'window'
        (ConvertFrom-SbxArgs @('--win', 'scratch')).Window      | Should -Be 'window'
        (ConvertFrom-SbxArgs @('foo', '--tab')).Window          | Should -Be 'tab'
    }
    It 'the retired --here flag is now an unknown option' {
        { ConvertFrom-SbxArgs @('--here') } | Should -Throw '*Unknown option*'
    }
    It 'errors on missing subcommand arguments' {
        { ConvertFrom-SbxArgs @('add') }          | Should -Throw '*add*'
        { ConvertFrom-SbxArgs @('rm') }           | Should -Throw '*rm*'
        { ConvertFrom-SbxArgs @('sync', 'foo') }  | Should -Throw '*sync*'
    }
    It 'retired v1 flags are unknown options' {
        { ConvertFrom-SbxArgs @('--ssh', 'foo') }        | Should -Throw '*Unknown option*'
        { ConvertFrom-SbxArgs @('--name', 'x', 'foo') }  | Should -Throw '*Unknown option*'
    }
    It 'rejects . and .. as a project name (traversal guard)' {
        { ConvertFrom-SbxArgs @('..') }             | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('.') }              | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('rm', '..') }       | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('rm', '.') }        | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('sync', '..', 'push') } | Should -Throw '*invalid project name*'
        { ConvertFrom-SbxArgs @('sync', '.', 'push') }  | Should -Throw '*invalid project name*'
    }
}

Describe 'ConvertFrom-SbxArgs - sync-setup (c-heavy)' {
    It 'parses the bare subcommand' {
        (ConvertFrom-SbxArgs @('sync-setup')).Command | Should -Be 'sync-setup'
    }
    It 'consumes the value-taking options' {
        $o = ConvertFrom-SbxArgs @('sync-setup', '--address', '172.20.240.1', '--user', 'me',
                                   '--port', '2222', '--authorized-keys', '/tmp/ak')
        $o.Address            | Should -Be '172.20.240.1'
        $o.SshUser            | Should -Be 'me'
        $o.Port               | Should -Be '2222'
        $o.AuthorizedKeysFile | Should -Be '/tmp/ak'
    }
    It 'parses the boolean switches' {
        (ConvertFrom-SbxArgs @('sync-setup', '--print-only')).PrintOnly | Should -BeTrue
        (ConvertFrom-SbxArgs @('sync-setup', '--remove')).Remove        | Should -BeTrue
    }
    It 'never swallows an option value as a positional' {
        # --address eating 'push' here would silently turn a typo into a sync.
        $o = ConvertFrom-SbxArgs @('sync-setup', '--address', 'host.docker.internal')
        $o.Command | Should -Be 'sync-setup'
        $o.Target  | Should -BeNullOrEmpty
    }
    It 'errors when a value-taking option is last' {
        { ConvertFrom-SbxArgs @('sync-setup', '--address') } | Should -Throw '*expects a value*'
    }
    It 'rejects a non-numeric port' {
        { ConvertFrom-SbxArgs @('sync-setup', '--port', 'abc') } | Should -Throw '*expects a number*'
    }
    It 'still rejects genuinely unknown options' {
        { ConvertFrom-SbxArgs @('sync-setup', '--yolo') } | Should -Throw '*Unknown option*'
    }
    It 'leaves the existing window flags working alongside the new parser loop' {
        (ConvertFrom-SbxArgs @('foo')).Window                 | Should -Be 'here'
        (ConvertFrom-SbxArgs @('foo', '--new-window')).Window | Should -Be 'window'
        (ConvertFrom-SbxArgs @('--window')).Window            | Should -Be 'window'
        (ConvertFrom-SbxArgs @('--win')).Window               | Should -Be 'window'
        (ConvertFrom-SbxArgs @('--tab')).Window               | Should -Be 'tab'
    }
}

Describe 'ConvertFrom-SbxArgs - gh-setup (c-gh)' {
    It 'parses the bare subcommand' {
        (ConvertFrom-SbxArgs @('gh-setup')).Command | Should -Be 'gh-setup'
    }
    It 'consumes --token-file' {
        $o = ConvertFrom-SbxArgs @('gh-setup', '--token-file', '/tmp/tok')
        $o.TokenFile | Should -Be '/tmp/tok'
    }
    It 'parses --remove' {
        (ConvertFrom-SbxArgs @('gh-setup', '--remove')).Remove | Should -BeTrue
    }
    It 'errors when --token-file is last' {
        { ConvertFrom-SbxArgs @('gh-setup', '--token-file') } | Should -Throw '*expects a value*'
    }
    It 'still rejects genuinely unknown options' {
        { ConvertFrom-SbxArgs @('gh-setup', '--yolo') } | Should -Throw '*Unknown option*'
    }
}

BeforeAll {
    $script:client = (Resolve-Path "$PSScriptRoot/../sbx-client.sh").Path
    $script:sh = (Get-Command sh -ErrorAction SilentlyContinue)?.Source

    # Runs the real client under a POSIX shell with the conf/key/PATH it would see
    # in the container. Returns exit code plus both streams, so a test can assert
    # on the message an agent would actually read.
    # The fakes below are written by [IO.File]::WriteAllText, which leaves them
    # non-executable. Git Bash on Windows runs them anyway; a POSIX shell does
    # not, so without this every fake-argv assertion silently fell through to the
    # REAL ssh/gh when the suite was run on Linux or macOS.
    function Set-FakeExecutable {
        param([Parameter(Mandatory)][string]$Path)
        if (-not $IsWindows) { & chmod +x $Path }
    }

    function Invoke-Client {
        param([string[]]$ClientArgs = @(), [string]$Conf, [string]$Key,
              [string]$Cwd, [string]$FakeSshDir)
        $env:SBX_SYNC_CONF = $Conf
        $env:SBX_SYNC_KEY  = $Key
        $old = $env:PATH
        if ($FakeSshDir) { $env:PATH = "$FakeSshDir$([IO.Path]::PathSeparator)$old" }
        try {
            $out = & $script:sh $script:client @ClientArgs 2>&1 | Out-String
            return [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
        }
        finally {
            $env:PATH = $old
            Remove-Item Env:SBX_SYNC_CONF, Env:SBX_SYNC_KEY -ErrorAction SilentlyContinue
        }
    }
}

# The in-container `sbx sync` client. It is NOT a security boundary - the agent
# holds the key and can invoke ssh by hand - the boundary is the host-side forced
# command. What these cover is the contract an agent depends on: the messages that
# tell it what went wrong, and the ssh options that keep a *misconfigured*
# container from authenticating as something else.
Describe 'sbx-sync-client.sh' -Skip:(-not (Get-Command sh -ErrorAction SilentlyContinue)) {
    BeforeEach {
        $script:tmp = Join-Path $TestDrive "cl-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $script:tmp | Out-Null
        $script:conf = Join-Path $script:tmp 'sync.conf'
        $script:key  = Join-Path $script:tmp 'id_sbx_sync'
        [IO.File]::WriteAllText($script:conf, "host=10.0.0.1`nuser=me`nport=2222`n")
        [IO.File]::WriteAllText($script:key, "KEY")
        # A stand-in ssh that records its argv instead of connecting.
        $script:fake = Join-Path $script:tmp 'bin'
        New-Item -ItemType Directory -Force $script:fake | Out-Null
        $script:argvLog = Join-Path $script:tmp 'argv.txt'
        [IO.File]::WriteAllText((Join-Path $script:fake 'ssh'),
            "#!/bin/sh`nfor a in `"`$@`"; do echo `"`$a`"; done > '$($script:argvLog -replace '\\','/')'`nexit 0`n")
        Set-FakeExecutable (Join-Path $script:fake 'ssh')
    }

    It 'is valid POSIX shell (the syntax gate the printf form never had)' {
        & $script:sh -n $script:client 2>&1 | Out-String | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }

    It 'prints usage and exits 0 with no arguments' {
        $r = Invoke-Client -Conf $script:conf -Key $script:key
        $r.Exit | Should -Be 0
        $r.Out  | Should -BeLike '*usage: sbx sync*'
    }

    It 'refuses a non-sync subcommand, pointing at the host' {
        $r = Invoke-Client -ClientArgs @('ls') -Conf $script:conf -Key $script:key
        $r.Exit | Should -Be 2
        $r.Out  | Should -BeLike '*run other sbx commands on the host*'
    }

    It 'reports unprovisioned before complaining about the cwd' {
        # Order matters: an unconfigured sandbox that blamed the cwd would send you
        # looking in entirely the wrong place.
        $r = Invoke-Client -ClientArgs @('sync', 'push') -Conf (Join-Path $script:tmp 'nope.conf') -Key $script:key
        $r.Exit | Should -Be 2
        $r.Out  | Should -BeLike '*not provisioned*'
    }

    It 'reports a missing key distinctly from a missing conf' {
        $r = Invoke-Client -ClientArgs @('sync', 'push') -Conf $script:conf -Key (Join-Path $script:tmp 'nokey')
        $r.Exit | Should -Be 2
        $r.Out  | Should -BeLike '*sync key missing*'
    }

    It 'rejects a request with no recognisable verb rather than guessing' {
        # Neither 'b' nor 'a' is push/pull/fetch, so there is no reading of this
        # under which the first two tokens are <name> <op>. The host would reject
        # it too - failing here just saves the round trip.
        $r = Invoke-Client -ClientArgs @('sync', 'a', 'b', 'c') -Conf $script:conf -Key $script:key
        $r.Exit | Should -Be 2
        $r.Out  | Should -BeLike '*usage: sbx sync*'
    }

    It 'offers ONLY the sync key - no agent, no other identity' {
        # Regression guard for the fix in dacf954. Without IdentitiesOnly, -i only
        # APPENDS to the candidate list, so any other key reachable from the
        # container could authenticate instead - landing on a session with no
        # restrict and no forced command, i.e. a shell on the host.
        Invoke-Client -ClientArgs @('sync', 'myrepo', 'push') -Conf $script:conf `
                      -Key $script:key -FakeSshDir $script:fake | Out-Null
        $argv = @(Get-Content $script:argvLog)
        $argv | Should -Contain 'IdentitiesOnly=yes'
        $argv | Should -Contain 'IdentityAgent=none'
        $argv | Should -Contain 'BatchMode=yes'
    }

    It 'sends the request as ONE remote command string' {
        Invoke-Client -ClientArgs @('sync', 'myrepo', 'push') -Conf $script:conf `
                      -Key $script:key -FakeSshDir $script:fake | Out-Null
        $argv = @(Get-Content $script:argvLog)
        $argv[-1] | Should -Be 'myrepo push'      # one argv element, not two
        $argv     | Should -Contain 'me@10.0.0.1'
        $argv     | Should -Contain '2222'
    }

    It 'forwards git options into that one string, unfiltered' {
        # Unfiltered on purpose: a second allowlist here could drift from the
        # host's, and this client is not the boundary. sbx-sync-exec decides.
        Invoke-Client -ClientArgs @('sync', 'myrepo', 'pull', '--recurse-submodules', '--rebase') `
                      -Conf $script:conf -Key $script:key -FakeSshDir $script:fake | Out-Null
        (@(Get-Content $script:argvLog))[-1] | Should -Be 'myrepo pull --recurse-submodules --rebase'
    }

    It 'accepts a lone verb followed by options, leaving the project to the cwd' {
        # With options in play the argument COUNT no longer says whether token 1
        # is a name or a verb, so `sync fetch --prune` has to be read as the
        # cwd-inferred form. Asserted through the unprovisioned error, which fires
        # after the parse and before the cwd is consulted: a usage error would
        # mean the parse rejected it, and the assertion does not depend on where
        # the suite happens to be run from.
        $r = Invoke-Client -ClientArgs @('sync', 'fetch', '--prune') `
                           -Conf (Join-Path $script:tmp 'nope.conf') -Key $script:key
        $r.Exit | Should -Be 2
        $r.Out  | Should -BeLike '*not provisioned*'
        $r.Out  | Should -Not -BeLike '*usage:*'
    }

    It 'still reads token 1 as the project when token 2 is the verb, even if the project IS a verb name' {
        Invoke-Client -ClientArgs @('sync', 'pull', 'push') -Conf $script:conf `
                      -Key $script:key -FakeSshDir $script:fake | Out-Null
        (@(Get-Content $script:argvLog))[-1] | Should -Be 'pull push'
    }
}

Describe 'sbx pr check' -Skip:(-not (Get-Command sh -ErrorAction SilentlyContinue)) {
    BeforeEach {
        $script:tmp = Join-Path $TestDrive "pr-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $script:tmp | Out-Null
        $script:conf = Join-Path $script:tmp 'sync.conf'
        $script:key  = Join-Path $script:tmp 'id_sbx_sync'
        [IO.File]::WriteAllText($script:conf, "host=10.0.0.1`nuser=me`nport=22`n")
        [IO.File]::WriteAllText($script:key, "KEY")
        # Fake `gh` that records its argv and prints canned output, standing in
        # for the sync tests' fake `ssh`. No fake `git` - `pr check` is
        # deliberately read-only and never shells out to it (see the "why no
        # push here" comment in sbx-client.sh); a stray git invocation would
        # hit the real git and fail the test loudly, which is the point.
        $script:fake = Join-Path $script:tmp 'bin'
        New-Item -ItemType Directory -Force $script:fake | Out-Null
        $script:argvLog = Join-Path $script:tmp 'argv.txt'
        # Same idiom as the fake `ssh` above: a plain double-quoted string with
        # backtick-escaped `$` and `` `n `` newlines - NOT a here-string, which
        # would let PowerShell try to interpolate the shell script's own `$1`/`$*`.
        # Matches on "$*" with wildcards rather than positional $1/$2: --paginate
        # shifts the resource-path argument's position, and matching the whole
        # argv string is resilient to that instead of hardcoding where it lands.
        [IO.File]::WriteAllText((Join-Path $script:fake 'gh'),
            "#!/bin/sh`necho `"gh `$*`" >> '$($script:argvLog -replace '\\','/')'`n" +
            "case `"`$*`" in`n" +
            "  'pr view --json number -q .number') echo 42 ;;`n" +
            "  *'pulls/42/comments'*) echo 'FAKE-COMMENT-1' ;;`n" +
            "esac`nexit 0`n")
        Set-FakeExecutable (Join-Path $script:fake 'gh')
    }

    It 'lists coderabbit comments without pushing' {
        $r = Invoke-Client -ClientArgs @('pr', 'check') -Conf $script:conf `
                           -Key $script:key -FakeSshDir $script:fake
        $r.Exit | Should -Be 0
        $log = Get-Content -Raw $script:argvLog
        $log | Should -BeLike '*gh pr view --json number*'
        $log | Should -BeLike '*gh api --paginate repos/{owner}/{repo}/pulls/42/comments*'
        $log | Should -Not -BeLike '*git push*'
    }

    It 'rejects an unknown pr subcommand' {
        $r = Invoke-Client -ClientArgs @('pr', 'bogus') -Conf $script:conf -Key $script:key
        $r.Exit | Should -Be 2
        $r.Out  | Should -BeLike '*usage: sbx pr check*'
    }
}

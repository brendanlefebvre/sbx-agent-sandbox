BeforeAll {
    $script:client = (Resolve-Path "$PSScriptRoot/../sbx-client.sh").Path
    $script:sh = (Get-Command sh -ErrorAction SilentlyContinue)?.Source

    # Writes a stand-in for a real binary. The exec bit is the whole point:
    # WriteAllText alone leaves it 0644, and a POSIX PATH lookup SKIPS a
    # non-executable file - so the test would silently shell out to the host's
    # real gh instead of the fake, which is how two of these once "passed" on
    # Windows and failed everywhere else.
    function New-FakeExe {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Body)
        [IO.File]::WriteAllText($Path, $Body)
        if (-not $IsWindows) { & chmod +x $Path }
    }

    # Runs the real client under a POSIX shell with the conf/key it would see in
    # the container. Returns exit code plus both streams, so a test can assert on
    # the message an agent would actually read.
    #
    # ssh is redirected with SBX_SSH, not by shadowing PATH: Git Bash prepends
    # its own /usr/bin, where Git for Windows ships ssh.exe, so on Windows a
    # prepended fake is never reached. gh has no twin there and still uses PATH.
    function Invoke-Client {
        param([string[]]$ClientArgs = @(), [string]$Conf, [string]$Key,
              [string]$FakeSshDir, [string]$FakeSsh)
        $env:SBX_SYNC_CONF = $Conf
        $env:SBX_SYNC_KEY  = $Key
        if ($FakeSsh) { $env:SBX_SSH = $FakeSsh }
        $old = $env:PATH
        if ($FakeSshDir) { $env:PATH = "$FakeSshDir$([IO.Path]::PathSeparator)$old" }
        try {
            $out = & $script:sh $script:client @ClientArgs 2>&1 | Out-String
            return [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
        }
        finally {
            $env:PATH = $old
            Remove-Item Env:SBX_SYNC_CONF, Env:SBX_SYNC_KEY, Env:SBX_SSH -ErrorAction SilentlyContinue
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
        # A stand-in ssh that records its argv instead of connecting. Handed to
        # the client via SBX_SSH as a forward-slashed path - sh treats a
        # backslash as an escape, so a native Windows path would not survive.
        $script:fake = Join-Path $script:tmp 'bin'
        New-Item -ItemType Directory -Force $script:fake | Out-Null
        $script:argvLog = Join-Path $script:tmp 'argv.txt'
        $sshPath = Join-Path $script:fake 'ssh'
        New-FakeExe -Path $sshPath -Body `
            "#!/bin/sh`nfor a in `"`$@`"; do echo `"`$a`"; done > '$($script:argvLog -replace '\\','/')'`nexit 0`n"
        $script:fakeSsh = $sshPath -replace '\\', '/'
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

    It 'rejects more than two arguments rather than passing them on' {
        # The remote command is a fixed two tokens; extra args are how "push
        # --force" would try to arrive.
        $r = Invoke-Client -ClientArgs @('sync', 'a', 'b', 'c') -Conf $script:conf -Key $script:key
        $r.Exit | Should -Be 2
        $r.Out  | Should -BeLike '*usage: sbx sync*'
    }

    It 'rejects a sync.conf field that ssh would misread' -ForEach @(
        # A CRLF-terminated conf is the realistic case - the host that writes it
        # is often Windows - and the leading-dash ones are why the check exists
        # at all: ssh reads "-oProxyCommand=..." as an option, not a hostname.
        @{ Field = 'host'; Body = "host=10.0.0.1`r`nuser=me`nport=2222`n" }
        @{ Field = 'host'; Body = "host=-oProxyCommand=x`nuser=me`nport=2222`n" }
        @{ Field = 'host'; Body = "host=10.0.0.1 x`nuser=me`nport=2222`n" }
        @{ Field = 'user'; Body = "host=10.0.0.1`nuser=me you`nport=2222`n" }
        @{ Field = 'port'; Body = "host=10.0.0.1`nuser=me`nport=22x`n" }
    ) {
        $bad = Join-Path $script:tmp 'bad.conf'
        [IO.File]::WriteAllText($bad, $Body)
        $r = Invoke-Client -ClientArgs @('sync', 'myrepo', 'push') -Conf $bad `
                           -Key $script:key -FakeSsh $script:fakeSsh
        $r.Exit | Should -Be 2
        $r.Out  | Should -BeLike "*bad $Field=*"
        # The guard must fire BEFORE ssh runs, not after it fails.
        Test-Path $script:argvLog | Should -BeFalse
    }

    It 'accepts a hostname, an IPv6 literal, and the default port' {
        $ok = Join-Path $script:tmp 'ok.conf'
        [IO.File]::WriteAllText($ok, "host=fe80::1`nuser=my-user_1`n")
        Invoke-Client -ClientArgs @('sync', 'myrepo', 'push') -Conf $ok `
                      -Key $script:key -FakeSsh $script:fakeSsh | Out-Null
        $argv = @(Get-Content $script:argvLog)
        $argv | Should -Contain 'my-user_1@fe80::1'
        $argv | Should -Contain '22'       # port= absent falls back to 22
    }

    It 'offers ONLY the sync key - no agent, no other identity' {
        # Regression guard for the fix in dacf954. Without IdentitiesOnly, -i only
        # APPENDS to the candidate list, so any other key reachable from the
        # container could authenticate instead - landing on a session with no
        # restrict and no forced command, i.e. a shell on the host.
        Invoke-Client -ClientArgs @('sync', 'myrepo', 'push') -Conf $script:conf `
                      -Key $script:key -FakeSsh $script:fakeSsh | Out-Null
        $argv = @(Get-Content $script:argvLog)
        $argv | Should -Contain 'IdentitiesOnly=yes'
        $argv | Should -Contain 'IdentityAgent=none'
        $argv | Should -Contain 'BatchMode=yes'
    }

    It 'sends the request as ONE fixed two-token remote command' {
        Invoke-Client -ClientArgs @('sync', 'myrepo', 'push') -Conf $script:conf `
                      -Key $script:key -FakeSsh $script:fakeSsh | Out-Null
        $argv = @(Get-Content $script:argvLog)
        $argv[-1] | Should -Be 'myrepo push'      # one argv element, not two
        $argv     | Should -Contain 'me@10.0.0.1'
        $argv     | Should -Contain '2222'
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
        New-FakeExe -Path (Join-Path $script:fake 'gh') -Body `
            ("#!/bin/sh`necho `"gh `$*`" >> '$($script:argvLog -replace '\\','/')'`n" +
             "case `"`$*`" in`n" +
             "  'pr view --json number -q .number') echo 42 ;;`n" +
             "  *'pulls/42/comments'*) echo 'FAKE-COMMENT-1' ;;`n" +
             "esac`nexit 0`n")
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

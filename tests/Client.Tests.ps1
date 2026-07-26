BeforeAll {
    $script:client = (Resolve-Path "$PSScriptRoot/../sbx-client.sh").Path
    $script:sh = (Get-Command sh -ErrorAction SilentlyContinue)?.Source

    # Runs the real client under a POSIX shell with the conf/key/PATH it would see
    # in the container. Returns exit code plus both streams, so a test can assert
    # on the message an agent would actually read.
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

# The in-container `sbx sync` client. It is NOT a security boundary — the agent
# holds the key and can invoke ssh by hand — the boundary is the host-side forced
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

    It 'offers ONLY the sync key — no agent, no other identity' {
        # Regression guard for the fix in dacf954. Without IdentitiesOnly, -i only
        # APPENDS to the candidate list, so any other key reachable from the
        # container could authenticate instead — landing on a session with no
        # restrict and no forced command, i.e. a shell on the host.
        Invoke-Client -ClientArgs @('sync', 'myrepo', 'push') -Conf $script:conf `
                      -Key $script:key -FakeSshDir $script:fake | Out-Null
        $argv = @(Get-Content $script:argvLog)
        $argv | Should -Contain 'IdentitiesOnly=yes'
        $argv | Should -Contain 'IdentityAgent=none'
        $argv | Should -Contain 'BatchMode=yes'
    }

    It 'sends the request as ONE fixed two-token remote command' {
        Invoke-Client -ClientArgs @('sync', 'myrepo', 'push') -Conf $script:conf `
                      -Key $script:key -FakeSshDir $script:fake | Out-Null
        $argv = @(Get-Content $script:argvLog)
        $argv[-1] | Should -Be 'myrepo push'      # one argv element, not two
        $argv     | Should -Contain 'me@10.0.0.1'
        $argv     | Should -Contain '2222'
    }
}

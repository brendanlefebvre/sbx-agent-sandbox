BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

# c-heavy provisioning (ROADMAP 1 / FINDINGS P7). These cover the parts that bit
# us during the probes — authorized_keys line construction and, especially, the
# file surgery around it, where a mistake either silently disables the key or
# eats a real one.

Describe 'Build-SbxAuthorizedKeysLine' {
    BeforeAll {
        $script:pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyMaterial someone@host'
    }
    It 'pins restrict + the forced command and rewrites the comment to the tag' {
        $line = Build-SbxAuthorizedKeysLine -PublicKey $script:pub -ExecPath '/opt/sbx/sbx-sync-exec.ps1' `
                                            -WorkspaceDir '/Users/me/sbx-ws' -PwshCommand '/opt/homebrew/bin/pwsh'
        $line | Should -Be ('restrict,command="/opt/homebrew/bin/pwsh -NoProfile -File /opt/sbx/sbx-sync-exec.ps1' +
                            ' -WorkspaceDir /Users/me/sbx-ws" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyMaterial sbx-sync')
    }
    It 'keeps restrict first — it is what kills -L/-D forwarding regardless of the command' {
        (Build-SbxAuthorizedKeysLine -PublicKey $script:pub -ExecPath '/x.ps1' -WorkspaceDir '/ws' -PwshCommand 'pwsh') |
            Should -BeLike 'restrict,command=*'
    }
    It 'normalizes Windows backslashes to forward slashes (pwsh accepts both; no escaping needed)' {
        $line = Build-SbxAuthorizedKeysLine -PublicKey $script:pub -ExecPath 'C:\repo\sbx-sync-exec.ps1' `
                                            -WorkspaceDir 'C:\Users\me\sbx-ws' -PwshCommand 'pwsh'
        $line | Should -BeLike '*-File C:/repo/sbx-sync-exec.ps1 -WorkspaceDir C:/Users/me/sbx-ws"*'
        # ONE backslash. PowerShell wildcards escape with a backtick, not a
        # backslash, so '*\\*' asks for two CONSECUTIVE backslashes — a pattern
        # this line could never match even with the normalization removed.
        $line | Should -Not -BeLike '*\*'
    }
    It 'escapes an inner quote pair around a path containing spaces' {
        $line = Build-SbxAuthorizedKeysLine -PublicKey $script:pub -ExecPath 'C:\My Tools\sbx-sync-exec.ps1' `
                                            -WorkspaceDir '/ws' -PwshCommand 'pwsh'
        $line | Should -BeLike '*-File \"C:/My Tools/sbx-sync-exec.ps1\" -WorkspaceDir /ws"*'
    }
    It 'refuses something that is not a public key' {
        { Build-SbxAuthorizedKeysLine -PublicKey 'garbage' -ExecPath '/x.ps1' -WorkspaceDir '/ws' } |
            Should -Throw '*not a public key*'
    }
}

Describe 'Update-SbxAuthorizedKeys' {
    BeforeEach {
        $script:ak = Join-Path $TestDrive "ak-$([guid]::NewGuid())"
        $script:mine = 'restrict,command="pwsh -NoProfile -File /x.ps1" ssh-ed25519 AAAAMine sbx-sync'
        $script:theirs = 'ssh-rsa AAAATheirRealKey me@laptop'
    }
    It 'creates the file when absent' {
        $r = Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        (Get-Content -Raw $script:ak) | Should -Be ($script:mine + "`n")
        $r.Replaced | Should -BeFalse
    }
    It 'leaves no .sbx.tmp behind, on either the create or the replace path' {
        # The write goes via a sidecar so an interrupted write can't truncate the
        # user's only way into their own host. It must not survive the swap.
        Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        (Test-Path -LiteralPath "$($script:ak).sbx.tmp") | Should -BeFalse
        Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        (Test-Path -LiteralPath "$($script:ak).sbx.tmp") | Should -BeFalse
        (Get-Content -Raw $script:ak) | Should -Be ($script:mine + "`n")
    }
    It 'appends without merging onto a file whose last line has NO trailing newline' {
        # P7 bug #1: a naive append merged our entry onto the previous key, which
        # stayed valid with a longer comment while ours silently vanished.
        [IO.File]::WriteAllText($script:ak, $script:theirs)   # no trailing newline
        Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        $lines = @(Get-Content $script:ak)
        $lines.Count | Should -Be 2
        $lines[0]    | Should -Be $script:theirs
        $lines[1]    | Should -Be $script:mine
    }
    It 'always leaves a trailing newline so the NEXT appender cannot merge either' {
        Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        (Get-Content -Raw $script:ak) | Should -BeLike "*`n"
    }
    It 'replaces our previous tagged line instead of accumulating duplicates' {
        Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        $rotated = 'restrict,command="pwsh -NoProfile -File /y.ps1" ssh-ed25519 AAAARotated sbx-sync'
        $r = Update-SbxAuthorizedKeys -Path $script:ak -Line $rotated
        $r.Replaced  | Should -BeTrue
        @(Get-Content $script:ak).Count | Should -Be 1
        (Get-Content -Raw $script:ak)   | Should -BeLike '*AAAARotated*'
    }
    It 'never touches a key that is not ours' {
        # P7 bug #2: an early harness rewrite blanked a user's real key.
        [IO.File]::WriteAllText($script:ak, ($script:theirs + "`n"))
        Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        Update-SbxAuthorizedKeys -Path $script:ak -Remove
        (Get-Content -Raw $script:ak) | Should -Be ($script:theirs + "`n")
    }
    It 'snapshots the pre-edit file to a .bak sidecar' {
        [IO.File]::WriteAllText($script:ak, ($script:theirs + "`n"))
        $r = Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        (Get-Content -Raw $r.Backup) | Should -Be ($script:theirs + "`n")
    }
    It 'preserves CRLF line endings when the file already uses them' {
        [IO.File]::WriteAllText($script:ak, ($script:theirs + "`r`n"))
        Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        (Get-Content -Raw $script:ak) | Should -Be ($script:theirs + "`r`n" + $script:mine + "`r`n")
    }
    It 'writes no BOM (sshd would read it as part of the first key)' {
        Update-SbxAuthorizedKeys -Path $script:ak -Line $script:mine
        $bytes = [IO.File]::ReadAllBytes($script:ak)
        $bytes[0] | Should -Be ([byte][char]'r')
    }
    It 'removing when nothing is installed is a no-op, not an error' {
        [IO.File]::WriteAllText($script:ak, ($script:theirs + "`n"))
        (Update-SbxAuthorizedKeys -Path $script:ak -Remove).Replaced | Should -BeFalse
        (Get-Content -Raw $script:ak) | Should -Be ($script:theirs + "`n")
    }
}

Describe 'Get-SbxAuthorizedKeysPath' {
    It 'uses the per-user file off Windows' {
        Get-SbxAuthorizedKeysPath -IsWin $false | Should -Be (Join-Path $HOME '.ssh/authorized_keys')
    }
    It 'honors an explicit override' {
        Get-SbxAuthorizedKeysPath -Override '/tmp/ak' -IsWin $true | Should -Be '/tmp/ak'
    }
}

Describe 'sync.conf round-trip' {
    It 'writes LF-terminated key=value the container sh client can parse, and reads it back' {
        $dir = Join-Path $TestDrive 'syncdir'
        $p = Write-SbxSyncConf -Address '172.20.240.1' -SshUser 'me' -Port 2222 -SyncDir $dir
        (Get-Content -Raw $p) | Should -Not -BeLike "*`r`n*"
        $c = Get-SbxSyncConf -SyncDir $dir
        $c.host | Should -Be '172.20.240.1'
        $c.user | Should -Be 'me'
        $c.port | Should -Be '2222'
    }
    It 'returns null when c-heavy was never provisioned' {
        Get-SbxSyncConf -SyncDir (Join-Path $TestDrive 'nope') | Should -BeNullOrEmpty
    }
}

Describe 'Build-SbxMainCreateArgs sync mount' {
    It 'omits the key mount when c-heavy is not provisioned' {
        $a = Build-SbxMainCreateArgs -WorkspacePath '/Users/me/sbx-ws' -SyncDir $null -Posix
        ($a -join ' ') | Should -Not -BeLike '*ssh-ro*'
    }
    It 'mounts the sync dir read-only at the entrypoint staging path when provisioned' {
        $a = Build-SbxMainCreateArgs -WorkspacePath '/Users/me/sbx-ws' -SyncDir '/Users/me/.sbx/sync' -Posix
        ($a -join ' ') | Should -BeLike '*-v /Users/me/.sbx/sync:/home/agent/.ssh-ro:ro*'
        # The workspace mount and the image/command must still come last.
        $a[-3..-1] | Should -Be @('sbx:latest', 'sleep', 'infinity')
    }
}

Describe 'Invoke-SbxSyncSetup' {
    BeforeEach {
        $script:syncDir = Join-Path $TestDrive "sync-$([guid]::NewGuid())"
        $script:ak      = Join-Path $TestDrive "ak-$([guid]::NewGuid())"
        $script:exec    = Join-Path $PSScriptRoot '../sbx-sync-exec.ps1'
        Mock -CommandName Write-Host -MockWith { }   # the summary banner is not under test
    }
    It 'refuses to guess the host address (P7: auto-discovery is unreliable)' {
        { Invoke-SbxSyncSetup -SyncDir $script:syncDir -AuthorizedKeysFile $script:ak } |
            Should -Throw '*--address*'
    }
    It 'generates a key, installs the pinned line, and writes the config' {
        $r = Invoke-SbxSyncSetup -Address '172.20.240.1' -SshUser 'me' -SyncDir $script:syncDir `
                                 -AuthorizedKeysFile $script:ak -WorkspaceDir '/ws' -ExecPath $script:exec
        Test-Path $r.Key | Should -BeTrue
        $line = (Get-Content $script:ak) | Where-Object { $_ -match 'sbx-sync$' }
        $line | Should -BeLike 'restrict,command=*sbx-sync-exec.ps1 -WorkspaceDir /ws"*'
        (Get-SbxSyncConf -SyncDir $script:syncDir).host | Should -Be '172.20.240.1'
    }
    It 'is idempotent — a second run replaces the line rather than adding one' {
        $p = @{ Address = '10.0.0.1'; SshUser = 'me'; SyncDir = $script:syncDir
                AuthorizedKeysFile = $script:ak; WorkspaceDir = '/ws'; ExecPath = $script:exec }
        Invoke-SbxSyncSetup @p | Out-Null
        Invoke-SbxSyncSetup @p | Out-Null
        @(Get-Content $script:ak | Where-Object { $_ -match 'sbx-sync$' }).Count | Should -Be 1
    }
    It 'reuses the existing keypair across re-runs (rotation is explicit, not incidental)' {
        $p = @{ Address = '10.0.0.1'; SshUser = 'me'; SyncDir = $script:syncDir
                AuthorizedKeysFile = $script:ak; WorkspaceDir = '/ws'; ExecPath = $script:exec }
        $first = (Invoke-SbxSyncSetup @p).Key
        $pub   = Get-Content -Raw "$first.pub"
        Invoke-SbxSyncSetup @p | Out-Null
        (Get-Content -Raw "$first.pub") | Should -Be $pub
    }
    It '--print-only writes nothing to authorized_keys' {
        Invoke-SbxSyncSetup -Address '10.0.0.1' -SshUser 'me' -SyncDir $script:syncDir `
                            -AuthorizedKeysFile $script:ak -WorkspaceDir '/ws' -ExecPath $script:exec `
                            -PrintOnly 6>$null | Out-Null
        Test-Path $script:ak | Should -BeFalse
    }
    It '--remove revokes the line and destroys the key material' {
        $p = @{ Address = '10.0.0.1'; SshUser = 'me'; SyncDir = $script:syncDir
                AuthorizedKeysFile = $script:ak; WorkspaceDir = '/ws'; ExecPath = $script:exec }
        Invoke-SbxSyncSetup @p | Out-Null
        Invoke-SbxSyncSetup -Remove -SyncDir $script:syncDir -AuthorizedKeysFile $script:ak 6>$null
        Test-Path $script:syncDir | Should -BeFalse
        @(Get-Content $script:ak | Where-Object { $_ -match 'sbx-sync$' }).Count | Should -Be 0
        Get-SbxProvisionedSyncDir -SyncDir $script:syncDir | Should -BeNullOrEmpty
    }
}

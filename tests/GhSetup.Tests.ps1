BeforeAll { . "$PSScriptRoot/../sbx.ps1" }

# c-gh provisioning. Unlike c-heavy sync there is no forced-command validator —
# the PAT's own github.com scopes are the boundary — so these primitives are
# much smaller: write a token file, mount it, done. See docs/GH.md.

Describe 'Get-SbxGhDir' {
    It 'defaults to ~/.sbx/gh' {
        Get-SbxGhDir | Should -Be (Join-Path $HOME '.sbx/gh')
    }
    It 'honors an override' {
        Get-SbxGhDir -Override '/tmp/ghdir' | Should -Be '/tmp/ghdir'
    }
}

Describe 'Get-SbxGhTokenPath' {
    It 'is <dir>/token' {
        Get-SbxGhTokenPath -GhDir '/tmp/ghdir' | Should -Be (Join-Path '/tmp/ghdir' 'token')
    }
}

Describe 'Get-SbxProvisionedGhDir' {
    It 'returns $null when no token has been written' {
        Get-SbxProvisionedGhDir -GhDir (Join-Path $TestDrive 'nope') | Should -BeNullOrEmpty
    }
    It 'returns the dir once a token file exists' {
        $dir = Join-Path $TestDrive "gh-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'token'), 'ghp_fake')
        Get-SbxProvisionedGhDir -GhDir $dir | Should -Be $dir
    }
}

Describe 'Write-SbxGhToken' {
    It 'writes the trimmed token to <dir>/token' {
        $tokenFile = Join-Path $TestDrive "in-$([guid]::NewGuid()).txt"
        [IO.File]::WriteAllText($tokenFile, "ghp_fakeTokenValue`n")
        $dir = Join-Path $TestDrive "gh-$([guid]::NewGuid())"
        $path = Write-SbxGhToken -TokenFile $tokenFile -GhDir $dir
        $path | Should -Be (Join-Path $dir 'token')
        (Get-Content -Raw $path) | Should -Be 'ghp_fakeTokenValue'
    }
    It 'creates the gh dir if it does not exist' {
        $tokenFile = Join-Path $TestDrive "in2-$([guid]::NewGuid()).txt"
        [IO.File]::WriteAllText($tokenFile, 'ghp_fake')
        $dir = Join-Path $TestDrive "gh-new-$([guid]::NewGuid())"
        Test-Path $dir | Should -BeFalse
        Write-SbxGhToken -TokenFile $tokenFile -GhDir $dir | Out-Null
        Test-Path $dir | Should -BeTrue
    }
    It 'refuses a missing token file' {
        { Write-SbxGhToken -TokenFile (Join-Path $TestDrive 'nope.txt') -GhDir (Join-Path $TestDrive 'gh') } |
            Should -Throw '*token file not found*'
    }
    It 'refuses an empty token file' {
        $tokenFile = Join-Path $TestDrive "empty-$([guid]::NewGuid()).txt"
        [IO.File]::WriteAllText($tokenFile, "`n`n")
        { Write-SbxGhToken -TokenFile $tokenFile -GhDir (Join-Path $TestDrive 'gh') } |
            Should -Throw '*empty*'
    }
    It 'writes no BOM (gh auth login reads stdin verbatim)' {
        $tokenFile = Join-Path $TestDrive "in3-$([guid]::NewGuid()).txt"
        [IO.File]::WriteAllText($tokenFile, 'ghp_fake')
        $dir = Join-Path $TestDrive "gh-$([guid]::NewGuid())"
        $path = Write-SbxGhToken -TokenFile $tokenFile -GhDir $dir
        $bytes = [IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Be ([byte][char]'g')
    }
}

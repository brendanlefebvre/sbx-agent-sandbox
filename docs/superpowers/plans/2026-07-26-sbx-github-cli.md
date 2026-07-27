# sbx GitHub CLI (c-gh) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `c-gh` tier that provisions a fine-grained GitHub PAT into the sandbox so an agent can `gh pr create` and iterate with CodeRabbit's review (`sbx pr respond`) without a human running `gh` on its behalf every round.

**Architecture:** Host-side `sbx gh-setup` (new sbx.ps1 verb, modeled on `sync-setup`) stores a PAT you created on github.com at `~/.sbx/gh/token` (mode 600) and mounts it read-only into `sbx-main`; the image entrypoint feeds it to `gh auth login`/`gh auth setup-git` at container start. Inside the container, the existing sync client script (renamed `sbx-client.sh`) grows two verbs, `pr create` and `pr respond`, thin wrappers over `gh`. Unlike c-heavy sync, there is no host-side forced-command validator here — GitHub's API has no equivalent primitive — so the PAT's own scopes (and a GitHub branch-protection rule blocking self-merge) are the entire boundary. See `docs/superpowers/specs/2026-07-26-sbx-github-cli-design.md` for the full rationale.

**Tech Stack:** PowerShell 7 (`pwsh`) host-side, POSIX `/bin/sh` in-container client, Pester for tests, GitHub CLI (`gh`) installed via its official apt repo in the Sandboxfile.

**Revision note (2026-07-27):** Tasks 1-7 below were executed as written, then corrected after review: `sbx pr create` was dropped (pure `gh pr create --fill` pass-through, no value over calling `gh` directly), and `sbx pr respond` was replaced with a read-only `sbx pr check` — the original conflated push-then-list-comments in one call, which is actively wrong given CodeRabbit's multi-minute review lag (a push-and-check call only ever sees nothing or CodeRabbit's bare "review started" ack). Push is now plain `git push`, called separately, before checking. Task 5's body below is left as originally written for the historical record of what was executed; the actual code, tests, and docs now reflect `sbx pr check` only. Task 8 has since been executed and its results recorded in place (see Task 8's checklist below and `docs/FINDINGS.md`'s 2026-07-27 entry) — it was not yet executed at the time this note was originally written. See the "Revision" section in `docs/superpowers/specs/2026-07-26-sbx-github-cli-design.md` for the full rationale.

## Global Constraints

- Windows host is ARM64, not x64 (per user's global CLAUDE.md) — the Sandboxfile already arch-maps for `pwsh`; the new `gh` apt install must work unmodified on `arm64` (GitHub's apt repo ships arm64 packages, confirm during Task 6's build).
- All host-side PowerShell functions are dot-sourced from `sbx.ps1` and tested via Pester (`Invoke-Pester tests -Output Detailed`); every new function needs a test in the same style as its `sync-setup` analog.
- Shell scripts are `.sh text eol=lf` in `.gitattributes` — no manual line-ending handling needed, but keep POSIX `sh` syntax (no bashisms) since the client's shebang is `#!/bin/sh`.
- Secret files (the token) get `chmod 600` on non-Windows only, mirroring `New-SbxSyncKey`'s `if (-not $IsWindows) { & chmod 600 ... }` guard — Windows ACLs aren't touched by this plan (same scope as the existing sync key, which also skips chmod on Windows).
- No placeholders, no TODOs — every code block below is the actual content to write.
- Granular commits: one per task, following this repo's `feat:`/`docs:`/`test:` convention (see `git log`).

---

### Task 1: Host-side gh token storage primitives

**Files:**
- Modify: `sbx.ps1` (new section, add near the end after the sync section, before `Get-SbxLiveSessions` at line 1343 — i.e. insert after `Test-SbxInAdministrators`)
- Test: `tests/GhSetup.Tests.ps1` (new file)

**Interfaces:**
- Produces: `Get-SbxGhDir -Override <string?> -> string`, `Get-SbxGhTokenPath -GhDir <string> -> string`, `Get-SbxProvisionedGhDir -GhDir <string> -> string|$null`, `Write-SbxGhToken -TokenFile <string> -GhDir <string> -> string` (returns the written token path). Task 2 and Task 3 consume all four.

- [ ] **Step 1: Write the failing tests**

Create `tests/GhSetup.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/GhSetup.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Get-SbxGhDir`, `Get-SbxGhTokenPath`, `Get-SbxProvisionedGhDir`, `Write-SbxGhToken` are not recognized commands.

- [ ] **Step 3: Implement the primitives in `sbx.ps1`**

Insert this new section into `sbx.ps1` right after the `Test-SbxInAdministrators` function (currently ending at line 1341, just before `function Get-SbxLiveSessions {`):

```powershell
# ---- c-gh: GitHub CLI token provisioning (ROADMAP; see docs/GH.md) -------------
#
# Unlike c-heavy sync, there is no host-side forced-command validator possible
# here — the GitHub REST/GraphQL API has no equivalent primitive. The PAT's own
# scopes (repos + Contents/Pull-requests permissions, chosen on github.com when
# you create it) ARE the boundary. This section only gets the token onto disk
# and mounted; it enforces nothing.

function Get-SbxGhDir {
    [CmdletBinding()]
    param([string]$Override = $env:SBX_GH_DIR)
    # Holds only the token file. Bind-mounted read-only into sbx-main, same
    # staging pattern as Get-SbxSyncDir.
    if ($Override) { return $Override }
    return (Join-Path $HOME '.sbx/gh')
}

function Get-SbxGhTokenPath {
    [CmdletBinding()]
    param([string]$GhDir = (Get-SbxGhDir))
    return (Join-Path $GhDir 'token')
}

function Get-SbxProvisionedGhDir {
    [CmdletBinding()]
    param([string]$GhDir = (Get-SbxGhDir))
    # $null unless c-gh is actually provisioned — callers use it to decide
    # whether sbx-main gets the token mount at all. No setup, no token in the
    # sandbox.
    if (Test-Path -LiteralPath (Get-SbxGhTokenPath -GhDir $GhDir)) { return $GhDir }
    return $null
}

function Write-SbxGhToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TokenFile, [string]$GhDir = (Get-SbxGhDir))
    if (-not (Test-Path -LiteralPath $TokenFile)) { throw "sbx: token file not found: $TokenFile" }
    $token = (Get-Content -Raw -LiteralPath $TokenFile).Trim()
    if (-not $token) { throw "sbx: token file is empty: $TokenFile" }
    if (-not (Test-Path -LiteralPath $GhDir)) { New-Item -ItemType Directory -Force $GhDir | Out-Null }
    $path = Get-SbxGhTokenPath -GhDir $GhDir
    # No BOM, no trailing newline: `gh auth login --with-token` reads stdin
    # verbatim and a stray CR/newline risks being read as part of the token.
    [IO.File]::WriteAllText($path, $token, [Text.UTF8Encoding]::new($false))
    if (-not $IsWindows) { & chmod 600 $path }
    return $path
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/GhSetup.Tests.ps1 -Output Detailed"`
Expected: PASS, all `It` blocks green.

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/GhSetup.Tests.ps1
git commit -m "feat(gh): add host-side token storage primitives for c-gh"
```

---

### Task 2: Mount the gh token into `sbx-main`

**Files:**
- Modify: `sbx.ps1:581-605` (`Build-SbxMainCreateArgs`)
- Test: `tests/GhSetup.Tests.ps1` (append)

**Interfaces:**
- Consumes: `Get-SbxProvisionedGhDir` (Task 1), `ConvertTo-SbxMountPath` (existing).
- Produces: `Build-SbxMainCreateArgs` gains a `-GhDir` parameter; when set, the returned arg array contains `-v <GhDir>:/home/agent/.gh-ro:ro`. Task 6 (entrypoint) consumes the `/home/agent/.gh-ro` mount point name.

- [ ] **Step 1: Write the failing tests**

Append to `tests/GhSetup.Tests.ps1`:

```powershell
Describe 'Build-SbxMainCreateArgs gh mount' {
    It 'omits the token mount when c-gh is not provisioned' {
        $a = Build-SbxMainCreateArgs -WorkspacePath '/Users/me/sbx-ws' -GhDir $null -Posix
        ($a -join ' ') | Should -Not -BeLike '*gh-ro*'
    }
    It 'mounts the gh dir read-only at the entrypoint staging path when provisioned' {
        $a = Build-SbxMainCreateArgs -WorkspacePath '/Users/me/sbx-ws' -GhDir '/Users/me/.sbx/gh' -Posix
        ($a -join ' ') | Should -BeLike '*-v /Users/me/.sbx/gh:/home/agent/.gh-ro:ro*'
        # The workspace mount and the image/command must still come last.
        $a[-3..-1] | Should -Be @('sbx:latest', 'sleep', 'infinity')
    }
    It 'mounts both sync and gh dirs together when both are provisioned' {
        $a = Build-SbxMainCreateArgs -WorkspacePath '/Users/me/sbx-ws' `
             -SyncDir '/Users/me/.sbx/sync' -GhDir '/Users/me/.sbx/gh' -Posix
        ($a -join ' ') | Should -BeLike '*ssh-ro*'
        ($a -join ' ') | Should -BeLike '*gh-ro*'
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/GhSetup.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Build-SbxMainCreateArgs` has no `-GhDir` parameter.

- [ ] **Step 3: Add the `-GhDir` param and mount**

In `sbx.ps1`, change the `Build-SbxMainCreateArgs` function (lines 581-605) from:

```powershell
function Build-SbxMainCreateArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath,
          [string]$Image = 'sbx:latest',
          [string]$AuthVolume = 'sbx-claude-auth',
          [string]$Name = 'sbx-main',
          [string]$SyncDir = (Get-SbxProvisionedSyncDir),
          [switch]$Posix)
    $ws = ConvertTo-SbxMountPath -HostPath $WorkspacePath -Posix:$Posix
    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('run','-d','--name',$Name,'--label','sbx=1',
                            '-v',"${AuthVolume}:/home/agent/.claude"))
    # c-heavy: the dedicated sync key, read-only, ONLY when sync-setup has run.
    # Lands at the image's existing .ssh-ro staging point, whose entrypoint copies
    # it to ~/.ssh at 0600 — bind mounts arrive 0777 and ssh refuses such a key.
    if ($SyncDir) {
        $sd = ConvertTo-SbxMountPath -HostPath $SyncDir -Posix:$Posix
        $a.AddRange([string[]]@('-v',"${sd}:/home/agent/.ssh-ro:ro"))
    }
    $a.AddRange([string[]]@('-v',"${ws}:/work",'-w','/work',$Image,'sleep','infinity'))
    return $a.ToArray()
```

to:

```powershell
function Build-SbxMainCreateArgs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath,
          [string]$Image = 'sbx:latest',
          [string]$AuthVolume = 'sbx-claude-auth',
          [string]$Name = 'sbx-main',
          [string]$SyncDir = (Get-SbxProvisionedSyncDir),
          [string]$GhDir = (Get-SbxProvisionedGhDir),
          [switch]$Posix)
    $ws = ConvertTo-SbxMountPath -HostPath $WorkspacePath -Posix:$Posix
    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('run','-d','--name',$Name,'--label','sbx=1',
                            '-v',"${AuthVolume}:/home/agent/.claude"))
    # c-heavy: the dedicated sync key, read-only, ONLY when sync-setup has run.
    # Lands at the image's existing .ssh-ro staging point, whose entrypoint copies
    # it to ~/.ssh at 0600 — bind mounts arrive 0777 and ssh refuses such a key.
    if ($SyncDir) {
        $sd = ConvertTo-SbxMountPath -HostPath $SyncDir -Posix:$Posix
        $a.AddRange([string[]]@('-v',"${sd}:/home/agent/.ssh-ro:ro"))
    }
    # c-gh: the GitHub PAT, read-only, ONLY when gh-setup has run. Lands at
    # .gh-ro, whose entrypoint feeds it to `gh auth login` — see Sandboxfile.
    if ($GhDir) {
        $gd = ConvertTo-SbxMountPath -HostPath $GhDir -Posix:$Posix
        $a.AddRange([string[]]@('-v',"${gd}:/home/agent/.gh-ro:ro"))
    }
    $a.AddRange([string[]]@('-v',"${ws}:/work",'-w','/work',$Image,'sleep','infinity'))
    return $a.ToArray()
```

(The trailing comment block after the function — "Anchor is `sleep infinity`..." — is unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/GhSetup.Tests.ps1 -Output Detailed"`
Expected: PASS. Also re-run `pwsh -NoProfile -Command "Invoke-Pester tests/SyncSetup.Tests.ps1 -Output Detailed"` to confirm the existing sync-mount tests still pass unchanged (they don't pass `-GhDir`, so it must default to `Get-SbxProvisionedGhDir`, which returns `$null` in a clean test env).

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/GhSetup.Tests.ps1
git commit -m "feat(gh): mount the provisioned gh token into sbx-main"
```

---

### Task 3: `Invoke-SbxGhSetup` (provision / --remove)

**Files:**
- Modify: `sbx.ps1` (append after `Write-SbxGhToken`, same new section from Task 1)
- Test: `tests/GhSetup.Tests.ps1` (append)

**Interfaces:**
- Consumes: `Get-SbxGhDir`, `Write-SbxGhToken` (Task 1).
- Produces: `Invoke-SbxGhSetup -TokenFile <string?> -Remove <switch> -GhDir <string> -> [pscustomobject]@{ Token = <path> }` (or nothing, for `-Remove`). Task 4 (CLI dispatch) consumes this signature.

- [ ] **Step 1: Write the failing tests**

Append to `tests/GhSetup.Tests.ps1`:

```powershell
Describe 'Invoke-SbxGhSetup' {
    BeforeEach {
        $script:ghDir = Join-Path $TestDrive "gh-$([guid]::NewGuid())"
        $script:tokenFile = Join-Path $TestDrive "token-$([guid]::NewGuid()).txt"
        [IO.File]::WriteAllText($script:tokenFile, "ghp_fakeTokenValue`n")
        Mock -CommandName Write-Host -MockWith { }   # the summary banner is not under test
    }
    It 'refuses to run without a token file' {
        { Invoke-SbxGhSetup -GhDir $script:ghDir } | Should -Throw '*--token-file*'
    }
    It 'writes the token and reports it' {
        $r = Invoke-SbxGhSetup -TokenFile $script:tokenFile -GhDir $script:ghDir
        $r.Token | Should -Be (Join-Path $script:ghDir 'token')
        Test-Path $r.Token | Should -BeTrue
    }
    It 'is idempotent — a second run overwrites rather than erroring' {
        Invoke-SbxGhSetup -TokenFile $script:tokenFile -GhDir $script:ghDir | Out-Null
        [IO.File]::WriteAllText($script:tokenFile, 'ghp_rotatedToken')
        $r = Invoke-SbxGhSetup -TokenFile $script:tokenFile -GhDir $script:ghDir
        (Get-Content -Raw $r.Token) | Should -Be 'ghp_rotatedToken'
    }
    It '--remove deletes the local token dir' {
        Invoke-SbxGhSetup -TokenFile $script:tokenFile -GhDir $script:ghDir | Out-Null
        Invoke-SbxGhSetup -Remove -GhDir $script:ghDir
        Test-Path $script:ghDir | Should -BeFalse
        Get-SbxProvisionedGhDir -GhDir $script:ghDir | Should -BeNullOrEmpty
    }
    It '--remove on an already-empty dir is a no-op, not an error' {
        { Invoke-SbxGhSetup -Remove -GhDir (Join-Path $TestDrive 'never-existed') } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/GhSetup.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Invoke-SbxGhSetup` is not recognized.

- [ ] **Step 3: Implement `Invoke-SbxGhSetup`**

Append to the c-gh section in `sbx.ps1` (after `Write-SbxGhToken`):

```powershell
function Invoke-SbxGhSetup {
    [CmdletBinding()]
    param([string]$TokenFile, [switch]$Remove, [string]$GhDir = (Get-SbxGhDir))
    if ($Remove) {
        Remove-Item -LiteralPath $GhDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "sbx: c-gh local token removed from $GhDir." -ForegroundColor Yellow
        Write-Host "sbx: this does NOT revoke the token on GitHub — do that at https://github.com/settings/tokens if it's no longer needed." -ForegroundColor Yellow
        Write-Host "sbx: run 'sbx rebuild' to drop the token mount from the running sandbox." -ForegroundColor Cyan
        return
    }
    if (-not $TokenFile) {
        throw @"
sbx: gh-setup needs a fine-grained GitHub PAT: sbx gh-setup --token-file <path>
     Create one at https://github.com/settings/personal-access-tokens/new scoped
     to only the repos you want, with ONLY:
       Contents:      Read and write
       Pull requests: Read and write
     Also add a branch-protection rule on the target repo requiring a human
     review before merge — a token can't be scoped to block merge on its own.
     See docs/GH.md.
"@
    }
    $path = Write-SbxGhToken -TokenFile $TokenFile -GhDir $GhDir
    Write-Host "sbx: c-gh provisioned." -ForegroundColor Green
    Write-Host "  token       $path (mounted read-only into sbx-main)"
    Write-Host "  agents get  gh + git push authenticated as this token, on whatever repos/permissions you scoped it to on github.com." -ForegroundColor DarkGray
    Write-Host "sbx: run 'sbx rebuild' so sbx-main picks up the token, then 'sbx pr create' / 'sbx pr respond' from inside a project." -ForegroundColor Cyan
    return [pscustomobject]@{ Token = $path }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/GhSetup.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add sbx.ps1 tests/GhSetup.Tests.ps1
git commit -m "feat(gh): add Invoke-SbxGhSetup (provision / --remove)"
```

---

### Task 4: Wire `sbx gh-setup` into the CLI parser and dispatcher

**Files:**
- Modify: `sbx.ps1:1-74` (`ConvertFrom-SbxArgs`), `sbx.ps1:188-250` (`Invoke-Sbx`)
- Test: `tests/Parser.Tests.ps1` (append)

**Interfaces:**
- Consumes: `Invoke-SbxGhSetup` (Task 3).
- Produces: `sbx gh-setup [--token-file <path>] [--remove]` on the command line, dispatching to `Invoke-SbxGhSetup`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/Parser.Tests.ps1`:

```powershell
Describe 'ConvertFrom-SbxArgs — gh-setup (c-gh)' {
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Parser.Tests.ps1 -Output Detailed"`
Expected: FAIL — `gh-setup` falls into the parser's `default` arm (treated as a project name) and `TokenFile` doesn't exist on `$opts`.

- [ ] **Step 3: Extend the parser**

In `sbx.ps1`, in `ConvertFrom-SbxArgs` (function starts at line 1):

Change the `$opts` initializer (lines 8-13):

```powershell
    $opts = [ordered]@{
        Command = 'attach'; Target = $null; Operation = $null; Window = 'here'
        # sync-setup only (see Invoke-SbxSyncSetup); null means "use the default".
        Address = $null; SshUser = $null; Port = $null; AuthorizedKeysFile = $null
        PrintOnly = $false; Remove = $false
    }
```

to:

```powershell
    $opts = [ordered]@{
        Command = 'attach'; Target = $null; Operation = $null; Window = 'here'
        # sync-setup only (see Invoke-SbxSyncSetup); null means "use the default".
        Address = $null; SshUser = $null; Port = $null; AuthorizedKeysFile = $null
        PrintOnly = $false; Remove = $false
        # gh-setup only (see Invoke-SbxGhSetup).
        TokenFile = $null
    }
```

Change the `$valueOpts` table (lines 20-25):

```powershell
    $valueOpts = @{
        '--address'         = 'Address'
        '--user'            = 'SshUser'
        '--port'            = 'Port'
        '--authorized-keys' = 'AuthorizedKeysFile'
    }
```

to:

```powershell
    $valueOpts = @{
        '--address'         = 'Address'
        '--user'            = 'SshUser'
        '--port'            = 'Port'
        '--authorized-keys' = 'AuthorizedKeysFile'
        '--token-file'      = 'TokenFile'
    }
```

Add a case to the `switch ($positional[0])` block (after the `'sync-setup' { ... }` line, currently line 59):

```powershell
        'sync-setup' { $opts.Command = 'sync-setup' }
        'gh-setup'   { $opts.Command = 'gh-setup' }
```

- [ ] **Step 4: Run parser tests to verify they pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Parser.Tests.ps1 -Output Detailed"`
Expected: PASS.

- [ ] **Step 5: Wire the dispatcher**

In `sbx.ps1`, in `Invoke-Sbx` (function starts at line 188), add a case after the existing `'sync-setup' { ... }` block (currently lines 198-205):

```powershell
        'sync-setup' {
            $p = @{ PrintOnly = [bool]$o.PrintOnly; Remove = [bool]$o.Remove }
            foreach ($k in 'Address', 'SshUser', 'AuthorizedKeysFile') {
                if ($o.$k) { $p[$k] = $o.$k }
            }
            if ($o.Port) { $p.Port = [int]$o.Port }
            return Invoke-SbxSyncSetup @p
        }
        'gh-setup' {
            $p = @{ Remove = [bool]$o.Remove }
            if ($o.TokenFile) { $p.TokenFile = $o.TokenFile }
            return Invoke-SbxGhSetup @p
        }
```

- [ ] **Step 6: Run the full unit suite**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests -Output Detailed"`
Expected: PASS, no regressions.

- [ ] **Step 7: Commit**

```bash
git add sbx.ps1 tests/Parser.Tests.ps1
git commit -m "feat(gh): wire 'sbx gh-setup' into the CLI parser and dispatcher"
```

---

### Task 5: Rename the in-container client and add `pr create` / `pr respond`

**Files:**
- Rename: `sbx-sync-client.sh` → `sbx-client.sh`
- Rename: `tests/SyncClient.Tests.ps1` → `tests/Client.Tests.ps1`
- Modify: `Sandboxfile:105-106` (the `COPY`/`chmod` lines)

**Interfaces:**
- Consumes: `gh` and `git` on `PATH` inside the container (Task 6 installs `gh`; `git` already ships in the base image).
- Produces: in-container `sbx pr create [gh-pr-create-args...]` and `sbx pr respond` verbs. Nothing outside this script depends on their internals.

The rename happens first, as its own verified step, so a reviewer can trust the diff that follows is purely additive.

- [ ] **Step 1: Rename the client script and its test file**

```bash
git mv sbx-sync-client.sh sbx-client.sh
git mv tests/SyncClient.Tests.ps1 tests/Client.Tests.ps1
```

- [ ] **Step 2: Update the one line in `tests/Client.Tests.ps1` that hardcodes the old filename**

In `tests/Client.Tests.ps1`, change:

```powershell
    $script:client = (Resolve-Path "$PSScriptRoot/../sbx-sync-client.sh").Path
```

to:

```powershell
    $script:client = (Resolve-Path "$PSScriptRoot/../sbx-client.sh").Path
```

- [ ] **Step 3: Update the `Sandboxfile` COPY line**

In `Sandboxfile`, change:

```dockerfile
COPY sbx-sync-client.sh /usr/local/bin/sbx
RUN chmod +x /usr/local/bin/sbx
```

to:

```dockerfile
COPY sbx-client.sh /usr/local/bin/sbx
RUN chmod +x /usr/local/bin/sbx
```

Also update the comment two lines above (currently "# c-heavy sync client. Inside the sandbox `sbx sync push` is the ONE host") to reflect the broader scope — change:

```dockerfile
# c-heavy sync client. Inside the sandbox `sbx sync push` is the ONE host
# operation an agent can trigger: it SSHes back to the host with the dedicated
# key (mounted at .ssh-ro by `sbx sync-setup`, copied to ~/.ssh above), whose
# authorized_keys line pins it to sbx-sync-exec — three verbs on workspace repos,
# no shell, no forwarding. Host address/user/port are read LIVE from the mounted
# sync.conf, so re-pointing the host doesn't need a container rebuild.
#
# The script is a real file in the repo, not a printf here: it is the one host
# operation c-heavy grants an agent, so it gets an `sh -n` syntax gate and unit
# tests (tests/SyncClient.Tests.ps1) like any other code — and is now shellcheck-
# able, though no host in this project has shellcheck installed yet. chmod
# separately rather than COPY --chmod, since git on Windows drops the exec bit.
```

to:

```dockerfile
# In-container sbx client: `sbx sync <op>` (c-heavy, unchanged — see the sync
# section above) and `sbx pr create`/`sbx pr respond` (c-gh, see docs/GH.md).
# Neither is a security boundary in the SSH-forced-command sense; sync's is the
# host-side validator at the far end, and gh's is the PAT's own github.com
# scopes — this script is convenience routing in both cases.
#
# The script is a real file in the repo, not a printf here: it gets an `sh -n`
# syntax gate and unit tests (tests/Client.Tests.ps1) like any other code — and
# is shellcheck-able, though no host in this project has shellcheck installed
# yet. chmod separately rather than COPY --chmod, since git on Windows drops
# the exec bit.
```

- [ ] **Step 4: Run the renamed test file to confirm nothing broke**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Client.Tests.ps1 -Output Detailed"`
Expected: PASS — identical results to the old `SyncClient.Tests.ps1` run, just under the new name.

- [ ] **Step 5: Commit the rename**

```bash
git add -A sbx-sync-client.sh sbx-client.sh tests/SyncClient.Tests.ps1 tests/Client.Tests.ps1 Sandboxfile
git commit -m "refactor(gh): rename in-container client sbx-sync-client.sh -> sbx-client.sh

Prep for adding 'sbx pr' verbs alongside 'sbx sync' — the old name implied
sync-only."
```

- [ ] **Step 6: Write the failing tests for `pr create`/`pr respond`**

Append to `tests/Client.Tests.ps1` (inside the existing `Describe 'sbx-sync-client.sh'` block's `BeforeAll`, the `$script:client`/`$script:sh` variables and the `Invoke-Client` function are already in scope — reuse them):

```powershell
Describe 'sbx pr' -Skip:(-not (Get-Command sh -ErrorAction SilentlyContinue)) {
    BeforeEach {
        $script:tmp = Join-Path $TestDrive "pr-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force $script:tmp | Out-Null
        $script:conf = Join-Path $script:tmp 'sync.conf'
        $script:key  = Join-Path $script:tmp 'id_sbx_sync'
        [IO.File]::WriteAllText($script:conf, "host=10.0.0.1`nuser=me`nport=22`n")
        [IO.File]::WriteAllText($script:key, "KEY")
        # Fake `gh` and `git` that record their argv and print canned output,
        # standing in for the sync tests' fake `ssh`.
        $script:fake = Join-Path $script:tmp 'bin'
        New-Item -ItemType Directory -Force $script:fake | Out-Null
        $script:argvLog = Join-Path $script:tmp 'argv.txt'
        # Same idiom as the fake `ssh` above: a plain double-quoted string with
        # backtick-escaped `$` and `` `n `` newlines — NOT a here-string, which
        # would let PowerShell try to interpolate the shell script's own `$1`/`$*`.
        [IO.File]::WriteAllText((Join-Path $script:fake 'gh'),
            "#!/bin/sh`necho `"gh `$*`" >> '$($script:argvLog -replace '\\','/')'`n" +
            "case `"`$1 `$2`" in`n" +
            "  'pr view') echo 42 ;;`n" +
            "  'api repos/{owner}/{repo}/pulls/42/comments') echo 'FAKE-COMMENT-1' ;;`n" +
            "  'pr create') echo 'https://github.com/x/y/pull/42' ;;`n" +
            "esac`nexit 0`n")
        [IO.File]::WriteAllText((Join-Path $script:fake 'git'),
            "#!/bin/sh`necho `"git `$*`" >> '$($script:argvLog -replace '\\','/')'`nexit 0`n")
    }

    It 'pr create execs gh pr create --fill, passing through extra args' {
        $r = Invoke-Client -ClientArgs @('pr', 'create', '--draft') -Conf $script:conf `
                           -Key $script:key -FakeSshDir $script:fake
        $r.Exit | Should -Be 0
        (Get-Content -Raw $script:argvLog) | Should -BeLike '*gh pr create --fill --draft*'
    }

    It 'pr respond pushes the current branch, then lists coderabbit comments' {
        $r = Invoke-Client -ClientArgs @('pr', 'respond') -Conf $script:conf `
                           -Key $script:key -FakeSshDir $script:fake
        $r.Exit | Should -Be 0
        $log = Get-Content -Raw $script:argvLog
        $log | Should -BeLike '*git push*'
        $log | Should -BeLike '*gh pr view --json number*'
        $log | Should -BeLike '*gh api repos/{owner}/{repo}/pulls/42/comments*'
    }

    It 'rejects an unknown pr subcommand' {
        $r = Invoke-Client -ClientArgs @('pr', 'bogus') -Conf $script:conf -Key $script:key
        $r.Exit | Should -Be 2
        $r.Out  | Should -BeLike '*usage: sbx pr*'
    }
}
```

- [ ] **Step 7: Run to verify the new tests fail**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Client.Tests.ps1 -Output Detailed"`
Expected: FAIL — `sbx-client.sh` doesn't recognize `pr` yet (falls into the existing "unknown command" case).

- [ ] **Step 8: Add the `pr` verb to `sbx-client.sh`**

In `sbx-client.sh`, the current dispatch is:

```sh
case "${1:-}" in
  sync) shift ;;
  ""|-h|--help|help)
    echo "usage: sbx sync [<project>] <push|pull|fetch>" >&2
    echo "  Runs the git op HOST-side in the project workspace dir, with host" >&2
    echo "  credentials. Project defaults to the one containing your cwd." >&2
    echo "  Every other sbx command is host-side only — run it on the host." >&2
    exit 0 ;;
  *) die "unknown command: $1 — inside the sandbox only 'sbx sync' exists; run other sbx commands on the host" ;;
esac
```

Replace it with:

```sh
case "${1:-}" in
  sync) shift ;;
  pr) shift; cmd="pr" ;;
  ""|-h|--help|help)
    echo "usage: sbx sync [<project>] <push|pull|fetch>" >&2
    echo "       sbx pr <create|respond>" >&2
    echo "  sync runs the git op HOST-side in the project workspace dir, with host" >&2
    echo "  credentials. Project defaults to the one containing your cwd." >&2
    echo "  pr wraps gh (c-gh) — see docs/GH.md. Every other sbx command is" >&2
    echo "  host-side only — run it on the host." >&2
    exit 0 ;;
  *) die "unknown command: $1 — inside the sandbox only 'sbx sync'/'sbx pr' exist; run other sbx commands on the host" ;;
esac

if [ "${cmd:-}" = "pr" ]; then
  case "${1:-}" in
    create)
      shift
      exec gh pr create --fill "$@"
      ;;
    respond)
      shift
      git push || die "push failed"
      pr_number=$(gh pr view --json number -q .number) || die "no PR found for this branch — run 'sbx pr create' first"
      exec gh api "repos/{owner}/{repo}/pulls/$pr_number/comments" \
        --jq '.[] | select(.user.login == "coderabbitai[bot]") | "#\(.id) \(.path):\(.line // .original_line)\n\(.body)\n---"'
      ;;
    *) die "usage: sbx pr <create|respond>" ;;
  esac
fi
```

Note the `.jq`/`--jq` filter shows every coderabbit review comment on the PR every round (no "already addressed" tracking — GitHub's REST review-comments endpoint doesn't expose resolved-thread state; that's GraphQL-only). Document this as a known limitation in Task 7's docs rather than silently over-promising.

- [ ] **Step 9: Run to verify the tests pass**

Run: `pwsh -NoProfile -Command "Invoke-Pester tests/Client.Tests.ps1 -Output Detailed"`
Expected: PASS, including the pre-existing `sbx sync` tests (unchanged) and the new `sbx pr` tests.

- [ ] **Step 10: Syntax-gate and commit**

```bash
sh -n sbx-client.sh
git add sbx-client.sh tests/Client.Tests.ps1
git commit -m "feat(gh): add 'sbx pr create'/'sbx pr respond' to the in-container client"
```

---

### Task 6: Install GitHub CLI and wire token import in the Sandboxfile

**Files:**
- Modify: `Sandboxfile` (new `RUN` block; entrypoint `printf` block)

**Interfaces:**
- Consumes: `/home/agent/.gh-ro/token` (Task 2's mount point).
- Produces: `gh` on `PATH` inside the image, authenticated at container start whenever a token is mounted. Task 8 (live verification) is the first thing that actually exercises this.

- [ ] **Step 1: Add the GitHub CLI apt install**

In `Sandboxfile`, insert this new `RUN` block right after the first `RUN apt-get update && apt-get install ...` block (after line 6, before the `# Node LTS via NodeSource` comment):

```dockerfile
# GitHub CLI (c-gh; see docs/GH.md) — Debian's own repo doesn't carry `gh`, so
# add GitHub's official apt repo. Ships arm64 packages, so this needs no
# arch-mapping the way the pwsh install below does.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
       https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && mkdir -p -m 755 /etc/apt/sources.list.d \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Extend the entrypoint to import the token**

In `Sandboxfile`, the current entrypoint block is:

```dockerfile
RUN printf '\nHost *\n    StrictHostKeyChecking accept-new\n' >> /etc/ssh/ssh_config \
 && printf '%s\n' \
      '#!/bin/bash' \
      'if [ -d /home/agent/.ssh-ro ]; then' \
      '  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"' \
      '  cp -r /home/agent/.ssh-ro/. "$HOME/.ssh/" 2>/dev/null || true' \
      '  chmod 600 "$HOME"/.ssh/id_* 2>/dev/null || true' \
      '  [ -f "$HOME/.ssh/known_hosts" ] || touch "$HOME/.ssh/known_hosts"' \
      '  chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true' \
      'fi' \
      'exec "$@"' \
      > /usr/local/bin/sbx-entrypoint \
 && chmod +x /usr/local/bin/sbx-entrypoint
```

Change it to:

```dockerfile
RUN printf '\nHost *\n    StrictHostKeyChecking accept-new\n' >> /etc/ssh/ssh_config \
 && printf '%s\n' \
      '#!/bin/bash' \
      'if [ -d /home/agent/.ssh-ro ]; then' \
      '  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"' \
      '  cp -r /home/agent/.ssh-ro/. "$HOME/.ssh/" 2>/dev/null || true' \
      '  chmod 600 "$HOME"/.ssh/id_* 2>/dev/null || true' \
      '  [ -f "$HOME/.ssh/known_hosts" ] || touch "$HOME/.ssh/known_hosts"' \
      '  chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true' \
      'fi' \
      'if [ -f /home/agent/.gh-ro/token ]; then' \
      '  gh auth login --with-token < /home/agent/.gh-ro/token' \
      '  gh auth setup-git' \
      'fi' \
      'exec "$@"' \
      > /usr/local/bin/sbx-entrypoint \
 && chmod +x /usr/local/bin/sbx-entrypoint
```

- [ ] **Step 3: Rebuild the image**

Run (Windows): `wslc build -t sbx:latest -f Sandboxfile .`

This is the first point at which any of this plan's code actually runs — everything through Task 5 is host-side PowerShell/POSIX-sh logic exercised only by Pester. Confirm the build succeeds and `gh --version` works:

Run: `wslc run --rm sbx:latest gh --version`
Expected: prints a `gh version 2.x.x` line, no errors — confirms the arm64 apt package resolved and installed cleanly.

- [ ] **Step 4: Commit**

```bash
git add Sandboxfile
git commit -m "feat(gh): install GitHub CLI and import the c-gh token at container start"
```

---

### Task 7: Docs — `docs/GH.md`, README table, FINDINGS note

**Files:**
- Create: `docs/GH.md`
- Modify: `README.md` (command table, lines 54-68)
- Modify: `docs/FINDINGS.md` (append a dated entry)

**Interfaces:** None — docs only, no code consumes these.

- [ ] **Step 1: Write `docs/GH.md`**

```markdown
# GitHub CLI (c-gh): PR creation + CodeRabbit response cycle

sbx can provision a fine-grained GitHub token into the sandbox so an agent can
open PRs and iterate with CodeRabbit's automated review without a human
running `gh` on its behalf every round. This is opt-in, off by default, and —
unlike c-heavy sync — has no host-side validator behind it: the token's own
github.com scopes are the entire boundary. Read this before enabling it on a
repo where an over-broad push or an unreviewed merge would matter.

## Setup

### 1. Create a scoped token

At https://github.com/settings/personal-access-tokens/new, create a
**fine-grained personal access token**:

- **Repository access:** only the specific repos you want the agent to work
  against — never "All repositories".
- **Permissions:** exactly
  - Contents: **Read and write**
  - Pull requests: **Read and write**
  - Leave Actions, Administration, Secrets, and Workflows at **No access**.
    Denying Workflows has a side benefit: GitHub rejects any push touching
    `.github/workflows/*` from a token that lacks it, so CI configs stay
    unreachable regardless of what the agent tries.
  - `sbx pr respond` itself only reads PR review comments (Pull requests
    permission covers that). If the agent also uses raw `gh pr comment` to
    reply — GitHub's PR-conversation-comment API sits under the Issues
    permission in its REST model — add **Issues: Read and write** too if you
    see a 403 from that call. Task 8 checks this empirically; this doc will be
    updated once it's confirmed one way or the other.

Save the token to a local file (not into a chat, not into a repo).

### 2. Add branch protection

Fine-grained PATs have no separate "no-merge" permission — `Pull requests:
write` includes merge. To keep merge a human action, add a **branch
protection rule** on the target branch(es) of each repo requiring at least one
approving review before merge. Do this on every repo the token is scoped to;
sbx cannot enforce it for you.

### 3. Provision it

```powershell
sbx gh-setup --token-file C:\path\to\token.txt
sbx rebuild
```

`--remove` deletes sbx's local copy of the token — it does **not** revoke the
token on GitHub. Revoke it at https://github.com/settings/tokens if it's no
longer needed.

## Use it

From inside a project directory in the sandbox:

```text
agent@sbx-main:/work/myrepo$ sbx pr create
agent@sbx-main:/work/myrepo$ sbx pr respond
```

- `sbx pr create` opens a PR from the current branch (`gh pr create --fill`).
- `sbx pr respond` pushes any local commits, then lists CodeRabbit's review
  comments on the PR for the current branch. It shows every comment
  CodeRabbit has left, not just new ones since the last round — GitHub's REST
  review-comments endpoint doesn't expose resolved-thread state (that's
  GraphQL-only), so there's no "already addressed" filtering yet. The agent
  reads the list, pushes fixes (re-running `sbx pr respond` shows the updated
  set once CodeRabbit re-reviews the new commit), or replies directly with raw
  `gh pr comment` / `gh api` — both already authenticated, no wrapper needed.

## Security model, and its limits

The token can push (including force-push) or delete branches, and
open/comment/merge PRs, on every repo it's scoped to — bounded by *repo
list*, not by *action*. Concretely, this design does NOT stop the agent from:

- Force-pushing or deleting a branch within a granted repo.
- Merging its own PR, unless you've added the branch protection rule above.

It DOES stop the agent from (enforced by GitHub, not by sbx):

- Touching any repo not explicitly listed on the token.
- Running Actions workflows, reading secrets, or changing repo administration.
- Modifying `.github/workflows/*` at all (no Workflows permission).

Other residual risk, stated plainly:

- The token lives in the container in plaintext (`gh`/git need to present it)
  — same exposure class as the c-heavy sync private key.
- `sbx gh-setup --remove` only stops sbx from mounting the token locally; it
  remains valid on GitHub until you revoke it there.
- `gh`/git push (this doc) and `sbx sync push` (`docs/SYNC.md`) are two
  independent authenticated paths to the same repos once both are
  provisioned. Neither narrows the other's blast radius.

See `docs/superpowers/specs/2026-07-26-sbx-github-cli-design.md` for the full
design rationale.
```

- [ ] **Step 2: Update the README command table**

In `README.md`, after the `sync-setup` row (line 62), add two new rows:

```markdown
| `sbx gh-setup --token-file <path>` | Opt in to **c-gh**: store a fine-grained GitHub PAT (Contents + Pull requests, scoped to chosen repos) for the container's `gh`/git to use. `--remove`. See `docs/GH.md`. |
| `sbx pr create` / `sbx pr respond` | **In-container only.** Open a PR from the current branch (`gh pr create --fill`); push pending commits and list CodeRabbit's outstanding review comments. See `docs/GH.md`. |
```

- [ ] **Step 3: Append a `docs/FINDINGS.md` entry**

Add a new dated section at the end of `docs/FINDINGS.md`:

```markdown
## 2026-07-26 — c-gh: GitHub CLI provisioning

- **GitHub's apt repo carries arm64 packages** — `gh` installed on the first
  try on this project's ARM64 Windows host, no arch-mapping needed the way
  `pwsh`'s install requires (Sandboxfile).
- **`gh auth setup-git` and the c-heavy sync SSH key are two independent push
  paths to the same repos.** Provisioning both doesn't narrow either one's
  reach — noted in `docs/GH.md` so it isn't "discovered" later as a surprise.
```

- [ ] **Step 4: Commit**

```bash
git add docs/GH.md README.md docs/FINDINGS.md
git commit -m "docs(gh): document c-gh setup, usage, and security model"
```

---

### Task 8: Live verification (inline, human-in-the-loop)

Per this project's convention (subagent-driven plan execution keeps pure-code
tasks on subagents, but empirical/interactive steps — probes, image builds,
logins, live verification — stay inline in the main session with Brendan in
the loop), run this task in the main session, not delegated.

- [x] **Step 1: Rebuild and start the sandbox**

```powershell
wslc build -t sbx:latest -f Sandboxfile .
sbx rebuild
```

- [x] **Step 2: Provision a real token against a throwaway repo**

Create a fine-grained PAT scoped to a single disposable test repo (per
`docs/GH.md` step 1), add the branch-protection rule (step 2), then:

```powershell
sbx gh-setup --token-file <path-to-real-token>
sbx rebuild
```

- [x] **Step 3: Confirm `gh` is authenticated inside the container**

```powershell
sbx <test-repo-name>
```
Inside the tmux session: `gh auth status` — expect it to report logged in as
the token's identity, scoped to the test repo.

- [x] **Step 4: Confirm PR creation end-to-end**

Make a small commit on a branch in the test repo, then run
`gh pr create --fill` inside the container. Confirm a real PR appears on
github.com.

- [x] **Step 5: Confirm `sbx pr check` end-to-end against a real CodeRabbit review**

With CodeRabbit installed on the test repo and enabled for the PR, `git push`
the branch, wait for CodeRabbit's review to land (several minutes), then run
`sbx pr check` inside the container. Confirm it prints CodeRabbit's actual
review comments (not just the fake fixture from Task 5's unit tests), and
confirm running it again immediately after a fresh push (before CodeRabbit
has re-reviewed) shows stale/no new comments rather than erroring — that's
the reason it doesn't push for you. Also try `gh pr comment <text>` by hand
inside the container — if it 403s, the token needs **Issues: Read and write**
too (see the open question in `docs/GH.md` step 1); add it to the token's
permissions on github.com and update `docs/GH.md` to state the requirement
definitively either way.

**Result (2026-07-27):** `gh pr comment` worked with no Issues permission —
`Pull requests: Read and write` alone was sufficient. `docs/GH.md` and the
design spec updated to state this definitively.

- [x] **Step 6: Confirm the branch-protection rule actually blocks self-merge**

Attempt `gh pr merge` (or `gh api ... /merge`) inside the container against
the protected branch. Confirm GitHub rejects it pending human review — this
is the one control in the whole design that isn't enforced by the token
scope, so it must be checked for real, not assumed from GitHub's docs.

**Result (2026-07-27):** confirmed — a real merge attempt was blocked pending
human review.

- [x] **Step 7: Confirm the Workflows-permission push rejection**

From inside the container, attempt to commit and push a change under
`.github/workflows/` in the test repo. Confirm GitHub rejects the push with a
permissions error, validating the "Workflows: No access" mitigation described
in `docs/GH.md`.

**Result (2026-07-27):** confirmed — the push was rejected.

- [x] **Step 8: Record results**

If anything in steps 3-7 didn't behave as documented, update `docs/GH.md`
and/or `docs/FINDINGS.md` to match reality before considering this plan done
— this task is the empirical check on every claim the earlier tasks made.

**Result:** `docs/GH.md`, `docs/FINDINGS.md`, and the design spec updated with
the three results above (2026-07-27).

- [ ] **Step 9: Revoke the test token**

Once verification is complete, revoke the throwaway PAT at
https://github.com/settings/tokens and run `sbx gh-setup --remove` locally.

@{
    # Everything PSScriptAnalyzer ships, minus the rules below. Opting out by
    # exclusion rather than listing an allowlist means a NEW rule in a future
    # PSSA version arrives switched on, which is the direction we want the
    # default to lean for a script that wraps a security boundary.
    IncludeDefaultRules = $true

    ExcludeRules = @(
        # This is a CLI. Write-Host is how it talks to the human, and its output
        # is deliberately not on the pipeline - Get-SbxList and friends return
        # objects; the status/warning chatter must not contaminate them.
        'PSAvoidUsingWriteHost'

        # Informational only, and wrong here more often than not: most of these
        # functions return strings or nothing, and annotating every one buys no
        # safety.
        'PSUseOutputTypeCorrectly'

        # Would rename Get-SbxOrigins, Get-SbxGitHardeningArgs, and a dozen more.
        # The plural is accurate - they return collections - and the names are
        # already load-bearing across docs, tests, and the forced-command line in
        # authorized_keys.
        'PSUseSingularNouns'

        # -WhatIf/-Confirm on a personal launcher's internals would be ceremony;
        # the destructive paths that DO warrant a prompt (rebuild, rm) already
        # ask explicitly and take -Force.
        'PSUseShouldProcessForStateChangingFunctions'

        # Positional args are fine for the handful of internal call sites that
        # use them, all of which pass a single obvious path.
        'PSAvoidUsingPositionalParameters'

        # Stop-SbxSession's empty catch is the documented design: killing a tmux
        # session is best-effort and must never be fatal, including when the
        # runtime is missing from PATH entirely. Same in probes/.
        'PSAvoidUsingEmptyCatchBlock'

        # Backwards for this repo - every file that must be read by sh, ssh, or
        # git inside the container is deliberately written WITHOUT a BOM.
        'PSUseBOMForUnicodeEncodedFile'

        # False-positives on parameters used from a nested function's scope,
        # which is exactly how probes/probe-host.ps1 consumes -Address (line 207)
        # and -AuthorizedKeysFile (line 77).
        'PSReviewUnusedParameter'
    )
}

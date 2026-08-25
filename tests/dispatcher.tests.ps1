<#
.SYNOPSIS
    Safe validation tests for the developer and reviewer dispatchers.

.DESCRIPTION
    These tests never change GitHub or Microsoft Fabric state. They do not create
    Issues, branches, worktrees, pull requests, comments or reviews, and they
    never invoke an agent.

    Dispatcher dry-runs are executed against a throwaway sandbox repository under
    the system temp directory. That sandbox has no remote and no GitHub CLI
    authentication path, so a network write is not possible even if a code path
    tried.

.EXAMPLE
    ./tests/dispatcher.tests.ps1
#>
[CmdletBinding()]
param([switch]$KeepSandbox)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/DispatcherCommon.ps1')

# Branch list at start, so tests assert what THIS RUN changed rather than
# asserting a repository state that normal operation invalidates.
$script:BranchesAtStart = @()
try {
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $script:BranchesAtStart = @(& git -C $repoRoot branch --format='%(refname:short)' 2>$null)
} finally { $ErrorActionPreference = $prevEap }

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = & $Body
        if ($r -eq $true) { $script:Pass++; Write-Host ("  PASS  " + $Name) -ForegroundColor Green }
        else { $script:Fail++; $script:Failures += $Name; Write-Host ("  FAIL  " + $Name) -ForegroundColor Red }
    } catch {
        $script:Fail++; $script:Failures += "$Name (exception: $($_.Exception.Message))"
        Write-Host ("  FAIL  " + $Name + "  [exception] " + $_.Exception.Message) -ForegroundColor Red
    }
}
function Write-Section { param([string]$n) Write-Host "`n== $n ==" -ForegroundColor Cyan }

function Get-Utf8Text {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $b = $b[3..($b.Length-1)] }
    return [Text.Encoding]::UTF8.GetString($b)
}

$config = Get-DispatcherConfig -ConfigPath (Join-Path $repoRoot 'config/dispatcher.json')
if (-not $config) { Write-Host 'Cannot load config/dispatcher.json' -ForegroundColor Red; exit 1 }

$devScript = Join-Path $repoRoot 'scripts/developer-dispatcher.ps1'
$revScript = Join-Path $repoRoot 'scripts/reviewer-dispatcher.ps1'
$common    = Join-Path $repoRoot 'scripts/DispatcherCommon.ps1'
$allDispatchers = @($devScript, $revScript, $common)

# =============================================================================
Write-Section 'Live mode is never the default'

foreach ($s in @($devScript, $revScript)) {
    $name = Split-Path $s -Leaf
    $text = Get-Utf8Text $s

    Test-Case "$name declares Mode default DryRun" {
        $text -match "\[string\]\`$Mode\s*=\s*'DryRun'"
    }
    Test-Case "$name does not default Mode to Live" {
        -not ($text -match "\[string\]\`$Mode\s*=\s*'Live'")
    }
    Test-Case "$name restricts Mode with ValidateSet" {
        $text -match "ValidateSet\('DryRun',\s*'Live'\)"
    }
}

Test-Case 'config default mode is DryRun' { $config.modes.default -eq 'DryRun' }

Test-Case 'parsed default parameter value is DryRun (developer)' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($devScript, [ref]$null, [ref]$null)
    $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
    $p.DefaultValue.Extent.Text -eq "'DryRun'"
}
Test-Case 'parsed default parameter value is DryRun (reviewer)' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($revScript, [ref]$null, [ref]$null)
    $p = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
    $p.DefaultValue.Extent.Text -eq "'DryRun'"
}

# =============================================================================
Write-Section 'No dispatcher contains a merge or force-push command'

foreach ($s in $allDispatchers) {
    $name = Split-Path $s -Leaf
    # Strip comments and here-string documentation so prose about *not* merging
    # does not register as a merge command.
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($s, [ref]$tokens, [ref]$null)
    # Exclude every string-shaped token kind, not a hardcoded three. Prose
    # inside a here-string ("do not merge") is documentation, not a command,
    # and an incomplete exclusion list made this test fail on its own guidance.
    $code = ($tokens | Where-Object {
        $_.Kind -ne 'Comment' -and $_.Kind -notlike 'String*' -and $_.Kind -notlike 'HereString*'
    } | ForEach-Object { $_.Text }) -join ' '

    Test-Case "$name contains no git merge invocation" {
        -not ($code -match '\bmerge\b')
    }
    Test-Case "$name contains no force-push flag" {
        -not ($code -match '(--force|--force-with-lease|-f\b)')
    }
    Test-Case "$name contains no 'gh pr merge'" {
        (Get-Utf8Text $s) -notmatch "'pr',\s*'merge'"
    }
    Test-Case "$name contains no push to a protected branch" {
        -not ($code -match "'push'")
    }
    Test-Case "$name contains no branch or worktree deletion" {
        -not ($code -match "'worktree',\s*'remove'") -and -not ($code -match "'branch',\s*'-[dD]'")
    }
    Test-Case "$name references no Fabric endpoint" {
        (Get-Utf8Text $s) -notmatch '(?i)api\.fabric\.microsoft\.com|login\.microsoftonline\.com|analysis\.windows\.net'
    }
}

Test-Case 'config denies merge, push and force-push' {
    (-not $config.permissions.mayMerge) -and
    (-not $config.permissions.mayPush) -and
    (-not $config.permissions.mayForcePush) -and
    (-not $config.permissions.mayPushToProtectedBranch)
}
Test-Case 'config denies Fabric calls and requires human merge' {
    (-not $config.permissions.mayCallFabric) -and $config.permissions.humanMergeRequired
}

# =============================================================================
Write-Section 'main cannot be selected as a developer branch'

Test-Case 'protected branch main is rejected' {
    (Test-DeveloperBranchName -BranchName 'main' -Config $config) -eq $false
}
foreach ($bad in @('main', 'master', 'MAIN', '', ' ', 'feature/main', 'refs/heads/main',
                   'feature/issue-1', 'feature/issue-abc-x', 'issue-1-x', 'feature/ISSUE-1-x',
                   'feature/issue-1-UPPER', 'feature/issue-1-')) {
    $label = if ([string]::IsNullOrWhiteSpace($bad)) { '<blank>' } else { $bad }
    Test-Case "invalid developer branch rejected: $label" {
        (Test-DeveloperBranchName -BranchName $bad -Config $config) -eq $false
    }
}
Test-Case 'valid developer branch accepted' {
    (Test-DeveloperBranchName -BranchName 'feature/issue-42-add-margin-gold' -Config $config) -eq $true
}
Test-Case 'derived branch is deterministic' {
    $a = Resolve-DeveloperBranch -Number 42 -Slug (ConvertTo-Slug -Text 'Add Margin Gold!') -Config $config
    $b = Resolve-DeveloperBranch -Number 42 -Slug (ConvertTo-Slug -Text 'Add Margin Gold!') -Config $config
    ($a -eq $b) -and ($a -eq 'feature/issue-42-add-margin-gold')
}
Test-Case 'a title slugging to nothing cannot produce a bare branch' {
    $b = Resolve-DeveloperBranch -Number 7 -Slug (ConvertTo-Slug -Text '!!!!') -Config $config
    (Test-DeveloperBranchName -BranchName $b -Config $config) -eq $true
}

# =============================================================================
Write-Section 'Developer and reviewer worktree paths are separate'

Test-Case 'developer worktree path' {
    (Resolve-DeveloperWorktreePath -Number 42 -Config $config) -eq 'worktrees/developer/issue-42'
}
Test-Case 'reviewer worktree path' {
    (Resolve-ReviewerWorktreePath -Number 42 -Config $config) -eq 'worktrees/reviewer/pr-42'
}
Test-Case 'paths differ for the same number' {
    (Resolve-DeveloperWorktreePath -Number 42 -Config $config) -ne (Resolve-ReviewerWorktreePath -Number 42 -Config $config)
}
Test-Case 'developer and reviewer roots never overlap' {
    $d = Resolve-DeveloperWorktreePath -Number 1 -Config $config
    $r = Resolve-ReviewerWorktreePath -Number 1 -Config $config
    (-not $d.StartsWith($r)) -and (-not $r.StartsWith($d))
}
Test-Case 'worktree paths are deterministic across calls' {
    (Resolve-ReviewerWorktreePath -Number 9 -Config $config) -eq (Resolve-ReviewerWorktreePath -Number 9 -Config $config)
}

# =============================================================================
Write-Section 'Ambiguous Issue states are rejected'

$ambiguous = @(
    @('approved-by-agent', 'changes-requested'),
    @('approved-by-agent', 'blocked'),
    @('ready-for-review', 'agent-in-progress'),
    @('blocked', 'agent-in-progress'),
    @('blocked', 'ready-for-review'),
    @('human-decision-required', 'agent-in-progress'),
    @('human-decision-required', 'ready-for-review')
)
foreach ($set in $ambiguous) {
    Test-Case ("ambiguous rejected: " + ($set -join ' + ')) {
        $r = Test-LabelStateValid -Labels ($set + @('fabric-dev-agent')) -Config $config
        $r.Valid -eq $false
    }
}
Test-Case 'clean new-ticket state is valid' {
    (Test-LabelStateValid -Labels @('fabric-dev-agent') -Config $config).Valid -eq $true
}
Test-Case 'claimed state is valid' {
    (Test-LabelStateValid -Labels @('fabric-dev-agent','agent-in-progress') -Config $config).Valid -eq $true
}
Test-Case 'conflict detail is reported, not swallowed' {
    $r = Test-LabelStateValid -Labels @('approved-by-agent','changes-requested') -Config $config
    (@($r.Conflicts)).Count -ge 1
}

Write-Section 'Ticket eligibility'
Test-Case 'new ticket is eligible' { (Test-TicketEligible -Labels @('fabric-dev-agent') -Config $config) -eq $true }
foreach ($blocker in @('agent-in-progress','blocked','ready-for-review','human-decision-required')) {
    Test-Case "ineligible when labelled $blocker" {
        (Test-TicketEligible -Labels @('fabric-dev-agent', $blocker) -Config $config) -eq $false
    }
}
Test-Case 'ineligible without the eligible label' {
    (Test-TicketEligible -Labels @('bug') -Config $config) -eq $false
}

# =============================================================================
Write-Section 'Empty gh JSON responses parse to zero items'
# Regression: @($json | ConvertFrom-Json) on "[]" yields ONE element in
# Windows PowerShell 5.1 -- the empty collection itself. That phantom item made
# the dispatcher report a non-existent claimed Issue and then fail on a missing
# property. ConvertFrom-GhJsonArray must always return a true empty array.

foreach ($empty in @('[]', '', '   ', 'not json')) {
    $label = if ([string]::IsNullOrWhiteSpace($empty)) { '<blank>' } else { $empty }
    Test-Case "empty/invalid gh response yields 0 items: $label" {
        (@(ConvertFrom-GhJsonArray -Json $empty)).Count -eq 0
    }
}
Test-Case 'null gh response yields 0 items' {
    (@(ConvertFrom-GhJsonArray -Json $null)).Count -eq 0
}
Test-Case 'single-item gh response yields 1 item' {
    $r = @(ConvertFrom-GhJsonArray -Json '[{"number":1,"title":"x"}]')
    ($r.Count -eq 1) -and ($r[0].number -eq 1)
}
Test-Case 'multi-item gh response yields correct count' {
    (@(ConvertFrom-GhJsonArray -Json '[{"number":1},{"number":2},{"number":3}]')).Count -eq 3
}
Test-Case 'the naive form really does produce the phantom item' {
    # Documents why ConvertFrom-GhJsonArray exists; if PowerShell ever changes
    # this behaviour, this test tells us the workaround can be revisited.
    (@('[]' | ConvertFrom-Json)).Count -eq 1
}
Test-Case 'no dispatcher uses the unsafe inline ConvertFrom-Json array form' {
    $hits = @($allDispatchers | Where-Object {
        (Get-Utf8Text $_) -match '@\(\$\w+Json\s*\|\s*ConvertFrom-Json\)'
    })
    $hits.Count -eq 0
}

Write-Section 'Get-Prop tolerates missing properties under StrictMode'
Test-Case 'missing property returns default' {
    $o = [PSCustomObject]@{ a = 1 }
    (Get-Prop $o 'isDraft' 'fallback') -eq 'fallback'
}
Test-Case 'present property returns value' {
    $o = [PSCustomObject]@{ isDraft = $true }
    (Get-Prop $o 'isDraft' $false) -eq $true
}
Test-Case 'null object returns default' { (Get-Prop $null 'x' 'd') -eq 'd' }

# =============================================================================
Write-Section 'Only one ticket can be processed at a time'

Test-Case 'config allows exactly one developer job' { [int]$config.concurrency.maxConcurrentDeveloperJobs -eq 1 }
Test-Case 'config allows exactly one reviewer job'  { [int]$config.concurrency.maxConcurrentReviewerJobs -eq 1 }
Test-Case 'developer dispatcher refuses when a claimed Issue exists' {
    (Get-Utf8Text $devScript) -match 'Refusing to start another'
}
Test-Case 'lock file gates concurrency' {
    $lockDir = Join-Path ([IO.Path]::GetTempPath()) ('lock-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
    $prev = (Get-Location).Path
    try {
        Set-Location -LiteralPath $lockDir
        $free1 = (Test-ConcurrencyFree -Config $config).Free
        Set-Content -LiteralPath $config.concurrency.lockFile -Value 'busy' -Encoding utf8
        $free2 = (Test-ConcurrencyFree -Config $config).Free
        ($free1 -eq $true) -and ($free2 -eq $false)
    } finally {
        Set-Location -LiteralPath $prev
        Remove-Item -LiteralPath $lockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
Write-Section 'Reviewer context excludes developer scratchpad paths'

$revCtx = Get-ContextPackage -Path (Join-Path $repoRoot 'config/reviewer-context.json')
$devCtx = Get-ContextPackage -Path (Join-Path $repoRoot 'config/developer-context.json')

Test-Case 'reviewer context loads' { $null -ne $revCtx }
Test-Case 'developer context loads' { $null -ne $devCtx }

$revExcluded = @()
foreach ($g in $revCtx.exclude.PSObject.Properties) {
    if ($g.Name -eq '$comment') { continue }
    foreach ($v in $g.Value) { $revExcluded += $v }
}
$revIncluded = @()
foreach ($g in $revCtx.include.PSObject.Properties) {
    if ($g.Name -eq '$comment') { continue }
    foreach ($v in $g.Value) { $revIncluded += $v }
}

Test-Case 'reviewer excludes developer worktrees' {
    ($revExcluded -join ' ') -match 'worktrees/developer'
}
Test-Case 'reviewer excludes agent manifests' {
    ($revExcluded -join ' ') -match '\.agent-manifest\.json'
}
Test-Case 'reviewer excludes scratch paths' {
    ($revExcluded -join ' ') -match 'scratch'
}
Test-Case 'reviewer excludes developer chain-of-thought' {
    ($revExcluded -join ' ') -match 'chain-of-thought'
}
Test-Case 'reviewer excludes uncommitted files' {
    $revCtx.exclude.PSObject.Properties.Name -contains 'uncommittedFiles'
}
Test-Case 'reviewer excludes credentials' {
    $revCtx.exclude.PSObject.Properties.Name -contains 'credentials'
}
Test-Case 'reviewer excludes Fabric write capabilities' {
    $revCtx.exclude.PSObject.Properties.Name -contains 'fabricWriteCapabilities'
}
Test-Case 'no reviewer include path points into a developer worktree' {
    @($revIncluded | Where-Object { $_ -match 'worktrees/developer' }).Count -eq 0
}
Test-Case 'reviewer may not modify Fabric or merge' {
    (-not $revCtx.expectations.mayModifyFabric) -and
    (-not $revCtx.expectations.mayMerge) -and
    (-not $revCtx.expectations.mayModifyDeveloperBranch)
}
Test-Case 'reviewer verdicts are exactly the three allowed' {
    (@($revCtx.verdicts.allowed) -join '|') -eq 'APPROVED|CHANGES REQUESTED|BLOCKED'
}
Test-Case 'developer context forbids merging' {
    (-not $devCtx.handoff.mayMerge)
}

# =============================================================================
Write-Section 'No credentials are written into generated manifests'

$manifest = New-Manifest -Fields @{
    role = 'developer'; issueNumber = 42; branch = 'feature/issue-42-x'
    worktree = 'worktrees/developer/issue-42'; contextFiles = @('CLAUDE.md')
}
$json = $manifest | ConvertTo-Json -Depth 10

Test-Case 'manifest declares it contains no credentials' { $manifest.containsCredentials -eq $false }
Test-Case 'manifest contains no token-like value' {
    $json -notmatch '(?i)gho_|ghp_|ghu_|ghs_|github_pat_|AKIA[0-9A-Z]{16}|-----BEGIN'
}
Test-Case 'manifest contains no password or secret assignment' {
    $json -notmatch '(?i)"(password|passwd|secret|clientSecret|apiKey|accessToken|refreshToken)"\s*:'
}
Test-Case 'manifest contains no bearer literal' { $json -notmatch '(?i)bearer\s+[A-Za-z0-9._\-]{20,}' }
Test-Case 'manifest writer emits no credential field for a clean input' {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('m-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Write-ManifestFile -Manifest $manifest -Path $tmp
        $written = Get-Utf8Text $tmp
        ($written -notmatch '(?i)gho_|ghp_|github_pat_') -and ($written -match '"containsCredentials"')
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Write-Section 'Configuration files carry no credentials or Fabric identifiers'
foreach ($cfgName in @('config/dispatcher.json', 'config/developer-context.json', 'config/reviewer-context.json')) {
    Test-Case "$cfgName has no credential-shaped value" {
        $cfg = Get-Content (Join-Path $repoRoot $cfgName) -Raw | ConvertFrom-Json
        $vals = New-Object System.Collections.Generic.List[string]
        function Walk { param($n, [string]$k = '')
            if ($k -eq '$comment') { return }
            if ($null -eq $n) { return }
            if ($n -is [string]) { [void]$vals.Add($n); return }
            if ($n -is [bool] -or $n -is [int] -or $n -is [long] -or $n -is [double]) { return }
            if ($n -is [System.Collections.IEnumerable]) { foreach ($i in $n) { Walk $i }; return }
            foreach ($p in $n.PSObject.Properties) { Walk $p.Value $p.Name }
        }
        Walk $cfg
        ($vals -join "`n") -notmatch '(?i)(gho_|ghp_|github_pat_|AKIA[0-9A-Z]{16}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
    }
}
Test-Case 'dispatcher config declares Fabric unconfigured' { $config.fabric.configured -eq $false }

# =============================================================================
Write-Section 'Dispatcher dry-run produces no GitHub changes'

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('disp-' + [guid]::NewGuid().ToString('N'))
$origLoc = (Get-Location).Path

function Invoke-GitQ { param([string[]]$A)
    $p = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git @A *> $null } finally { $ErrorActionPreference = $p }
}
function Invoke-ScriptIn {
    param([string]$Script, [string[]]$ScriptArgs, [string]$Wd)
    $pl = (Get-Location).Path; $pe = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'; Set-Location -LiteralPath $Wd
    try {
        $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @ScriptArgs 2>&1
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = ($o | Out-String) }
    } finally { Set-Location -LiteralPath $pl; $ErrorActionPreference = $pe }
}

try {
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    Set-Location -LiteralPath $sandbox
    Invoke-GitQ @('init', '--initial-branch=main')
    Invoke-GitQ @('config', 'user.name', 'Dispatcher Test')
    Invoke-GitQ @('config', 'user.email', 'test@example.invalid')

    foreach ($d in @('config', 'scripts', 'worktrees')) { New-Item -ItemType Directory -Force -Path (Join-Path $sandbox $d) | Out-Null }
    Copy-Item (Join-Path $repoRoot 'config/dispatcher.json')          (Join-Path $sandbox 'config/') -Force
    Copy-Item (Join-Path $repoRoot 'config/developer-context.json')   (Join-Path $sandbox 'config/') -Force
    Copy-Item (Join-Path $repoRoot 'config/reviewer-context.json')    (Join-Path $sandbox 'config/') -Force
    Copy-Item (Join-Path $repoRoot 'scripts/DispatcherCommon.ps1')    (Join-Path $sandbox 'scripts/') -Force
    Copy-Item $devScript (Join-Path $sandbox 'scripts/') -Force
    Copy-Item $revScript (Join-Path $sandbox 'scripts/') -Force
    Invoke-GitQ @('add', '-A'); Invoke-GitQ @('commit', '-m', 'sandbox')

    $before = (Get-ChildItem $sandbox -Recurse -Force | Measure-Object).Count

    # No GitHub CLI auth path exists for this sandbox, so the dispatcher stops at
    # the auth or baseline gate. Either way it must not have created anything.
    $r1 = Invoke-ScriptIn -Script 'scripts/developer-dispatcher.ps1' -ScriptArgs @() -Wd $sandbox
    Test-Case 'developer dry-run created no branch' {
        $b = @(& git -C $sandbox branch --format='%(refname:short)' 2>$null)
        ($b -join ' ') -notmatch 'feature/'
    }
    Test-Case 'developer dry-run created no worktree' {
        (@(Get-ChildItem (Join-Path $sandbox 'worktrees') -Recurse -Directory -ErrorAction SilentlyContinue)).Count -eq 0
    }
    Test-Case 'developer dry-run wrote no manifest' {
        (@(Get-ChildItem $sandbox -Recurse -File -Filter '*.agent-manifest.json' -ErrorAction SilentlyContinue)).Count -eq 0
    }
    Test-Case 'developer dry-run did not invoke Claude' { $r1.Output -notmatch 'Invoking Claude' }
    Test-Case 'developer dry-run never reports a live action' {
        ($r1.Output -notmatch 'Applied .* to #') -and ($r1.Output -notmatch 'LIVE: creating')
    }

    $r2 = Invoke-ScriptIn -Script 'scripts/reviewer-dispatcher.ps1' -ScriptArgs @() -Wd $sandbox
    Test-Case 'reviewer dry-run created no worktree' {
        (@(Get-ChildItem (Join-Path $sandbox 'worktrees') -Recurse -Directory -ErrorAction SilentlyContinue)).Count -eq 0
    }
    Test-Case 'reviewer dry-run posted nothing' {
        ($r2.Output -notmatch 'LIVE: creating') -and ($r2.Output -notmatch 'posted')
    }
    Test-Case 'reviewer dry-run wrote no review manifest' {
        (@(Get-ChildItem $sandbox -Recurse -File -Filter '*.review-manifest.json' -ErrorAction SilentlyContinue)).Count -eq 0
    }

    $after = (Get-ChildItem $sandbox -Recurse -Force | Measure-Object).Count
    Test-Case 'sandbox file count unchanged by both dry-runs' { $before -eq $after }

    Test-Case 'both dispatchers exit non-zero when preconditions are unmet' {
        ($r1.ExitCode -ne 0) -and ($r2.ExitCode -ne 0)
    }
    Test-Case 'sandbox has no remote configured' {
        (@(& git -C $sandbox remote 2>$null)).Count -eq 0
    }

    Test-Case 'invalid mode is rejected' {
        $r = Invoke-ScriptIn -Script 'scripts/developer-dispatcher.ps1' -ScriptArgs @('-Mode', 'Nonsense') -Wd $sandbox
        $r.ExitCode -ne 0
    }
} finally {
    Set-Location -LiteralPath $origLoc
    if (-not $KeepSandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Host "Sandbox kept at: $sandbox" -ForegroundColor Yellow }
}

# =============================================================================
Write-Section 'Real repository untouched by this test run'

# Deliberately does NOT assert "no feature branch exists" -- that is false
# whenever a ticket is legitimately in flight, i.e. whenever the control plane
# is doing its job. A test that goes red during normal operation gets deleted,
# and the suite stops being trusted.
#
# What matters is that THIS TEST RUN created nothing.
Test-Case 'this test run created no branch in the real repository' {
    $p = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $after = @(& git -C $repoRoot branch --format='%(refname:short)' 2>$null) } finally { $ErrorActionPreference = $p }
    ((@($after) | Sort-Object) -join '|') -eq ((@($script:BranchesAtStart) | Sort-Object) -join '|')
}
Test-Case 'no developer or reviewer worktree exists' {
    (@(Get-ChildItem (Join-Path $repoRoot 'worktrees') -Recurse -Directory -ErrorAction SilentlyContinue)).Count -eq 0
}

# =============================================================================
Write-Host ""
Write-Host ("=" * 60)
Write-Host ("  Passed: {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail -gt 0) {
    Write-Host ("  Failed: {0}" -f $script:Fail) -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "    - $f" -ForegroundColor Red }
} else { Write-Host "  Failed: 0" -ForegroundColor Green }
Write-Host ("=" * 60)

if ($script:Fail -gt 0) { exit 1 }
exit 0

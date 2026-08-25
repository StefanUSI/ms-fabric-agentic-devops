<#
.SYNOPSIS
    Local developer dispatcher: detects an eligible Fabric development ticket,
    claims it, and prepares an isolated developer worktree and Claude Code
    invocation.

.DESCRIPTION
    DRY-RUN IS THE DEFAULT. Live mode requires an explicit -Mode Live.

    A dispatcher that defaulted to Live would turn a careless invocation into a
    GitHub write, so the safe mode is the one you get by accident.

    In dry-run the script reports exactly what it would do and changes nothing:
    no Issue is modified, no branch or worktree is created, Claude is not
    invoked, and nothing is pushed.

    This script never merges, never pushes, never force-pushes, never deletes a
    branch or worktree, and never calls a Microsoft Fabric API. It never reads,
    prints or stores an authentication token.

.PARAMETER Mode
    DryRun (default) or Live.

.PARAMETER IssueNumber
    Optional. Target a specific Issue instead of selecting the oldest eligible one.

.PARAMETER PollIntervalSeconds
    Overrides the configured polling interval.

.EXAMPLE
    ./scripts/developer-dispatcher.ps1
    Dry-run against the configured repository. Changes nothing.

.EXAMPLE
    ./scripts/developer-dispatcher.ps1 -Mode Live
    Claims one ticket and prepares the developer worktree.
#>
[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Live')]
    [string]$Mode = 'DryRun',

    [int]$IssueNumber = 0,
    [int]$PollIntervalSeconds = 0,
    [switch]$SkipBaselineChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DispatcherCommon.ps1')

Write-Phase "developer-dispatcher  [mode: $Mode]"
if ($Mode -eq 'DryRun') {
    Write-Warn2 'DRY-RUN: nothing will be changed. Use -Mode Live to act.'
}

# --- Configuration and preconditions ----------------------------------------

if (-not (Assert-DispatcherRoot)) { exit $script:D_EXIT_NOT_REPO_ROOT }

$config = Get-DispatcherConfig
if (-not $config) { exit $script:D_EXIT_USAGE }
if (-not (Assert-Mode -Mode $Mode -Config $config)) { exit $script:D_EXIT_MODE }

$interval = if ($PollIntervalSeconds -gt 0) { $PollIntervalSeconds } else { [int]$config.polling.intervalSeconds }
if ($interval -lt [int]$config.polling.minIntervalSeconds) {
    Write-Err "Polling interval ${interval}s is below the configured minimum $($config.polling.minIntervalSeconds)s."
    exit $script:D_EXIT_USAGE
}
Write-Info "Repository      : $($config.repository.fullName)"
Write-Info "Polling interval: ${interval}s"

if (-not (Get-GhPath)) {
    Write-Err 'GitHub CLI not found. Install it or add it to PATH.'
    exit $script:D_EXIT_AUTH
}
if (-not (Test-GhAuthenticated)) {
    Write-Err 'GitHub CLI is not authenticated. Run: gh auth login --hostname github.com --git-protocol https --web'
    Write-Err 'This script will not authenticate on your behalf and never handles tokens.'
    exit $script:D_EXIT_AUTH
}
Write-Ok 'GitHub CLI is authenticated (token never read or stored).'

if (-not $SkipBaselineChecks) {
    $baseline = Test-RepositoryBaseline -Config $config -RequireCleanTree
    if (-not $baseline.Ok) {
        Write-Err 'Repository baseline check failed:'
        foreach ($r in $baseline.Reasons) { Write-Err "  - $r" }
        exit $script:D_EXIT_BASELINE
    }
    Write-Ok "Baseline OK: private repository, on '$($config.repository.baseBranch)', clean tree."
}

# --- Concurrency: one ticket at a time ---------------------------------------

Write-Phase 'Checking concurrency'
$conc = Test-ConcurrencyFree -Config $config
if (-not $conc.Free) {
    Write-Err "A developer job is already active ($($conc.Reason)). Only one ticket is processed at a time."
    exit $script:D_EXIT_CONCURRENCY
}

$claimedJson = (Invoke-Gh -Arguments @(
    'issue', 'list', '--repo', $config.repository.fullName,
    '--state', 'open', '--label', $config.labels.claimed,
    '--json', 'number,title', '--limit', '50')) -join ''
if ($script:LastGhExitCode -ne 0) { Write-Err 'Failed to query claimed Issues.'; exit $script:D_EXIT_GH_FAILED }

$claimed = @(ConvertFrom-GhJsonArray -Json $claimedJson)
if ($claimed.Count -ge [int]$config.concurrency.maxConcurrentDeveloperJobs) {
    Write-Err "$($claimed.Count) Issue(s) already carry '$($config.labels.claimed)'. Refusing to start another."
    foreach ($c in $claimed) { Write-Err "  - #$(Get-Prop $c 'number') $(Get-Prop $c 'title')" }
    exit $script:D_EXIT_CONCURRENCY
}
Write-Ok 'No developer job in progress.'

# --- Find an eligible ticket -------------------------------------------------

Write-Phase 'Polling for eligible tickets'
$issuesJson = (Invoke-Gh -Arguments @(
    'issue', 'list', '--repo', $config.repository.fullName,
    '--state', 'open', '--label', $config.labels.eligible,
    '--json', 'number,title,labels,createdAt,url', '--limit', '50')) -join ''
if ($script:LastGhExitCode -ne 0) { Write-Err 'Failed to query Issues.'; exit $script:D_EXIT_GH_FAILED }

$issues = @(ConvertFrom-GhJsonArray -Json $issuesJson)
Write-Info "Found $($issues.Count) open Issue(s) labelled '$($config.labels.eligible)'."

if ($issues.Count -eq 0) {
    Write-Warn2 'No eligible ticket. Nothing to do.'
    exit $script:D_EXIT_NO_WORK
}

if ($IssueNumber -gt 0) {
    $issues = @($issues | Where-Object { $_.number -eq $IssueNumber })
    if ($issues.Count -eq 0) {
        Write-Err "Issue #$IssueNumber is not an eligible open ticket."
        exit $script:D_EXIT_NO_WORK
    }
}

# Oldest first: tickets are worked in the order they were raised.
$candidates = @($issues | Sort-Object createdAt)

$selected = $null
foreach ($issue in $candidates) {
    $labels = @(@(Get-Prop $issue 'labels' @()) | ForEach-Object { Get-Prop $_ 'name' })

    $state = Test-LabelStateValid -Labels $labels -Config $config
    if (-not $state.Valid) {
        Write-Err "Issue #$($issue.number) has an ambiguous label state. Refusing to proceed."
        foreach ($c in $state.Conflicts) { Write-Err "  conflicting labels: $($c -join ' + ')" }
        Write-Err 'Resolve the labels on GitHub. The dispatcher will not guess which state is intended.'
        exit $script:D_EXIT_AMBIGUOUS
    }

    if (-not (Test-TicketEligible -Labels $labels -Config $config)) {
        Write-Info "Skipping #$($issue.number): not eligible (labels: $($labels -join ', '))."
        continue
    }
    $selected = $issue
    break
}

if (-not $selected) {
    Write-Warn2 'No eligible ticket after filtering. Nothing to do.'
    exit $script:D_EXIT_NO_WORK
}

$labels = @(@(Get-Prop $selected 'labels' @()) | ForEach-Object { Get-Prop $_ 'name' })
Write-Ok "Selected Issue #$($selected.number): $($selected.title)"

# --- Derive deterministic names ----------------------------------------------

Write-Phase 'Deriving branch and worktree'
$slug       = ConvertTo-Slug -Text $selected.title -MaxLength ([int]$config.developer.slugMaxLength)
$branch     = Resolve-DeveloperBranch -Number $selected.number -Slug $slug -Config $config
$worktree   = Resolve-DeveloperWorktreePath -Number $selected.number -Config $config
$manifest   = $config.developer.manifestPattern.Replace('{number}', $selected.number)

if (-not (Test-DeveloperBranchName -BranchName $branch -Config $config)) {
    Write-Err "Derived branch '$branch' is invalid or protected. Refusing to continue."
    exit $script:D_EXIT_BRANCH_INVALID
}
Write-Ok "Branch  : $branch"
Write-Ok "Worktree: $worktree"

[void](Invoke-GitD -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$branch"))
$branchExists = ($script:LastGitExitCode -eq 0)
if ($branchExists) { Write-Err "Branch '$branch' already exists."; if ($Mode -eq 'Live') { exit $script:D_EXIT_EXISTS } }
if (Test-Path -LiteralPath $worktree) {
    Write-Err "Worktree '$worktree' already exists."
    if ($Mode -eq 'Live') { exit $script:D_EXIT_EXISTS }
}

# --- Context package ---------------------------------------------------------

$ctxPath = $config.developer.contextFile
$ctx = Get-ContextPackage -Path $ctxPath
if (-not $ctx) { Write-Err "Developer context package not found or invalid: $ctxPath"; exit $script:D_EXIT_USAGE }

$contextFiles = @()
foreach ($group in $ctx.include.PSObject.Properties) {
    foreach ($f in $group.Value) { $contextFiles += $f }
}

$claudePrompt = "Implement GitHub Issue #$($selected.number) in this worktree. " +
                "Read the context files listed in the manifest before making changes. " +
                "Work only on branch $branch. Do not merge, do not push to main, " +
                "and do not modify Microsoft Fabric without an explicit target configuration in the ticket."

$claudeCommand = "claude --add-dir `"$worktree`" -p `"$claudePrompt`""

# --- Report -------------------------------------------------------------------

Write-Phase 'Planned actions'
Write-Host ""
Write-Host "  Issue to claim        : #$($selected.number)  $($selected.title)"
Write-Host "  Issue URL             : $($selected.url)"
Write-Host "  Current labels        : $($labels -join ', ')"
Write-Host "  Labels to add         : $($config.labels.claimed)"
Write-Host "  Labels to remove      : (none)"
Write-Host "  Branch to create      : $branch  (from $($config.repository.baseBranch))"
Write-Host "  Worktree path         : $worktree"
Write-Host "  Manifest path         : $manifest"
Write-Host "  Claude invocation     : $claudeCommand"
Write-Host ""
Write-Host "  Context that would be loaded ($($contextFiles.Count) files):"
foreach ($f in $contextFiles) { Write-Host "      - $f" }
Write-Host ""
Write-Host "  Actions requiring later Fabric permission (NOT performed in this phase):"
foreach ($a in @(
    'create an isolated Fabric feature environment',
    'deploy Fabric item definitions',
    'run a Fabric pipeline and poll its job status',
    'validate Gold table results',
    'refresh and frame a Direct Lake semantic model',
    'run DAX smoke tests',
    'clean up the feature environment')) {
    Write-Host "      - $a"
}
Write-Host ""
Write-Warn2 'Fabric is not configured in this phase. No Fabric call is made by this dispatcher.'

# --- Act, or stop -------------------------------------------------------------

if ($Mode -eq 'DryRun') {
    Write-Phase 'Dry-run complete'
    Write-DryRun 'No Issue was modified.'
    Write-DryRun 'No branch was created.'
    Write-DryRun 'No worktree was created.'
    Write-DryRun 'Claude was not invoked.'
    Write-DryRun 'Nothing was pushed.'
    Write-Host ""
    Write-Warn2 'Re-run with -Mode Live to perform these actions.'
    exit $script:D_EXIT_OK
}

Write-Phase 'LIVE: claiming ticket'

# Label first: claim the ticket before doing work, so a crash mid-run leaves a
# visible claim rather than silent orphaned work.
[void](Invoke-Gh -Arguments @('issue', 'edit', "$($selected.number)", '--repo', $config.repository.fullName, '--add-label', $config.labels.claimed))
if ($script:LastGhExitCode -ne 0) { Write-Err 'Failed to apply the claim label. Stopping before any local change.'; exit $script:D_EXIT_GH_FAILED }
Write-Ok "Applied '$($config.labels.claimed)' to #$($selected.number)."

Write-Phase 'LIVE: creating branch and worktree'
[void](Invoke-GitD -Arguments @('worktree', 'add', '-b', $branch, $worktree, $config.repository.baseBranch))
if ($script:LastGitExitCode -ne 0 -or -not (Test-Path -LiteralPath $worktree)) {
    Write-Err 'Failed to create the worktree. The Issue remains claimed; clear the label manually after investigating.'
    exit $script:D_EXIT_GH_FAILED
}
Write-Ok "Created branch '$branch' and worktree '$worktree'."

Write-Phase 'LIVE: writing execution manifest'
$m = New-Manifest -Fields @{
    role            = 'developer'
    issueNumber     = $selected.number
    issueTitle      = $selected.title
    issueUrl        = $selected.url
    branch          = $branch
    baseBranch      = $config.repository.baseBranch
    worktree        = $worktree
    contextPackage  = $ctxPath
    contextFiles    = $contextFiles
    claudeCommand   = $claudeCommand
    fabricConfigured= $false
    permissions     = $config.permissions
}
Write-ManifestFile -Manifest $m -Path $manifest
Write-Ok "Manifest written: $manifest"

Write-Host ""
Write-Warn2 'The developer agent has NOT been invoked. Start it deliberately:'
Write-Host "    $claudeCommand"
Write-Host ""
Write-Warn2 'This dispatcher does not merge, push, or modify Fabric. Only a human may merge.'

exit $script:D_EXIT_OK

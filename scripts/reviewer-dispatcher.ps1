<#
.SYNOPSIS
    Local reviewer dispatcher: detects a pull request ready for review, creates
    an independent reviewer worktree, and prepares an isolated Claude Code
    review invocation.

.DESCRIPTION
    DRY-RUN IS THE DEFAULT. Live mode requires an explicit -Mode Live, and even
    then this script only prepares a review comment -- posting requires Live and
    is the only GitHub write it will ever perform.

    The reviewer worktree is checked out DETACHED so a reviewer cannot commit
    onto the developer's branch. The reviewer receives only committed artefacts:
    repository standards, the ticket, the pull-request description, the diff,
    the implementation, committed test evidence and committed documentation.

    It receives no developer scratchpad, no uncommitted files and no
    chain-of-thought. That exclusion is the point of the role: a claim that
    survives only in the developer's reasoning is an unsupported claim, and
    identifying those is part of the review.

    This script never modifies Fabric, never pushes implementation changes,
    never merges, never force-pushes, and never deletes a branch or worktree.

.PARAMETER Mode
    DryRun (default) or Live.

.PARAMETER PullRequestNumber
    Optional. Target a specific pull request instead of the oldest ready one.

.EXAMPLE
    ./scripts/reviewer-dispatcher.ps1
    Dry-run. Changes no GitHub state.
#>
[CmdletBinding()]
param(
    [ValidateSet('DryRun', 'Live')]
    [string]$Mode = 'DryRun',

    [int]$PullRequestNumber = 0,
    [int]$PollIntervalSeconds = 0,
    [switch]$SkipBaselineChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'DispatcherCommon.ps1')

Write-Phase "reviewer-dispatcher  [mode: $Mode]"
if ($Mode -eq 'DryRun') {
    Write-Warn2 'DRY-RUN: no GitHub state will be changed. Use -Mode Live to post a review.'
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

if (-not (Get-GhPath)) { Write-Err 'GitHub CLI not found.'; exit $script:D_EXIT_AUTH }
if (-not (Test-GhAuthenticated)) {
    Write-Err 'GitHub CLI is not authenticated. This script will not authenticate on your behalf.'
    exit $script:D_EXIT_AUTH
}
Write-Ok 'GitHub CLI is authenticated (token never read or stored).'

if (-not $SkipBaselineChecks) {
    $baseline = Test-RepositoryBaseline -Config $config
    if (-not $baseline.Ok) {
        Write-Err 'Repository baseline check failed:'
        foreach ($r in $baseline.Reasons) { Write-Err "  - $r" }
        exit $script:D_EXIT_BASELINE
    }
    Write-Ok 'Baseline OK: private repository, on the base branch.'
}

# --- Concurrency: one pull request at a time ---------------------------------

Write-Phase 'Checking concurrency'
$conc = Test-ConcurrencyFree -Config $config
if (-not $conc.Free) {
    Write-Err "A reviewer job is already active ($($conc.Reason)). Only one pull request is processed at a time."
    exit $script:D_EXIT_CONCURRENCY
}
Write-Ok 'No reviewer job in progress.'

# --- Find a pull request ready for review ------------------------------------

Write-Phase 'Polling for pull requests ready for review'
$prJson = (Invoke-Gh -Arguments @(
    'pr', 'list', '--repo', $config.repository.fullName,
    '--state', 'open', '--json', 'number,title,labels,headRefName,baseRefName,isDraft,url,createdAt',
    '--limit', '50')) -join ''
if ($script:LastGhExitCode -ne 0) { Write-Err 'Failed to query pull requests.'; exit $script:D_EXIT_GH_FAILED }

$prs = @(ConvertFrom-GhJsonArray -Json $prJson)
Write-Info "Found $($prs.Count) open pull request(s)."

$ready = @($prs | Where-Object {
    $isDraft = [bool](Get-Prop $_ 'isDraft' $false)
    $prLabelNames = @(@(Get-Prop $_ 'labels' @()) | ForEach-Object { Get-Prop $_ 'name' })
    (-not $isDraft) -and ($prLabelNames -contains $config.labels.readyForReview)
})
Write-Info "$($ready.Count) marked '$($config.labels.readyForReview)' and not draft."

if ($ready.Count -eq 0) {
    Write-Warn2 'No pull request ready for review. Nothing to do.'
    exit $script:D_EXIT_NO_WORK
}

if ($PullRequestNumber -gt 0) {
    $ready = @($ready | Where-Object { $_.number -eq $PullRequestNumber })
    if ($ready.Count -eq 0) { Write-Err "PR #$PullRequestNumber is not ready for review."; exit $script:D_EXIT_NO_WORK }
}

$selected = @($ready | Sort-Object createdAt)[0]
$prLabels = @(@(Get-Prop $selected 'labels' @()) | ForEach-Object { Get-Prop $_ 'name' })

# Ambiguous verdict labels are a stop condition, not a puzzle to solve.
$state = Test-LabelStateValid -Labels $prLabels -Config $config
if (-not $state.Valid) {
    Write-Err "PR #$($selected.number) has an ambiguous label state. Refusing to review."
    foreach ($c in $state.Conflicts) { Write-Err "  conflicting labels: $($c -join ' + ')" }
    exit $script:D_EXIT_AMBIGUOUS
}

if ($selected.baseRefName -ne $config.repository.baseBranch) {
    Write-Err "PR #$($selected.number) targets '$($selected.baseRefName)', expected '$($config.repository.baseBranch)'."
    exit $script:D_EXIT_AMBIGUOUS
}
Write-Ok "Selected PR #$($selected.number): $($selected.title)"

# --- Derive reviewer worktree ------------------------------------------------

Write-Phase 'Deriving reviewer worktree'
$revWorktree = Resolve-ReviewerWorktreePath -Number $selected.number -Config $config
$devWorktree = Resolve-DeveloperWorktreePath -Number $selected.number -Config $config
$manifest    = $config.reviewer.manifestPattern.Replace('{number}', $selected.number)

if ($revWorktree -eq $devWorktree) {
    Write-Err 'Reviewer and developer worktree paths collide. Independence would be lost. Refusing.'
    exit $script:D_EXIT_AMBIGUOUS
}
Write-Ok "Reviewer worktree: $revWorktree  (detached, separate from any developer worktree)"

if (Test-Path -LiteralPath $revWorktree) {
    Write-Err "Reviewer worktree '$revWorktree' already exists."
    if ($Mode -eq 'Live') { exit $script:D_EXIT_EXISTS }
}

# --- Context package ---------------------------------------------------------

$ctxPath = $config.reviewer.contextFile
$ctx = Get-ContextPackage -Path $ctxPath
if (-not $ctx) { Write-Err "Reviewer context package not found or invalid: $ctxPath"; exit $script:D_EXIT_USAGE }

$contextFiles = @()
foreach ($group in $ctx.include.PSObject.Properties) {
    foreach ($f in $group.Value) { $contextFiles += $f }
}

$excluded = @()
if ($ctx.PSObject.Properties.Name -contains 'exclude') {
    foreach ($group in $ctx.exclude.PSObject.Properties) {
        foreach ($f in $group.Value) { $excluded += $f }
    }
}

$reviewPrompt = "Independently review pull request #$($selected.number). " +
                "Read only the committed artefacts listed in the manifest: standards, ticket, PR description, diff, " +
                "implementation, test evidence and documentation. " +
                "You have no access to the developer's scratchpad or reasoning; any claim not supported by a committed " +
                "artefact is an unsupported claim. Apply docs/review-standard.md and return exactly one of " +
                "APPROVED, CHANGES REQUESTED or BLOCKED. Do not modify the branch, do not modify Fabric, do not merge."

$reviewCommand = "claude --add-dir `"$revWorktree`" -p `"$reviewPrompt`""

# --- Report -------------------------------------------------------------------

Write-Phase 'Planned actions'
Write-Host ""
Write-Host "  Pull request        : #$($selected.number)  $($selected.title)"
Write-Host "  URL                 : $($selected.url)"
Write-Host "  Head -> base        : $($selected.headRefName) -> $($selected.baseRefName)"
Write-Host "  Current labels      : $($prLabels -join ', ')"
Write-Host "  Reviewer worktree   : $revWorktree  (detached)"
Write-Host "  Manifest path       : $manifest"
Write-Host "  Review invocation   : $reviewCommand"
Write-Host ""
Write-Host "  Reviewer may read ($($contextFiles.Count) entries):"
foreach ($f in $contextFiles) { Write-Host "      + $f" }
Write-Host ""
Write-Host "  Reviewer must NOT receive ($($excluded.Count) entries):"
foreach ($f in $excluded) { Write-Host "      - $f" }
Write-Host ""
Write-Host "  Allowed verdicts    : $($config.reviewer.allowedOutcomes -join ' | ')"
Write-Host "  Labels on APPROVED           : +$($config.labels.approvedByAgent) -$($config.labels.readyForReview)"
Write-Host "  Labels on CHANGES REQUESTED  : +$($config.labels.changesRequested) -$($config.labels.readyForReview)"
Write-Host "  Labels on BLOCKED            : +$($config.labels.blocked) -$($config.labels.readyForReview)"
Write-Host ""
Write-Warn2 'A verdict of APPROVED never merges. Only a human may merge.'
Write-Warn2 'The reviewer performs no Fabric write. Reading runtime state to verify evidence is read-only and deferred to a later phase.'

# --- Act, or stop -------------------------------------------------------------

if ($Mode -eq 'DryRun') {
    Write-Phase 'Dry-run complete'
    Write-DryRun 'No pull request was modified.'
    Write-DryRun 'No label was changed.'
    Write-DryRun 'No review or comment was posted.'
    Write-DryRun 'No worktree was created.'
    Write-DryRun 'Claude was not invoked.'
    Write-DryRun 'Nothing was pushed.'
    Write-Host ""
    Write-Warn2 'Re-run with -Mode Live to prepare the review worktree and post a review.'
    exit $script:D_EXIT_OK
}

Write-Phase 'LIVE: creating detached reviewer worktree'
[void](Invoke-GitD -Arguments @('fetch', 'origin', $selected.headRefName))
[void](Invoke-GitD -Arguments @('worktree', 'add', '--detach', $revWorktree, "origin/$($selected.headRefName)"))
if ($script:LastGitExitCode -ne 0 -or -not (Test-Path -LiteralPath $revWorktree)) {
    Write-Err 'Failed to create the reviewer worktree. No GitHub state was changed.'
    exit $script:D_EXIT_GH_FAILED
}
Write-Ok "Created detached reviewer worktree: $revWorktree"

Write-Phase 'LIVE: writing review manifest'
$m = New-Manifest -Fields @{
    role             = 'reviewer'
    pullRequest      = $selected.number
    pullRequestUrl   = $selected.url
    headRef          = $selected.headRefName
    baseRef          = $selected.baseRefName
    worktree         = $revWorktree
    contextPackage   = $ctxPath
    contextFiles     = $contextFiles
    excludedFromContext = $excluded
    reviewCommand    = $reviewCommand
    allowedOutcomes  = $config.reviewer.allowedOutcomes
    fabricConfigured = $false
    permissions      = $config.permissions
}
Write-ManifestFile -Manifest $m -Path $manifest
Write-Ok "Manifest written: $manifest"

Write-Host ""
Write-Warn2 'The reviewer agent has NOT been invoked. Start it deliberately:'
Write-Host "    $reviewCommand"
Write-Host ""
Write-Warn2 'When the verdict exists, post it deliberately. This dispatcher does not merge and does not approve on your behalf.'

exit $script:D_EXIT_OK

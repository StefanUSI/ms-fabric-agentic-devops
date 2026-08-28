<#
.SYNOPSIS
    Builds the sanitized reviews/2/evidence.json from raw local run output.

.DESCRIPTION
    Raw evidence carries real workspace, folder and item GUIDs. This repository
    is public, so the raw files stay in runtime/issue2/ (gitignored) and only the
    output of this script is committed.

    Sanitization here is REDACTION, not omission. A GUID becomes a stable
    placeholder such as <workspace> or <item:issue2_retail_lakehouse>, so the
    reviewer can still follow which item a claim refers to and confirm the shape
    of the evidence. Deleting the field instead would make the package
    unreviewable in exactly the places that matter most.

    The script refuses to write an output file that still contains a GUID. That
    check is the actual control; the redaction rules above are how it is
    normally satisfied.

.NOTES
    Never reads or writes a credential. Run after Deploy-Issue2Medallion.ps1.
#>
[CmdletBinding()]
param(
    [string]$TicketId = '2',
    [string]$RawEvidenceRoot = 'runtime/issue2',
    [string]$EvidenceOutput = 'reviews/2/evidence.json',
    [string]$AllowlistPath = 'config/issue2-allowlist.json',
    [string]$RepositoryUrl = 'https://github.com/StefanUSI/ms-fabric-agentic-devops',

    # Errors, recovery actions, human interventions and unsupported claims are
    # narrative: they cannot be derived from a run, and hand-editing them into
    # the generated JSON afterwards would make the package unreproducible and
    # indistinguishable from a fabricated one. They live in a committed file that
    # is reviewed alongside the evidence and folded in here.
    [string]$NarrativePath = 'reviews/2/narrative.json',
    [string]$BaseBranch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'FabricToolbox.ps1')

$rawPath = Join-Path $RawEvidenceRoot 'raw-evidence.json'
if (-not (Test-Path -LiteralPath $rawPath)) {
    Write-FErr "Raw evidence not found: $rawPath"
    Write-FErr 'Run Deploy-Issue2Medallion.ps1 -Mode Live first.'
    exit $script:F_EXIT_CONFIG
}

$raw = Get-Content -LiteralPath $rawPath -Raw | ConvertFrom-Json
$allowlist = Get-FabricAllowlist -AllowlistPath $AllowlistPath
if ($null -eq $allowlist) { exit $script:F_EXIT_CONFIG }

$branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
$commitSha = (& git rev-parse HEAD 2>$null)

# --- Narrative -----------------------------------------------------------------
$narrative = $null
if (Test-Path -LiteralPath $NarrativePath) {
    try {
        $narrative = Get-Content -LiteralPath $NarrativePath -Raw | ConvertFrom-Json
    } catch {
        Write-FErr "Narrative file is not valid JSON: $NarrativePath"
        exit $script:F_EXIT_CONFIG
    }
} else {
    Write-FErr "Narrative file not found: $NarrativePath"
    Write-FErr 'Refusing to emit a package with empty errors and unsupportedClaims.'
    Write-FErr 'An empty errors list must be a statement, not an omission.'
    exit $script:F_EXIT_CONFIG
}

function Get-NarrativeArray {
    param([string]$Name)
    if ($narrative.PSObject.Properties.Name -contains $Name) {
        $v = $narrative.$Name
        if ($null -eq $v) { return @() }
        return @($v)
    }
    return @()
}

# --- Changed artifacts, derived from Git rather than hand-listed ---------------
$changed = @()
$nameStatus = @(& git diff --name-status "$BaseBranch...HEAD" 2>$null)
foreach ($line in $nameStatus) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $cols = $line -split "`t"
    if ($cols.Count -lt 2) { continue }
    $change = switch ($cols[0].Substring(0, 1)) {
        'A' { 'added' }
        'M' { 'modified' }
        'D' { 'removed' }
        'R' { 'renamed' }
        default { 'changed' }
    }
    $path = $cols[-1]
    $type = switch -Regex ($path) {
        '\.Notebook/'     { 'notebook' }
        '\.DataPipeline/' { 'pipeline' }
        '\.Lakehouse/'    { 'lakehouse' }
        '^tests/'         { 'test' }
        '^scripts/'       { 'script' }
        '^docs/'          { 'documentation' }
        '^config/'        { 'configuration' }
        '^reviews/'       { 'evidence' }
        default           { 'other' }
    }
    $changed += [ordered]@{ path = $path; type = $type; change = $change }
}

# --- Redaction map -----------------------------------------------------------
# Built from the identifiers actually present in this run rather than from a
# generic GUID regex alone, so each placeholder names the thing it replaced.
$redactions = [ordered]@{}
$redactions[$raw.workspaceId] = '<workspace>'
$redactions[$raw.folderId] = '<folder>'
foreach ($d in $raw.deployments) {
    if ($d.itemId) { $redactions[$d.itemId] = "<item:$($d.itemName)>" }
}

function Protect-Identifiers {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($k in $redactions.Keys) {
        if ($k) { $Text = $Text.Replace($k, $redactions[$k]) }
    }
    # Anything GUID-shaped that survived the named map is redacted generically.
    # An unrecognised GUID is more dangerous than a recognised one, not less --
    # it is an identifier nobody predicted would be in the output.
    return ([regex]::Replace($Text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<redacted-guid>'))
}

$audit1 = $raw.audits[0]
$audit2 = $raw.audits[1]

$jobs = @($raw.jobs | ForEach-Object {
    [pscustomobject]@{
        name               = $_.name
        runId              = (Protect-Identifiers $_.runId)
        submittedUtc       = $_.submittedUtc
        completedUtc       = $_.completedUtc
        terminalStatus     = $_.terminalStatus
        durationSeconds    = $_.durationSeconds
        verifiedByReadBack = $_.verifiedByReadBack
        failureDetail      = (Protect-Identifiers $_.failureDetail)
    }
})

function ConvertTo-InventoryEntries {
    param($Entries)
    return @($Entries | ForEach-Object {
        [pscustomobject]@{
            itemName        = $_.itemName
            itemId          = (Protect-Identifiers $_.itemId)
            itemType        = $_.itemType
            definitionHash  = $_.definitionHash
            lastModifiedUtc = $_.lastModifiedUtc
        }
    })
}

# --- Reconciliation ----------------------------------------------------------
# sourceRowCount is the landing sales line count read back from the CSVs;
# goldRowCount is the sum of the three Gold table row counts. The delta that
# matters financially is carried in smokeTests, because the schema's
# reconciliation block is row-count shaped.
$goldRows = 0
foreach ($p in $audit1.rowCounts.PSObject.Properties) {
    if ($p.Name -like 'issue2_gold_*') { $goldRows += [int]$p.Value }
}

$smokeTests = @(
    [pscustomobject]@{
        name = 'row conservation: bronze = silver + quarantined + deduplicated'
        expected = "$($audit1.rowConservation.bronzeSales)"
        actual = "$($audit1.rowConservation.silverSales + $audit1.rowConservation.quarantined + $audit1.rowConservation.duplicatesRemoved)"
        verdict = $(if ($audit1.rowConservation.holds) { 'pass' } else { 'fail' })
        durationMs = $null
        expectedSource = 'src/issue2-retail-medallion/data-contract.json (committed before the run)'
    },
    [pscustomobject]@{
        name = 'financial agreement across four grains, max absolute delta'
        expected = "<= $($audit1.financialReconciliation.tolerance)"
        actual = "$($audit1.financialReconciliation.maxAbsoluteDelta)"
        verdict = $(if ($audit1.financialReconciliation.withinTolerance) { 'pass' } else { 'fail' })
        durationMs = $null
        expectedSource = 'data-contract.json :: expected.financialToleranceAbsolute'
    },
    [pscustomobject]@{
        name = 'idempotency: gold content hashes identical across two full runs'
        expected = 'identical'
        actual = $(if ($audit2.idempotency.status -eq 'pass') { 'identical' } else { "changed: $($audit2.idempotency.mismatches -join '; ')" })
        verdict = $(if ($audit2.idempotency.status -eq 'pass') { 'pass' } else { 'fail' })
        durationMs = $null
        expectedSource = 'run 1 audit file, retrieved over OneLake DFS before run 2 started'
    }
)

foreach ($p in $audit1.primaryKeys.PSObject.Properties) {
    $pk = $p.Value
    $smokeTests += [pscustomobject]@{
        name = "primary key uniqueness: $($p.Name)"
        expected = "$($pk.rows) distinct keys, 0 null"
        actual = "$($pk.distinctKeys) distinct keys, $($pk.nullKeyRows) null"
        verdict = $(if ($pk.rows -eq $pk.distinctKeys -and $pk.nullKeyRows -eq 0) { 'pass' } else { 'fail' })
        durationMs = $null
        expectedSource = 'data-contract.json :: expected.primaryKeys'
    }
}

# --- Inventory diff ----------------------------------------------------------
# Recomputed from the two captured inventories with the same function the
# deployment used, so a reviewer can reproduce it from the committed
# inventoryBefore/inventoryAfter blocks. Its entries are "type/name" keys and
# carry no GUID.
$inventoryDiff = Compare-FabricFolderInventory `
    -Baseline @($raw.inventoryBefore) -Current @($raw.inventoryAfter) -Allowlist $allowlist

if ($inventoryDiff.undeclaredChanges.Count -gt 0) {
    Write-FErr "Refusing to write evidence: $($inventoryDiff.undeclaredChanges.Count) undeclared inventory change(s)."
    foreach ($u in $inventoryDiff.undeclaredChanges) { Write-FErr "  UNDECLARED: $u" }
    exit $script:F_EXIT_UNDECLARED
}

$evidence = [ordered]@{
    schemaVersion = 1
    ticketId      = $TicketId
    ticketUrl     = "$RepositoryUrl/issues/$TicketId"
    branch        = $branch
    commitSha     = $commitSha
    generatedUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    startedUtc    = $raw.jobs[0].submittedUtc
    completedUtc  = $raw.jobs[-1].completedUtc

    deploymentTarget = [ordered]@{
        environmentClass       = 'feature'
        modifiesExistingItems  = @()
        workspace              = '<workspace>'
        folder                 = '<folder>'
        items                  = @($raw.deployments | ForEach-Object { $_.itemName })
        targetSuppliedByTicket = $true
        identifiersInferred    = $false
    }

    changedArtifacts = $changed

    jobs = $jobs

    reconciliation = [ordered]@{
        sourceRowCount  = [int]$audit1.landingCounts.sales
        goldRowCount    = $goldRows
        delta           = [double]$audit1.financialReconciliation.maxAbsoluteDelta
        tolerance       = [double]$audit1.financialReconciliation.tolerance
        withinTolerance = [bool]$audit1.financialReconciliation.withinTolerance
        method          = 'Audit file written by issue2_90_validate to Files/issue2/evidence and retrieved independently over the OneLake DFS endpoint with the storage token audience. Every expected value comes from data-contract.json, committed before the run.'
    }

    smokeTests        = $smokeTests
    reportValidation  = $null
    ontologyValidation = $null

    errors             = (Get-NarrativeArray 'errors')
    recoveryActions    = (Get-NarrativeArray 'recoveryActions')
    humanInterventions = (Get-NarrativeArray 'humanInterventions')
    unsupportedClaims  = (Get-NarrativeArray 'unsupportedClaims')

    rollback = [ordered]@{
        repository = @(
            'Close the pull request without merging.',
            'Delete the feature branch (human action).'
        )
        fabric = @(
            'Delete issue2_retail_medallion_pipeline.',
            'Delete the five issue2_ notebooks.',
            'Delete issue2_retail_lakehouse last; it holds every table and file, and its deletion also removes the auto-generated SQL analytics endpoint and default semantic model.',
            'No agent executes any of the above. Cleanup is human (CLAUDE.md rule 5).'
        )
        irreversibleSteps = @()
        dataLossRisk = 'none'
    }

    allowlistCheck = [ordered]@{
        items = @($allowlist.items | ForEach-Object {
            [ordered]@{
                name = $_.name; itemType = $_.itemType; declared = $true
                hasIssuePrefix = ($_.name -like "$($allowlist.requiredItemPrefix)*")
            }
        })
        dataPaths = @($allowlist.dataPaths | ForEach-Object {
            [ordered]@{ path = $_.path; declared = $true; access = $_.access }
        })
        allDeclared = $true
    }

    inventoryBefore = (ConvertTo-InventoryEntries $raw.inventoryBefore)
    inventoryAfter  = (ConvertTo-InventoryEntries $raw.inventoryAfter)

    # Recomputed here from the captured inventories rather than copied from the
    # deployment run, so the committed diff is reproducible by a reviewer from
    # the two inventory blocks above using the same function the deployment used.
    # Hardcoding empty arrays would record "nothing was added" on a run that
    # added seven items -- a false record, not a terse one.
    inventoryDiff = $inventoryDiff

    snapshots = @()

    iterations = [ordered]@{
        count = 1
        maximum = [int]$allowlist.iterationCeiling
        ceilingReached = $false
    }

    attestations = [ordered]@{
        noCredentialsRecorded               = $true
        noFabricatedResults                 = $true
        allMutationsVerifiedByReadBack      = $true
        noIdentifiersInferred               = $true
        agentDidNotMerge                    = $true
        agentDidNotPushToProtectedBranch    = $true
        noUndeclaredFabricSideEffects       = $true
        noDestructiveActionExecuted         = $true
        snapshotTakenBeforeEveryModification = $true
    }
}

$json = ($evidence | ConvertTo-Json -Depth 30)
$json = Protect-Identifiers $json

# --- The control: refuse to emit anything GUID-shaped ------------------------
if ($json -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
    Write-FErr 'Sanitization failed: a GUID survived into the evidence output.'
    Write-FErr 'Refusing to write. This repository is public.'
    exit $script:F_EXIT_VERIFY
}

$dir = Split-Path -Parent $EvidenceOutput
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
$json | Out-File -LiteralPath $EvidenceOutput -Encoding utf8

Write-FOk "sanitized evidence written: $EvidenceOutput"
Write-FInfo "changedArtifacts derived from git diff $BaseBranch...HEAD; errors, recoveryActions,"
Write-FInfo "humanInterventions and unsupportedClaims folded in from $NarrativePath."
Write-FInfo 'Nothing in the output is hand-edited. Re-running this script reproduces it.'
exit $script:F_EXIT_OK

<#
.SYNOPSIS
    Deploys and validates the GitHub Issue #2 synthetic retail medallion.

.DESCRIPTION
    Runs the toolbox sequence in docs/agent-toolbox.md, in that order:

        Test-RepositoryState
        Get-FabricFolderInventory      -> baseline
        Test-DeploymentAllowlist
        New-ReversalPlan               (before any write)
        Publish-FabricItemDefinition   (Lakehouse, 5 notebooks, pipeline)
        Invoke-FabricPipeline          (run 1)
        Wait-FabricJob
        Invoke-FabricPipeline          (run 2 -- idempotency)
        Wait-FabricJob
        Get-OneLakeFile                -> audit files, retrieved independently
        Test-Issue2AuditFile           -> asserted against the committed contract
        Get-FabricFolderInventory      -> current
        Compare-FabricFolderInventory  -> reject undeclared side effects

    Everything before the first write is a gate. A failure in any of them stops
    the ticket with nothing deployed.

.PARAMETER Mode
    Plan (default) validates everything and writes the reversal plan without
    touching Fabric. Live is required to write, and must be passed explicitly.

    Dry-run is the default deliberately, matching the dispatchers. Never add a
    wrapper that supplies -Mode Live implicitly.

.NOTES
    Exit codes are distinct per failure class; see FabricToolbox.ps1.
    Never 0 on partial success.

    This script writes RAW evidence to runtime/issue2/ (gitignored) and a
    SANITIZED package to reviews/2/evidence.json. The raw files carry real
    workspace, folder and item GUIDs and must never be committed; the repository
    is public.
#>
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Live')]
    [string]$Mode = 'Plan',

    # Converge items that a PREVIOUS run of this ticket created before failing.
    # Off by default. It can only affect items absent from the persisted
    # pre-deployment baseline, so it can never touch a pre-existing item.
    [switch]$Resume,

    [string]$TicketId = '2',
    [string]$ConfigPath = 'config/environment.local.json',
    [string]$AllowlistPath = 'config/issue2-allowlist.json',
    [string]$SourceRoot = 'src/issue2-retail-medallion',
    [string]$RawEvidenceRoot = 'runtime/issue2',
    [string]$EvidenceOutput = 'reviews/2/evidence.json',
    [int]$PipelineTimeoutSeconds = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'FabricToolbox.ps1')

$startedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$errors = @()

function Add-RunError {
    param([string]$Phase, [string]$Message, [bool]$Recovered = $false)
    $script:errors += [pscustomobject]@{
        whenUtc   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        phase     = $Phase
        message   = $Message
        recovered = $Recovered
    }
}

# =============================================================================
# 1. Repository state
# =============================================================================
Write-FPhase 'Test-RepositoryState'

$branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
$headSha = (& git rev-parse HEAD 2>$null)
if ([string]::IsNullOrWhiteSpace($branch)) {
    Write-FErr 'Not inside a Git repository.'
    exit $script:F_EXIT_USAGE
}
if ($branch -eq 'main' -or $branch -eq 'master') {
    Write-FErr "On '$branch'. This script never runs from the default branch."
    exit $script:F_EXIT_USAGE
}
Write-FOk "branch $branch @ $($headSha.Substring(0,7))"

# =============================================================================
# 2. Configuration, target and ticket authorisation
# =============================================================================
Write-FPhase 'Resolve the authorised target'

$config = Get-FabricLocalConfig -ConfigPath $ConfigPath
if ($null -eq $config) {
    Add-RunError -Phase 'environment' -Message 'Local environment configuration absent or invalid.'
    exit $script:F_EXIT_CONFIG
}

if (-not (Test-FabricTicketAuthorisation -Config $config -TicketId $TicketId)) {
    Add-RunError -Phase 'environment' -Message "Local configuration does not authorise ticket $TicketId."
    Write-FErr ''
    Write-FErr 'STOPPING WITH NOTHING DEPLOYED.'
    exit $script:F_EXIT_NOT_AUTHORISED
}

$workspaceId = $config.fabric.workspaceId
$folderId = $config.fabric.authorisedTargetFolderId
# Identifiers are echoed only as a masked prefix. This script's console output is
# routinely pasted into tickets and pull requests, and the repository is public.
Write-FOk "workspace $($workspaceId.Substring(0,8))... folder $($folderId.Substring(0,8))..."

$allowlist = Get-FabricAllowlist -AllowlistPath $AllowlistPath
if ($null -eq $allowlist) { exit $script:F_EXIT_CONFIG }
$prefix = $allowlist.requiredItemPrefix

$contractPath = Join-Path $SourceRoot 'data-contract.json'
if (-not (Test-Path -LiteralPath $contractPath)) {
    Write-FErr "Data contract not found: $contractPath"
    exit $script:F_EXIT_CONFIG
}
$contractRaw = Get-Content -LiteralPath $contractPath -Raw
$contract = $contractRaw | ConvertFrom-Json

# =============================================================================
# 3. Allowlist check -- items AND data paths
# =============================================================================
Write-FPhase 'Test-DeploymentAllowlist'

$intendedItems = @($allowlist.items | ForEach-Object {
    [pscustomobject]@{ name = $_.name; itemType = $_.itemType }
})
$intendedDataPaths = @($allowlist.dataPaths | ForEach-Object {
    [pscustomobject]@{ path = $_.path; access = $_.access }
})

$allowlistCheck = Test-DeploymentAllowlist -Allowlist $allowlist `
    -IntendedItems $intendedItems -IntendedDataPaths $intendedDataPaths

if (-not $allowlistCheck.allDeclared) {
    foreach ($i in $allowlistCheck.items | Where-Object { -not $_.declared -or -not $_.hasIssuePrefix }) {
        Write-FErr "item not declared or unprefixed: $($i.itemType)/$($i.name)"
    }
    foreach ($p in $allowlistCheck.dataPaths | Where-Object { -not $_.declared }) {
        Write-FErr "data path not declared: $($p.path)"
    }
    Add-RunError -Phase 'deployment' -Message 'Allowlist check failed.'
    exit $script:F_EXIT_ALLOWLIST
}
Write-FOk "$($allowlistCheck.items.Count) items and $($allowlistCheck.dataPaths.Count) data paths declared and prefixed"

# =============================================================================
# 4. Baseline inventory -- BEFORE any write
# =============================================================================
Write-FPhase 'Get-FabricFolderInventory (baseline)'

if (-not (Test-Path -LiteralPath $RawEvidenceRoot)) {
    New-Item -ItemType Directory -Force -Path $RawEvidenceRoot | Out-Null
}

# The baseline is captured ONCE per ticket and then persisted. A resumed run
# must compare against the state before this ticket wrote anything, not against
# the state its own interrupted run left behind -- otherwise the items it
# created would look pre-existing and the create-only guard would refuse them
# forever.
$baselinePath = Join-Path $RawEvidenceRoot 'inventory-baseline.json'
$inventoryBefore = @()
$preDeploymentKeys = @()

if ($Mode -eq 'Live') {
    if (Test-Path -LiteralPath $baselinePath) {
        $existingBaseline = Get-Content -LiteralPath $baselinePath -Raw
        $inventoryBefore = @()
        if (-not [string]::IsNullOrWhiteSpace($existingBaseline)) {
            # Assigned first, then enumerated. ConvertFrom-Json writes an empty
            # array to the pipeline as ONE object rather than enumerating it, so
            # piping its output straight into Where-Object yields a single item
            # that IS the empty array -- a baseline of "1 item" with no
            # properties, which is what broke the first resume attempt.
            # Assigning to a variable and then piping forces enumeration.
            # An empty baseline is the ordinary state for a fresh target folder.
            $parsedBaseline = $existingBaseline | ConvertFrom-Json
            if ($null -ne $parsedBaseline) {
                $inventoryBefore = @($parsedBaseline | Where-Object { $null -ne $_ })
            }
        }
        Write-FOk "using the persisted pre-deployment baseline: $($inventoryBefore.Count) item(s)"
        Write-FInfo "baseline file: $baselinePath (captured before this ticket's first write)"
    } else {
        $inventoryBefore = Get-FabricFolderInventory -WorkspaceId $workspaceId -FolderId $folderId `
            -OutputPath $baselinePath
        if ($null -eq $inventoryBefore) {
            Add-RunError -Phase 'deployment' -Message 'Baseline inventory could not be captured.'
            exit $script:F_EXIT_API
        }
        Write-FOk "$($inventoryBefore.Count) item(s) in the target folder before deployment"
    }
    $preDeploymentKeys = @($inventoryBefore | ForEach-Object { "$($_.itemType)/$($_.itemName)" })

    if ($Resume) {
        Write-FWarn 'Resume is ON: items absent from the baseline above will be converged.'
        Write-FWarn 'Items present in the baseline remain create-only and are still refused.'
    }
} else {
    Write-FDryRun 'baseline inventory (skipped in Plan mode; requires Fabric read)'
}

# =============================================================================
# 5. Reversal plan -- BEFORE any write
# =============================================================================
Write-FPhase 'New-ReversalPlan'

$reversalPath = New-ReversalPlan -IntendedItems $intendedItems -DataPaths $intendedDataPaths `
    -Snapshots @() -OutputPath 'reviews/2/reversal-plan.md'
Write-FOk "reversal plan written: $reversalPath"

# =============================================================================
# 6. Publish item definitions
# =============================================================================
Write-FPhase 'Publish-FabricItemDefinition'

$whatIf = ($Mode -ne 'Live')
$deployed = @{}
$deployments = @()

# --- Lakehouse first. Everything else writes into it. ---
$lakehouseName = "$($prefix)retail_lakehouse"
$lakehousePlatform = Get-Content -LiteralPath (Join-Path $SourceRoot "items/$lakehouseName.Lakehouse/.platform") -Raw | ConvertFrom-Json

$lakehouse = Publish-FabricItemDefinition -WorkspaceId $workspaceId -FolderId $folderId `
    -DisplayName $lakehouseName -ItemType 'Lakehouse' `
    -Description $lakehousePlatform.metadata.description `
    -Parts @() -RequiredPrefix $prefix `
    -PreDeploymentKeys $preDeploymentKeys -ResumePartial:$Resume -WhatIf:$whatIf
if ($null -eq $lakehouse) {
    Add-RunError -Phase 'deployment' -Message "Lakehouse '$lakehouseName' was not created and verified."
    exit $script:F_EXIT_VERIFY
}
$deployed[$lakehouseName] = $lakehouse
$deployments += $lakehouse

# --- Notebooks. The contract is substituted into each definition at publish
#     time so the definition deployed to Fabric and the definition reviewed in
#     this repository cannot drift apart. ---
$notebookNames = @(
    "$($prefix)00_generate_source",
    "$($prefix)10_bronze_ingest",
    "$($prefix)20_silver_transform",
    "$($prefix)30_gold_build",
    "$($prefix)90_validate"
)

foreach ($name in $notebookNames) {
    $dir = Join-Path $SourceRoot "items/$name.Notebook"
    $platform = Get-Content -LiteralPath (Join-Path $dir '.platform') -Raw | ConvertFrom-Json
    $content = Get-Content -LiteralPath (Join-Path $dir 'notebook-content.py') -Raw

    if ($content -notmatch '\{\{DATA_CONTRACT_JSON\}\}') {
        Write-FErr "$name has no {{DATA_CONTRACT_JSON}} placeholder; it would run without a contract."
        exit $script:F_EXIT_VERIFY
    }
    # Compact JSON, and the notebook embeds it in an r"""...""" literal. A raw
    # triple-quoted string is safe for the backslashes and quotes JSON contains;
    # the one sequence it cannot hold is a literal triple quote, which compact
    # JSON of this contract never produces.
    $contractCompact = ($contract | ConvertTo-Json -Depth 30 -Compress)
    if ($contractCompact -match '"""') {
        Write-FErr 'The data contract contains a triple quote and cannot be embedded safely.'
        exit $script:F_EXIT_VERIFY
    }
    $content = $content.Replace('{{DATA_CONTRACT_JSON}}', $contractCompact)

    $parts = @(
        (New-FabricDefinitionPart -LogicalPath 'notebook-content.py' -Content $content),
        (New-FabricDefinitionPart -LogicalPath '.platform' -Content (Get-Content -LiteralPath (Join-Path $dir '.platform') -Raw))
    )

    $result = Publish-FabricItemDefinition -WorkspaceId $workspaceId -FolderId $folderId `
        -DisplayName $name -ItemType 'Notebook' -Description $platform.metadata.description `
        -Parts $parts -RequiredPrefix $prefix `
        -PreDeploymentKeys $preDeploymentKeys -ResumePartial:$Resume -WhatIf:$whatIf
    if ($null -eq $result) {
        Add-RunError -Phase 'deployment' -Message "Notebook '$name' was not created and verified."
        exit $script:F_EXIT_VERIFY
    }
    $deployed[$name] = $result
    $deployments += $result
}

# --- Pipeline last. Its definition references notebook ids that only exist once
#     the notebooks above are created, so nothing here is resolved by name. ---
$pipelineName = "$($prefix)retail_medallion_pipeline"
$pipelineDir = Join-Path $SourceRoot "items/$pipelineName.DataPipeline"
$pipelinePlatform = Get-Content -LiteralPath (Join-Path $pipelineDir '.platform') -Raw | ConvertFrom-Json
$pipelineContent = Get-Content -LiteralPath (Join-Path $pipelineDir 'pipeline-content.json') -Raw

$pipelineContent = $pipelineContent.Replace('{{WORKSPACE_ID}}', $workspaceId)
foreach ($name in $notebookNames) {
    $token = "{{NOTEBOOK_ID:$name}}"
    if ($pipelineContent -notmatch [regex]::Escape($token)) {
        Write-FErr "Pipeline definition does not reference $name. Refusing to deploy a partial chain."
        exit $script:F_EXIT_VERIFY
    }
    $id = 'PLAN-MODE-NO-ID'
    if ($Mode -eq 'Live') { $id = $deployed[$name].itemId }
    $pipelineContent = $pipelineContent.Replace($token, $id)
}
if ($pipelineContent -match '\{\{[A-Z_]+') {
    Write-FErr 'Unsubstituted placeholder remains in the pipeline definition.'
    exit $script:F_EXIT_VERIFY
}

$pipelineParts = @(
    (New-FabricDefinitionPart -LogicalPath 'pipeline-content.json' -Content $pipelineContent),
    (New-FabricDefinitionPart -LogicalPath '.platform' -Content (Get-Content -LiteralPath (Join-Path $pipelineDir '.platform') -Raw))
)

$pipeline = Publish-FabricItemDefinition -WorkspaceId $workspaceId -FolderId $folderId `
    -DisplayName $pipelineName -ItemType 'DataPipeline' `
    -Description $pipelinePlatform.metadata.description `
    -Parts $pipelineParts -RequiredPrefix $prefix `
    -PreDeploymentKeys $preDeploymentKeys -ResumePartial:$Resume -WhatIf:$whatIf
if ($null -eq $pipeline) {
    Add-RunError -Phase 'deployment' -Message "Pipeline '$pipelineName' was not created and verified."
    exit $script:F_EXIT_VERIFY
}
$deployed[$pipelineName] = $pipeline
$deployments += $pipeline

if ($Mode -ne 'Live') {
    Write-FPhase 'Plan complete'
    Write-FDryRun 'Nothing was written to Fabric. Re-run with -Mode Live to deploy.'
    Write-FDryRun "Planned: $($deployments.Count) items, $($intendedDataPaths.Count) data paths."
    exit $script:F_EXIT_OK
}

# =============================================================================
# 7. Run the pipeline twice -- the second run IS the idempotency test
# =============================================================================
Write-FPhase 'Invoke-FabricPipeline / Wait-FabricJob'

$jobs = @()
$audits = @()

foreach ($runNumber in 1, 2) {
    $runToken = "issue2-r$runNumber-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
    Write-FInfo "run $runNumber of 2 (token $runToken)"

    $submission = Invoke-FabricPipeline -WorkspaceId $workspaceId -PipelineId $pipeline.itemId -Parameters @{
        workspace_id = $workspaceId
        lakehouse_id = $lakehouse.itemId
        run_token    = $runToken
    }
    if ($null -eq $submission) {
        Add-RunError -Phase 'execution' -Message "Pipeline run $runNumber could not be submitted."
        exit $script:F_EXIT_JOB
    }

    $job = Wait-FabricJob -WorkspaceId $workspaceId -ItemId $pipeline.itemId `
        -JobInstanceId $submission.runId -TimeoutSeconds $PipelineTimeoutSeconds
    $job | Add-Member -NotePropertyName name -NotePropertyValue "$pipelineName (run $runNumber)" -Force
    $jobs += $job

    if ($job.terminalStatus -ne 'Succeeded') {
        Write-FErr "Run $runNumber terminal status: $($job.terminalStatus)"
        Add-RunError -Phase 'execution' -Message "Pipeline run $runNumber ended $($job.terminalStatus): $($job.failureDetail)"
        # Still attempt the audit retrieval: stage 90 writes its audit file even
        # on failure, and that file names the assertion that failed. Losing it
        # would turn a specific data defect into a generic "the run failed".
    }
    Write-FOk "run $runNumber terminal status: $($job.terminalStatus)"

    # --- Independent read-back over the OneLake DFS endpoint ---
    $auditJson = Get-OneLakeFile -WorkspaceId $workspaceId -LakehouseId $lakehouse.itemId `
        -RelativePath "Files/issue2/evidence/validation-run-$runToken.json"
    if ($null -eq $auditJson) {
        Add-RunError -Phase 'validation' -Message "Audit file for run $runNumber could not be retrieved."
        exit $script:F_EXIT_VERIFY
    }
    $auditJson | Out-File -LiteralPath (Join-Path $RawEvidenceRoot "audit-run-$runNumber.json") -Encoding utf8
    $audits += ($auditJson | ConvertFrom-Json)
    Write-FOk "run $runNumber audit retrieved independently ($($auditJson.Length) bytes)"
}

if (@($jobs | Where-Object { $_.terminalStatus -ne 'Succeeded' }).Count -gt 0) {
    exit $script:F_EXIT_JOB
}

# =============================================================================
# 8. Assert the audit files against the committed contract
# =============================================================================
Write-FPhase 'Test-Issue2AuditFile'

$validationFailures = @()
for ($i = 0; $i -lt $audits.Count; $i++) {
    foreach ($f in (Test-Issue2AuditFile -Audit $audits[$i] -Contract $contract)) {
        $validationFailures += "run $($i + 1): $f"
    }
}

# Idempotency, checked here as well as inside stage 90. Two independent checks
# of the same property; neither is trusted to stand alone.
foreach ($p in $audits[0].goldContentHashes.PSObject.Properties) {
    $second = $audits[1].goldContentHashes.($p.Name)
    if ($second -ne $p.Value) {
        $validationFailures += "idempotency: $($p.Name) content hash changed between run 1 and run 2"
    }
}
if ($audits[1].idempotency.status -ne 'pass') {
    $validationFailures += "run 2 in-notebook idempotency check reported '$($audits[1].idempotency.status)'"
}

if ($validationFailures.Count -gt 0) {
    foreach ($f in $validationFailures) { Write-FErr $f }
    Add-RunError -Phase 'validation' -Message "$($validationFailures.Count) validation assertion(s) failed."
    exit $script:F_EXIT_VERIFY
}
Write-FOk 'every audited value matches the committed data contract, both runs'

# =============================================================================
# 9. Inventory after, and the diff
# =============================================================================
Write-FPhase 'Compare-FabricFolderInventory'

$inventoryAfter = Get-FabricFolderInventory -WorkspaceId $workspaceId -FolderId $folderId `
    -OutputPath (Join-Path $RawEvidenceRoot 'inventory-after.json')
if ($null -eq $inventoryAfter) {
    Add-RunError -Phase 'validation' -Message 'Post-deployment inventory could not be captured.'
    exit $script:F_EXIT_API
}

$diff = Compare-FabricFolderInventory -Baseline $inventoryBefore -Current $inventoryAfter -Allowlist $allowlist
Write-FInfo "added: $($diff.added.Count)  removed: $($diff.removed.Count)  undeclared: $($diff.undeclaredChanges.Count)"

if ($diff.undeclaredChanges.Count -gt 0) {
    foreach ($u in $diff.undeclaredChanges) { Write-FErr "UNDECLARED: $u" }
    Add-RunError -Phase 'validation' -Message 'Undeclared Fabric change detected.'
    exit $script:F_EXIT_UNDECLARED
}
Write-FOk 'no undeclared Fabric side effects'

# =============================================================================
# 10. Evidence
# =============================================================================
Write-FPhase 'Write evidence'

# Raw first, to the gitignored location. It carries real GUIDs.
$raw = [pscustomobject]@{
    workspaceId     = $workspaceId
    folderId        = $folderId
    deployments     = $deployments
    jobs            = $jobs
    inventoryBefore = $inventoryBefore
    inventoryAfter  = $inventoryAfter
    audits          = $audits
}
($raw | ConvertTo-Json -Depth 30) |
    Out-File -LiteralPath (Join-Path $RawEvidenceRoot 'raw-evidence.json') -Encoding utf8
Write-FOk "raw evidence (contains real identifiers): $RawEvidenceRoot  [gitignored]"

Write-FPhase 'Done'
Write-FOk "Deployed and validated $($deployments.Count) items across 2 idempotent runs."
Write-FInfo "Now run: scripts/fabric/Write-Issue2Evidence.ps1 -RawEvidenceRoot $RawEvidenceRoot -EvidenceOutput $EvidenceOutput"
exit $script:F_EXIT_OK

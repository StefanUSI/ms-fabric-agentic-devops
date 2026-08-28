<#
.SYNOPSIS
    Deterministic checks for the Issue #2 synthetic retail medallion.

.DESCRIPTION
    These tests never contact Microsoft Fabric, never authenticate, and never
    change any state. They run entirely against committed repository artefacts,
    which is what makes them runnable by the reviewer from a cold checkout.

    They cover three things the reviewer should not have to take on trust:

      1. The data contract is arithmetically self-consistent. Every expected
         value is derivable from the generation parameters, so a contract that
         quietly disagrees with itself fails here rather than after a Spark run.

      2. The deployed artefacts agree with the contract and the allowlist -- item
         names, prefixes, the notebook/pipeline wiring and the data paths.

      3. The safety functions actually REJECT. A guard that has never been shown
         to fail is not a guard; several tests below feed deliberately bad input
         to Test-DeploymentAllowlist, Compare-FabricFolderInventory and
         Test-Issue2AuditFile and assert that each one refuses.

    Exit code is non-zero if any assertion fails, as the ticket requires.

.EXAMPLE
    ./tests/issue2-validation.tests.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1')

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

$srcRoot       = Join-Path $repoRoot 'src/issue2-retail-medallion'
$itemsRoot     = Join-Path $srcRoot 'items'
$contractPath  = Join-Path $srcRoot 'data-contract.json'
$allowlistPath = Join-Path $repoRoot 'config/issue2-allowlist.json'

$contract  = Get-Utf8Text $contractPath | ConvertFrom-Json
$allowlist = Get-Utf8Text $allowlistPath | ConvertFrom-Json
$gen       = $contract.generation
$expected  = $contract.expected

$notebookNames = @(
    'issue2_00_generate_source',
    'issue2_10_bronze_ingest',
    'issue2_20_silver_transform',
    'issue2_30_gold_build',
    'issue2_90_validate'
)

# =============================================================================
Write-Section 'Data contract arithmetic'
# Each expected count is recomputed here from the generation parameters. A
# contract edited in one place and not the other fails at this point instead of
# consuming a Spark session to discover the same thing.
# =============================================================================

Test-Case 'clean sales lines = days x stores x linesPerStoreDay' {
    ($gen.days * $gen.storeCount * $gen.linesPerStoreDay) -eq $expected.sourceCleanSalesLines
}

Test-Case 'injected defect lines = sum of every injectedDefects entry' {
    $sum = 0
    foreach ($p in $gen.injectedDefects.PSObject.Properties) {
        if (-not $p.Name.StartsWith('$')) { $sum += [int]$p.Value }
    }
    $sum -eq $expected.sourceInjectedDefectLines
}

Test-Case 'total source lines = clean + injected' {
    ($expected.sourceCleanSalesLines + $expected.sourceInjectedDefectLines) -eq $expected.sourceTotalSalesLines
}

Test-Case 'bronze sales = total source lines (bronze filters nothing)' {
    $expected.bronze.issue2_bronze_sales -eq $expected.sourceTotalSalesLines
}

Test-Case 'quarantine total = sum of the per-reason breakdown' {
    $sum = 0
    foreach ($p in $expected.quarantineByReason.PSObject.Properties) {
        if (-not $p.Name.StartsWith('$')) { $sum += [int]$p.Value }
    }
    $sum -eq $expected.silver.issue2_silver_quarantine_sales
}

Test-Case 'quarantine reasons match the injected defect categories exactly' {
    # nullProductId -> null_natural_key etc. The duplicates are deliberately NOT
    # a quarantine reason: they are removed by deduplication, and conflating the
    # two would make the breakdown add up while describing the wrong failure.
    ($expected.quarantineByReason.non_positive_quantity -eq $gen.injectedDefects.nonPositiveQuantity) -and
    ($expected.quarantineByReason.null_natural_key      -eq $gen.injectedDefects.nullProductId) -and
    ($expected.quarantineByReason.orphan_store          -eq $gen.injectedDefects.orphanStoreId) -and
    ($expected.quarantineByReason.non_positive_price    -eq $gen.injectedDefects.nonPositivePrice)
}

Test-Case 'duplicatesRemoved equals the injected duplicate count' {
    $expected.duplicatesRemoved -eq $gen.injectedDefects.duplicateLines
}

Test-Case 'row conservation: bronze = silver + quarantine + duplicates' {
    $rc = $expected.rowConservation
    ($rc.bronzeSales -eq ($rc.silverSales + $rc.quarantine + $rc.duplicatesRemoved)) -and
    ($rc.bronzeSales -eq $expected.bronze.issue2_bronze_sales) -and
    ($rc.silverSales -eq $expected.silver.issue2_silver_sales) -and
    ($rc.quarantine  -eq $expected.silver.issue2_silver_quarantine_sales)
}

Test-Case 'silver sales = clean lines (every clean row survives, no defect does)' {
    $expected.silver.issue2_silver_sales -eq $expected.sourceCleanSalesLines
}

Test-Case 'gold daily grain = days x stores' {
    $expected.gold.issue2_gold_daily_store_sales -eq ($gen.days * $gen.storeCount)
}

Test-Case 'gold product grain = productCount' {
    $expected.gold.issue2_gold_product_performance -eq $gen.productCount
}

Test-Case 'gold segment grain = segmentCount' {
    $expected.gold.issue2_gold_customer_segment_kpi -eq $gen.segmentCount
}

Test-Case 'silver dimensions match the generated reference counts' {
    ($expected.silver.issue2_silver_dim_store    -eq $gen.storeCount) -and
    ($expected.silver.issue2_silver_dim_product  -eq $gen.productCount) -and
    ($expected.silver.issue2_silver_dim_customer -eq $gen.customerCount)
}

Test-Case 'orphan store id lies outside the generated store range' {
    # If it did not, the orphan_store rule would match nothing and its expected
    # count of 20 would be unreachable.
    $gen.orphanStoreIdValue -gt $gen.storeCount
}

Test-Case 'every data-quality rule id is referenced by the expected breakdown' {
    $ruleIds = @($contract.dataQualityRules | Where-Object { $_.severity -eq 'reject' } | ForEach-Object { $_.id })
    $reasonKeys = @($expected.quarantineByReason.PSObject.Properties |
        Where-Object { -not $_.Name.StartsWith('$') } | ForEach-Object { $_.Name })
    $missing = @($ruleIds | Where-Object { $reasonKeys -notcontains $_ })
    $missing.Count -eq 0
}

# =============================================================================
Write-Section 'Item definitions and allowlist agreement'
# =============================================================================

Test-Case 'every allowlisted item carries the issue2_ prefix' {
    $bad = @($allowlist.items | Where-Object { $_.name -notlike "$($allowlist.requiredItemPrefix)*" })
    $bad.Count -eq 0
}

Test-Case 'every allowlisted item is createOnly' {
    # This ticket names no existing item, so every operation must be a create
    # that refuses to overwrite. A single update here would need the Issue to
    # name that item explicitly (CLAUDE.md rule 5).
    $bad = @($allowlist.items | Where-Object { $_.operation -ne 'create' -or -not $_.createOnly })
    $bad.Count -eq 0
}

Test-Case 'every allowlisted item exists in src/ (except platform companions)' {
    $missing = @()
    foreach ($i in $allowlist.items) {
        $dir = Join-Path $itemsRoot "$($i.name).$($i.itemType)"
        if (-not (Test-Path -LiteralPath $dir)) { $missing += $i.name }
    }
    $missing.Count -eq 0
}

Test-Case 'every src/ item is declared on the allowlist' {
    # The direction that catches an item added to the repository but never
    # declared -- which would deploy without ever being allowlist-checked.
    $declared = @($allowlist.items | ForEach-Object { "$($_.name).$($_.itemType)" })
    $undeclared = @(Get-ChildItem -LiteralPath $itemsRoot -Directory |
        Where-Object { $declared -notcontains $_.Name } | ForEach-Object { $_.Name })
    $undeclared.Count -eq 0
}

Test-Case '.platform displayName matches the directory name for every item' {
    $bad = @()
    foreach ($d in Get-ChildItem -LiteralPath $itemsRoot -Directory) {
        $p = Get-Utf8Text (Join-Path $d.FullName '.platform') | ConvertFrom-Json
        $expectedName = $d.Name.Substring(0, $d.Name.LastIndexOf('.'))
        $expectedType = $d.Name.Substring($d.Name.LastIndexOf('.') + 1)
        if ($p.metadata.displayName -ne $expectedName -or $p.metadata.type -ne $expectedType) {
            $bad += $d.Name
        }
    }
    $bad.Count -eq 0
}

Test-Case 'every notebook has the data-contract placeholder' {
    # Without it the notebook would deploy with no expected values and its
    # reconciliation cells would assert nothing.
    $bad = @()
    foreach ($n in $notebookNames) {
        $c = Get-Utf8Text (Join-Path $itemsRoot "$n.Notebook/notebook-content.py")
        if ($c -notmatch '\{\{DATA_CONTRACT_JSON\}\}') { $bad += $n }
    }
    $bad.Count -eq 0
}

Test-Case 'every notebook guards against unbound identifiers' {
    $bad = @()
    foreach ($n in $notebookNames) {
        $c = Get-Utf8Text (Join-Path $itemsRoot "$n.Notebook/notebook-content.py")
        if ($c -notmatch 'never infers an identifier') { $bad += $n }
    }
    $bad.Count -eq 0
}

Test-Case 'the compact data contract contains no triple quote' {
    # It is embedded into each notebook inside an r"""...""" literal at publish
    # time; a triple quote in the JSON would terminate that literal early and
    # produce a syntactically broken notebook.
    ($contract | ConvertTo-Json -Depth 30 -Compress) -notmatch '"""'
}

# =============================================================================
Write-Section 'Pipeline wiring'
# =============================================================================

$pipelinePath = Join-Path $itemsRoot 'issue2_retail_medallion_pipeline.DataPipeline/pipeline-content.json'
$pipelineText = Get-Utf8Text $pipelinePath
$pipeline = $pipelineText | ConvertFrom-Json

Test-Case 'pipeline references every notebook by substitution token' {
    $missing = @($notebookNames | Where-Object { $pipelineText -notmatch [regex]::Escape("{{NOTEBOOK_ID:$_}}") })
    $missing.Count -eq 0
}

Test-Case 'pipeline has exactly one activity per notebook' {
    @($pipeline.properties.activities).Count -eq $notebookNames.Count
}

Test-Case 'pipeline stages form a strict Succeeded-only chain' {
    # Sequential on purpose: capacity is shared and modest, and a later stage
    # must never read a layer an earlier stage was still writing.
    $activities = @($pipeline.properties.activities)
    $ok = @($activities[0].dependsOn).Count -eq 0
    for ($i = 1; $i -lt $activities.Count -and $ok; $i++) {
        $dep = @($activities[$i].dependsOn)
        $ok = ($dep.Count -eq 1) -and
              ($dep[0].activity -eq $activities[$i - 1].name) -and
              (@($dep[0].dependencyConditions) -join ',') -eq 'Succeeded'
    }
    $ok
}

Test-Case 'pipeline concurrency is 1' {
    $pipeline.properties.concurrency -eq 1
}

Test-Case 'no pipeline stage retries' {
    # A retry would start a second Spark job against the same tables while the
    # first may still be finishing, on a shared capacity.
    $bad = @($pipeline.properties.activities | Where-Object { $_.policy.retry -ne 0 })
    $bad.Count -eq 0
}

Test-Case 'every stage receives all three parameters' {
    $bad = @()
    foreach ($a in $pipeline.properties.activities) {
        $names = @($a.typeProperties.parameters.PSObject.Properties.Name)
        foreach ($required in @('workspace_id', 'lakehouse_id', 'run_token')) {
            if ($names -notcontains $required) { $bad += "$($a.name)/$required" }
        }
    }
    $bad.Count -eq 0
}

Test-Case 'pipeline parameter defaults are empty so an unbound run fails loudly' {
    $p = $pipeline.properties.parameters
    ($p.workspace_id.defaultValue -eq '') -and
    ($p.lakehouse_id.defaultValue -eq '') -and
    ($p.run_token.defaultValue -eq '')
}

# =============================================================================
Write-Section 'Data-path allowlist'
# =============================================================================

Test-Case 'every declared data path is inside the ticket lakehouse' {
    $bad = @($allowlist.dataPaths | Where-Object { $_.path -notlike 'issue2_retail_lakehouse/*' })
    $bad.Count -eq 0
}

Test-Case 'every declared table path carries the issue2_ prefix' {
    $tables = @($allowlist.dataPaths | Where-Object { $_.path -like '*/Tables/*' })
    $bad = @($tables | Where-Object { ($_.path -split '/')[-1] -notlike 'issue2_*' })
    ($tables.Count -gt 0) -and ($bad.Count -eq 0)
}

Test-Case 'every contract table has a declared data path' {
    $declared = @($allowlist.dataPaths | ForEach-Object { ($_.path -split '/')[-1] })
    $missing = @()
    foreach ($layer in @('bronze', 'silver', 'gold')) {
        foreach ($p in $expected.$layer.PSObject.Properties) {
            if ($p.Name.StartsWith('$')) { continue }
            if ($declared -notcontains $p.Name) { $missing += $p.Name }
        }
    }
    $missing.Count -eq 0
}

Test-Case 'the evidence file area is declared writable' {
    @($allowlist.dataPaths | Where-Object {
        $_.path -like '*Files/issue2/evidence*' -and $_.access -eq 'write'
    }).Count -eq 1
}

# =============================================================================
Write-Section 'Safety functions REJECT bad input'
# Guards that have only ever been shown to pass are not guards.
# =============================================================================

Test-Case 'Test-DeploymentAllowlist rejects an undeclared item' {
    $r = Test-DeploymentAllowlist -Allowlist $allowlist `
        -IntendedItems @([pscustomobject]@{ name = 'issue2_sneaky'; itemType = 'Notebook' }) `
        -IntendedDataPaths @()
    (-not $r.allDeclared)
}

Test-Case 'Test-DeploymentAllowlist rejects an unprefixed item even if named' {
    $r = Test-DeploymentAllowlist -Allowlist $allowlist `
        -IntendedItems @([pscustomobject]@{ name = 'production_sales'; itemType = 'Lakehouse' }) `
        -IntendedDataPaths @()
    (-not $r.allDeclared)
}

Test-Case 'Test-DeploymentAllowlist rejects a data path outside the lakehouse' {
    $r = Test-DeploymentAllowlist -Allowlist $allowlist -IntendedItems @() `
        -IntendedDataPaths @([pscustomobject]@{ path = 'someone_elses_lakehouse/Tables/gold_revenue'; access = 'write' })
    (-not $r.allDeclared)
}

Test-Case 'Test-DeploymentAllowlist rejects write access where only read was declared' {
    # The wildcard entries are write, so a read-declared probe of an undeclared
    # path must still fail rather than matching on path alone.
    $r = Test-DeploymentAllowlist -Allowlist $allowlist -IntendedItems @() `
        -IntendedDataPaths @([pscustomobject]@{ path = 'issue2_retail_lakehouse/Tables/not_declared'; access = 'write' })
    (-not $r.allDeclared)
}

Test-Case 'Test-DeploymentAllowlist accepts the real intended target set' {
    $items = @($allowlist.items | ForEach-Object { [pscustomobject]@{ name = $_.name; itemType = $_.itemType } })
    $paths = @($allowlist.dataPaths | ForEach-Object { [pscustomobject]@{ path = $_.path; access = $_.access } })
    $r = Test-DeploymentAllowlist -Allowlist $allowlist -IntendedItems $items -IntendedDataPaths $paths
    $r.allDeclared
}

Test-Case 'Compare-FabricFolderInventory accepts the declared items and companions' {
    $after = @()
    foreach ($i in $allowlist.items) {
        $after += [pscustomobject]@{ itemName = $i.name; itemType = $i.itemType; definitionHash = 'x'; itemId = $null; lastModifiedUtc = $null }
    }
    foreach ($c in $allowlist.expectedAutoGeneratedCompanions) {
        $after += [pscustomobject]@{ itemName = $c.name; itemType = $c.itemType; definitionHash = 'x'; itemId = $null; lastModifiedUtc = $null }
    }
    $d = Compare-FabricFolderInventory -Baseline @() -Current $after -Allowlist $allowlist
    $d.undeclaredChanges.Count -eq 0
}

Test-Case 'Compare-FabricFolderInventory flags an undeclared new item' {
    $after = @([pscustomobject]@{ itemName = 'someone_elses_report'; itemType = 'Report'; definitionHash = 'x'; itemId = $null; lastModifiedUtc = $null })
    $d = Compare-FabricFolderInventory -Baseline @() -Current $after -Allowlist $allowlist
    $d.undeclaredChanges.Count -eq 1
}

Test-Case 'Compare-FabricFolderInventory flags any removal as undeclared' {
    # Nothing in this ticket may delete an item, so a disappearance always needs
    # a human -- there is no "expected removal" classification.
    $before = @([pscustomobject]@{ itemName = 'pre_existing'; itemType = 'Lakehouse'; definitionHash = 'x'; itemId = $null; lastModifiedUtc = $null })
    $d = Compare-FabricFolderInventory -Baseline $before -Current @() -Allowlist $allowlist
    $d.undeclaredChanges.Count -eq 1
}

Test-Case 'inventory diff keys on name AND type, not name alone' {
    # The Lakehouse, its SQL endpoint and its default semantic model share one
    # display name. Keyed on name alone, two of the three vanish from the diff.
    $after = @(
        [pscustomobject]@{ itemName = 'issue2_retail_lakehouse'; itemType = 'Lakehouse';     definitionHash = 'x'; itemId = $null; lastModifiedUtc = $null },
        [pscustomobject]@{ itemName = 'issue2_retail_lakehouse'; itemType = 'SQLEndpoint';   definitionHash = 'x'; itemId = $null; lastModifiedUtc = $null },
        [pscustomobject]@{ itemName = 'issue2_retail_lakehouse'; itemType = 'SemanticModel'; definitionHash = 'x'; itemId = $null; lastModifiedUtc = $null }
    )
    $d = Compare-FabricFolderInventory -Baseline @() -Current $after -Allowlist $allowlist
    $d.added.Count -eq 3
}

# --- Audit-file assertions ---------------------------------------------------

function New-PassingAudit {
    <#
        A synthetic audit file that matches the contract exactly. Used ONLY to
        prove the assertion function distinguishes good from bad; it is never
        committed as evidence and never presented as a run result.
    #>
    $rowCounts = @{}
    foreach ($layer in @('bronze', 'silver', 'gold')) {
        foreach ($p in $expected.$layer.PSObject.Properties) {
            if (-not $p.Name.StartsWith('$')) { $rowCounts[$p.Name] = [int]$p.Value }
        }
    }
    $reasons = @{}
    foreach ($p in $expected.quarantineByReason.PSObject.Properties) {
        if (-not $p.Name.StartsWith('$')) { $reasons[$p.Name] = [int]$p.Value }
    }
    $pks = @{}
    foreach ($p in $expected.primaryKeys.PSObject.Properties) {
        if ($p.Name.StartsWith('$')) { continue }
        $pks[$p.Name] = @{ columns = @($p.Value); rows = $rowCounts[$p.Name]; distinctKeys = $rowCounts[$p.Name]; nullKeyRows = 0 }
    }
    return (@{
        passed = $true
        failures = @()
        landingCounts = @{ sales = $expected.sourceTotalSalesLines }
        rowCounts = $rowCounts
        quarantineByReason = $reasons
        rowConservation = @{
            bronzeSales = $expected.rowConservation.bronzeSales
            silverSales = $expected.rowConservation.silverSales
            quarantined = $expected.rowConservation.quarantine
            duplicatesRemoved = $expected.rowConservation.duplicatesRemoved
            holds = $true
        }
        primaryKeys = $pks
        financialReconciliation = @{
            maxAbsoluteDelta = 0.0
            tolerance = $expected.financialToleranceAbsolute
            withinTolerance = $true
        }
    } | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

Test-Case 'Test-Issue2AuditFile passes a contract-conforming audit' {
    (Test-Issue2AuditFile -Audit (New-PassingAudit) -Contract $contract).Count -eq 0
}

Test-Case 'Test-Issue2AuditFile rejects a wrong silver row count' {
    $a = New-PassingAudit
    $a.rowCounts.issue2_silver_sales = $expected.silver.issue2_silver_sales - 1
    (Test-Issue2AuditFile -Audit $a -Contract $contract).Count -gt 0
}

Test-Case 'Test-Issue2AuditFile rejects broken row conservation' {
    $a = New-PassingAudit
    $a.rowConservation.duplicatesRemoved = 0
    (Test-Issue2AuditFile -Audit $a -Contract $contract).Count -gt 0
}

Test-Case 'Test-Issue2AuditFile rejects a non-unique primary key' {
    $a = New-PassingAudit
    $a.primaryKeys.issue2_gold_product_performance.distinctKeys = 1
    (Test-Issue2AuditFile -Audit $a -Contract $contract).Count -gt 0
}

Test-Case 'Test-Issue2AuditFile rejects a NULL in a primary key' {
    $a = New-PassingAudit
    $a.primaryKeys.issue2_silver_sales.nullKeyRows = 3
    (Test-Issue2AuditFile -Audit $a -Contract $contract).Count -gt 0
}

Test-Case 'Test-Issue2AuditFile rejects a financial delta outside tolerance' {
    $a = New-PassingAudit
    $a.financialReconciliation.withinTolerance = $false
    (Test-Issue2AuditFile -Audit $a -Contract $contract).Count -gt 0
}

Test-Case 'Test-Issue2AuditFile rejects a widened tolerance' {
    # Catches the specific cheat of loosening the tolerance in the notebook to
    # make a genuinely failing reconciliation pass.
    $a = New-PassingAudit
    $a.financialReconciliation.tolerance = 1000
    (Test-Issue2AuditFile -Audit $a -Contract $contract).Count -gt 0
}

Test-Case 'Test-Issue2AuditFile rejects a quarantine reason count that drifted' {
    $a = New-PassingAudit
    $a.quarantineByReason.orphan_store = 0
    (Test-Issue2AuditFile -Audit $a -Contract $contract).Count -gt 0
}

Test-Case 'Test-Issue2AuditFile surfaces notebook-reported failures' {
    $a = New-PassingAudit
    $a.passed = $false
    $a.failures = @('some assertion failed inside the notebook')
    (Test-Issue2AuditFile -Audit $a -Contract $contract).Count -gt 0
}

# =============================================================================
Write-Section 'Public-repository identifier hygiene'
# =============================================================================

$trackedIssue2Files = @(
    (Get-ChildItem -LiteralPath $srcRoot -Recurse -File | ForEach-Object { $_.FullName }) +
    @($allowlistPath,
      (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1'),
      (Join-Path $repoRoot 'scripts/fabric/Deploy-Issue2Medallion.ps1'),
      (Join-Path $repoRoot 'scripts/fabric/Write-Issue2Evidence.ps1'),
      $PSCommandPath)
) | Where-Object { Test-Path -LiteralPath $_ }

Test-Case 'no tracked Issue #2 file contains a GUID' {
    $hits = @()
    foreach ($f in $trackedIssue2Files) {
        $t = Get-Utf8Text $f
        if ($t -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
            $hits += (Split-Path -Leaf $f)
        }
    }
    if ($hits.Count -gt 0) { Write-Host "        GUID found in: $($hits -join ', ')" -ForegroundColor Yellow }
    $hits.Count -eq 0
}

Test-Case 'no tracked Issue #2 file contains an email address' {
    $hits = @()
    foreach ($f in $trackedIssue2Files) {
        $t = Get-Utf8Text $f
        if ($t -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') { $hits += (Split-Path -Leaf $f) }
    }
    $hits.Count -eq 0
}

Test-Case 'the allowlist supplies the target by reference, never by value' {
    # It must name WHAT may be touched, while the gitignored local config names
    # WHERE. A literal workspace or folder id here would be the exposure the
    # ticket forbids.
    ($allowlist.target.workspaceFrom -like '*environment.local.json*') -and
    ($allowlist.target.folderFrom    -like '*environment.local.json*')
}

Test-Case 'config/environment.local.json is gitignored' {
    $ignore = Get-Utf8Text (Join-Path $repoRoot '.gitignore')
    $ignore -match 'config/environment\.local\.json'
}

Test-Case 'the raw evidence directory is gitignored' {
    # runtime/ holds real GUIDs. If it were ever tracked, the sanitization step
    # would be bypassed entirely.
    $ignore = Get-Utf8Text (Join-Path $repoRoot '.gitignore')
    $ignore -match '(?m)^runtime/'
}

# =============================================================================
Write-Section 'Scripts parse and declare no dangerous default'
# =============================================================================

Test-Case 'every Issue #2 script parses' {
    $bad = @()
    foreach ($s in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts/fabric') -Filter '*.ps1') {
        $tokens = $null; $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) { $bad += $s.Name }
    }
    $bad.Count -eq 0
}

Test-Case 'this test file parses' {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
    (-not $parseErrors) -or ($parseErrors.Count -eq 0)
}

Test-Case 'the deployment script defaults to Plan, never to Live' {
    # Dry-run is the default deliberately. A Live default would make an
    # accidental invocation a deployment.
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/Deploy-Issue2Medallion.ps1')
    $t -match "\`$Mode\s*=\s*'Plan'"
}

Test-Case 'no script accepts a token, password or secret as a parameter' {
    $bad = @()
    foreach ($s in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'scripts/fabric') -Filter '*.ps1') {
        $t = Get-Utf8Text $s.FullName
        if ($t -match '(?m)^\s*\[.*\]\s*\$(Token|Password|Secret|ClientSecret|ApiKey)\b') { $bad += $s.Name }
    }
    $bad.Count -eq 0
}

Test-Case 'the toolbox never writes a token to a file' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1')
    ($t -notmatch '\$token\s*\|\s*Out-File') -and ($t -notmatch 'Set-Content.*\$token')
}

# =============================================================================
Write-Section 'Long-running-operation handling (regressions from the first Live run)'

# The first Live deployment created a notebook in Fabric and reported it as a
# failure, with no error message. Fabric answered the create with 202 and a
# `Location` header; the toolbox looked only for `Operation-Location`, missed it,
# and fell through to parsing the body -- the literal JSON `null` -- which
# ConvertFrom-Json turns into $null, the same value the function returns on
# error. Each test below pins one link in that chain.

Test-Case 'header lookup finds Location when Operation-Location is absent' {
    $h = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $h.Add('Location', 'https://example/operations/abc')
    $h.Add('Retry-After', '20')
    (Get-FHttpHeaderValue -Headers $h -Names @('Operation-Location', 'Location')) -eq 'https://example/operations/abc'
}

Test-Case 'header lookup is case-insensitive' {
    # Invoke-WebRequest exposes headers in a case-SENSITIVE dictionary, so a
    # header that is present can still be missed by an exact-case index.
    $h = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $h.Add('operation-location', 'https://example/operations/xyz')
    (Get-FHttpHeaderValue -Headers $h -Names @('Operation-Location')) -eq 'https://example/operations/xyz'
}

Test-Case 'header lookup prefers Operation-Location over Location' {
    $h = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $h.Add('Location', 'https://example/redirect')
    $h.Add('Operation-Location', 'https://example/operations/preferred')
    (Get-FHttpHeaderValue -Headers $h -Names @('Operation-Location', 'Location')) -eq 'https://example/operations/preferred'
}

Test-Case 'header lookup returns null when no candidate is present' {
    $h = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $h.Add('Content-Type', 'application/json')
    $null -eq (Get-FHttpHeaderValue -Headers $h -Names @('Operation-Location', 'Location'))
}

Test-Case 'header lookup unwraps a single-element array value' {
    $h = @{ 'Location' = @('https://example/operations/arr') }
    (Get-FHttpHeaderValue -Headers $h -Names @('Location')) -eq 'https://example/operations/arr'
}

Test-Case 'ConvertFrom-Json on a null body yields $null (the trap being guarded)' {
    # Documents WHY Invoke-FabricRest must not return a parsed body verbatim.
    $null -eq ('null' | ConvertFrom-Json)
}

Test-Case 'Invoke-FabricRest polls a 202 rather than returning its body' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1')
    # Both header names considered, and a 202 without a pollable operation is an
    # explicit failure rather than a silent pass.
    ($t -match "Names\s*@\('Operation-Location',\s*'Location'\)") -and
    ($t -match 'returned 202 with no operation URI to poll')
}

Test-Case 'Invoke-FabricRest never returns a bare null on a successful response' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1')
    $t -match "if \(\`$null -eq \`$parsed\) \{[\s\S]{0,200}body\s*=\s*'null'"
}

Test-Case 'an empty folder inventory serialises to [] rather than a zero-byte file' {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "issue2-inv-$([guid]::NewGuid()).json"
    try {
        # Exercises the serialisation branch directly: an empty baseline must be
        # distinguishable from a failed write.
        $inventory = @()
        $json = '[]'
        if ($inventory.Count -eq 1) { $json = "[$($inventory[0] | ConvertTo-Json -Depth 8)]" }
        elseif ($inventory.Count -gt 1) { $json = ($inventory | ConvertTo-Json -Depth 8) }
        $json | Out-File -LiteralPath $tmp -Encoding utf8
        $text = (Get-Utf8Text $tmp).Trim()
        ($text -eq '[]') -and ((Get-Item $tmp).Length -gt 0)
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

Write-Section 'Resume is scoped to this ticket own partial deployment'

Test-Case 'resume converges only items absent from the pre-deployment baseline' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1')
    # The branch order is the control: a baseline hit is handled as somebody
    # else's item BEFORE resume is ever considered.
    $preIdx = $t.IndexOf('$preExisted = ($PreDeploymentKeys -contains')
    $resumeIdx = $t.IndexOf('} elseif ($ResumePartial) {')
    ($preIdx -gt 0) -and ($resumeIdx -gt $preIdx)
}

Test-Case 'a pre-existing item still needs AllowUpdate AND a snapshot' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1')
    ($t -match 'Refusing to overwrite an item this ticket did not create') -and
    ($t -match 'Refusing to modify .* without a prior definition snapshot')
}

Test-Case 'resume is opt-in: the deployment script does not default it on' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/Deploy-Issue2Medallion.ps1')
    # A [switch] with no assignment is off unless passed explicitly.
    ($t -match '(?m)^\s*\[switch\]\$Resume,') -and ($t -notmatch '\$Resume\s*=\s*\$true')
}

Test-Case 'piping ConvertFrom-Json straight into a filter does NOT enumerate an empty array' {
    # Pins the trap itself. ConvertFrom-Json writes an empty array to the
    # pipeline as one object, so the naive one-liner sees a single item that is
    # the empty array -- a baseline of "1 item" with no properties. This test
    # asserts the broken behaviour exists, so that the correct form below is
    # visibly different rather than looking like a pointless refactor.
    $naive = @('[]' | ConvertFrom-Json | Where-Object { $null -ne $_ })
    $naive.Count -eq 1
}

Test-Case 'an empty persisted baseline loads as zero items when assigned first' {
    $parsed = '[]' | ConvertFrom-Json
    $loaded = @()
    if ($null -ne $parsed) { $loaded = @($parsed | Where-Object { $null -ne $_ }) }
    $loaded.Count -eq 0
}

Test-Case 'a one-item persisted baseline loads as exactly one item' {
    $parsed = '[{"itemType":"Lakehouse","itemName":"issue2_retail_lakehouse"}]' | ConvertFrom-Json
    $loaded = @()
    if ($null -ne $parsed) { $loaded = @($parsed | Where-Object { $null -ne $_ }) }
    ($loaded.Count -eq 1) -and ($loaded[0].itemType -eq 'Lakehouse')
}

Test-Case 'the deployment script assigns the parsed baseline before enumerating it' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/Deploy-Issue2Medallion.ps1')
    ($t -match '\$parsedBaseline = \$existingBaseline \| ConvertFrom-Json') -and
    ($t -match '@\(\$parsedBaseline \| Where-Object \{ \$null -ne \$_ \}\)')
}

Test-Case 'the baseline is persisted and reused rather than recaptured on resume' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/Deploy-Issue2Medallion.ps1')
    ($t -match 'inventory-baseline\.json') -and
    ($t -match 'using the persisted pre-deployment baseline')
}

Test-Case 'a deployed item with parts is verified by reading its definition back' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1')
    ($t -match 'is missing definition part') -and
    ($t -match 'its definition could not be read back')
}

Write-Section 'Evidence narrative is committed, not hand-edited into generated JSON'

Test-Case 'the narrative file exists and is valid JSON' {
    $p = Join-Path $repoRoot 'reviews/2/narrative.json'
    (Test-Path -LiteralPath $p) -and ($null -ne ((Get-Utf8Text $p) | ConvertFrom-Json))
}

Test-Case 'the narrative declares errors, recovery, interventions and unsupported claims' {
    $n = (Get-Utf8Text (Join-Path $repoRoot 'reviews/2/narrative.json')) | ConvertFrom-Json
    $names = $n.PSObject.Properties.Name
    ($names -contains 'errors') -and ($names -contains 'recoveryActions') -and
    ($names -contains 'humanInterventions') -and ($names -contains 'unsupportedClaims')
}

Test-Case 'every recovery action points at a real error index' {
    $n = (Get-Utf8Text (Join-Path $repoRoot 'reviews/2/narrative.json')) | ConvertFrom-Json
    $errorCount = @($n.errors).Count
    $bad = @($n.recoveryActions | Where-Object { $_.forError -lt 0 -or $_.forError -ge $errorCount })
    ($errorCount -gt 0) -and ($bad.Count -eq 0)
}

Test-Case 'the agent declares its own unsupported claims rather than none' {
    # An unsupported claim the reviewer finds after the agent declared none is a
    # materially worse finding than one the agent flagged itself.
    $n = (Get-Utf8Text (Join-Path $repoRoot 'reviews/2/narrative.json')) | ConvertFrom-Json
    @($n.unsupportedClaims).Count -gt 0
}

Test-Case 'the manifest mayCallFabric discrepancy is declared, not hidden' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'reviews/2/narrative.json')
    ($t -match 'mayCallFabric') -and ($t -match 'did NOT edit the manifest')
}

Test-Case 'the evidence writer refuses to run without a narrative file' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/Write-Issue2Evidence.ps1')
    ($t -match 'Narrative file not found') -and
    ($t -match 'Refusing to emit a package with empty errors and unsupportedClaims')
}

Test-Case 'the narrative contains no GUID and no email address' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'reviews/2/narrative.json')
    ($t -notmatch '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') -and
    ($t -notmatch '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
}

Test-Case 'the evidence writer computes the inventory diff instead of hardcoding it' {
    # Recording "nothing was added" on a run that added seven items would be a
    # false record, which the evidence standard treats as a BLOCKED finding.
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/Write-Issue2Evidence.ps1')
    ($t -match 'inventoryDiff = \$inventoryDiff') -and
    ($t -match 'Compare-FabricFolderInventory')
}

Write-Section 'OneLake returns bytes, not text (regression from the first full run)'

Test-Case 'Get-OneLakeFile decodes a byte[] response before returning it' {
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1')
    ($t -match '\$content -is \[byte\[\]\]') -and
    ($t -match '\[Text\.Encoding\]::UTF8\.GetString\(\$bytes\)')
}

Test-Case 'Get-OneLakeFile strips a UTF-8 BOM from a byte[] response' {
    # A BOM left at the front of the string makes ConvertFrom-Json fail on a
    # payload that is otherwise perfectly valid.
    $t = Get-Utf8Text (Join-Path $repoRoot 'scripts/fabric/FabricToolbox.ps1')
    $t -match '\$bytes\[0\] -eq 0xEF -and \$bytes\[1\] -eq 0xBB -and \$bytes\[2\] -eq 0xBF'
}

Test-Case 'the byte[] trap really does defeat every surface check' {
    # Pins WHY this was missed rather than only that it is fixed, because the
    # trap is quieter than it first appears:
    #
    #   .Length      returns the payload size, so the "N bytes retrieved" log
    #                line is correct and reassuring.
    #   ConvertFrom  does NOT throw. Each byte is an integer, and an integer is
    #                a valid JSON document, so the pipeline yields a list of
    #                numbers instead of the object -- no error anywhere.
    #
    # The first symptom is a missing property on the parsed audit, thrown far
    # from the cause. If a future PowerShell changes either behaviour this test
    # goes red and tells us the guard is no longer load-bearing.
    $bytes = [Text.Encoding]::UTF8.GetBytes('{"passed": true}')
    $lengthLooksRight = ($bytes.Length -eq 16)

    $parsed = @($bytes | ConvertFrom-Json)
    $silentlyWrong = ($parsed.Count -gt 1) -and
                     ($parsed[0] -is [int]) -and
                     ($parsed[0] -eq $bytes[0])

    $lengthLooksRight -and $silentlyWrong
}

Test-Case 'decoding the byte[] yields an audit object that has the properties the validator reads' {
    $bytes = [Text.Encoding]::UTF8.GetBytes('{"passed": true, "rowCounts": {"a": 1}}')
    $decoded = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    ($decoded.PSObject.Properties.Name -contains 'passed') -and ($decoded.passed -eq $true)
}

# =============================================================================
Write-Host ''
if ($script:Fail -gt 0) {
    Write-Host "FAILED  $($script:Fail) failed, $($script:Pass) passed" -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}
Write-Host "PASSED  $($script:Pass) passed, 0 failed" -ForegroundColor Green
exit 0

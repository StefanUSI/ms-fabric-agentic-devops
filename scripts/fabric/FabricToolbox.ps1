# FabricToolbox.ps1
#
# Deterministic implementations of the commands contracted in
# docs/agent-toolbox.md. Dot-source this file; it defines functions only and
# performs no action on load.
#
# CLAUDE.md rule 8: any Fabric operation performed more than once belongs here as
# parameterised, re-runnable source -- not re-improvised per session. An API
# sequence that is re-derived each time never appears in a diff, because it was
# never source.
#
# CREDENTIAL HANDLING
# Access tokens are obtained from the Azure CLI session at the moment of use and
# are never written to a file, a log, a command argument, an evidence record or a
# variable that outlives the call. No function here accepts a token, password or
# secret as a parameter. Tokens are held only in the Authorization header of the
# request being made.
#
# IDENTIFIERS
# No function resolves a workspace, folder or item by guessing, partial match or
# "the only plausible candidate". Every identifier is supplied by the caller,
# which supplies it from config/environment.local.json. Ambiguity is a hard stop
# with a non-zero exit code, never a choice.

Set-StrictMode -Version Latest

# --- Exit codes --------------------------------------------------------------
# Distinct per failure class so a caller can branch on the reason. Never 0 on
# partial success.
$script:F_EXIT_OK              = 0
$script:F_EXIT_USAGE           = 2
$script:F_EXIT_CONFIG          = 20
$script:F_EXIT_AUTH            = 21
$script:F_EXIT_TARGET          = 22   # target missing, unresolvable or ambiguous
$script:F_EXIT_ALLOWLIST       = 23   # intended target not declared
$script:F_EXIT_API             = 24
$script:F_EXIT_UNDECLARED      = 25   # inventory diff found an undeclared change
$script:F_EXIT_VERIFY          = 26   # read-back did not match intent
$script:F_EXIT_JOB             = 27   # job failed, cancelled or timed out
$script:F_EXIT_NOT_AUTHORISED  = 28   # local config does not authorise this ticket
$script:F_EXIT_SNAPSHOT        = 29   # modification attempted without a snapshot

$script:FabricApi  = 'https://api.fabric.microsoft.com/v1'
$script:OneLakeDfs = 'https://onelake.dfs.fabric.microsoft.com'

function Write-FPhase  { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-FOk     { param([string]$m) Write-Host "    OK    $m" -ForegroundColor Green }
function Write-FInfo   { param([string]$m) Write-Host "    ..    $m" -ForegroundColor Gray }
function Write-FWarn   { param([string]$m) Write-Host "    !     $m" -ForegroundColor Yellow }
function Write-FErr    { param([string]$m) Write-Host "    ERROR $m" -ForegroundColor Red }
function Write-FDryRun { param([string]$m) Write-Host "    [WHATIF] $m" -ForegroundColor Magenta }

# =============================================================================
# Configuration and authorisation
# =============================================================================

function Get-FabricLocalConfig {
    <#
        Reads config/environment.local.json -- the ONLY source of real
        identifiers. Fails loudly if absent.

        It never falls back to config/environment.json. That file holds
        placeholders, and a placeholder that silently "works" is precisely how a
        wrong target gets written to.
    #>
    param([string]$ConfigPath = 'config/environment.local.json')

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-FErr "Local environment configuration not found: $ConfigPath"
        Write-FErr 'This is a hard stop. Copy config/environment.json and fill it in.'
        Write-FErr 'The placeholder template is NEVER used as a fallback target.'
        return $null
    }

    try {
        $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ConfigPath).Path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bytes = $bytes[3..($bytes.Length - 1)]
        }
        $cfg = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    } catch {
        Write-FErr "Local environment configuration is not valid JSON: $ConfigPath"
        return $null
    }

    foreach ($required in @('workspaceId', 'authorisedTargetFolderId')) {
        if (-not $cfg.fabric.PSObject.Properties.Name.Contains($required)) {
            Write-FErr "Local configuration is missing fabric.$required"
            return $null
        }
        $value = $cfg.fabric.$required
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-FErr "Local configuration has an empty fabric.$required"
            return $null
        }
        # A placeholder left in the local file is worse than a missing one: it
        # looks configured. Reject the template shape explicitly.
        if ($value -match '^<.*>$') {
            Write-FErr "fabric.$required still holds the placeholder '$value'."
            Write-FErr 'Refusing to treat a placeholder as a deployment target.'
            return $null
        }
        if ($value -notmatch '^[0-9a-fA-F-]{36}$') {
            Write-FErr "fabric.$required is not a GUID. Identifiers are supplied, never inferred."
            return $null
        }
    }

    return $cfg
}

function Test-FabricTicketAuthorisation {
    <#
        Confirms the LOCAL configuration binds its target to THIS ticket.

        The GitHub Issue authorises deployment; the local file supplies the
        target. Both halves are required. fabric.authorisedForTicket is the field
        that ties one to the other, and it is set by a human -- an agent that set
        it would be opening its own gate, which CLAUDE.md rule 12 forbids.

        Authorisation for one ticket is never authorisation for the next.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TicketId
    )

    $recorded = $null
    if ($Config.fabric.PSObject.Properties.Name.Contains('authorisedForTicket')) {
        $recorded = $Config.fabric.authorisedForTicket
    }

    if ([string]::IsNullOrWhiteSpace($recorded)) {
        Write-FErr 'fabric.authorisedForTicket is not set in config/environment.local.json.'
        Write-FErr "Expected the string '$TicketId'."
        Write-FErr ''
        Write-FErr 'This is a HUMAN gate. The Issue authorises deployment in principle;'
        Write-FErr 'this field records that a human bound THIS local target to THIS'
        Write-FErr 'ticket. An agent may not set it -- doing so would be an agent'
        Write-FErr 'opening its own authorisation gate (CLAUDE.md rules 5, 11 and 12).'
        return $false
    }

    if ([string]$recorded -ne [string]$TicketId) {
        Write-FErr "fabric.authorisedForTicket is '$recorded' but this ticket is '$TicketId'."
        Write-FErr 'Authorisation does not carry between tickets. Stopping.'
        return $false
    }

    return $true
}

function Get-FabricAllowlist {
    param([Parameter(Mandatory)][string]$AllowlistPath)

    if (-not (Test-Path -LiteralPath $AllowlistPath)) {
        Write-FErr "Allowlist not found: $AllowlistPath"
        return $null
    }
    try {
        return (Get-Content -LiteralPath $AllowlistPath -Raw | ConvertFrom-Json)
    } catch {
        Write-FErr "Allowlist is not valid JSON: $AllowlistPath"
        return $null
    }
}

# =============================================================================
# Authentication and REST
# =============================================================================

function Get-FabricAccessToken {
    <#
        Returns an access token for the requested audience from the Azure CLI
        session.

        The token is returned to the immediate caller, used in one request, and
        never persisted. Callers must not log it, write it to evidence, or pass
        it as a command argument.

        Two audiences are used by this toolbox:
          https://api.fabric.microsoft.com  - control plane (items, jobs)
          https://storage.azure.com         - OneLake DFS (file read-back)

        The audit-file read-back deliberately uses the SECOND audience. Evidence
        retrieved with a different token, through a different endpoint, from the
        one that wrote it is a genuinely independent read rather than the same
        component agreeing with itself.
    #>
    param(
        [ValidateSet('fabric', 'storage')]
        [string]$Audience = 'fabric'
    )

    $resource = 'https://api.fabric.microsoft.com'
    if ($Audience -eq 'storage') { $resource = 'https://storage.azure.com' }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $token = & az account get-access-token --resource $resource --query accessToken -o tsv 2>$null
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }

    if ($code -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        Write-FErr "Could not obtain an access token for audience '$Audience'."
        Write-FErr 'Run: az login   (interactive, browser-based)'
        return $null
    }
    return ($token | Select-Object -First 1).Trim()
}

function Get-FHttpHeaderValue {
    <#
        Case-insensitive header lookup across several candidate names.

        Invoke-WebRequest -UseBasicParsing exposes headers as a generic
        Dictionary whose default comparer is CASE-SENSITIVE, and whose values may
        arrive as a single string or a one-element array. Indexing it directly
        with a guessed casing returns $null for a header that is present, which
        is how a long-running operation silently stops being polled.
    #>
    param($Headers, [Parameter(Mandatory)][string[]]$Names)

    if ($null -eq $Headers) { return $null }
    foreach ($name in $Names) {
        foreach ($key in $Headers.Keys) {
            if ($key -ine $name) { continue }
            $value = $Headers[$key]
            if ($value -is [array]) { $value = @($value)[0] }
            if (-not [string]::IsNullOrWhiteSpace($value)) { return [string]$value }
        }
    }
    return $null
}

function Invoke-FabricRest {
    <#
        One request against the Fabric REST API, with long-running-operation
        polling.

        A 202 is NOT success. When Fabric returns 202, this function polls the
        operation to a terminal state and returns the result, so no caller can
        mistake acceptance for completion.

        The operation URI is read from EITHER Operation-Location OR Location,
        case-insensitively. Fabric returns `Location` for item create and
        getDefinition; an earlier version of this function looked only for
        `Operation-Location`, found nothing, fell through, and returned the
        response body -- which for those calls is the literal JSON `null`.
        ConvertFrom-Json turns that into $null, which callers could not tell
        apart from the error return. The result was an item that WAS created
        asynchronously being reported as a failure, with no message. A 202 whose
        operation URI cannot be found is now a loud error, never a pass.

        This function never returns a bare $null on a successful response.
        Success with an empty or `null` body returns a small object, so $null
        means one thing only: the request failed.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body = $null,
        [int]$TimeoutSeconds = 900
    )

    $token = Get-FabricAccessToken -Audience 'fabric'
    if (-not $token) { return $null }

    $uri = $Path
    if ($Path -notmatch '^https?://') { $uri = "$script:FabricApi/$($Path.TrimStart('/'))" }

    $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $json = $null
    if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Depth 40 -Compress) }

    try {
        $response = Invoke-WebRequest -Uri $uri -Method $Method -Headers $headers `
            -Body $json -UseBasicParsing -ErrorAction Stop
    } catch {
        $status = ''
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        # The message is surfaced; the request headers (which carry the token)
        # deliberately are not.
        Write-FErr "Fabric API $Method $Path failed (HTTP $status): $($_.Exception.Message)"
        return $null
    }

    if ($response.StatusCode -eq 202) {
        $operationUri = Get-FHttpHeaderValue -Headers $response.Headers `
            -Names @('Operation-Location', 'Location')
        if ([string]::IsNullOrWhiteSpace($operationUri)) {
            Write-FErr "Fabric API $Method $Path returned 202 with no operation URI to poll."
            Write-FErr 'Acceptance without a pollable operation cannot be verified. Treating as FAILED.'
            return $null
        }
        return (Wait-FabricOperation -OperationUri $operationUri -TimeoutSeconds $TimeoutSeconds)
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return [pscustomobject]@{ statusCode = [int]$response.StatusCode; body = 'empty' }
    }
    try {
        $parsed = ($response.Content | ConvertFrom-Json)
    } catch {
        return [pscustomobject]@{ statusCode = [int]$response.StatusCode; raw = $response.Content }
    }
    # ConvertFrom-Json returns $null for the literal body `null`. Returning that
    # verbatim would make a successful response indistinguishable from a failed
    # one at every call site.
    if ($null -eq $parsed) {
        return [pscustomobject]@{ statusCode = [int]$response.StatusCode; body = 'null' }
    }
    return $parsed
}

function Wait-FabricOperation {
    <#
        Polls a Fabric long-running operation to a terminal state.

        A timeout returns $null and is reported as a timeout. It is never
        reported as success -- "we stopped waiting" and "it worked" are different
        outcomes and the difference is the whole point of this function.
    #>
    param(
        [Parameter(Mandatory)][string]$OperationUri,
        [int]$TimeoutSeconds = 900,
        [int]$PollIntervalSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds

        $token = Get-FabricAccessToken -Audience 'fabric'
        if (-not $token) { return $null }
        try {
            $poll = Invoke-RestMethod -Uri $OperationUri -Method GET `
                -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
        } catch {
            Write-FErr "Operation poll failed: $($_.Exception.Message)"
            return $null
        }

        # Under Set-StrictMode, reading a property the response does not carry is
        # a terminating error. An operation payload without a status is a
        # protocol surprise worth reporting, not worth crashing on.
        $status = $null
        if ($null -ne $poll -and $poll.PSObject.Properties.Name -contains 'status') {
            $status = $poll.status
        }
        if ($null -eq $status) {
            Write-FErr 'Operation poll returned no status field. Cannot confirm completion.'
            return $null
        }

        switch ($status) {
            'Succeeded' {
                # The operation result lives at a separate URI for most item
                # operations. Absence of a result body is normal, not an error.
                $resultUri = "$($OperationUri.TrimEnd('/'))/result"
                try {
                    return (Invoke-RestMethod -Uri $resultUri -Method GET `
                        -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop)
                } catch { return $poll }
            }
            'Failed' {
                Write-FErr "Operation failed: $($poll | ConvertTo-Json -Depth 6 -Compress)"
                return $null
            }
            'Undefined' {
                Write-FErr 'Operation reported an Undefined status.'
                return $null
            }
        }
    }

    Write-FErr "Operation did not reach a terminal state within $TimeoutSeconds seconds."
    Write-FErr 'Reporting a timeout. This is NOT a success.'
    return $null
}

# =============================================================================
# 2. Get-FabricFolderInventory
# =============================================================================

function Get-FabricFolderInventory {
    <#
        Captures every item in the target folder, keyed on NAME AND TYPE.

        Name alone is not a key. A Lakehouse, its SQL analytics endpoint and its
        default semantic model all share one display name, so a name-keyed
        inventory collapses three items into one and makes two of them invisible
        to the later diff.

        Never returns a partial inventory as if it were complete: a paging
        failure returns $null, because a truncated baseline makes every
        subsequent diff lie in the direction of "nothing happened".
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$FolderId,
        [string]$OutputPath
    )

    $items = @()
    $path = "workspaces/$WorkspaceId/items"
    $guard = 0

    while ($path -and $guard -lt 100) {
        $guard++
        $page = Invoke-FabricRest -Method GET -Path $path
        if ($null -eq $page) {
            Write-FErr 'Folder inventory could not be enumerated. Refusing to return a partial baseline.'
            return $null
        }
        if ($page.PSObject.Properties.Name -contains 'value') { $items += @($page.value) }

        $path = $null
        if ($page.PSObject.Properties.Name -contains 'continuationUri' -and $page.continuationUri) {
            $path = $page.continuationUri
        }
    }

    $inFolder = @($items | Where-Object {
        $_.PSObject.Properties.Name -contains 'folderId' -and $_.folderId -eq $FolderId
    })

    $inventory = @($inFolder | ForEach-Object {
        [pscustomobject]@{
            itemName        = $_.displayName
            itemId          = $_.id
            itemType        = $_.type
            # The Items API returns no definition hash. Recording the literal
            # string rather than a fabricated value keeps open decision 6 in
            # docs/environment-and-constraints.md visible instead of papering
            # over it: additions and removals are detectable, in-place
            # modifications are not.
            definitionHash  = 'not-captured'
            lastModifiedUtc = $null
        }
    } | Sort-Object itemType, itemName)

    if ($OutputPath) {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        # An empty inventory must serialise to "[]", not to nothing. ConvertTo-Json
        # of an empty array writes a zero-byte file, and a zero-byte file cannot
        # be told apart from a write that failed -- which is exactly the
        # ambiguity a baseline must not have.
        # Windows PowerShell 5.1 has no -AsArray, and it unwraps a single-element
        # array into a bare JSON object. Both shapes are forced to a real array
        # here so the file is always a list, whatever it holds.
        $json = '[]'
        if ($inventory.Count -eq 1) {
            $json = "[$($inventory[0] | ConvertTo-Json -Depth 8)]"
        } elseif ($inventory.Count -gt 1) {
            $json = ($inventory | ConvertTo-Json -Depth 8)
        }
        $json | Out-File -LiteralPath $OutputPath -Encoding utf8
    }

    # Comma operator: an inventory of exactly one item would otherwise unroll to
    # a bare object and a caller's .Count would fail. A folder holding one item
    # is a completely ordinary baseline state.
    return ,@($inventory)
}

# =============================================================================
# 3. Compare-FabricFolderInventory
# =============================================================================

function Compare-FabricFolderInventory {
    <#
        Diffs a post-deployment inventory against the baseline and classifies
        every change as declared or undeclared.

        With no Git sync-back, this is the ONLY mechanism that detects a change
        made outside the repository. Any undeclared entry is a defect, not a
        note, and the caller is expected to exit non-zero on one.

        Both the allowlist items and the documented auto-generated companions
        count as declared. A companion is a platform side effect of creating a
        Lakehouse -- declaring it distinguishes "documented and expected" from
        "nobody knows where this came from", which is the distinction the diff
        exists to draw.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Baseline,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Current,
        [Parameter(Mandatory)]$Allowlist
    )

    function Get-Key { param($e) return "$($e.itemType)/$($e.itemName)" }

    $baselineKeys = @{}
    foreach ($e in $Baseline) { $baselineKeys[(Get-Key $e)] = $e }
    $currentKeys = @{}
    foreach ($e in $Current) { $currentKeys[(Get-Key $e)] = $e }

    $declared = @{}
    foreach ($i in $Allowlist.items) { $declared["$($i.itemType)/$($i.name)"] = 'allowlist' }
    foreach ($c in $Allowlist.expectedAutoGeneratedCompanions) {
        $declared["$($c.itemType)/$($c.name)"] = 'companion'
    }

    $added = @($currentKeys.Keys | Where-Object { -not $baselineKeys.ContainsKey($_) } | Sort-Object)
    $removed = @($baselineKeys.Keys | Where-Object { -not $currentKeys.ContainsKey($_) } | Sort-Object)

    $undeclared = @()
    foreach ($k in $added) {
        if (-not $declared.ContainsKey($k)) { $undeclared += "added, not declared: $k" }
    }
    # A removal is ALWAYS undeclared. Nothing in this ticket may delete an item,
    # so a disappearance is either someone else's action or a rule violation --
    # and both need a human, not a classification.
    foreach ($k in $removed) { $undeclared += "removed (deletion is never authorised): $k" }

    return [pscustomobject]@{
        added             = $added
        modified          = @()   # see definitionHash note in Get-FabricFolderInventory
        removed           = $removed
        undeclaredChanges = @($undeclared)
    }
}

# =============================================================================
# 5. Test-DeploymentAllowlist
# =============================================================================

function Test-DeploymentAllowlist {
    <#
        Confirms every intended item and data path is declared, and that every
        item carries the ticket prefix.

        The data-path half is not decoration. Items live in folders; Lakehouse
        tables do not. An item-only allowlist can come back perfectly clean while
        somebody else's Gold tables are being overwritten.
    #>
    param(
        [Parameter(Mandatory)]$Allowlist,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$IntendedItems,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$IntendedDataPaths
    )

    $prefix = $Allowlist.requiredItemPrefix
    $declaredItems = @{}
    foreach ($i in $Allowlist.items) { $declaredItems["$($i.itemType)/$($i.name)"] = $i }

    $itemResults = @()
    foreach ($intended in $IntendedItems) {
        $key = "$($intended.itemType)/$($intended.name)"
        $itemResults += [pscustomobject]@{
            name           = $intended.name
            itemType       = $intended.itemType
            declared       = $declaredItems.ContainsKey($key)
            hasIssuePrefix = ($intended.name -like "$prefix*")
        }
    }

    $pathResults = @()
    foreach ($intended in $IntendedDataPaths) {
        $isDeclared = $false
        foreach ($d in $Allowlist.dataPaths) {
            if ($d.access -ne $intended.access) { continue }
            # A trailing ** is a prefix wildcard; anything else must match whole.
            if ($d.path.EndsWith('/**')) {
                $stem = $d.path.Substring(0, $d.path.Length - 2)
                if ($intended.path.StartsWith($stem)) { $isDeclared = $true; break }
            } elseif ($d.path -eq $intended.path) { $isDeclared = $true; break }
        }
        $pathResults += [pscustomobject]@{
            path     = $intended.path
            declared = $isDeclared
            access   = $intended.access
        }
    }

    $allDeclared = -not (
        @($itemResults | Where-Object { -not $_.declared -or -not $_.hasIssuePrefix }).Count -or
        @($pathResults | Where-Object { -not $_.declared }).Count
    )

    return [pscustomobject]@{
        items       = @($itemResults)
        dataPaths   = @($pathResults)
        allDeclared = [bool]$allDeclared
    }
}

# =============================================================================
# 4. Save-FabricItemSnapshot
# =============================================================================

function Save-FabricItemSnapshot {
    <#
        Captures an item's current definition BEFORE it is modified.

        No snapshot, no modification. A reversal plan for a change whose prior
        state was never captured is a wish, not a plan.

        This ticket creates only and therefore takes no snapshots. The function
        exists so that the create-only claim is enforced by a code path rather
        than by an intention: Publish-FabricItemDefinition refuses to update an
        existing item unless a snapshot was taken first.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$ItemName,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $definition = Invoke-FabricRest -Method POST -Path "workspaces/$WorkspaceId/items/$ItemId/getDefinition"
    if ($null -eq $definition) {
        Write-FErr "Could not retrieve the definition of '$ItemName'. Deployment must not proceed."
        return $null
    }

    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $body = ($definition | ConvertTo-Json -Depth 40)
    $body | Out-File -LiteralPath $OutputPath -Encoding utf8

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($body)) |
            ForEach-Object { $_.ToString('x2') }) -join ''
    } finally { $sha.Dispose() }

    return [pscustomobject]@{
        itemName       = $ItemName
        itemId         = $ItemId
        capturedUtc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        definitionHash = $hash
        snapshotPath   = $OutputPath
    }
}

# =============================================================================
# 6. Publish-FabricItemDefinition
# =============================================================================

function Get-FabricItemByName {
    <#
        Finds an item by exact display name AND type within one workspace.

        Two matches is a HARD STOP, never a "pick the first". Display names are
        unique per workspace in principle, so a duplicate means something is not
        what it appears to be, and guessing which one the ticket meant is exactly
        the inference CLAUDE.md rule 6 forbids.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$ItemType
    )

    $page = Invoke-FabricRest -Method GET -Path "workspaces/$WorkspaceId/items"
    if ($null -eq $page) { return 'ERROR' }

    $matches = @()
    if ($page.PSObject.Properties.Name -contains 'value') {
        $matches = @($page.value | Where-Object {
            $_.displayName -eq $DisplayName -and $_.type -eq $ItemType
        })
    }

    if ($matches.Count -gt 1) {
        Write-FErr "Ambiguous: $($matches.Count) items named '$DisplayName' of type '$ItemType'."
        Write-FErr 'Stopping. An ambiguous identifier is never resolved by choosing one.'
        return 'AMBIGUOUS'
    }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function New-FabricDefinitionPart {
    param(
        [Parameter(Mandatory)][string]$LogicalPath,
        [Parameter(Mandatory)][string]$Content
    )
    return @{
        path        = $LogicalPath
        payload     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))
        payloadType = 'InlineBase64'
    }
}

function Publish-FabricItemDefinition {
    <#
        Creates an item from a repository definition, inside the target folder.

        Refuses, rather than proceeding, when:
          * the display name lacks the ticket prefix
          * the item already exists and -AllowUpdate was not given with a snapshot
          * the read-back does not confirm the item exists afterwards

        The read-back is not ceremony. A create call that returns 201 has been
        accepted; re-reading the item by id is what establishes that it exists.

        RESUMING AN INTERRUPTED DEPLOYMENT
        -PreDeploymentKeys carries the set of "type/name" keys that existed in
        the target folder BEFORE this ticket wrote anything, and -ResumePartial
        opts in to converging items that this ticket's own earlier run created.

        The distinction is the whole point, and it is decided by data rather than
        by intent: an item whose key IS in the pre-deployment baseline belongs to
        somebody else and is refused exactly as before, needing -AllowUpdate and
        a snapshot. An item whose key is NOT in that baseline did not exist until
        this ticket created it, so completing its definition finishes an
        interrupted create rather than overwriting anyone's work.

        Without this, a deployment that failed halfway could never be resumed:
        the create-only guard would refuse the items the ticket itself had just
        made, and the only route forward would be deletion -- which is a human
        action and is never automatic. It also makes the function behave as
        docs/agent-toolbox.md 6 already documents it, namely idempotent on
        republication.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$FolderId,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$ItemType,
        [string]$Description = '',
        [array]$Parts = @(),
        [Parameter(Mandatory)][string]$RequiredPrefix,
        [switch]$AllowUpdate,
        $Snapshot = $null,
        [string[]]$PreDeploymentKeys = @(),
        [switch]$ResumePartial,
        [switch]$WhatIf
    )

    if ($DisplayName -notlike "$RequiredPrefix*") {
        Write-FErr "'$DisplayName' lacks the required prefix '$RequiredPrefix'. Refusing."
        Write-FErr 'Names are unique per WORKSPACE, so the prefix is the collision control.'
        return $null
    }

    # -WhatIf returns BEFORE any API call, so a plan is fully offline: no token,
    # no network, no Fabric read. That is what lets a reviewer run the plan from
    # a cold checkout without Fabric access.
    #
    # It deliberately does NOT pre-check for an existing item. Such a check would
    # be stale by the time the deployment ran, and would invite treating "the
    # plan said it was clear" as permission to overwrite. The real control is the
    # createOnly guard below, which runs at the moment of the write.
    if ($WhatIf) {
        Write-FDryRun "CREATE $ItemType '$DisplayName' ($($Parts.Count) definition part(s)); collision checked at write time"
        return [pscustomobject]@{
            itemName = $DisplayName; itemType = $ItemType; itemId = $null
            created = $false; whatIf = $true
        }
    }

    $existing = Get-FabricItemByName -WorkspaceId $WorkspaceId -DisplayName $DisplayName -ItemType $ItemType
    if ($existing -eq 'AMBIGUOUS' -or $existing -eq 'ERROR') { return $null }

    $resumed = $false
    if ($null -ne $existing) {
        $preExisted = ($PreDeploymentKeys -contains "$ItemType/$DisplayName")

        if ($preExisted) {
            # Present before this ticket touched anything: somebody else's item.
            if (-not $AllowUpdate) {
                Write-FErr "'$DisplayName' ($ItemType) already exists and createOnly is set."
                Write-FErr 'Refusing to overwrite an item this ticket did not create.'
                return $null
            }
            if ($null -eq $Snapshot) {
                Write-FErr "Refusing to modify '$DisplayName' without a prior definition snapshot."
                return $null
            }
        } elseif ($ResumePartial) {
            $resumed = $true
            Write-FWarn "'$DisplayName' exists but was absent from the pre-deployment baseline."
            Write-FWarn 'Completing this ticket''s own interrupted create rather than overwriting.'
        } else {
            Write-FErr "'$DisplayName' ($ItemType) already exists and createOnly is set."
            Write-FErr 'It is absent from the pre-deployment baseline, so a previous run of this'
            Write-FErr 'ticket created it. Re-run with -Resume to converge it, or have a human'
            Write-FErr 'delete it. This command never deletes.'
            return $null
        }
    }

    if ($null -eq $existing) {
        $body = @{ displayName = $DisplayName; type = $ItemType; folderId = $FolderId }
        if ($Description) { $body['description'] = $Description }
        if ($Parts.Count -gt 0) { $body['definition'] = @{ parts = $Parts } }

        $created = Invoke-FabricRest -Method POST -Path "workspaces/$WorkspaceId/items" -Body $body
        if ($null -eq $created) { return $null }

        $itemId = $null
        if ($created.PSObject.Properties.Name -contains 'id') { $itemId = $created.id }

        if ([string]::IsNullOrWhiteSpace($itemId)) {
            # A create that completed through a long-running operation does not
            # always carry the item in its result payload. Re-resolving by exact
            # display name AND type inside the supplied workspace is a read-back,
            # not an inference: it matches exactly, and Get-FabricItemByName is a
            # hard stop on ambiguity rather than a chooser.
            Write-FInfo "Create returned no item id for '$DisplayName'; resolving by name and type."
            $resolved = Get-FabricItemByName -WorkspaceId $WorkspaceId -DisplayName $DisplayName -ItemType $ItemType
            if ($resolved -eq 'AMBIGUOUS' -or $resolved -eq 'ERROR' -or $null -eq $resolved) {
                Write-FErr "'$DisplayName' was accepted but could not be resolved afterwards."
                return $null
            }
            $itemId = $resolved.id
        }
    } else {
        $itemId = $existing.id
        if ($Parts.Count -gt 0) {
            $body = @{ definition = @{ parts = $Parts } }
            $updated = Invoke-FabricRest -Method POST `
                -Path "workspaces/$WorkspaceId/items/$itemId/updateDefinition?updateMetadata=True" -Body $body
            if ($null -eq $updated) { return $null }
        } else {
            # A Lakehouse carries no deployable definition parts. There is
            # nothing to converge, and posting an empty definition would be a
            # write with no content rather than a no-op.
            Write-FInfo "'$DisplayName' has no definition parts; nothing to converge."
        }
    }

    # --- Read-back. Acceptance is not verification. ---
    if ([string]::IsNullOrWhiteSpace($itemId)) {
        Write-FErr "'$DisplayName' was accepted but no item id was returned. Cannot verify."
        return $null
    }
    $readBack = Invoke-FabricRest -Method GET -Path "workspaces/$WorkspaceId/items/$itemId"
    if ($null -eq $readBack) {
        Write-FErr "'$DisplayName' was accepted but could not be read back. Treating as FAILED."
        return $null
    }
    if ($readBack.displayName -ne $DisplayName) {
        Write-FErr "Read-back mismatch: expected '$DisplayName', found '$($readBack.displayName)'."
        return $null
    }
    if ($readBack.PSObject.Properties.Name -contains 'folderId' -and $readBack.folderId -ne $FolderId) {
        Write-FErr "'$DisplayName' landed in folder '$($readBack.folderId)', not the authorised '$FolderId'."
        return $null
    }

    # For an item that carries definition parts, existence is not enough: the
    # parts are the thing that was deployed. Reading the definition back is what
    # separates "an item with this name exists" from "the code in this repository
    # is what is now in Fabric".
    $definitionPartCount = $null
    if ($Parts.Count -gt 0) {
        $definition = Invoke-FabricRest -Method POST -Path "workspaces/$WorkspaceId/items/$itemId/getDefinition"
        if ($null -eq $definition) {
            Write-FErr "'$DisplayName' exists but its definition could not be read back. Treating as FAILED."
            return $null
        }
        $returnedPaths = @()
        if ($definition.PSObject.Properties.Name -contains 'definition' -and
            $definition.definition.PSObject.Properties.Name -contains 'parts') {
            $returnedPaths = @($definition.definition.parts | ForEach-Object { $_.path })
        }
        $definitionPartCount = $returnedPaths.Count
        foreach ($expectedPath in @($Parts | ForEach-Object { $_.path })) {
            if ($returnedPaths -notcontains $expectedPath) {
                Write-FErr "'$DisplayName' is missing definition part '$expectedPath' after deployment."
                return $null
            }
        }
    }

    $verb = if ($resumed) { 'converged' } else { 'verified' }
    Write-FOk "$ItemType '$DisplayName' $verb by read-back (id $itemId, $definitionPartCount part(s))"
    return [pscustomobject]@{
        itemName            = $DisplayName
        itemType            = $ItemType
        itemId              = $itemId
        created             = ($null -eq $existing)
        resumed             = $resumed
        definitionPartCount = $definitionPartCount
        whatIf              = $false
    }
}

# =============================================================================
# 7 / 8. Invoke-FabricPipeline and Wait-FabricJob
# =============================================================================

function Invoke-FabricPipeline {
    <#
        Starts ONE pipeline run and returns its run id.

        Not idempotent: every call is a distinct run. Never retry blindly on a
        timeout -- poll the run id that was already issued, or a "retry" silently
        starts a second concurrent job on a shared, modest capacity.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$PipelineId,
        [hashtable]$Parameters = @{},
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-FDryRun "RUN pipeline $PipelineId with parameters: $($Parameters.Keys -join ', ')"
        return $null
    }

    $token = Get-FabricAccessToken -Audience 'fabric'
    if (-not $token) { return $null }

    $uri = "$script:FabricApi/workspaces/$WorkspaceId/items/$PipelineId/jobs/instances?jobType=Pipeline"
    $body = (@{ executionData = @{ parameters = $Parameters } } | ConvertTo-Json -Depth 10 -Compress)

    try {
        $response = Invoke-WebRequest -Uri $uri -Method POST -Body $body -UseBasicParsing `
            -Headers @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' } -ErrorAction Stop
    } catch {
        Write-FErr "Pipeline run could not be submitted: $($_.Exception.Message)"
        return $null
    }

    $location = $response.Headers['Location']
    if ([string]::IsNullOrWhiteSpace($location)) {
        Write-FErr 'Pipeline run was accepted but returned no Location header; no run id to poll.'
        return $null
    }
    $runId = ($location -split '/')[-1]

    Write-FInfo "Pipeline run submitted: $runId (submission is not success)"
    return [pscustomobject]@{
        runId        = $runId
        submittedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

function Wait-FabricJob {
    <#
        Polls a job instance to a terminal state and reports the REAL outcome.

        A timeout returns TimedOut, never Succeeded. The whole reason this
        function exists is that a caller must not be able to confuse "I gave up
        waiting" with "it finished".
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$JobInstanceId,
        [int]$TimeoutSeconds = 3600,
        [int]$PollIntervalSeconds = 20
    )

    $terminal = @('Completed', 'Failed', 'Cancelled', 'Deduped')
    $started = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $job = Invoke-FabricRest -Method GET `
            -Path "workspaces/$WorkspaceId/items/$ItemId/jobs/instances/$JobInstanceId"

        if ($null -ne $job -and $job.PSObject.Properties.Name -contains 'status') {
            if ($terminal -contains $job.status) {
                $status = 'Failed'
                if ($job.status -eq 'Completed') { $status = 'Succeeded' }
                elseif ($job.status -eq 'Cancelled') { $status = 'Cancelled' }

                $detail = $null
                if ($job.PSObject.Properties.Name -contains 'failureReason' -and $job.failureReason) {
                    $detail = ($job.failureReason | ConvertTo-Json -Depth 6 -Compress)
                }

                return [pscustomobject]@{
                    runId              = $JobInstanceId
                    terminalStatus     = $status
                    submittedUtc       = $job.startTimeUtc
                    completedUtc       = $job.endTimeUtc
                    durationSeconds    = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
                    verifiedByReadBack = $true
                    failureDetail      = $detail
                }
            }
            Write-FInfo "job $JobInstanceId : $($job.status)"
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    Write-FErr "Job $JobInstanceId did not reach a terminal state within $TimeoutSeconds seconds."
    return [pscustomobject]@{
        runId              = $JobInstanceId
        terminalStatus     = 'TimedOut'
        submittedUtc       = $null
        completedUtc       = $null
        durationSeconds    = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        verifiedByReadBack = $true
        failureDetail      = 'Polling deadline exceeded. Outcome unknown; NOT a success.'
    }
}

# =============================================================================
# 9. Test-FabricTableResult -- via the OneLake audit file
# =============================================================================

function Get-OneLakeFile {
    <#
        Reads a file from OneLake over the DFS endpoint.

        This is the resolution of open decision 1 in
        docs/environment-and-constraints.md. It needs no ODBC driver and no
        semantic model, and -- critically -- it uses the STORAGE token audience,
        so the evidence is retrieved by a different path than the one that wrote
        it. A read-back through the same component that produced the value only
        proves that component is self-consistent.
    #>
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$LakehouseId,
        [Parameter(Mandatory)][string]$RelativePath   # e.g. Files/issue2/evidence/x.json
    )

    $token = Get-FabricAccessToken -Audience 'storage'
    if (-not $token) { return $null }

    $uri = "$script:OneLakeDfs/$WorkspaceId/$LakehouseId/$($RelativePath.TrimStart('/'))"
    try {
        $response = Invoke-WebRequest -Uri $uri -Method GET -UseBasicParsing -ErrorAction Stop `
            -Headers @{ Authorization = "Bearer $token"; 'x-ms-version' = '2021-06-08' }
    } catch {
        Write-FErr "OneLake read failed for '$RelativePath': $($_.Exception.Message)"
        return $null
    }
    # OneLake answers with application/octet-stream, and Windows PowerShell hands
    # back .Content as a byte[] for a non-text content type. A byte[] survives
    # everything that looks like a success: .Length reports the payload size, so
    # the log line is right; Out-File writes one decimal per line; and piping it
    # to ConvertFrom-Json feeds bytes in one at a time. The failure only surfaces
    # much later, as a missing property on the parsed audit. Decode here so the
    # function's contract is "returns the file's text" rather than "returns
    # whatever Invoke-WebRequest chose this time".
    $content = $response.Content
    if ($content -is [byte[]]) {
        $bytes = $content
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bytes = $bytes[3..($bytes.Length - 1)]
        }
        $content = [Text.Encoding]::UTF8.GetString($bytes)
    }
    return $content
}

function Test-Issue2AuditFile {
    <#
        Asserts a retrieved audit file against the data contract.

        Every expected value comes from src/issue2-retail-medallion/data-contract.json,
        which is committed BEFORE the run. Nothing is compared against a value
        the run produced -- a self-derived expectation makes every run pass, and
        this function would then assert nothing while appearing to assert
        everything.

        Returns a list of failure strings. Empty means pass.

        The result is returned with the comma operator. Windows PowerShell
        unrolls a returned collection onto the pipeline, so an empty or
        single-element result would reach the caller as $null or as a bare
        string -- and `.Count` on either is a hard error under Set-StrictMode.
        A guard that throws instead of returning "no failures" is a guard that
        cannot be relied on to report success.
    #>
    param(
        [Parameter(Mandatory)]$Audit,
        [Parameter(Mandatory)]$Contract
    )

    $failures = @()
    $expected = $Contract.expected

    if (-not $Audit.passed) {
        foreach ($f in @($Audit.failures)) { $failures += "notebook assertion: $f" }
    }

    # Row counts, re-asserted here against the contract rather than trusting the
    # notebook's own verdict. The notebook could have been deployed from a
    # different definition than the one in this repository; comparing its output
    # to the repository's contract is what would catch that.
    foreach ($layer in @('bronze', 'silver', 'gold')) {
        foreach ($p in $expected.$layer.PSObject.Properties) {
            if ($p.Name.StartsWith('$')) { continue }
            $observed = $null
            if ($Audit.rowCounts.PSObject.Properties.Name -contains $p.Name) {
                $observed = $Audit.rowCounts.($p.Name)
            }
            if ($observed -ne $p.Value) {
                $failures += "$($p.Name): audit reports $observed, contract expects $($p.Value)"
            }
        }
    }

    foreach ($p in $expected.quarantineByReason.PSObject.Properties) {
        if ($p.Name.StartsWith('$')) { continue }
        $observed = 0
        if ($Audit.quarantineByReason.PSObject.Properties.Name -contains $p.Name) {
            $observed = $Audit.quarantineByReason.($p.Name)
        }
        if ($observed -ne $p.Value) {
            $failures += "quarantine[$($p.Name)]: audit reports $observed, contract expects $($p.Value)"
        }
    }

    $rc = $Audit.rowConservation
    if (-not $rc.holds) { $failures += 'row conservation does not hold in the audit file' }
    if ($rc.bronzeSales -ne ($rc.silverSales + $rc.quarantined + $rc.duplicatesRemoved)) {
        $failures += "row conservation arithmetic fails: $($rc.bronzeSales) != $($rc.silverSales) + $($rc.quarantined) + $($rc.duplicatesRemoved)"
    }
    if ($rc.duplicatesRemoved -ne $expected.duplicatesRemoved) {
        $failures += "duplicatesRemoved: audit reports $($rc.duplicatesRemoved), contract expects $($expected.duplicatesRemoved)"
    }

    if (-not $Audit.financialReconciliation.withinTolerance) {
        $failures += "financial reconciliation outside tolerance: max delta $($Audit.financialReconciliation.maxAbsoluteDelta)"
    }
    if ($Audit.financialReconciliation.tolerance -ne $expected.financialToleranceAbsolute) {
        $failures += 'financial tolerance in the audit file does not match the contract'
    }

    foreach ($p in $expected.primaryKeys.PSObject.Properties) {
        if ($p.Name.StartsWith('$')) { continue }
        if ($Audit.primaryKeys.PSObject.Properties.Name -notcontains $p.Name) {
            $failures += "primary key for $($p.Name) was not asserted in the audit file"
            continue
        }
        $pk = $Audit.primaryKeys.($p.Name)
        if ($pk.rows -ne $pk.distinctKeys) {
            $failures += "$($p.Name): key not unique ($($pk.rows) rows, $($pk.distinctKeys) keys)"
        }
        if ($pk.nullKeyRows -ne 0) {
            $failures += "$($p.Name): $($pk.nullKeyRows) rows have a NULL key column"
        }
    }

    return ,@($failures)
}

# =============================================================================
# 10. New-ReversalPlan
# =============================================================================

function New-ReversalPlan {
    <#
        Writes the exact steps to undo a deployment, BEFORE it happens.

        Never executes anything. Deletion and restoration are human actions, and
        an agent that could execute its own reversal plan could also execute it
        by mistake.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$IntendedItems,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$DataPaths,
        [array]$Snapshots = @(),
        [Parameter(Mandatory)][string]$OutputPath
    )

    $lines = @()
    $lines += '# Reversal plan - GitHub Issue #2'
    $lines += ''
    $lines += "Generated $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) BEFORE any write."
    $lines += ''
    $lines += '**No step below is executed by an agent.** Cleanup is a human action'
    $lines += '(CLAUDE.md rule 5 and the compensating controls in'
    $lines += 'docs/environment-and-constraints.md). This file exists so that the'
    $lines += 'decision to reverse is a decision, not an improvisation.'
    $lines += ''
    $lines += '## What this ticket creates'
    $lines += ''
    $lines += 'Every item is NEW and prefixed `issue2_`. Nothing pre-existing is'
    $lines += 'modified, so reversal is deletion of newly created items rather than'
    $lines += 'restoration of prior definitions.'
    $lines += ''
    $lines += '| # | Item | Type | Reversal |'
    $lines += '|---|---|---|---|'
    $n = 0
    foreach ($i in $IntendedItems) {
        $n++
        $lines += "| $n | ``$($i.name)`` | $($i.itemType) | Delete the item (human, via the Fabric portal) |"
    }
    $lines += ''
    $lines += '## Order'
    $lines += ''
    $lines += 'Delete the pipeline first, then the notebooks, then the Lakehouse last.'
    $lines += 'The Lakehouse holds every table and file, so deleting it first would'
    $lines += 'strand the other items against a target that no longer exists and'
    $lines += 'discard the evidence files before they could be retrieved.'
    $lines += ''
    $lines += '## Data'
    $lines += ''
    $lines += 'All data written by this ticket lives inside `issue2_retail_lakehouse`,'
    $lines += 'which this ticket creates. Deleting that Lakehouse removes every table'
    $lines += 'and file listed below in one action. No path outside it was written,'
    $lines += 'so no other data needs to be considered.'
    $lines += ''
    foreach ($p in $DataPaths) { $lines += "- ``$($p.path)`` ($($p.access))" }
    $lines += ''
    $lines += '## Auto-generated companions'
    $lines += ''
    $lines += 'The SQL analytics endpoint and the default semantic model are created'
    $lines += 'by the platform alongside the Lakehouse. They are removed with it and'
    $lines += 'need no separate step.'
    $lines += ''
    $lines += '## Snapshots'
    $lines += ''
    if ($Snapshots.Count -eq 0) {
        $lines += 'None, and none required: no existing item is modified. Were that to'
        $lines += 'change, `Publish-FabricItemDefinition` refuses to update an item'
        $lines += 'without a snapshot, so this section cannot silently become wrong.'
    } else {
        foreach ($s in $Snapshots) { $lines += "- ``$($s.itemName)`` -> ``$($s.snapshotPath)`` (sha256 $($s.definitionHash))" }
    }
    $lines += ''
    $lines += '## Repository'
    $lines += ''
    $lines += '1. Close the pull request without merging.'
    $lines += '2. Delete the feature branch (human).'
    $lines += ''
    $lines += '## Irreversible steps'
    $lines += ''
    $lines += 'None. Every Fabric object is newly created by this ticket, and every'
    $lines += 'repository change is confined to an unmerged feature branch.'
    $lines += ''
    $lines += '**Data-loss risk: none.** All data is synthetic, deterministic and'
    $lines += 'regenerable from `data-contract.json` by re-running the pipeline.'

    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    ($lines -join "`r`n") | Out-File -LiteralPath $OutputPath -Encoding utf8
    return $OutputPath
}

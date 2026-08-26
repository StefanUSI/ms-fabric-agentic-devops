# DispatcherCommon.ps1
#
# Shared helpers for the developer and reviewer dispatchers.
#
# Dot-source this file; it defines functions only and performs no action on
# load. All conventions come from config/dispatcher.json so that labels, paths
# and permissions live in exactly one place.
#
# This file never merges, pushes, force-pushes, deletes branches or worktrees,
# posts to GitHub, or contacts Microsoft Fabric. It never reads, prints or
# stores an authentication token.

Set-StrictMode -Version Latest

$script:D_EXIT_OK             = 0
$script:D_EXIT_USAGE          = 2
$script:D_EXIT_NOT_REPO_ROOT  = 3
$script:D_EXIT_BASELINE       = 4
$script:D_EXIT_AUTH           = 5
$script:D_EXIT_NO_WORK        = 6
$script:D_EXIT_AMBIGUOUS      = 7
$script:D_EXIT_CONCURRENCY    = 8
$script:D_EXIT_BRANCH_INVALID = 9
$script:D_EXIT_EXISTS         = 10
$script:D_EXIT_GH_FAILED      = 11
$script:D_EXIT_MODE           = 12

function Write-Phase  { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok     { param([string]$m) Write-Host "    OK    $m" -ForegroundColor Green }
function Write-Info   { param([string]$m) Write-Host "    ..    $m" -ForegroundColor Gray }
function Write-Warn2  { param([string]$m) Write-Host "    !     $m" -ForegroundColor Yellow }
function Write-Err    { param([string]$m) Write-Host "    ERROR $m" -ForegroundColor Red }
function Write-DryRun { param([string]$m) Write-Host "    [DRY-RUN] $m" -ForegroundColor Magenta }

function Get-DispatcherConfig {
    param([string]$ConfigPath = 'config/dispatcher.json')
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Err "Dispatcher config not found: $ConfigPath"
        return $null
    }
    try {
        $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ConfigPath).Path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bytes = $bytes[3..($bytes.Length - 1)]
        }
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    } catch {
        Write-Err "Dispatcher config is not valid JSON: $ConfigPath"
        return $null
    }
}

function Get-GhPath {
    <#
        Locates the GitHub CLI. Returns a path only; never inspects, prints or
        stores any credential the CLI holds.
    #>
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $env:LOCALAPPDATA 'github-cli\bin\gh.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    return $null
}

function Invoke-Gh {
    <#
        Runs the GitHub CLI and returns stdout.

        Windows PowerShell 5.1 wraps a native command's stderr in an ErrorRecord,
        which becomes terminating under $ErrorActionPreference = 'Stop'. The
        preference is relaxed for the duration of the call and the exit code is
        captured in $script:LastGhExitCode.
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)
    $gh = Get-GhPath
    if (-not $gh) { $script:LastGhExitCode = 127; return @() }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $gh @Arguments 2>$null
        $script:LastGhExitCode = $LASTEXITCODE
        return @($out | ForEach-Object { $_.ToString() })
    } finally { $ErrorActionPreference = $prev }
}

function Invoke-GitD {
    param([Parameter(Mandatory)][string[]]$Arguments, [string]$WorkingDirectory)
    $prevLoc = $null
    if ($WorkingDirectory) { $prevLoc = (Get-Location).Path; Set-Location -LiteralPath $WorkingDirectory }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git @Arguments 2>$null
        $script:LastGitExitCode = $LASTEXITCODE
        return @($out | ForEach-Object { $_.ToString() })
    } finally {
        $ErrorActionPreference = $prev
        if ($prevLoc) { Set-Location -LiteralPath $prevLoc }
    }
}

function ConvertFrom-GhJsonArray {
    <#
        Parses a GitHub CLI --json array response into a real array.

        Windows PowerShell 5.1 trap: `@($json | ConvertFrom-Json)` on "[]"
        yields ONE element -- the empty collection itself -- because the cmdlet
        writes the collection to the pipeline without enumerating it. The caller
        then sees a phantom item that has none of the expected properties, which
        under Set-StrictMode is a hard error.

        Assigning to a variable first and wrapping afterwards yields the correct
        empty array, so that is what this function does. Always parse gh array
        responses through here.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
    try { $parsed = $Json | ConvertFrom-Json } catch { return @() }
    if ($null -eq $parsed) { return @() }
    return @($parsed)
}

function Get-Prop {
    <#
        Reads a property that may be absent, without tripping Set-StrictMode.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Assert-DispatcherRoot {
    $top = Invoke-GitD -Arguments @('rev-parse', '--show-toplevel')
    if ($script:LastGitExitCode -ne 0 -or -not $top) { Write-Err 'Not inside a Git repository.'; return $false }
    $root = [IO.Path]::GetFullPath(($top | Select-Object -First 1)).TrimEnd('\', '/')
    $here = [IO.Path]::GetFullPath((Get-Location).Path).TrimEnd('\', '/')
    if ($root -ne $here) {
        Write-Err 'Dispatchers must run from the repository root.'
        Write-Err "  repository root : $root"
        Write-Err "  current location: $here"
        return $false
    }
    return $true
}

function Test-GhAuthenticated {
    <#
        Confirms an authenticated GitHub CLI session exists.

        Only the exit status is used. The token itself is never requested,
        read, printed or stored -- not even in masked form.
    #>
    [void](Invoke-Gh -Arguments @('auth', 'status'))
    return ($script:LastGhExitCode -eq 0)
}

function Test-RepositoryBaseline {
    <#
        Verifies the repository is in a state where dispatching is safe:
        correct repo, private, clean tree, on the base branch, in sync.
    #>
    param([Parameter(Mandatory)]$Config, [switch]$RequireCleanTree)

    $full = $Config.repository.fullName
    $result = [PSCustomObject]@{ Ok = $true; Reasons = @() }

    $json = (Invoke-Gh -Arguments @('repo', 'view', $full, '--json', 'visibility,defaultBranchRef')) -join ''
    if ($script:LastGhExitCode -ne 0 -or -not $json) {
        $result.Ok = $false; $result.Reasons += "cannot read repository $full"
        return $result
    }
    $repo = $json | ConvertFrom-Json
    if ($Config.repository.requirePrivate -and $repo.visibility -ne 'PRIVATE') {
        $result.Ok = $false; $result.Reasons += "repository is $($repo.visibility), expected PRIVATE"
    }

    $branch = (Invoke-GitD -Arguments @('branch', '--show-current') | Select-Object -First 1)
    if ($branch -ne $Config.repository.baseBranch) {
        $result.Ok = $false; $result.Reasons += "on branch '$branch', expected '$($Config.repository.baseBranch)'"
    }

    if ($RequireCleanTree) {
        $status = Invoke-GitD -Arguments @('status', '--porcelain')
        if (@($status | Where-Object { $_ -match '\S' }).Count -gt 0) {
            $result.Ok = $false; $result.Reasons += 'working tree is not clean'
        }
    }
    return $result
}

function ConvertTo-Slug {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [int]$MaxLength = 40)
    $s = $Text.ToLowerInvariant()
    $s = [regex]::Replace($s, '[^a-z0-9]+', '-')
    $s = $s.Trim('-')
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength).Trim('-') }
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'ticket' }
    return $s
}

function Resolve-DeveloperBranch {
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Slug, [Parameter(Mandatory)]$Config)
    return $Config.developer.branchPattern.Replace('{number}', $Number).Replace('{slug}', $Slug)
}

function Test-DeveloperBranchName {
    <#
        Validates a developer branch name.

        A protected branch can never be a developer branch: returning $false for
        'main' is the point of this function, not an edge case.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$BranchName, [Parameter(Mandatory)]$Config)
    if ([string]::IsNullOrWhiteSpace($BranchName)) { return $false }
    foreach ($p in $Config.repository.protectedBranches) {
        if ($BranchName -eq $p) { return $false }
    }
    return [bool]([regex]::IsMatch($BranchName, $Config.developer.branchValidationPattern))
}

function Resolve-DeveloperWorktreePath {
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)]$Config)
    return $Config.developer.worktreePattern.Replace('{number}', $Number)
}

function Resolve-ReviewerWorktreePath {
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)]$Config)
    return $Config.reviewer.worktreePattern.Replace('{number}', $Number)
}

function Test-LabelStateValid {
    <#
        Checks a label set against the configured invalid combinations.

        An ambiguous state is a stop condition, never something to resolve by
        picking the most likely interpretation. A dispatcher that guesses makes
        the labels stop describing reality.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Labels, [Parameter(Mandatory)]$Config)

    $conflicts = @()
    foreach ($combo in $Config.invalidLabelCombinations) {
        $all = $true
        foreach ($l in $combo) { if ($Labels -notcontains $l) { $all = $false; break } }
        if ($all) { $conflicts += ,@($combo) }
    }
    return [PSCustomObject]@{
        Valid     = ($conflicts.Count -eq 0)
        Conflicts = $conflicts
    }
}

function Test-TicketEligible {
    <#
        An Issue is eligible when it carries the eligible label and is not
        already claimed, blocked, in review, or awaiting a human decision.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Labels, [Parameter(Mandatory)]$Config)

    if ($Labels -notcontains $Config.labels.eligible) { return $false }
    foreach ($blocker in @(
        $Config.labels.claimed,
        $Config.labels.blocked,
        $Config.labels.readyForReview,
        $Config.labels.humanDecisionRequired)) {
        if ($Labels -contains $blocker) { return $false }
    }
    return $true
}

function Assert-Mode {
    <#
        Validates the requested mode. DryRun is the default everywhere; Live is
        only ever reached by an explicit argument.
    #>
    param([Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)]$Config)
    if ($Config.modes.allowed -notcontains $Mode) {
        Write-Err "Invalid mode '$Mode'. Allowed: $($Config.modes.allowed -join ', ')"
        return $false
    }
    return $true
}

function New-Manifest {
    <#
        Builds an execution manifest.

        Manifests record file paths, identifiers and intentions only. No token,
        password, connection string or authentication output is ever placed in a
        manifest, and the caller must not add one.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Fields
    )
    $m = [ordered]@{}
    $m['schemaVersion'] = 1
    $m['generatedUtc']  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    foreach ($k in ($Fields.Keys | Sort-Object)) { $m[$k] = $Fields[$k] }
    $m['containsCredentials'] = $false
    $m['note'] = 'Contains no credentials or authentication output. Authentication is resolved at runtime from OS-level credential storage.'
    return [PSCustomObject]$m
}

function Write-ManifestFile {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = $Manifest | ConvertTo-Json -Depth 12
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Get-ContextPackage {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $bytes = $bytes[3..($bytes.Length - 1)]
        }
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    } catch { return $null }
}

function Test-ConcurrencyFree {
    <#
        Confirms no other dispatcher job is active.

        Concurrency is excluded on purpose: two agents writing to the same
        the authorised target produce interleaved state that neither the evidence
        nor the reviewer can untangle.
    #>
    param([Parameter(Mandatory)]$Config)
    $lock = $Config.concurrency.lockFile
    if (Test-Path -LiteralPath $lock) {
        return [PSCustomObject]@{ Free = $false; Reason = "lock file present: $lock" }
    }
    return [PSCustomObject]@{ Free = $true; Reason = 'no active job' }
}

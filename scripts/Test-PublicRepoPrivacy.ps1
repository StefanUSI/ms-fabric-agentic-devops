<#
.SYNOPSIS
    Pre-commit privacy gate for a PUBLIC repository. Exits non-zero if anything
    staged would expose a real identifier.

.DESCRIPTION
    Run before every commit and push. This is the check that has to be
    mechanical: a human deciding "this looks fine" is exactly how an identifier
    reaches a public repository, and a value committed once is permanent.

    It reads the real values from config/environment.local.json and searches the
    STAGED content for them, then applies generic patterns so an identifier
    nobody enumerated is still caught.

.PARAMETER Staged
    Check staged content (default). Otherwise checks all tracked files.
#>
[CmdletBinding()]
param(
    [switch]$AllTracked,
    [string]$ConfigPath = 'config/environment.local.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Utf8 {
    param([string]$Path)
    $b = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $b = $b[3..($b.Length - 1)] }
    return [Text.Encoding]::UTF8.GetString($b)
}

$files = if ($AllTracked) { @(git ls-files) } else { @(git diff --cached --name-only) }
$files = @($files | Where-Object { $_ -and (Test-Path -LiteralPath $_) })

Write-Host "Public-repo privacy gate: checking $($files.Count) file(s)" -ForegroundColor Cyan

# Exact real values, read from the local config so the gate cannot drift from
# the environment it is protecting.
$exact = @{}
if (Test-Path -LiteralPath $ConfigPath) {
    $cfg = Read-Utf8 $ConfigPath | ConvertFrom-Json
    foreach ($pair in @(
        @{ v = $cfg.fabric.workspaceId;                p = 'workspace id' },
        @{ v = $cfg.fabric.capacityId;                 p = 'capacity id' },
        @{ v = $cfg.fabric.authorisedTargetFolderId;   p = 'folder id' },
        @{ v = $cfg.fabric.workspaceName;              p = 'workspace name' },
        @{ v = $cfg.fabric.capacityName;               p = 'capacity name' },
        @{ v = $cfg.fabric.authorisedTargetFolderName; p = 'folder name' },
        @{ v = $cfg.fabric.region;                     p = 'region' }
    )) {
        if ($pair.v -and -not [string]::IsNullOrWhiteSpace([string]$pair.v)) { $exact[[string]$pair.v] = $pair.p }
    }
} else {
    Write-Host "  note: $ConfigPath absent - exact-value checks skipped, generic patterns still apply" -ForegroundColor Yellow
}

# Generic patterns. 'test@example.invalid' is RFC 2606 reserved and cannot route
# anywhere, so it is allowed; every other email shape is not.
$patterns = [ordered]@{
    'GUID (any)'        = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    'email address'     = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    'local user path'   = '[A-Za-z]:\\Users\\'
    'token-like value'  = '(?i)(gho_|ghp_|ghu_|ghs_|github_pat_)[A-Za-z0-9_]{20,}'
    'AWS key'           = 'AKIA[0-9A-Z]{16}'
    'private key block' = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'JWT'               = 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.'
}
$allowedEmails = @('test@example.invalid')

$violations = @()

foreach ($f in $files) {
    if ($f -match '(^|/)config/environment\.local\.json$') {
        $violations += "$f :: the local config itself must never be staged"
        continue
    }
    $t = Read-Utf8 $f

    foreach ($k in $exact.Keys) {
        if ($t.Contains($k)) { $violations += "$f :: real $($exact[$k])" }
    }
    foreach ($name in $patterns.Keys) {
        foreach ($m in [regex]::Matches($t, $patterns[$name])) {
            if ($name -eq 'email address' -and ($allowedEmails -contains $m.Value)) { continue }
            $violations += "$f :: $name -> $($m.Value)"
        }
    }
}

Write-Host ""
if ($violations.Count -eq 0) {
    Write-Host "PASS - nothing staged exposes a real identifier." -ForegroundColor Green
    exit 0
}

Write-Host "FAIL - $($violations.Count) violation(s). DO NOT COMMIT:" -ForegroundColor Red
$violations | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
Write-Host ""
Write-Host "A value committed to a public repository is permanent. Deleting it in a" -ForegroundColor Yellow
Write-Host "later commit does not remove it from history." -ForegroundColor Yellow
exit 1

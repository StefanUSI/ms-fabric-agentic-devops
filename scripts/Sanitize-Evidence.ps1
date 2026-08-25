<#
.SYNOPSIS
    Replaces real environment identifiers with placeholders so evidence can be
    committed to a public repository.

.DESCRIPTION
    THIS REPOSITORY IS PUBLIC. Raw runtime evidence contains real workspace,
    capacity, folder, item and job identifiers. Those stay local and gitignored;
    only the sanitized output is committed.

    Reads the real values from config/environment.local.json and replaces them,
    then replaces any REMAINING GUID with a generic placeholder — so an
    identifier nobody thought to enumerate is still caught. The default is
    "redact anything that looks like an identifier", not "redact the ones we
    listed".

    What sanitization costs, stated plainly: a reviewer reading the sanitized
    evidence can verify row counts, terminal statuses and reconciliation, but
    CANNOT independently confirm which folder was deployed to. That is a real
    reduction in what the review proves, and it is the price of publishing.

.PARAMETER InputPath
    Raw evidence file (local, ignored).

.PARAMETER OutputPath
    Sanitized file to be committed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$OutputPath,
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

if (-not (Test-Path -LiteralPath $InputPath))  { throw "Raw evidence not found: $InputPath" }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Local config not found: $ConfigPath" }

$cfg  = Read-Utf8 $ConfigPath | ConvertFrom-Json
$text = Read-Utf8 $InputPath

# Longest first, so a value that contains another is replaced correctly.
$map = [ordered]@{}
foreach ($pair in @(
    @{ v = $cfg.fabric.workspaceId;                 p = '<WORKSPACE_ID>' },
    @{ v = $cfg.fabric.capacityId;                  p = '<CAPACITY_ID>' },
    @{ v = $cfg.fabric.authorisedTargetFolderId;    p = '<FOLDER_ID>' },
    @{ v = $cfg.fabric.workspaceName;               p = '<FABRIC_WORKSPACE>' },
    @{ v = $cfg.fabric.capacityName;                p = '<FABRIC_CAPACITY>' },
    @{ v = $cfg.fabric.authorisedTargetFolderName;  p = '<TARGET_FOLDER>' },
    @{ v = $cfg.fabric.region;                      p = '<REGION>' },
    @{ v = $cfg.fabric.sku;                         p = '<SKU>' },
    @{ v = $cfg.github.owner;                       p = '<GITHUB_OWNER>' }
)) {
    if ($pair.v -and -not [string]::IsNullOrWhiteSpace([string]$pair.v)) { $map[[string]$pair.v] = $pair.p }
}

$replaced = 0
foreach ($k in ($map.Keys | Sort-Object { $_.Length } -Descending)) {
    $n = ([regex]::Matches($text, [regex]::Escape($k))).Count
    if ($n -gt 0) { $text = $text.Replace($k, $map[$k]); $replaced += $n }
}

# Catch-all: any GUID still present is an identifier nobody enumerated -
# an item id, a job run id, something new. Redact rather than publish.
$residual = [regex]::Matches($text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
$text = [regex]::Replace($text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<FABRIC_ITEM_ID>')

# Emails and local paths must never appear in published evidence.
$text = [regex]::Replace($text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<EMAIL_ADDRESS>')
$text = [regex]::Replace($text, '[A-Za-z]:\\Users\\[^\s"'',;]*', '<LOCAL_PROJECT_PATH>')

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[IO.File]::WriteAllText($OutputPath, $text, (New-Object Text.UTF8Encoding($false)))

Write-Host "sanitized: $InputPath -> $OutputPath"
Write-Host "  named identifiers replaced : $replaced"
Write-Host "  residual GUIDs redacted    : $($residual.Count)"

# Verify the OUTPUT, not the intent.
$check = Read-Utf8 $OutputPath
$fail = 0
foreach ($probe in @(
    @{ n = 'GUID';          r = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' },
    @{ n = 'email';         r = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' },
    @{ n = 'local path';    r = '[A-Za-z]:\\Users\\' }
)) {
    if ([regex]::IsMatch($check, $probe.r)) { Write-Host "  FAIL residual $($probe.n)" -ForegroundColor Red; $fail++ }
}
foreach ($k in $map.Keys) {
    if ($check.Contains($k)) { Write-Host "  FAIL residual value for $($map[$k])" -ForegroundColor Red; $fail++ }
}

if ($fail -gt 0) { Write-Host "SANITIZATION FAILED - do not commit" -ForegroundColor Red; exit 1 }
Write-Host "  verified clean" -ForegroundColor Green
exit 0

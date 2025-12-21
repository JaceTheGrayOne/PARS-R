# Save as: tools\parity\verify_parity.ps1
# Usage:
#   pwsh .\tools\parity\verify_parity.ps1 -XmlPath .\Test_Reports\Test_Report.xml
# Optional:
#   -OutDir .\out
#   -HtmlPath .\out\report.html
#   -XmlCanonicalPath .\out\canonical_xml.json   (if you already have one)
#   -OutDiffPath .\out\parity_diff.json

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$XmlPath,

    [string]$OutDir = ".\out",

    [string]$HtmlPath,

    [string]$XmlCanonicalPath,

    [string]$HtmlCanonicalPath,

    [string]$OutDiffPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RelPath([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Resolve-Path -LiteralPath $p).Path
}

# Resolve defaults that depend on OutDir
if (-not $HtmlPath) { $HtmlPath = Join-Path $OutDir "report.html" }
if (-not $HtmlCanonicalPath) { $HtmlCanonicalPath = Join-Path $OutDir "canonical_html.json" }
if (-not $OutDiffPath) { $OutDiffPath = Join-Path $OutDir "parity_diff.json" }

# Ensure output directory exists
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$repoRoot = (Get-Location).Path
$trexPath = Join-Path $repoRoot "trex.ps1"
$extractHtmlPath = Join-Path $repoRoot "tools\parity\extract_html.ps1"
$comparePath = Join-Path $repoRoot "tools\parity\Compare-Parity.ps1"

foreach ($p in @($trexPath, $extractHtmlPath, $comparePath)) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw "Required script not found: $p"
    }
}

$XmlPath = Resolve-RelPath $XmlPath

Write-Host "1) Generating HTML..." -ForegroundColor Cyan
pwsh $trexPath -XmlPath $XmlPath -OutputHtmlPath $HtmlPath

Write-Host "2) Extracting canonical HTML JSON..." -ForegroundColor Cyan
pwsh $extractHtmlPath -HtmlPath $HtmlPath -OutPath $HtmlCanonicalPath

# If caller didn't provide canonical XML, try to find a reasonable default.
if (-not $XmlCanonicalPath) {
    $candidate1 = Join-Path $OutDir "canonical_xml.json"
    $candidate2 = Join-Path $OutDir "canonical_xml_v2.json"
    if (Test-Path -LiteralPath $candidate1) { $XmlCanonicalPath = $candidate1 }
    elseif (Test-Path -LiteralPath $candidate2) { $XmlCanonicalPath = $candidate2 }
    else {
        throw "Canonical XML JSON not found. Provide -XmlCanonicalPath (e.g., .\out\canonical_xml.json)."
    }
}

Write-Host "3) Comparing parity..." -ForegroundColor Cyan
pwsh $comparePath -XmlJsonPath $XmlCanonicalPath -HtmlJsonPath $HtmlCanonicalPath -OutDiffPath $OutDiffPath
$exit = $LASTEXITCODE

if ($exit -eq 0) {
    Write-Host "PARITY OK (exit 0)" -ForegroundColor Green
}
else {
    Write-Host "PARITY FAILED (exit $exit). See: $OutDiffPath" -ForegroundColor Red
}

exit $exit

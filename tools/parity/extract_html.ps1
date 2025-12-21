<#
.SYNOPSIS
    Extracts canonical Parity Data from a PARS-R generated HTML report.

.DESCRIPTION
    Parses an HTML file as text (Regex-based) to locate <tr> tags instrumented
    with `data-parity-*` attributes. Emits a JSON array of Canonical Step Records
    conforming to the PARS-R Parity Contract.

    Designed to be robust against visual HTML changes, relying ONLY on the
    parity contract attributes.

.PARAMETER HtmlPath
    Path to the input HTML file.

.PARAMETER OutPath
    Optional. Path to save the output JSON. If omitted, writes to stdout.

.EXAMPLE
    .\extract_html.ps1 -HtmlPath ".\Report.html" -OutPath ".\canonical_html.json"
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$HtmlPath,

    [string]$OutPath
)

# 1. Validation
if (-not (Test-Path -LiteralPath $HtmlPath)) {
    Write-Error "File not found: $HtmlPath"
    exit 1
}

# 2. Ingestion
$content = Get-Content -LiteralPath $HtmlPath -Raw

# 3. Regex Setup
# Matches opening <tr> tags that contain at least one data-parity attribute.
# Case-insensitive, Single-line mode (dot matches newline).
$trRegex = [regex]'(?si)<tr\s+([^>]*data-parity-[^>]*)>'

# Attribute Regex: Matches data-parity-KEY="VALUE"
$attrRegex = [regex]'data-parity-([a-z]+)="([^"]*)"'

$matches = $trRegex.Matches($content)

if ($matches.Count -eq 0) {
    Write-Error "No 'data-parity-*' rows found in $HtmlPath. Ensure the report was generated with a parity-aware version of trex.ps1."
    exit 2
}

$results = @()

# 4. Parsing
foreach ($m in $matches) {
    $attrString = $m.Groups[1].Value
    $attrs = @{}

    $attrMatches = $attrRegex.Matches($attrString)
    foreach ($am in $attrMatches) {
        $key = $am.Groups[1].Value
        $rawVal = $am.Groups[2].Value
        
        # HTML Decode value (safe for &amp; &lt; &quot; etc.)
        # Using [System.Net.WebUtility]::HtmlDecode which is available in PS Core.
        $val = [System.Net.WebUtility]::HtmlDecode($rawVal)
        $attrs[$key] = $val
    }

    # Ensure required identity fields exist
    if (-not $attrs.ContainsKey('path') -or -not $attrs.ContainsKey('ordinal')) {
        Write-Warning "Skipping malformed row: Missing path or ordinal. Attributes found: $($attrs.Keys -join ', ')"
        continue
    }

    # 5. Contract Mapping
    
    # Derive StepName from Attribute (Primary) or Path (Fallback)
    $stepName = if ($attrs.ContainsKey('name') -and $attrs['name']) {
        $attrs['name']
    }
    elseif ($attrs['path'].Contains('/')) {
        $attrs['path'].Substring($attrs['path'].LastIndexOf('/') + 1)
    }
    else {
        $attrs['path']
    }

    # Construct Limits Structure
    $limits = [Ordered]@{
        Low          = if ($attrs.low) { $attrs.low } else { $null }
        LowComp      = if ($attrs.lowcomp) { $attrs.lowcomp } else { "NONE" }
        High         = if ($attrs.high) { $attrs.high } else { $null }
        HighComp     = if ($attrs.highcomp) { $attrs.highcomp } else { "NONE" }
        Expected     = if ($attrs.expected) { $attrs.expected } else { $null }
        ExpectedComp = if ($attrs.expectedcomp) { $attrs.expectedcomp } else { "NONE" }
    }

    # Construct Canonical Record
    $rec = [Ordered]@{
        CanonicalKey     = "$($attrs.path)|$($attrs.ordinal)"
        ExecutionOrdinal = [int]$attrs.ordinal
        Path             = $attrs.path
        Kind             = if ($attrs.kind) { $attrs.kind } else { "Unknown" }
        StepName         = $stepName
        Status           = if ($attrs.status) { $attrs.status } else { "" }
        Value            = if ($attrs.value) { $attrs.value } else { "" }
        Units            = if ($attrs.units) { $attrs.units } else { "" }
        Limits           = $limits
        Timestamp        = if ($attrs.timestamp) { $attrs.timestamp } else { "" }
    }

    $results += [PSCustomObject]$rec
}

# 6. Output
$json = $results | ConvertTo-Json -Depth 5

if ($OutPath) {
    $dir = Split-Path $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json | Set-Content -LiteralPath $OutPath -Encoding UTF8
    Write-Host "Extracted $($results.Count) records to $OutPath" -ForegroundColor Green
}
else {
    $json
}

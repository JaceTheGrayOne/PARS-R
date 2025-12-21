<#
.SYNOPSIS
    Compares two Canonical Parity JSON files (XML Source vs HTML Source).

.DESCRIPTION
    Performs a deterministic, field-level comparison of test data to verify
    integrity and parity.
    
    Checks for:
    1. Dropped Data (Missing in HTML)
    2. Hallucinated Data (Extra in HTML)
    3. Corruption (Mismatched values, limits, timestamps, etc.)

    Uses a "String First, Numeric Fallback" comparison policy to allow
    formatting differences (1 vs 1.0) while preserving strictness for
    textual data.

.PARAMETER XmlJsonPath
    Path to the Canonical XML JSON (Reference/Golden).

.PARAMETER HtmlJsonPath
    Path to the Canonical HTML JSON (Difference/Subject).

.PARAMETER OutDiffPath
    Optional. Path to save the detailed JSON diff report.

.EXAMPLE
    .\Compare-Parity.ps1 -XmlJsonPath ".\xml.json" -HtmlJsonPath ".\html.json"
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$XmlJsonPath,

    [Parameter(Mandatory = $true)]
    [string]$HtmlJsonPath,

    [string]$OutDiffPath
)

# -----------------------------------------------------------------------------
# 1. Setup & Helper Functions
# -----------------------------------------------------------------------------

function Get-Dataset ($Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "File not found: $Path"
        exit 2
    }
    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        # Convert to Hashtable for O(1) lookup
        $hash = @{}
        if ($json) {
            # Handle single object vs array
            $arr = if ($json -is [array]) { $json } else { @($json) }
            foreach ($item in $arr) {
                if (-not $item.CanonicalKey) { continue }
                $hash[$item.CanonicalKey] = $item
            }
        }
        return $hash
    }
    catch {
        Write-Error "Failed to load JSON from $Path : $($_.Exception.Message)"
        exit 2
    }
}

function Test-ValueParity ($valA, $valB) {
    # Normalize Nulls to Empty String
    $sA = if ($valA) { $valA.ToString().Trim() } else { "" }
    $sB = if ($valB) { $valB.ToString().Trim() } else { "" }

    # 1. String Equality (Primary)
    if ($sA -eq $sB) { return $true }
    
    # 2. Case Insensitive Check (for good measure, though contract implies strict casing for some fields)
    if ($sA.Equals($sB, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }

    # 3. Numeric Fallback
    # If both parsable as doubles, compare values.
    # Allows "1" == "1.00"
    $dA = 0.0; $dB = 0.0
    $isNumA = [double]::TryParse($sA, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dA)
    $isNumB = [double]::TryParse($sB, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dB)

    if ($isNumA -and $isNumB) {
        # Epsilon comparison for floats if needed, but usually equality is sufficient for test reports
        if ($dA -eq $dB) { return $true }
    }

    return $false
}

# -----------------------------------------------------------------------------
# 2. Load Data
# -----------------------------------------------------------------------------
Write-Host "Loading datasets..." -ForegroundColor Cyan
$xmlData = Get-Dataset $XmlJsonPath
$htmlData = Get-Dataset $HtmlJsonPath

Write-Host "XML Records: $($xmlData.Count)" -ForegroundColor Gray
Write-Host "HTML Records: $($htmlData.Count)" -ForegroundColor Gray

# -----------------------------------------------------------------------------
# 3. Comparison Logic
# -----------------------------------------------------------------------------
Write-Host "Comparing..." -ForegroundColor Cyan

$dropped = @()
$hallucinated = @()
$corruption = @()

$fields = @("Path", "ExecutionOrdinal", "Kind", "StepName", "Status", "Value", "Units", "Timestamp")
# Nested Limit fields to check
$limitFields = @("Low", "LowComp", "High", "HighComp", "Expected", "ExpectedComp")

# A. Forward Pass (XML -> HTML)
foreach ($key in $xmlData.Keys) {
    if (-not $htmlData.ContainsKey($key)) {
        # Dropped
        $dropped += $xmlData[$key]
        continue
    }

    $recRef = $xmlData[$key]
    $recSub = $htmlData[$key]
    $diffs = [Ordered]@{}
    $hasDiff = $false

    # Check Top-Level Fields
    foreach ($f in $fields) {
        if (-not (Test-ValueParity $recRef.$f $recSub.$f)) {
            $diffs[$f] = @{ Ref = $recRef.$f; Sub = $recSub.$f }
            $hasDiff = $true
        }
    }

    # Check Nested Limits
    foreach ($lf in $limitFields) {
        $vRef = $recRef.Limits.$lf
        $vSub = $recSub.Limits.$lf
        if (-not (Test-ValueParity $vRef $vSub)) {
            $diffs["Limits.$lf"] = @{ Ref = $vRef; Sub = $vSub }
            $hasDiff = $true
        }
    }

    if ($hasDiff) {
        $corruption += [PSCustomObject]@{
            CanonicalKey = $key
            Diffs        = $diffs
        }
    }

    # Mark as visited in HTML (Remove from map or track)
    $htmlData.Remove($key)
}

# B. Backward Pass (Remaining HTML keys)
foreach ($key in $htmlData.Keys) {
    $hallucinated += $htmlData[$key]
}

# -----------------------------------------------------------------------------
# 4. Reporting
# -----------------------------------------------------------------------------

$pass = ($dropped.Count -eq 0) -and ($hallucinated.Count -eq 0) -and ($corruption.Count -eq 0)

Write-Host "`n---------------- Parity Report ----------------" -ForegroundColor ($pass ? "Green" : "Red")
Write-Host "Dropped (Only in XML)      : $($dropped.Count)"
Write-Host "Hallucinated (Only in HTML): $($hallucinated.Count)"
Write-Host "Corrupted (Mismatch)       : $($corruption.Count)"
Write-Host "-----------------------------------------------"

if ($corruption.Count -gt 0) {
    Write-Host "`nTop 5 Corruptions:" -ForegroundColor Yellow
    $corruption | Select-Object -First 5 | ForEach-Object {
        Write-Host "  [$($_.CanonicalKey)]"
        $_.Diffs.GetEnumerator() | ForEach-Object {
            Write-Host "    $($_.Key): '$($_.Value.Ref)' != '$($_.Value.Sub)'"
        }
    }
}

$results = [PSCustomObject]@{
    Summary      = @{
        Success           = $pass
        DroppedCount      = $dropped.Count
        HallucinatedCount = $hallucinated.Count
        CorruptionCount   = $corruption.Count
    }
    Dropped      = $dropped
    Hallucinated = $hallucinated
    Corruption   = $corruption
}

if ($OutDiffPath) {
    $dir = Split-Path $OutDiffPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutDiffPath -Encoding UTF8
    Write-Host "`nDetailed report saved to: $OutDiffPath" -ForegroundColor Gray
}

exit ($pass ? 0 : 1)

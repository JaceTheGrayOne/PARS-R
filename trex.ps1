<#
.SYNOPSIS
    T-REX "TestStand Report Extractor" - TestStand XML to HTML Parser

.DESCRIPTION
    Parses XML (ATML) output from TestStand into a self contained, human
    readable, interactive, and well formatted HTML with collapsible
    categories and pass/fail indicators.

.METHODOLOGY
    Recursively walks through XML node structure to flatten unformatted
    XML data and then converts it into a formatted hierarchical HTML
    table embedded with CSS and JavaScript.

.NOTES
    File Name    : TREX.ps1
    Author       : 1130538 (Brandon Heath)
    Version      : 2.5.0
    Creation     : 14NOV2025
    Last Update  : 24DEC2025
    Requires     : PowerShell 7.0+, Windows 10+
    Versioning   : Semantic Versioning #.#.# (Major.Minor.Patch)

.CHANGE LOG
    v2.5.0 - Modularized C#, HTML, CSS, and JS into separate files for maintainability.
    v2.1.5 - Light mode UI toggle. *Pending*
    v2.1.0 - Added filter and search functionality.
    v2.0.4 - Redesigned UI with new color scheme and improved readability.
    v1.0.0 - Finalized parsing logic and HTML generation.
    v0.0.6 - Adjusted several UI elements for readability.
    v0.0.5 - Fix comparator conversion bug.
    v0.0.4 - Adjustment to Regex filtering.
    v0.0.3 - Minor HTML formatting changes.
    v0.0.2 - Minor syntactic changes.
    v0.0.1 - Initial build.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$XmlPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputHtmlPath = "D:\Development\XML_Parser\Resources\Output.html",

    # Module Directory
    # - template.html
    # - styles.css
    # - app.js
    [Parameter(Mandatory = $false)]
    [string]$AssetsDir
)

# Validate Module Directory
if (-not $AssetsDir) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $AssetsDir = Join-Path $scriptDir "web"
}

# Module Paths
$templatePath = Join-Path $AssetsDir "template.html"
$cssPath      = Join-Path $AssetsDir "styles.css"
$jsPath       = Join-Path $AssetsDir "app.js"

<# ----------------------------------------------------------------------
Function: Convert-Comparator
---------------------------------------------------------------------- #>
function Convert-Comparator {
    param($comp)

    if (-not $comp) { return "" }

    switch ($comp.ToString().ToUpper()) {
        'GE' { "&ge;" }    # Greater or Equal
        'GT' { "&gt;" }    # Greater Than
        'LE' { "&le;" }    # Less or Equal
        'LT' { "&lt;" }    # Less Than
        'EQ' { "=" }       # Equal
        'NE' { "&ne;" }    # Not Equal
        default { $comp }  # Fallback: unchanged
    }
}

<# ----------------------------------------------------------------------
Function: Get-LimitsString
---------------------------------------------------------------------- #>
function Get-LimitsString ($testResultNode) {
    if (-not $testResultNode) { return "" }

    $limits = $testResultNode.TestLimits.Limits
    if (-not $limits) { return "" }

    if ($limits.LimitPair) {
        $low = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "GE|GT" } | Select-Object -First 1
        $high = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "LE|LT" } | Select-Object -First 1
        $segments = @()

        if ($low) { $segments += "Low: $(Convert-Comparator $low.comparator) $($low.Datum.value)" }
        if ($high) { $segments += "High: $(Convert-Comparator $high.comparator) $($high.Datum.value)" }
        return $segments -join " | "
    }

    if ($limits.Expected) {
        return "$(Convert-Comparator $limits.Expected.comparator) $($limits.Expected.Datum.value)"
    }
    return ""
}

<# ----------------------------------------------------------------------
Function: Get-LimitInfo
---------------------------------------------------------------------- #>
function Get-LimitInfo ($testResultNode) {
    if (-not $testResultNode) { return $null }
    $limits = $testResultNode.TestLimits.Limits
    if (-not $limits) { return $null }

    $info = [Ordered]@{
        Low          = $null
        LowComp      = "NONE"
        High         = $null
        HighComp     = "NONE"
        Expected     = $null
        ExpectedComp = "NONE"
    }

    $Normalize = { param($c)
        if (-not $c) { return "NONE" }
        switch -Regex ($c.ToString().ToUpper()) {
            'GE|&GE;|=>' { 'GE' }
            'GT|&GT;|>' { 'GT' }
            'LE|&LE;|=>' { 'LE' }
            'LT|&LT;|<' { 'LT' }
            'EQ|=|==' { 'EQ' }
            'NE|&NE;|!=' { 'NE' }
            default { $c }
        }
    }

    if ($limits.LimitPair) {
        $l = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "GE|GT" } | Select-Object -First 1
        $h = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "LE|LT" } | Select-Object -First 1

        if ($l) {
            $info.Low = $l.Datum.value
            $info.LowComp = & $Normalize $l.comparator
        }
        if ($h) {
            $info.High = $h.Datum.value
            $info.HighComp = & $Normalize $h.comparator
        }
    }

    if ($limits.Expected) {
        $info.Expected = $limits.Expected.Datum.value
        $info.ExpectedComp = & $Normalize $limits.Expected.comparator
    }

    return $info
}

<# ----------------------------------------------------------------------
Function: Format-Timestamp
---------------------------------------------------------------------- #>
function Format-Timestamp ($timestamp) {
    if (-not $timestamp) { return '' }
    try {
        $dt = [datetime]$timestamp
        return $dt.ToString("HH:mm:ss - ddMMMyyyy").ToUpper()
    }
    catch {
        return $timestamp
    }
}

<# ----------------------------------------------------------------------
Function: Format-DisplayValue
---------------------------------------------------------------------- #>
function Format-DisplayValue ($val, $unit) {
    $v = if ($val) { $val.ToString().Trim() } else { "" }
    $u = if ($unit) { $unit.ToString().Trim() } else { "" }

    if (-not $v -and -not $u) { return "" }

    if ($u -eq "PORT" -and $v -match '^\d+$') {
        return "PORT $v"
    }

    if ($v -and $u) { return "$v $u" }
    if ($v) { return $v }
    if ($u) { return $u }
    return ""
}

<# ----------------------------------------------------------------------
Function: Format-ResultSetDisplayName
---------------------------------------------------------------------- #>
function Format-ResultSetDisplayName ([string]$rawName) {
    if (-not $rawName) { return "" }

    $base = ($rawName -split '#', 2)[0]
    $leaf = [System.IO.Path]::GetFileName($base)

    if ($leaf -match '\.seq$') { $leaf = $leaf -replace '\.seq$', '' }
    $leaf = ($leaf -replace '_', ' ') -replace '\s{2,}', ' '

    return $leaf.Trim()
}

<# ----------------------------------------------------------------------
Function: Get-TestNode
---------------------------------------------------------------------- #>
function Get-TestNode ($node, $level) {
    $results = @()

    $name = if ($node.callerName) { $node.callerName } else { $node.name }

    if ($node.LocalName -eq 'ResultSet' -and $node.name) {
        $name = Format-ResultSetDisplayName $node.name
    }

    $status = $node.Outcome.value
    $timestamp = $node.endDateTime
    $numericResult = $node.TestResult | Where-Object { $_.name -eq 'Numeric' } | Select-Object -First 1

    $value = ''
    $units = ''
    $limits = ''

    $limitData = $null
    $kind = "Step"

    if ($numericResult) {
        $value = $numericResult.TestData.Datum.value
        $units = $numericResult.TestData.Datum.nonStandardUnit
        $kind = "Measurement"

        if (-not $units) { $units = $numericResult.TestData.Datum.unit }
        $limits = Get-LimitsString $numericResult
        $limitData = Get-LimitInfo $numericResult
    }

    if ($node.LocalName -in @("TestGroup", "SessionAction")) {
        $kind = "Group"
    }

    $results += [PSCustomObject]@{
        Level     = $level
        Name      = $name
        Status    = $status
        Value     = $value
        Units     = $units
        Limits    = $limits
        LimitData = $limitData
        Kind      = $kind
        Time      = $timestamp
        IsGroup   = ($node.LocalName -in @("TestGroup", "SessionAction"))
    }

    $children = $node.ChildNodes | Where-Object {
        $_.NodeType -eq 'Element' -and $_.LocalName -in @("TestGroup", "Test", "SessionAction")
    }

    foreach ($child in $children) {
        $results += Get-TestNode $child ($level + 1)
    }

    return $results
}

<# ----------------------------------------------------------------------
Section: Main Execution
---------------------------------------------------------------------- #>
Write-Host "Validating XML file path: $XmlPath" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $XmlPath)) {
    Write-Error "File not found: $XmlPath"
    exit 1
}

if (-not (Test-Path -LiteralPath $templatePath)) { Write-Error "Missing template: $templatePath"; exit 1 }
if (-not (Test-Path -LiteralPath $cssPath))      { Write-Error "Missing CSS: $cssPath"; exit 1 }
if (-not (Test-Path -LiteralPath $jsPath))       { Write-Error "Missing JS: $jsPath"; exit 1 }

[xml]$xml = Get-Content -LiteralPath $XmlPath -Raw

$uut = $xml.TestResultsCollection.TestResults.UUT

$serialNumber = $uut.SerialNumber
if ($serialNumber) { $serialNumber = $serialNumber.Trim() } else { $serialNumber = "[missing serial]" }

$partNumber = $uut.Definition.Identification.IdentificationNumbers.IdentificationNumber.number
if (-not $partNumber) { $partNumber = "[missing part]" }

$startTime = $xml.TestResultsCollection.TestResults.ResultSet.startDateTime
$startTimeFormatted = if ($startTime) { Format-Timestamp $startTime } else { "[missing start time]" }

$overallResult = $xml.TestResultsCollection.TestResults.ResultSet.Outcome.value
if (-not $overallResult) { $overallResult = "[unknown]" }

Write-Host "Parsing test data..." -ForegroundColor Cyan

$resultSet = $xml.TestResultsCollection.TestResults.ResultSet
$flatResults = Get-TestNode $resultSet 0

$totalTests = ($flatResults | Where-Object { -not $_.IsGroup }).Count
$passCount  = ($flatResults | Where-Object { -not $_.IsGroup -and $_.Status -eq "Passed" }).Count
$failCount  = ($flatResults | Where-Object { -not $_.IsGroup -and $_.Status -eq "Failed" }).Count

$renderRows = $flatResults

<# ----------------------------------------------------------------------
Section: HTML Row Generation
---------------------------------------------------------------------- #>
Write-Host "Generating HTML..." -ForegroundColor Cyan
$htmlRowsSb = New-Object System.Text.StringBuilder

$rowIdCounter = 0
$groupStack = New-Object System.Collections.Generic.List[string]

$pathStack = New-Object System.Collections.Generic.List[string]
$ordinalTracker = @{}

foreach ($item in $renderRows) {
    while ($groupStack.Count -gt $item.Level) {
        $groupStack.RemoveAt($groupStack.Count - 1)
        if ($pathStack.Count -gt $groupStack.Count) { $pathStack.RemoveAt($pathStack.Count - 1) }
    }
}

for ($i = 0; $i -lt $renderRows.Count; $i++) {
    $item = $renderRows[$i]
    $hasChildren = ($i -lt $renderRows.Count - 1) -and ($renderRows[$i + 1].Level -gt $item.Level)

    while ($groupStack.Count -gt $item.Level) {
        $groupStack.RemoveAt($groupStack.Count - 1)
        if ($pathStack.Count -gt $groupStack.Count) { $pathStack.RemoveAt($pathStack.Count - 1) }
    }

    $parentId = $null
    if ($item.Level -gt 0 -and $groupStack.Count -ge $item.Level) {
        $parentId = $groupStack[$item.Level - 1]
    }

    $parentPath = $pathStack -join '/'
    $currentPath = if ($parentPath) { "$parentPath/$($item.Name)" } else { $item.Name }

    $ordKey = "$parentPath|$($item.Name)|$($item.Kind)"
    if (-not $ordinalTracker.ContainsKey($ordKey)) { $ordinalTracker[$ordKey] = 0 }
    $ordinalTracker[$ordKey]++
    $ordinal = $ordinalTracker[$ordKey]

    $pStatus = if ($item.Status) { $item.Status } else { "" }

    $pValue = if ($item.Value) { $item.Value } else { "" }
    $pUnit  = if ($item.Units) { $item.Units } else { "" }

    $pLow = ""; $pLowC = "NONE"; $pHigh = ""; $pHighC = "NONE"; $pExp = ""; $pExpC = "NONE"
    if ($item.LimitData) {
        if ($item.LimitData.Low) { $pLow = $item.LimitData.Low }
        if ($item.LimitData.LowComp) { $pLowC = $item.LimitData.LowComp }
        if ($item.LimitData.High) { $pHigh = $item.LimitData.High }
        if ($item.LimitData.HighComp) { $pHighC = $item.LimitData.HighComp }
        if ($item.LimitData.Expected) { $pExp = $item.LimitData.Expected }
        if ($item.LimitData.ExpectedComp) { $pExpC = $item.LimitData.ExpectedComp }
    }

    $EscSimple = { param($s)
        if (-not $s) { return "" }
        return $s.ToString().Replace('&', '&amp;').Replace('"', '&quot;').Replace('<', '&lt;').Replace('>', '&gt;')
    }

    $displayTime = Format-Timestamp $item.Time
    $pTime = if ($displayTime) { $displayTime } else { "" }

    $parityAttrs =
        "data-parity-path=""$(& $EscSimple $currentPath)"" " +
        "data-parity-name=""$(& $EscSimple $item.Name)"" " +
        "data-parity-ordinal=""$ordinal"" " +
        "data-parity-kind=""$($item.Kind)"" " +
        "data-parity-status=""$(& $EscSimple $pStatus)"" " +
        "data-parity-value=""$(& $EscSimple $pValue)"" " +
        "data-parity-units=""$(& $EscSimple $pUnit)"" " +
        "data-parity-low=""$(& $EscSimple $pLow)"" " +
        "data-parity-lowcomp=""$pLowC"" " +
        "data-parity-high=""$(& $EscSimple $pHigh)"" " +
        "data-parity-highcomp=""$pHighC"" " +
        "data-parity-expected=""$(& $EscSimple $pExp)"" " +
        "data-parity-expectedcomp=""$pExpC"" " +
        "data-parity-timestamp=""$(& $EscSimple $pTime)"""

    $rowIdCounter++
    $rowId = "row$rowIdCounter"

    if ($item.IsGroup) {
        if ($groupStack.Count -eq $item.Level) {
            $groupStack.Add($rowId)
            $pathStack.Add($item.Name)
        }
        elseif ($groupStack.Count -gt $item.Level) {
            $groupStack[$item.Level] = $rowId
            while ($pathStack.Count -gt $item.Level) { $pathStack.RemoveAt($pathStack.Count - 1) }
            $pathStack.Add($item.Name)
        }
        else {
            while ($groupStack.Count -lt $item.Level) {
                $groupStack.Add($null)
                $pathStack.Add("Unknown")
            }
            $groupStack.Add($rowId)
            $pathStack.Add($item.Name)
        }
    }

    $rowClassParts = @()
    if ($item.IsGroup) {
        $rowClassParts += "group"

        if ($item.Name -match '(?i)\bcold\b') { $rowClassParts += "cold" }
        elseif ($item.Name -match '(?i)\bhot\b') { $rowClassParts += "hot" }
        elseif ($item.Name -match '(?i)\b(startup|shutdown|ambient|pre[-\s]?ess|post[-\s]?ess)\b') { $rowClassParts += "phase-normal" }
    }

    $rowClassParts += "level-$($item.Level)"

    if ($item.Status -eq "Failed") { $rowClassParts += "failed" }
    $rowClass = $rowClassParts -join " "

    $statusKey = ($item.Status -replace "\\s", "").ToLower()
    if (-not $statusKey) { $statusKey = "notrun" }

    $indent = $item.Level * 20
    $nameStyle = "padding-left: $($indent)px;"
    if ($item.IsGroup) { $nameStyle += " font-weight: bold;" }

    $toggleMarkup = ""
    if ($item.IsGroup) {
        if ($hasChildren) {
            $toggleMarkup = '<span class="caret" aria-hidden="true"></span>'
        }
        else {
            $toggleMarkup = '<span class="caret" aria-hidden="true" style="visibility:hidden; pointer-events:none;"></span>'
        }
    }
    else {
        $toggleMarkup = '<span class="dot status-' + $statusKey + '" aria-hidden="true"></span>'
    }

    $parentAttr = if ($parentId) { "data-parent=""$parentId""" } else { 'data-root="true"' }
    $expandableAttr = "data-expandable=""$(if ($hasChildren) { 1 } else { 0 })"""

    $displayValue = Format-DisplayValue $item.Value $item.Units

    $badgeClass = "test-status-badge"
    if ($statusKey -eq 'passed') { $badgeClass += " passed" }
    elseif ($statusKey -eq 'failed') { $badgeClass += " failed" }
    else { $badgeClass += " notrun" }

    $statusContent = if ($item.Status) { "<span class=""$badgeClass"">$($item.Status)</span>" } else { "" }

    [void]$htmlRowsSb.Append(@"
    <tr class="$rowClass" data-id="$rowId" data-level="$($item.Level)" $parentAttr $expandableAttr $parityAttrs>
        <td class="name-cell" style="$nameStyle">$toggleMarkup$($item.Name)</td>
        <td class="status-cell">
            $statusContent
        </td>
        <td class="value-cell">$displayValue</td>
        <td>$($item.Limits)</td>
        <td class="meta">$displayTime</td>
    </tr>
"@)
}

<# ----------------------------------------------------------------------
Section: HTML Assembly (template + inlined CSS/JS)
    Requirements:
      - Output HTML must be byte-identical to monolithic output
---------------------------------------------------------------------- #>

# Read assets raw (preserve whitespace)
$template = Get-Content -LiteralPath $templatePath -Raw
$css      = Get-Content -LiteralPath $cssPath -Raw
$js       = Get-Content -LiteralPath $jsPath -Raw

# Compute dynamic fragments that were previously embedded expressions
$overallBadgeClass = if ($overallResult -eq 'Passed') { 'passed' } else { 'failed' }

# Literal substitutions (do NOT use -replace; avoid regex and escaping changes)
$htmlContent = $template
$htmlContent = $htmlContent.Replace("__SERIAL_NUMBER__", $serialNumber)
$htmlContent = $htmlContent.Replace("__PART_NUMBER__", $partNumber)
$htmlContent = $htmlContent.Replace("__START_TIME__", $startTimeFormatted)
$htmlContent = $htmlContent.Replace("__OVERALL_RESULT__", $overallResult)
$htmlContent = $htmlContent.Replace("__OVERALL_BADGE_CLASS__", $overallBadgeClass)
$htmlContent = $htmlContent.Replace("__PASS_COUNT__", $passCount.ToString())
$htmlContent = $htmlContent.Replace("__FAIL_COUNT__", $failCount.ToString())
$htmlContent = $htmlContent.Replace("__TOTAL_TESTS__", $totalTests.ToString())

# Title uses serial number in original
$htmlContent = $htmlContent.Replace("__TITLE_SERIAL__", $serialNumber)

# Inline blocks
$htmlContent = $htmlContent.Replace("__INLINE_CSS__", $css)
$htmlContent = $htmlContent.Replace("__HTML_ROWS__", $htmlRowsSb.ToString())
$htmlContent = $htmlContent.Replace("__INLINE_JS__", $js)

$outDir = Split-Path -Parent $OutputHtmlPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

[System.IO.File]::WriteAllText($OutputHtmlPath, $htmlContent, [System.Text.Encoding]::UTF8)
Write-Host "Report generated successfully: $OutputHtmlPath" -ForegroundColor Green

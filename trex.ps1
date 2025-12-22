<#
.SYNOPSIS
    🦖 T-REX "TestStand Report Extractor" - TestStand XML to HTML Parser

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
    Version      : 2.0.4
    Creation     : 14NOV2025
    Last Update  : 19DEC2025
    Requires     : PowerShell 7.0+, Windows 10+
    Versioning   : Semantic Versioning 2.0.0 (Major.Minor.Patch)

.CHANGE LOG
    v2.0.4 - Redesigned UI with new color scheme and improved readability.
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
    [string]$OutputHtmlPath = "D:\Development\XML_Parser\Resources\Output.html"
)

<# ----------------------------------------------------------------------
Function: Convert-Comparator
    - Convert symbolic comparator codes into HTML-Safe equivalents.

This keeps the rendering logic isolated from the formatting layer
in the main HTML generation.
---------------------------------------------------------------------- #>
function Convert-Comparator {
    param($comp)

    if (-not $comp) { return "" }

    switch ($comp.ToString().ToUpper()) {
        'GE' { "&ge;" }    # Greater or Equal
        'GT' { "&gt;" }    # Greater Than
        'LE' { "&le;" }    # Less or Equal
        'LT' { "&lt;" }    # Less Than
        'EQ' { "=" }       # Equal (I know this should be '==' (compare, not set) but '=' is more human readable)
        'NE' { "&ne;" }    # Not Equal
        default { $comp }  # Fallback: unchanged
    }
}

<# ----------------------------------------------------------------------
Function: Get-LimitsString
    - Extract limit information from XML test result nodes and convert
      it into HTML-safe formatted text.

    - Check if the test node has limit information then convert comparator
      keywords (GE, LT, etc.) into HTML-safe entities.

TestStand's engine encodes limits in XML, often with symbolic comparator
codes that are not HTML-Safe. These have to be parsed and converted
prior to the HTML generation to avoid displaying broken characters.
---------------------------------------------------------------------- #>
function Get-LimitsString ($testResultNode) {
    # Validate input. Missing nodes are evaluated as no input.
    # If no node was passed, return an empty string to avoid
    # contaminating the HTML with "null".
    if (-not $testResultNode) { return "" }

    # Return empty for nodes that do not include limits.
    $limits = $testResultNode.TestLimits.Limits
    if (-not $limits) { return "" }

    # Limit Pair Handler
    # Filter limit pairs to identify "High" and "Low" boundaries.
    if ($limits.LimitPair) {
        $low = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "GE|GT" } | Select-Object -First 1
        $high = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "LE|LT" } | Select-Object -First 1
        $segments = @()

        # Label boundaries explicitly for readability.
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
    - Extract raw limit data for parity verification.
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

    # Normalize Comparators
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
    - Normalize timestamps into NATO DTG (HH:MMZ | DDMMYYYY).
    - Falls back to the base input if parsing fails.

TestStand's engine displays full time including milliseconds with a very
poorly formatted date the result of which is virtually unintelligible at
a glance.
---------------------------------------------------------------------- #>
function Format-Timestamp ($timestamp) {
    if (-not $timestamp) { return '' }
    try {
        $dt = [datetime]$timestamp
        return $dt.ToString("HH:mm:ss - ddMMMyyyy").ToUpper()
    }
    catch {
        return $timestamp   # Preserve the raw value if string parsing fails.
    }
}

<# ----------------------------------------------------------------------
Function: Format-DisplayValue
    - Normalize certain tokens in the visible HTML.
    - "## PORT" -> "PORT ##"
---------------------------------------------------------------------- #>
function Format-DisplayValue ($val, $unit) {
    # Normalize nulls
    $v = if ($val) { $val.ToString().Trim() } else { "" }
    $u = if ($unit) { $unit.ToString().Trim() } else { "" }

    if (-not $v -and -not $u) { return "" }
    
    # Port token re-order
    if ($u -eq "PORT" -and $v -match '^\d+$') {
        return "PORT $v"
    }
    
    # Default
    if ($v -and $u) { return "$v $u" }
    if ($v) { return $v }
    if ($u) { return $u }
    return ""
}

<# ----------------------------------------------------------------------
Function: Format-ResultSetDisplayName
    - Convert a ResultSet "name" path into a readable display name.
---------------------------------------------------------------------- #>
function Format-ResultSetDisplayName ([string]$rawName) {
    if (-not $rawName) { return "" }

    # Drop anything after '#'
    $base = ($rawName -split '#', 2)[0]

    # Keep the file name
    $leaf = [System.IO.Path]::GetFileName($base)

    # Remove ".seq" extension
    if ($leaf -match '\.seq$') { $leaf = $leaf -replace '\.seq$', '' }

    # Replace underscores with spaces and collapse doubles
    $leaf = ($leaf -replace '_', ' ') -replace '\s{2,}', ' '

    return $leaf.Trim()
}

<# ----------------------------------------------------------------------
Function: Get-TestNode
    - Recursively walks through TestGroup, Test, and SessionAction nodes
      flattening the hierarchical XML into a list of easy to render
      custom PowerShell objects that include formattable data such as
      tree depth, value, limit, and timestamp.

The asinine way in which TestStand progressively builds out data trees
results in deeply nested data multiple layers in depth. The cleanest way
to evaluate this data while preserving the parent-child-kid context is
full recursion to whatever arbitrary depth is necessary which means
walking the entire tree down and back up. It's not exactly efficient
but it ensures no data or context is lost in the process and that all
data is captured which removes the requirement for a post parsing
validation or some kind of data hashing mechanism to check for parity.
---------------------------------------------------------------------- #>

function Get-TestNode ($node, $level) {
    $results = @()

    # Use 'callerName' for step indicator otherwise fallback to internally coded name.
    $name = if ($node.callerName) { $node.callerName } else { $node.name }

    if ($node.LocalName -eq 'ResultSet' -and $node.name) {
        $name = Format-ResultSetDisplayName $node.name
    }

    $status = $node.Outcome.value
    $timestamp = $node.endDateTime
    # Prioritize retrieving numeric result blocks for display.
    $numericResult = $node.TestResult | Where-Object { $_.name -eq 'Numeric' } | Select-Object -First 1

    # Initialize output fields
    $value = ''
    $units = ''
    $limits = ''

    # Extract value, units, and limit information from any present numeric block.
    $limitData = $null
    $kind = "Step" 

    if ($numericResult) {
        $value = $numericResult.TestData.Datum.value
        $units = $numericResult.TestData.Datum.nonStandardUnit
        $kind = "Measurement"

        # Fallback to standardized unit if no custom unit is present.
        if (-not $units) { $units = $numericResult.TestData.Datum.unit }
        $limits = Get-LimitsString $numericResult
        $limitData = Get-LimitInfo $numericResult
    }

    if ($node.LocalName -in @("TestGroup", "SessionAction")) {
        $kind = "Group"
    }

    # Create normalized custom PowerShell object for the current node.
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
    # Identify child nodes to recurse into including TestGroup, Test, and SessionAction types.
    $children = $node.ChildNodes | Where-Object {
        $_.NodeType -eq 'Element' -and $_.LocalName -in @("TestGroup", "Test", "SessionAction")
    }
    # Increase indentation level for each child to preserve structure.
    foreach ($child in $children) {
        $results += Get-TestNode $child ($level + 1)
    }

    return $results
}

<# ----------------------------------------------------------------------
Section: Main Execution
    - Validate input.
    - Load XML.
    - Extract Metadata.
    - Flatten test results.
    - Calculate statistics.
    - Prep rows for HTML generation.
---------------------------------------------------------------------- #>
Write-Host "Validating XML file path: $XmlPath" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $XmlPath)) {
    Write-Error "File not found: $XmlPath"
    exit 1
}

# Load XML content.
[xml]$xml = Get-Content -LiteralPath $XmlPath -Raw

# Extract header information including serial number, part number, and status.
# Defensively guard against null results from incomplete tests.
$uut = $xml.TestResultsCollection.TestResults.UUT

# Extract UUT serial number.
$serialNumber = $uut.SerialNumber
if ($serialNumber) { $serialNumber = $serialNumber.Trim() } else { $serialNumber = "[missing serial]" }

# Extract UUT part number.
$partNumber = $uut.Definition.Identification.IdentificationNumbers.IdentificationNumber.number
if (-not $partNumber) { $partNumber = "[missing part]" }

# Extract overall execution start time.
$startTime = $xml.TestResultsCollection.TestResults.ResultSet.startDateTime
$startTimeFormatted = if ($startTime) { Format-Timestamp $startTime } else { "[missing start time]" }

# Extract final outcome of test.
$overallResult = $xml.TestResultsCollection.TestResults.ResultSet.Outcome.value
if (-not $overallResult) { $overallResult = "[unknown]" }

Write-Host "Parsing test data..." -ForegroundColor Cyan

# Flatten test result hierarchy.
$resultSet = $xml.TestResultsCollection.TestResults.ResultSet
$flatResults = Get-TestNode $resultSet 0

# Compute summary statistics excluding group containers.
$totalTests = ($flatResults | Where-Object { -not $_.IsGroup }).Count
$passCount = ($flatResults | Where-Object { -not $_.IsGroup -and $_.Status -eq "Passed" }).Count
$failCount = ($flatResults | Where-Object { -not $_.IsGroup -and $_.Status -eq "Failed" }).Count

$renderRows = $flatResults


<# ----------------------------------------------------------------------
Section: HTML Generation
    - Build self-contained collapsible HTML table.
---------------------------------------------------------------------- #>
Write-Host "Generating HTML..." -ForegroundColor Cyan
$htmlRowsSb = New-Object System.Text.StringBuilder

# Stack ID counter to track the ID of the current parent group.
$rowIdCounter = 0
$groupStack = New-Object System.Collections.Generic.List[string] # Tracks latest group ID per group depth

# Parity Tracking
$pathStack = New-Object System.Collections.Generic.List[string] # Tracks ancestor names
$ordinalTracker = @{} # Maps "ParentPath|Name|Kind" -> Integer Count

foreach ($item in $renderRows) {
    # Trim the stack when moving back up the tree to preserve hierarchy structure.
    while ($groupStack.Count -gt $item.Level) { 
        $groupStack.RemoveAt($groupStack.Count - 1) 
        # Sync path stack
        if ($pathStack.Count -gt $groupStack.Count) { $pathStack.RemoveAt($pathStack.Count - 1) }
    }
}

for ($i = 0; $i -lt $renderRows.Count; $i++) {
    $item = $renderRows[$i]
    
    # Lookahead: Check if the next item is a child (deeper level).
    $hasChildren = ($i -lt $renderRows.Count - 1) -and ($renderRows[$i + 1].Level -gt $item.Level)

    # Trim the stack when moving back up the tree to preserve hierarchy structure.
    while ($groupStack.Count -gt $item.Level) { 
        $groupStack.RemoveAt($groupStack.Count - 1) 
        # Sync path stack
        if ($pathStack.Count -gt $groupStack.Count) { $pathStack.RemoveAt($pathStack.Count - 1) }
    }

    # Determine parent ID of current row based on tree depth.
    $parentId = $null
    if ($item.Level -gt 0 -and $groupStack.Count -ge $item.Level) {
        $parentId = $groupStack[$item.Level - 1]
    }
    
    # --- Parity Verification ---
    # 1. Compute Path (Ancestors + Current)
    #       - Contract: Path delimiter is "/"
    $parentPath = $pathStack -join '/'
    $currentPath = if ($parentPath) { "$parentPath/$($item.Name)" } else { $item.Name }
    
    # 2. Compute Execution Ordinal
    #       - Key: "ParentPath|Name|Kind"
    $ordKey = "$parentPath|$($item.Name)|$($item.Kind)"
    if (-not $ordinalTracker.ContainsKey($ordKey)) { $ordinalTracker[$ordKey] = 0 }
    $ordinalTracker[$ordKey]++
    $ordinal = $ordinalTracker[$ordKey]

    # 3. Prep Attribute Strings
    $pStatus = if ($item.Status) { $item.Status } else { "" }
    
    # Normalize Value for Parity Verification
    $pValue = if ($item.Value) { $item.Value } else { "" }
    $pUnit = if ($item.Units) { $item.Units } else { "" }
    
    $pLow = ""; $pLowC = "NONE"; $pHigh = ""; $pHighC = "NONE"; $pExp = ""; $pExpC = "NONE"
    if ($item.LimitData) {
        if ($item.LimitData.Low) { $pLow = $item.LimitData.Low }
        if ($item.LimitData.LowComp) { $pLowC = $item.LimitData.LowComp }
        if ($item.LimitData.High) { $pHigh = $item.LimitData.High }
        if ($item.LimitData.HighComp) { $pHighC = $item.LimitData.HighComp }
        if ($item.LimitData.Expected) { $pExp = $item.LimitData.Expected }
        if ($item.LimitData.ExpectedComp) { $pExpC = $item.LimitData.ExpectedComp }
    }

    # Escape attribute values
    $EscSimple = { param($s) 
        if (-not $s) { return "" }
        return $s.ToString().Replace('&', '&amp;').Replace('"', '&quot;').Replace('<', '&lt;').Replace('>', '&gt;')
    }

    # Prep Formatted Timestamp values.
    $displayTime = Format-Timestamp $item.Time
    $pTime = if ($displayTime) { $displayTime } else { "" }

    $parityAttrs = "data-parity-path=""$(& $EscSimple $currentPath)"" " +
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
    # --- Parity Verification End ---

    $rowIdCounter++
    $rowId = "row$rowIdCounter"

    # If the current item is a group push its ID to the stack to track
    # subsequent children as part of this group.
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
            # Fill empty gaps on the off chance a level gets skipped.
            while ($groupStack.Count -lt $item.Level) { 
                $groupStack.Add($null) 
                $pathStack.Add("Unknown") 
            }
            $groupStack.Add($rowId)
            $pathStack.Add($item.Name)
        }
    }

    # Determine CSS classes for row styling based on status or group type.
    $rowClassParts = @()
    if ($item.IsGroup) {
        $rowClassParts += "group"

        # Theme groups by name; descendants inherit via JS.
        if ($item.Name -match '(?i)\bcold\b') { $rowClassParts += "cold" }
        elseif ($item.Name -match '(?i)\bhot\b') { $rowClassParts += "hot" }
        elseif ($item.Name -match '(?i)\b(startup|shutdown|ambient|pre[-\s]?ess|post[-\s]?ess)\b') { $rowClassParts += "phase-normal" }
    }
    
    # Add level styling hook
    $rowClassParts += "level-$($item.Level)"

    if ($item.Status -eq "Failed") { $rowClassParts += "failed" }
    $rowClass = $rowClassParts -join " "
    

    # Clean the status tag for use as a css class
    $statusKey = ($item.Status -replace "\\s", "").ToLower()
    if (-not $statusKey) { $statusKey = "notrun" }

    # Calculate the visual indentation at 20px per level of tree depth.
    $indent = $item.Level * 20
    $nameStyle = "padding-left: $($indent)px;"
    if ($item.IsGroup) { $nameStyle += " font-weight: bold;" }

    # Icons: Caret for groups, colored dot for tests.
    $toggleMarkup = ""
    if ($item.IsGroup) { 
        if ($hasChildren) {
            $toggleMarkup = '<span class="caret" aria-hidden="true"></span>' 
        }
        else {
            # Hide Caret if group has no children.
            $toggleMarkup = '<span class="caret" aria-hidden="true" style="visibility:hidden; pointer-events:none;"></span>' 
        }
    }
    else { 
        $toggleMarkup = '<span class="dot status-' + $statusKey + '" aria-hidden="true"></span>' 
    }

    # JS data attributes for expand/collapse logic.
    $parentAttr = if ($parentId) { "data-parent=""$parentId""" } else { 'data-root="true"' }
    $expandableAttr = "data-expandable=""$(if ($hasChildren) { 1 } else { 0 })"""

    # Prep formatted value/unit strings.
    $displayValue = Format-DisplayValue $item.Value $item.Units
    
    # Status Badge
    $badgeClass = "test-status-badge"
    if ($statusKey -eq 'passed') { $badgeClass += " passed" }
    elseif ($statusKey -eq 'failed') { $badgeClass += " failed" }
    else { $badgeClass += " notrun" }
    
    # Only show badge \if Status is present
    $statusContent = if ($item.Status) { "<span class=""$badgeClass"">$($item.Status)</span>" } else { "" }

    # Build HTML table rows.
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
Function: HTML Assembly
    - Combine generated rows with static HTML framework
    - Embed CSS styling and JavaScript directly into HTML

Using the PowerShell script to build the framework and then embedding
the CSS and JavaScript directly in the HTML ensures portability as
the resulting file is not reliant on any external data source once
generated. This also ensures it will load in virtually any environment.
---------------------------------------------------------------------- #>
$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Test Report - $serialNumber</title>
<style>
        :root {
            /* Base */
            --neutral-950: rgba(10,10,10,1);
            --neutral-900: rgba(23,23,23,1);
            --neutral-800: rgba(38,38,38,1);
            --neutral-700: rgba(64,64,64,1);
            --neutral-600: rgba(82,82,82,1);
            --neutral-500: rgba(115,115,115,1);
            --neutral-300: rgba(212,212,216,1);
            --neutral-200: rgba(229,229,229,1);
            --neutral-100: rgba(245,245,245,1);

            --zinc-200: rgba(228,228,231,1);
            --zinc-300: rgba(212,212,216,1);
            --zinc-400: rgba(161,161,170,1);
            --zinc-500: rgba(113,113,122,1);
            --zinc-600: rgba(82,82,91,1);

            /* Page */
            --bg-page: var(--neutral-950);
            --bg-card: var(--neutral-900);
            --bg-table: var(--neutral-900);
            --bg-header: var(--neutral-800);
            --bg-header-grad-end: var(--neutral-900);

            --border-strong: var(--neutral-800);
            --border: var(--neutral-700);
            --border-muted: rgba(63,63,70,0.55); /* ~zinc-700/55-ish */

            /* Text */
            --text-strong: var(--neutral-100);
            --text: var(--neutral-200);
            --text-subtle: var(--neutral-300);
            --text-muted: var(--neutral-500);
            --text-faint: var(--zinc-500);

            /* Columns */
            --col-muted: var(--zinc-400);
            --caret: var(--zinc-400);
            --caret-hover: var(--zinc-200);

            /* Row Backgrounds */
            --row-bg-group-top: rgba(38,38,38,0.70);  /* Group Header */
            --row-bg-group: rgba(63,63,70,0.36);    /* Nested Groups */
            --row-bg-leaf: rgba(63,63,70,0.18);            /* Test Rows */
            --row-bg-leaf-alt: rgba(63,63,70,0.23);      /* Test Rows 2 */

            /* Hover */
            --row-hover-overlay: rgba(255,255,255,0.055);

            /* Status Badges */
            --pass-bg: rgba(16,185,129,0.2);
            --pass-text: rgba(52,211,153,1);
            --pass-border: rgba(16,185,129,0.3);

            --fail-bg: rgba(244,63,94,0.2);
            --fail-text: rgba(251,113,133,1);
            --fail-border: rgba(244,63,94,0.3);

            --badge-neutral-bg: rgba(39,39,42,0.5);
            --badge-neutral-text: var(--text-muted);
            --badge-neutral-border: var(--border);

            /* Cycle Indicator Accents */
            --accent-cold: rgba(162, 198, 245, 0.40);
            --accent-hot: rgba(252, 198, 192, 0.40);
            --accent-neutral: rgba(255, 255, 255, 0.12);
        }

        body {
            font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            color: var(--text);
            margin: 20px;
            background-color: var(--bg-page);
        }

        .summary-box {
            background: var(--bg-card);
            padding: 15px;
            border: 1px solid var(--border-strong);
            margin-bottom: 20px;
            border-radius: 12px;
            display: flex;
            gap: 30px;
            box-shadow: 0 10px 25px rgba(0,0,0,0.35);
            background-image: linear-gradient(to bottom, var(--bg-header), var(--bg-header-grad-end) 40%);
            border-bottom: 1px solid var(--border);
        }

        .summary-item { display: flex; flex-direction: column; }

        .summary-label {
            font-size: 12px;
            color: var(--text-muted);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            font-weight: 600;
        }

        .summary-value {
            font-size: 16px;
            font-weight: 600;
            color: var(--text);
        }

        .stats-detail {
            font-size: 0.75rem;
            font-weight: normal;
            margin-left: 8px;
            white-space: nowrap;
            color: var(--text-muted);
        }

        table {
            width: 100%;
            border-collapse: separate;
            border-spacing: 0;
            background: var(--bg-table);
            border: 1px solid var(--border-strong);
            border-radius: 12px;
            table-layout: auto;
            overflow: hidden;
        }

        th {
            background-color: var(--bg-header);
            color: var(--text);
            text-align: left;
            padding: 12px 10px;
            border-bottom: 1px solid var(--border);
            font-size: 14px;
            font-weight: 500;
        }

        td {
            padding: 8px 10px;
            border-bottom: 1px solid var(--border-muted);
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
            color: var(--text-subtle);
            background-color: var(--row-bg-leaf);
        }

        /* ============================================================
           Row Shading
           ============================================================ */

        /* Test Rows */
        tr:not(.group) td {
            background-color: var(--row-bg-leaf);
            color: var(--neutral-300);
            font-weight: 400;
        }

        /* Test Rows 2 */
        tbody tr:not(.group):nth-of-type(even) td {
            background-color: var(--row-bg-leaf-alt);
        }

        /* Nested Groups */
        tr.group td {
            background-color: var(--row-bg-group);
            color: var(--neutral-200);
            font-weight: 500;
        }

        /* Group Header */
        tr.group[data-level="0"] td {
            background-color: var(--row-bg-group-top);
            color: var(--neutral-100);
            font-weight: 600;
        }

        /* Hover */
        tr:hover td {
            box-shadow: inset 0 0 0 9999px var(--row-hover-overlay);
            transition: box-shadow 0.1s ease;
        }

        /* Cycle Indicator Accents */
        tr.group.cold td.name-cell, tr.cold:not(.group) td.name-cell { box-shadow: inset 4px 0 0 var(--accent-cold); }
        tr.group.hot td.name-cell, tr.hot:not(.group) td.name-cell { box-shadow: inset 4px 0 0 var(--accent-hot); }
        tr.group.phase-normal td.name-cell, tr.phase-normal:not(.group) td.name-cell { box-shadow: inset 4px 0 0 var(--accent-neutral); }

        /* Removed */
        .failed { background-color: transparent; }
        .failed .value-cell { color: var(--fail-text); font-weight: 700; }

        /* ============================================================
           Timestamps
           ============================================================ */
        td:nth-child(5),
        td:nth-child(5) *,
        .timestamp-cell,
        .timestamp-cell * {
            font-size: 14px !important;
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace !important;
            color: var(--text-faint) !important;
            font-weight: 400 !important;
        }

        .meta, .meta * {
            font-size: 14px !important;
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace !important;
            color: var(--text-faint) !important;
            font-weight: 400 !important;
        }

        .name-cell {
            cursor: default;
            user-select: none;
            white-space: normal;
            word-break: break-word;
        }

        .name-cell .caret {
            display: inline-block;
            width: 8px;
            height: 8px;
            margin-right: 10px;
            border: solid var(--caret);
            border-width: 0 2px 2px 0;
            transform: rotate(-45deg);
            transition: transform 0.2s ease, border-color 0.2s;
        }

        .name-cell:hover .caret { border-color: var(--caret-hover); }

        .name-cell .dot {
            display: inline-block;
            width: 6px;
            height: 6px;
            margin: 0 8px 2px 2px;
            border-radius: 50%;
            background: var(--neutral-700);
            vertical-align: middle;
        }

        .dot.status-passed { background: var(--pass-text); }
        .dot.status-failed { background: var(--fail-text); }
        .dot.status-inprogress, .dot.status-interrupted { background: #d99000; }
        .dot.status-notrun { background: var(--neutral-600); }

        .failed .dot.status-failed { box-shadow: 0 0 4px var(--fail-text); }

        .group[data-expanded="true"] .caret,
        #global-toggle.expanded { transform: rotate(45deg); }

        #global-toggle {
            display: inline-block;
            width: 8px;
            height: 8px;
            margin-right: 6px;
            border: solid var(--caret);
            border-width: 0 2px 2px 0;
            transform: rotate(-45deg);
            transition: transform 0.2s ease, border-color 0.2s;
            cursor: pointer;
            vertical-align: middle;
        }
        #global-toggle:hover { border-color: var(--caret-hover); }

        tr[hidden] { display: none; }

        /* Status Badges */
        .test-status-badge {
            display: inline-flex;
            align-items: center;
            padding: 0.25rem 0.625rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 600;
            line-height: 1rem;
        }
        .test-status-badge.passed { background-color: var(--pass-bg); color: var(--pass-text); border: 1px solid var(--pass-border); }
        .test-status-badge.failed { background-color: var(--fail-bg); color: var(--fail-text); border: 1px solid var(--fail-border); }
        .test-status-badge.notrun, .test-status-badge.unknown { background-color: var(--badge-neutral-bg); color: var(--badge-neutral-text); border: 1px solid var(--badge-neutral-border); }

        /* Values/Limits */
        .value-cell, td:nth-child(3), td:nth-child(4) { color: var(--col-muted); }
    </style>
</head>
<body>
    <div class="summary-box">
        <div class="summary-item">
            <span class="summary-label">Serial Number</span>
            <span class="summary-value">$serialNumber</span>
        </div>
        <div class="summary-item">
            <span class="summary-label">Part Number</span>
            <span class="summary-value">$partNumber</span>
        </div>
        <div class="summary-item">
            <span class="summary-label">Start Time</span>
            <span class="summary-value">$startTimeFormatted</span>
        </div>
        <div class="summary-item">
            <span class="summary-label">Result</span>
            <span class="summary-value">
                <span class="test-status-badge $(if($overallResult -eq 'Passed') { 'passed' } else { 'failed' })">$overallResult</span>
            </span>
        </div>
         <div class="summary-item">
            <span class="summary-label">Stats</span>
            <span class="summary-value">
                <span class="pass-count" style="color:var(--pass-text)">$passCount Pass</span> / <span class="fail-count" style="color:var(--fail-text)">$failCount Fail</span>
                <span class="stats-detail">
                    ($totalTests Total)
                </span>
            </span>
        </div>
    </div>
    <table>
        <thead>
            <tr>
                <th><span id="global-toggle" class="caret" title="Toggle All"></span> Step Name</th>
                <th>Status</th>
                <th>Value</th>
                <th>Limits</th>
                <th>Timestamp</th>
            </tr>
        </thead>

        <tbody>
            $($htmlRowsSb.ToString())
        </tbody>

    </table>

    <script>
        (() => {
            const tbody = document.querySelector('tbody');
            const rows = Array.from(tbody.querySelectorAll('tr'));
            const children = new Map();
            const globalToggle = document.getElementById('global-toggle');

            const lockColumnWidths = () => {
                const table = tbody.closest('table');
                const theadRow = table.querySelector('thead tr');
                const headerCells = Array.from(theadRow.cells);

                const prevVis = table.style.visibility;
                table.style.visibility = 'hidden';

                const prevLayout = table.style.tableLayout;
                table.style.tableLayout = 'auto';
                const touched = [];
                rows.forEach(r => {
                    Array.from(r.cells).forEach(c => {
                        touched.push([c, c.style.whiteSpace, c.style.overflow, c.style.textOverflow]);
                        c.style.whiteSpace = 'nowrap';
                        c.style.overflow = 'visible';
                        c.style.textOverflow = 'clip';
                    });
                });

                const prevHidden = rows.map(r => r.hidden);
                rows.forEach(r => r.hidden = false);

                const colCount = headerCells.length;
                const max = new Array(colCount).fill(0);

                headerCells.forEach((cell, i) => { max[i] = Math.max(max[i], cell.scrollWidth); });

                rows.forEach(r => {
                    for (let i = 0; i < colCount; i++) {
                        const cell = r.cells[i];
                        if (!cell) continue;
                        max[i] = Math.max(max[i], cell.scrollWidth);
                    }
                });

                rows.forEach((r, i) => r.hidden = prevHidden[i]);

                const pad = 24;
                const old = table.querySelector('colgroup');
                if (old) old.remove();

                const colgroup = document.createElement('colgroup');
                max.forEach(w => {
                    const col = document.createElement('col');
                    col.style.width = (w + pad) + 'px';
                    colgroup.appendChild(col);
                });
                table.insertBefore(colgroup, table.firstChild);

                touched.forEach(([c, ws, ov, to]) => {
                    c.style.whiteSpace = ws;
                    c.style.overflow = ov;
                    c.style.textOverflow = to;
                });
                table.style.tableLayout = prevLayout;

                table.style.visibility = prevVis;
            };

            lockColumnWidths();

            rows.forEach(row => {
                const parent = row.dataset.parent;
                if (parent) {
                    const next = children.get(parent) || [];
                    next.push(row);
                    children.set(parent, next);
                    row.hidden = true;
                }
                if (row.classList.contains('group')) {
                    row.classList.add('collapsed');
                }
            });

            const applyTheme = (row, themeClass) => {
                const kids = children.get(row.dataset.id) || [];
                kids.forEach(kid => {
                    kid.classList.add(themeClass);
                    if (kid.classList.contains('group')) {
                        applyTheme(kid, themeClass);
                    }
                });
            };

            rows.forEach(row => {
                if (!row.classList.contains('group')) return;
                if (row.classList.contains('cold')) applyTheme(row, 'cold');
                else if (row.classList.contains('hot')) applyTheme(row, 'hot');
                else if (row.classList.contains('phase-normal')) applyTheme(row, 'phase-normal');
            });

            const collapse = (row) => {
                row.classList.add('collapsed');
                row.dataset.expanded = 'false';
                const kids = children.get(row.dataset.id) || [];
                kids.forEach(kid => {
                    kid.hidden = true;
                    if (kid.classList.contains('group')) {
                        collapse(kid);
                    }
                });
            };

            const expand = (row) => {
                row.classList.remove('collapsed');
                row.dataset.expanded = 'true';
                const kids = children.get(row.dataset.id) || [];
                kids.forEach(kid => {
                    kid.hidden = false;
                    if (kid.classList.contains('group')) {
                        kid.classList.add('collapsed');
                    }
                });
            };

            rows.filter(r => r.classList.contains('group')).forEach(collapse);

            globalToggle.addEventListener('click', () => {
                const isExp = globalToggle.classList.contains('expanded');
                if (isExp) {
                    globalToggle.classList.remove('expanded');
                    rows.forEach(r => {
                        if (r.dataset.parent) r.hidden = true;
                        if (r.classList.contains('group')) {
                            r.classList.add('collapsed');
                            r.dataset.expanded = 'false';
                        }
                    });
                } else {
                    globalToggle.classList.add('expanded');
                    rows.forEach(r => {
                        r.hidden = false;
                        if (r.classList.contains('group') && r.dataset.expandable !== "0") {
                            r.classList.remove('collapsed');
                            r.dataset.expanded = 'true';
                        }
                    });
                }
            });

            tbody.addEventListener('click', (event) => {
                const nameCell = event.target.closest('.name-cell');
                if (!nameCell) { return; }
                const row = nameCell.parentElement;
                if (!row.classList.contains('group')) { return; }

                if (row.dataset.expandable === "0") { return; }

                const isCollapsed = row.classList.contains('collapsed');
                if (isCollapsed) { expand(row); } else { collapse(row); }
            });
        })();
    </script>
</body>
</html>
"@


$outDir = Split-Path -Parent $OutputHtmlPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($OutputHtmlPath, $htmlContent, [System.Text.Encoding]::UTF8)
Write-Host "Report generated successfully: $OutputHtmlPath" -ForegroundColor Green

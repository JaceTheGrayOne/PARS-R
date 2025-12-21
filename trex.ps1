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
    Version      : 0.0.6
    Creation     : 14NOV2025
    Last Update  : 19DEC2025
    Requires     : PowerShell 7.0+, Windows 10+
    Versioning   : Semantic Versioning 2.0.0 (Major.Minor.Patch)

.CHANGE LOG
    v0.0.6 - Adjusted several UI elements for readability
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
    - Extract raw limit data for parity verification (canonical tokens).
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

    # Normalize Comparator Helper
    # Maps symbols to canonical tokens: GE, GT, LE, LT, EQ, NE, NONE
    $Normalize = { param($c)
        if (-not $c) { return "NONE" }
        switch -Regex ($c.ToString().ToUpper()) {
            'GE|&GE;|=>' { 'GE' }
            'GT|&GT;|>' { 'GT' }
            'LE|&LE;|=>' { 'LE' }
            'LT|&LT;|<' { 'LT' }
            'EQ|=|==' { 'EQ' }
            'NE|&NE;|!=' { 'NE' }
            default { $c } # Pass through if already token or unknown
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
        # Preserve the raw value if string parsing fails.
        return $timestamp
    }
}

<# ----------------------------------------------------------------------
Function: Format-ParityValue
    - Normalizes symbolic or weirdly formatted value strings.
    - REQ: "123 PORT" -> "PORT 123"
---------------------------------------------------------------------- #>
<# ----------------------------------------------------------------------
Function: Format-DisplayValue
    - Formats the VISIBLE text in the HTML cell.
    - REQ: If Units="PORT" & Value is numeric -> "PORT 123"
    - Default: "123 Units"
---------------------------------------------------------------------- #>
function Format-DisplayValue ($val, $unit) {
    # Normalize nulls
    $v = if ($val) { $val.ToString().Trim() } else { "" }
    $u = if ($unit) { $unit.ToString().Trim() } else { "" }

    if (-not $v -and -not $u) { return "" }
    
    # Special Case: Port reordering
    if ($u -eq "PORT" -and $v -match '^\d+$') {
        return "PORT $v"
    }
    
    # Default Formatting
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

    # Keep the leaf file name
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
    
    # --- Parity Logic Start ---
    # 1. Compute Path (Ancestors + Current)
    # Note: pathStack currently contains only ancestors up to Level-1
    # Parity Contract: Path delimiter is "/"
    $parentPath = $pathStack -join '/'
    $currentPath = if ($parentPath) { "$parentPath/$($item.Name)" } else { $item.Name }
    
    # 2. Compute Execution Ordinal
    # Key: "ParentPath|Name|Kind"
    $ordKey = "$parentPath|$($item.Name)|$($item.Kind)"
    if (-not $ordinalTracker.ContainsKey($ordKey)) { $ordinalTracker[$ordKey] = 0 }
    $ordinalTracker[$ordKey]++
    $ordinal = $ordinalTracker[$ordKey]

    # 3. Prepare Attribute String
    # Normalize nulls to empty strings safely
    # Note: $item properties are mostly strings already, LimitData might be null if not populated
    $pStatus = if ($item.Status) { $item.Status } else { "" }
    
    # Normalize Value for Parity
    # Normalize Value for Parity
    # We keep the raw value for parity comparisons to match the XML source (split fields)
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

    # Helper/Closure to escape attribute values
    # Since HttpUtility might not be loaded, using Replace
    $EscSimple = { param($s) 
        if (-not $s) { return "" }
        return $s.ToString().Replace('&', '&amp;').Replace('"', '&quot;').Replace('<', '&lt;').Replace('>', '&gt;')
    }

    # Prep formatted Timestamp values.
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
    # --- Parity Logic End ---

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
            # Sync path: We are replacing at Level. 
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
    if ($item.Status -eq "Failed") { $rowClassParts += "failed" }
    $rowClass = $rowClassParts -join " "
    

    # Clean the status tag for use as a css class
    $statusKey = ($item.Status -replace "\\s", "").ToLower()
    if (-not $statusKey) { $statusKey = "notrun" }

    # Calculate the visual indentation at 20px per level of tree depth.
    $indent = $item.Level * 20
    $nameStyle = "padding-left: $($indent)px;"
    if ($item.IsGroup) { $nameStyle += " font-weight: bold;" }

    # Icon selection: Caret for groups, colored dot for tests.
    $toggleMarkup = ""
    if ($item.IsGroup) { 
        if ($hasChildren) {
            $toggleMarkup = '<span class="caret" aria-hidden="true"></span>' 
        }
        else {
            # Hidden caret for empty groups (preserves spacing but removes visual cue)
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
    # Prep formatted value/unit strings.
    # Logic moved to Format-DisplayValue to handle Port reordering in UI only
    $displayValue = Format-DisplayValue $item.Value $item.Units

    # Build HTML table rows.
    [void]$htmlRowsSb.Append(@"
    <tr class="$rowClass" data-id="$rowId" data-level="$($item.Level)" $parentAttr $expandableAttr $parityAttrs>
        <td class="name-cell" style="$nameStyle">$toggleMarkup$($item.Name)</td>
        <td class="status-cell status-$statusKey">$($item.Status)</td>
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
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            color: #333;
            margin: 20px;
            background-color: #f9f9f9;
        }

        .summary-box {
            background: #fff;
            padding: 15px;
            border: 1px solid #ddd;
            margin-bottom: 20px;
            border-radius: 4px;
            display: flex;
            gap: 30px;
        }

        .summary-item {
            display: flex;
            flex-direction: column;
        }

        .summary-label {
            font-size: 0.85em;
            color: #777;
            text-transform: uppercase;
        }

        .summary-value {
            font-size: 1.2em;
            font-weight: bold;
        }

        .stats-detail {
            font-size: 0.60em;
            font-weight: normal;
            margin-left: 2px;
            white-space: nowrap;
        }

        .pass-badge {
            color: #27ae60;
        }
        
        .fail-badge {
            color: #c0392b;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            background: #fff;
            border: 1px solid #ddd;
            table-layout: auto;
        }

        th {
            background-color: #f1f1f1;
            text-align: left;
            padding: 10px;
            border-bottom: 2px solid #ddd;
        }

        td {
            padding: 8px 10px;
            border-bottom: 1px solid #eee;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }

        .group {
            background-color: #f8f9fa;
            color: #555;
        }

        /* Hot/Cold theming (Step Name cell only) */
        tr.group.cold td.name-cell {
            box-shadow: inset 6px 0 0 rgba(162, 198, 245, 0.75);
        }
        tr.cold:not(.group) td.name-cell {
            box-shadow: inset 6px 0 0 rgba(162, 198, 245, 0.55);
        }

        tr.group.hot td.name-cell {
            box-shadow: inset 6px 0 0 rgba(252, 198, 192, 0.75);
        }
        tr.hot:not(.group) td.name-cell {
            box-shadow: inset 6px 0 0 rgba(252, 198, 192, 0.55);
        }

        /* Normal phase theming (Startup/Pre/Ambient/Post/Shutdown) */
        tr.group.phase-normal td.name-cell {
            box-shadow: inset 6px 0 0 rgba(0, 0, 0, 0.18);
        }
        tr.phase-normal:not(.group) td.name-cell {
            box-shadow: inset 6px 0 0 rgba(0, 0, 0, 0.12);
        }

        .failed {
            background-color: #ffe6e6;
        }

        .failed .value-cell {
            color: #c0392b;
            font-weight: bold;
        }

        .meta {
            font-size: 0.85em;
            color: #999;
        }

        .name-cell {
            cursor: default;
            user-select: none;
            white-space: normal;
            word-break: break-word;
        }

        .name-cell .caret {
            display: inline-block;
            width: 10px;
            height: 10px;
            margin-right: 10px;
            border: solid #555;
            border-width: 0 2px 2px 0;
            transform: rotate(-45deg);
            transition: transform 0.2s ease;
        }

        .name-cell .dot {
            display: inline-block;
            width: 8px;
            height: 8px;
            margin: 0 8px 1px 2px;
            border-radius: 50%;
            background: #bbb;
            vertical-align: middle;
        }
        .group[data-expanded="true"] .caret,
        #global-toggle.expanded {
            transform: rotate(45deg);
        }
        
        #global-toggle {
            display: inline-block;
            width: 10px;
            height: 10px;
            margin-right: 6px;
            border: solid #333;
            border-width: 0 2px 2px 0;
            transform: rotate(-45deg);
            transition: transform 0.2s ease;
            cursor: pointer;
            vertical-align: middle;
        }
        
        tr[hidden] {
            display: none;
        }

        /* Status colors */
        .status-cell {
            font-weight: bold;
        }

        .status-passed {
            color: #27ae60;
        }

        .status-failed {
            color: #c0392b;
        }

        .status-inprogress, .status-interrupted {
            color: #d99000;
        }

        .status-notrun {
            color: #9aa0a6;
        }

        .dot.status-passed {
            background: #27ae60;
        }

        .dot.status-failed {
            background: #c0392b;
        }

        .dot.status-inprogress, .dot.status-interrupted {
            background: #d99000;
        }

        .dot.status-notrun {
            background: #bbb;
        }
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
            <span class="summary-value $(if($overallResult -eq 'Passed') { 'pass-badge' } else { 'fail-badge' })">$overallResult</span>
        </div>
         <div class="summary-item">
            <span class="summary-label">Stats</span>
            <span class="summary-value">
                <span class="pass-badge">$passCount Pass</span> / <span class="fail-badge">$failCount Fail</span>
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

            // Lock table column widths based on the widest content in each column.
            // This prevents columns shifting when rows are expanded/collapsed.
            const lockColumnWidths = () => {
                const table = tbody.closest('table');
                const theadRow = table.querySelector('thead tr');
                const headerCells = Array.from(theadRow.cells);

                // Hide the table while we measure to avoid visual flicker.
                const prevVis = table.style.visibility;
                table.style.visibility = 'hidden';

                // Temporarily disable truncation so scrollWidth reflects full content width.
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

                // Temporarily unhide rows so their content participates in measurement.
                const prevHidden = rows.map(r => r.hidden);
                rows.forEach(r => r.hidden = false);

                const colCount = headerCells.length;
                const max = new Array(colCount).fill(0);

                // Include headers in the measurement.
                headerCells.forEach((cell, i) => { max[i] = Math.max(max[i], cell.scrollWidth); });

                // Measure all body cells using scrollWidth (required width of content).
                rows.forEach(r => {
                    for (let i = 0; i < colCount; i++) {
                        const cell = r.cells[i];
                        if (!cell) continue;
                        max[i] = Math.max(max[i], cell.scrollWidth);
                    }
                });

                // Restore original hidden states.
                rows.forEach((r, i) => r.hidden = prevHidden[i]);

                // Build/replace colgroup with fixed pixel widths (+ a little padding buffer).
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

                // Restore styles we temporarily changed.
                touched.forEach(([c, ws, ov, to]) => {
                    c.style.whiteSpace = ws;
                    c.style.overflow = ov;
                    c.style.textOverflow = to;
                });
                table.style.tableLayout = prevLayout;

                table.style.visibility = prevVis;
            };

            lockColumnWidths();

            // Build parent -> child map and hide all non-root rows by default.
            // This ensures the table loads in a clean "summary" style view.
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

            // Propagate hot/cold theme from group rows to all descendants.
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

            // Collapse group row and all subsequent descendents
            const collapse = (row) => {
                row.classList.add('collapsed');
                row.dataset.expanded = 'false';
                const kids = children.get(row.dataset.id) || [];
                kids.forEach(kid => {
                    kid.hidden = true;
                    if (kid.classList.contains('group')) {
                        collapse(kid); // recursive collapse keeps descendants hidden
                    }
                });
            };

            // Expand group row but keep children collapsed
            const expand = (row) => {
                row.classList.remove('collapsed');
                row.dataset.expanded = 'true';
                const kids = children.get(row.dataset.id) || [];
                kids.forEach(kid => {
                    kid.hidden = false;
                    if (kid.classList.contains('group')) {
                        kid.classList.add('collapsed'); // show the group row but keep its children collapsed
                    }
                });
            };

            // Start with all groups collapsed (roots visible, their children hidden)
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

            // Delegate event listener to the table body.
            // This prevents the inevitable performance impact
            // of adding a listener to each row in large reports.
            tbody.addEventListener('click', (event) => {
                const nameCell = event.target.closest('.name-cell');
                if (!nameCell) { return; }
                const row = nameCell.parentElement;
                if (!row.classList.contains('group')) { return; }
                
                // Allow interactions only if row is expandable
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
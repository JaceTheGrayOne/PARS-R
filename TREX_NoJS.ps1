<#
.SYNOPSIS
    🦖 T-REX "TestStand Report EXtractor" - TestStand XML to HTML Parser (No JavaScript)

.DESCRIPTION
    Parses XML (ATML) output from TestStand into a self contained, human
    readable, interactive, and well formatted HTML with collapsible
    categories and pass/fail indicators. Uses native HTML collapsibility
    without requiring JavaScript execution.

.METHODOLOGY
    Recursively walks through XML node structure to flatten unformatted
    XML data and then converts it into a formatted hierarchical HTML
    using nested <details> elements with embedded CSS.

.NOTES
    File Name    : TREX_NoJS.ps1
    Author       : 1130538
    Version      : 0.1.0
    Creation     : 01DEC2025
    Last Update  : 01DEC2025
    Requires     : PowerShell 7.0+, Windows 10+

    Change Log:
    v0.1.0 - Modified to remove JavaScript dependency, using HTML5 <details> elements.
    v0.0.1 - Initial release.
#>
param (
    [Parameter(Mandatory=$true)]
    [string]$XmlPath,

    [Parameter(Mandatory=$true)]
    [string]$OutputHtmlPath = "D:\Development\XML_Parser\Resources\Output.html"
)

<# ----------------------------------------------------------------------
Function: Get-LimitsString
    - Extract limit information from XML test result nodes and convert
      it into HTML-safe formatted text.

    - Check if the test node has limit information then convert comparator.
      keywords (GE, LT, etc.) into HTML-safe entities (≥, ≤, etc).

TestStand's engine encodes limits in XML, often with symbolic comparator
codes that are not HTML-Safe. These have to be parsed and converted
prior to the HTML generation to avoid displaying broken characters.
---------------------------------------------------------------------- #>
function Get-LimitsString ($testResultNode) {
    # Validate input. Missing nodes are evaluated as no input.
    # If no node was passed, return an empty string to avoid
    # contaminating the HTML with "null".
    if (-not $testResultNode) { return "" }

    # Node path: TestResult.TestLimits.Limits
    # Return empty for nodes that do not include limits.
    $limits = $testResultNode.TestLimits.Limits
    if (-not $limits) { return "" }

    <# ----------------------------------------------------------------------
    Function: Convert-Comparator
        - Convert symbolic comparator codes into HTML-Safe equivalents.

    This keeps the rendering logic isolated from the formatting layer
    in the main HTML generation.
    ---------------------------------------------------------------------- #>
    function Convert-Comparator($comp) {
            switch ($comp.ToUpper()) {
            'GE' { "&ge;" }    # Greater or Equal
            'GT' { "&gt;" }    # Greater Than
            'LE' { "&le;" }    # Less or Equal
            'LT' { "&lt;" }    # Less Than
            'EQ' { "=" }       # Equal
            'NE' { "&ne;" }    # Not Equal
            default { $comp }  # Fallback: leave unchanged
        }
    }

    # Limit Pair Handler
    # Filter limit pairs to identify "High" and "Low" boundaries.
    if ($limits.LimitPair) {
        $low = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "GE|GT" }
        $high = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "LE|LT" }
        $segments = @()

        # Apply "Up Arrow" or "Down Arrow" to appropriate limit.
        if ($low)  { $segments += "&uarr; $(Convert-Comparator $low.comparator) $($low.Datum.value)" }
        if ($high) { $segments += "&darr; $(Convert-Comparator $high.comparator) $($high.Datum.value)" }
        return $segments -join " | "
    }
    if ($limits.Expected) {
        return "$(Convert-Comparator $limits.Expected.comparator) $($limits.Expected.Datum.value)"
    }
    return ""
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
    if (-not $timestamp) { return "" }
    try {
        $dt = [datetime]$timestamp
        return $dt.ToString("HH:mm:ss - ddMMMyyyy").ToUpper()
    } catch {
        # Preserve the raw value if string parsing fails.
        return $timestamp
    }
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

    # Determine group/test/step identifier name.
    # Prefer 'callerName' as that is often the most human readable
    # step indicator otherwise fallback to the internally coded name.
    $name = if ($node.callerName) { $node.callerName } else { $node.name }
    $status = $node.Outcome.value
    $timestamp = $node.endDateTime

    # Prioritize retrieving numeric result blocks for display.
    $numericResult = $node.TestResult | Where-Object { $_.name -eq 'Numeric' }

    # Initialize output fields
    $value = ""
    $units = ""
    $limits = ""

    # Extract value, units, and limit information from any present numeric block.
    if ($numericResult) {
        $value = $numericResult.TestData.Datum.value
        $units = $numericResult.TestData.Datum.nonStandardUnit

        # Fallback to standardized unit if no custom unit is present.
        if (-not $units) { $units = $numericResult.TestData.Datum.unit }
        $limits = Get-LimitsString $numericResult
    }

    # Create normalized custom PowerShell object for the current node.
    $results += [PSCustomObject]@{
        Level     = $level
        Name      = $name
        Status    = $status
        Value     = $value
        Units     = $units
        Limits    = $limits
        Time      = $timestamp
        IsGroup   = ($node.LocalName -and $node.LocalName -eq "TestGroup")
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
Function: Build-HierarchicalHTML
    - Converts flat test results into nested HTML structure using
      <details> and <summary> elements for native collapsibility.

This function processes the flat list of test results and builds a
hierarchical HTML structure where groups become collapsible <details>
elements and individual tests become styled rows within those groups.
---------------------------------------------------------------------- #>
function Build-HierarchicalHTML ($flatResults) {
    $html = ""
    $stack = New-Object System.Collections.Generic.Stack[int]
    $stack.Push(-1) # Root level

    foreach ($item in $flatResults) {
        # Close any open details tags if we've moved back up the tree
        while ($stack.Count -gt 1 -and $stack.Peek() -ge $item.Level) {
            $stack.Pop()
            $html += "</div></details>`n"
        }

        # Clean the status tag for use as a CSS class
        $statusKey = ($item.Status -replace "\s","").ToLower()
        if (-not $statusKey) { $statusKey = "notrun" }

        # Prep formatted Timestamp values
        $displayTime = Format-Timestamp $item.Time

        # Prep formatted value/unit strings
        $displayValue = $item.Value
        if ($item.Value -and $item.Units) { $displayValue = "$($item.Value) $($item.Units)" }
        elseif (-not $item.Value -and $item.Units) { $displayValue = $item.Units }

        if ($item.IsGroup) {
            # Create a collapsible group using <details>
            $groupClass = "test-group level-$($item.Level)"
            if ($item.Status -eq "Failed") { $groupClass += " failed-group" }

            $html += "<details class=`"$groupClass`">`n"
            $html += "<summary class=`"group-summary status-$statusKey`">`n"
            $html += "<div class=`"summary-content`">`n"
            $html += "<span class=`"name-col`"><span class=`"caret`"></span><strong>$($item.Name)</strong></span>`n"
            $html += "<span class=`"status-col status-$statusKey`">$($item.Status)</span>`n"
            $html += "<span class=`"value-col`">$displayValue</span>`n"
            $html += "<span class=`"limits-col`">$($item.Limits)</span>`n"
            $html += "<span class=`"time-col meta`">$displayTime</span>`n"
            $html += "</div>`n"
            $html += "</summary>`n"
            $html += "<div class=`"group-content`">`n"

            $stack.Push($item.Level)
        }
        else {
            # Create a test item row
            $rowClass = "test-item level-$($item.Level)"
            if ($item.Status -eq "Failed") { $rowClass += " failed" }

            $html += "<div class=`"$rowClass`">`n"
            $html += "<span class=`"name-col`"><span class=`"dot status-$statusKey`"></span>$($item.Name)</span>`n"
            $html += "<span class=`"status-col status-$statusKey`">$($item.Status)</span>`n"
            $html += "<span class=`"value-col`">$displayValue</span>`n"
            $html += "<span class=`"limits-col`">$($item.Limits)</span>`n"
            $html += "<span class=`"time-col meta`">$displayTime</span>`n"
            $html += "</div>`n"
        }
    }

    # Close any remaining open details tags
    while ($stack.Count -gt 1) {
        $stack.Pop()
        $html += "</div></details>`n"
    }

    return $html
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
Write-Host "Reading XML file: $XmlPath" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $XmlPath)) {
    Write-Error "File not found: $XmlPath"
    exit 1
}
# Load XML content.
[xml]$xml = Get-Content -LiteralPath $XmlPath

# Extract header information including serial number, part number, and status.
# Defensively guard against null results from incomplete tests.
$uut = $xml.TestResultsCollection.TestResults.UUT
if (-not $uut) {
    Write-Error "Missing UUT node in XML; cannot summarize."
    exit 1
}
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

Write-Host "Parsing test data (this may take a moment)..." -ForegroundColor Cyan

# Flatten test result hierarchy.
$resultSet = $xml.TestResultsCollection.TestResults.ResultSet
$flatResults = Get-TestNode $resultSet 0

# Compute summary statistics excluding group containers.
$totalTests = ($flatResults | Where-Object { -not $_.IsGroup }).Count
$passCount = ($flatResults | Where-Object { -not $_.IsGroup -and $_.Status -eq "Passed" }).Count
$failCount = ($flatResults | Where-Object { -not $_.IsGroup -and $_.Status -eq "Failed" }).Count

<# ----------------------------------------------------------------------
Section: HTML Generation
    - Build self-contained collapsible HTML using native HTML5 elements.
---------------------------------------------------------------------- #>
Write-Host "Generating HTML..." -ForegroundColor Cyan

$htmlBody = Build-HierarchicalHTML $flatResults

<# ----------------------------------------------------------------------
Function: HTML Assembly
    - Combine generated HTML with static framework
    - Embed CSS styling directly into HTML (no JavaScript required)

Using native HTML5 <details> elements provides collapsibility without
JavaScript, ensuring the report works in restricted environments while
maintaining portability and functionality.
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
        * { box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            color: #333;
            margin: 20px;
            background-color: #f9f9f9;
        }
        h1 {
            color: #2c3e50;
            border-bottom: 2px solid #ddd;
            padding-bottom: 10px;
            margin-bottom: 20px;
        }

        /* Summary Box Styling */
        .summary-box {
            background: #fff;
            padding: 15px;
            border: 1px solid #ddd;
            margin-bottom: 20px;
            border-radius: 4px;
            display: flex;
            gap: 30px;
            flex-wrap: wrap;
        }
        .summary-item { display: flex; flex-direction: column; }
        .summary-label {
            font-size: 0.85em;
            color: #777;
            text-transform: uppercase;
            margin-bottom: 4px;
        }
        .summary-value { font-size: 1.2em; font-weight: bold; }
        .pass-badge { color: #27ae60; }
        .fail-badge { color: #c0392b; }

        /* Test Results Container */
        .test-results {
            background: #fff;
            border: 1px solid #ddd;
            border-radius: 4px;
            overflow: hidden;
        }

        /* Column Headers */
        .column-headers {
            background-color: #f1f1f1;
            display: grid;
            grid-template-columns: 3fr 1fr 1.5fr 1.5fr 1.5fr;
            gap: 10px;
            padding: 10px 15px;
            border-bottom: 2px solid #ddd;
            font-weight: bold;
        }

        /* Test Groups and Items */
        .test-group { margin: 0; border-bottom: 1px solid #eee; }
        .test-group:last-child { border-bottom: none; }

        details.test-group > summary {
            list-style: none;
            cursor: pointer;
            user-select: none;
        }

        details.test-group > summary::-webkit-details-marker {
            display: none;
        }

        .group-summary {
            background-color: #f8f9fa;
            padding: 10px 15px;
            transition: background-color 0.2s ease;
        }

        .group-summary:hover {
            background-color: #e9ecef;
        }

        .failed-group > .group-summary {
            background-color: #ffe6e6;
        }

        .failed-group > .group-summary:hover {
            background-color: #ffd4d4;
        }

        .summary-content, .test-item {
            display: grid;
            grid-template-columns: 3fr 1fr 1.5fr 1.5fr 1.5fr;
            gap: 10px;
            align-items: center;
        }

        .test-item {
            padding: 8px 15px;
            border-bottom: 1px solid #f5f5f5;
        }

        .test-item:last-child {
            border-bottom: none;
        }

        .test-item.failed {
            background-color: #fff5f5;
        }

        .group-content {
            padding-left: 20px;
        }

        /* Column Styling */
        .name-col {
            word-break: break-word;
            display: flex;
            align-items: center;
        }

        .status-col { font-weight: bold; }
        .value-col { }
        .limits-col { }
        .time-col { }
        .meta { font-size: 0.85em; color: #999; }

        /* Icons */
        .caret {
            display: inline-block;
            width: 0;
            height: 0;
            margin-right: 8px;
            border-left: 5px solid transparent;
            border-right: 5px solid transparent;
            border-top: 6px solid #555;
            transition: transform 0.2s ease;
            flex-shrink: 0;
        }

        details[open] > summary .caret {
            transform: rotate(180deg);
        }

        .dot {
            display: inline-block;
            width: 8px;
            height: 8px;
            margin-right: 8px;
            border-radius: 50%;
            background: #bbb;
            flex-shrink: 0;
        }

        /* Status Colors */
        .status-passed { color: #27ae60; }
        .status-failed { color: #c0392b; }
        .status-inprogress, .status-interrupted { color: #d99000; }
        .status-notrun { color: #9aa0a6; }

        .dot.status-passed { background: #27ae60; }
        .dot.status-failed { background: #c0392b; }
        .dot.status-inprogress, .dot.status-interrupted { background: #d99000; }
        .dot.status-notrun { background: #bbb; }

        /* Responsive adjustments */
        @media (max-width: 768px) {
            .column-headers, .summary-content, .test-item {
                grid-template-columns: 2fr 1fr 1fr;
                font-size: 0.9em;
            }
            .limits-col, .time-col {
                display: none;
            }
            .summary-box {
                gap: 15px;
            }
        }
    </style>
</head>
<body>
    <h1>Test Execution Report</h1>

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
            <span class="summary-value">$totalTests Total ($passCount Pass / $failCount Fail)</span>
        </div>
    </div>

    <div class="test-results">
        <div class="column-headers">
            <div>Step Name</div>
            <div>Status</div>
            <div>Value</div>
            <div>Limits</div>
            <div>Timestamp</div>
        </div>
        $htmlBody
    </div>
</body>
</html>
"@

$outDir = Split-Path -Parent $OutputHtmlPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($OutputHtmlPath, $htmlContent, [System.Text.Encoding]::UTF8)

Write-Host "Report generated successfully: $OutputHtmlPath" -ForegroundColor Green

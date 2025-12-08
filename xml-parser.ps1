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
    Version      : 0.0.1
    Creation     : 14NOV2025
    Last Update  : 07DEC2025
    Requires     : PowerShell 7.0+, Windows 10+
    Versioning   : Semantic Versioning 2.0.0 (Major.Minor.Patch)

    Change Log:
    v0.0.1 - Initial build.
#>

param (
    [Parameter(Mandatory=$true)]
    [string]$XmlPath,

    [Parameter(Mandatory=$true)]
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
    switch ($comp.ToUpper()) {
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
        $low = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "GE|GT" } | Select-Object
        $high = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "LE|LT" } | Select-Object
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
    $numericResult = $node.TestResult | Where-Object { $_.name -eq "Numeric" }

    # Initialize output fields
    $value = ''
    $units = ''
    $limits = ''

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
[xml]$xml = Get-Content -LiteralPath $XmlPath

# Extract header information including serial number, part number, and status.
# Defensively guard against null results from incomplete tests.
$uut = $xml.TestResultsCollection.TestResults.UUT
# if (-not $uut) {
#     Write-Error "Missing UUT node in XML; cannot summarize."
#     exit 1
# }

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
$htmlRows = ''

# Stack ID counter to track the ID of the current parent group.
$rowIdCounter = 0
$groupStack = New-Object System.Collections.Generic.List[string] # Tracks latest group ID per group depth

foreach ($item in $renderRows) {
    # Trim the stack when moving back up the tree to preserve heirarchy structure.
    while ($groupStack.Count -gt $item.Level) { $groupStack.RemoveAt($groupStack.Count - 1) }

    # Determine parent ID of current row based on tree depth.
    $parentId = $null
    if ($item.Level -gt 0 -and $groupStack.Count -ge $item.Level) {
        $parentId = $groupStack[$item.Level - 1]
    }

    $rowIdCounter++
    $rowId = "row$rowIdCounter"

    # If the current item is a group push its ID to the stack to track
    # subsequent children as part of this group.
    if ($item.IsGroup) {
        if ($groupStack.Count -eq $item.Level) { $groupStack.Add($rowId) }
        elseif ($groupStack.Count -gt $item.Level) { $groupStack[$item.Level] = $rowId }
        else {
            # Fill empty gaps on the off chance a level gets skipped.
            while ($groupStack.Count -lt $item.Level) { $groupStack.Add($null) }
            $groupStack.Add($rowId)
        }
    }

# Determine CSS classes for row styling based on status or group type.
    $rowClass = ''
    if ($item.Status -eq "Failed") { $rowClass = "failed" }
    elseif ($item.IsGroup) { $rowClass = "group" }

    # Clean the status tag for use as a css class
    $statusKey = ($item.Status -replace "\\s","").ToLower()
    if (-not $statusKey) { $statusKey = "notrun" }

    # Calculate the visual indentation at 20px per level of tree depth.
    $indent = $item.Level * 20
    $nameStyle = "padding-left: $($indent)px;"
    if ($item.IsGroup) { $nameStyle += " font-weight: bold;" }

    # Icon selection: Caret for groups, colored dot for tests.
    $toggleMarkup = if ($item.IsGroup) { '<span class="caret" aria-hidden="true"></span>' } else { '<span class="dot status-' + $statusKey + '" aria-hidden="true"></span>' }

    # JS data attributes for expand/collapse logic.
    $parentAttr = if ($parentId) { "data-parent=""$parentId""" } else { 'data-root="true"' }

    # Prep formatted Timestamp values.
    $displayTime = Format-Timestamp $item.Time

    # Prep formatted value/unit strings.
    $displayValue = $item.Value
    # Merge Value and Unit
    if ($item.Value -and $item.Units) { $displayValue = "$($item.Value) $($item.Units)" }
    elseif (-not $item.Value -and $item.Units) { $displayValue = $item.Units }

    # Build HTML table rows.
    $htmlRows += @"
    <tr class="$rowClass" data-id="$rowId" data-level="$($item.Level)" $parentAttr>
        <td class="name-cell" style="$nameStyle">$toggleMarkup$($item.Name)</td>
        <td class="status-cell status-$statusKey">$($item.Status)</td>
        <td>$displayValue</td>
        <td>$($item.Limits)</td>
        <td class="meta">$displayTime</td>
    </tr>
"@
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

        h1 {
            color: #2c3e50;
            border-bottom: 2px solid #ddd;
            padding-bottom: 10px;
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

        /* Size column to content width. */
        /* Bind name column to a restricted width and allow wrapping */
        th:nth-child(1), td:first-child {
            min-width: 240px;
            max-width: 45vw;
        }

        .group {
            background-color: #f8f9fa;
            color: #555;
        }

        .failed {
            background-color: #ffe6e6;
            color: #a00;
            font-weight: bold;
        }

        .failed .status-cell {
            color: #d00;
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
            margin-right: 6px;
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

        .group:not(.collapsed) .caret {
            transform: rotate(45deg);
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

    <table>
        <thead>
            <tr>
                <th>Step Name</th>
                <th>Status</th>
                <th>Value</th>
                <th>Limits</th>
                <th>Timestamp</th>
            </tr>
        </thead>
        <tbody>
            $htmlRows
        </tbody>
    </table>
    <script>
        (() => {
            const tbody = document.querySelector('tbody');
            const rows = Array.from(tbody.querySelectorAll('tr'));
            const children = new Map();

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

            // Delegate event listener to the table body.
            // This prevents the inevitable performance impact
            // of adding a listener to each row in large reports.
            tbody.addEventListener('click', (event) => {
                const nameCell = event.target.closest('.name-cell');
                if (!nameCell) { return; }
                const row = nameCell.parentElement;
                if (!row.classList.contains('group')) { return; }
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

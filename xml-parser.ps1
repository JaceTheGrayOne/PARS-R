param (
    [Parameter(Mandatory=$true)]
    [string]$XmlPath,

    [Parameter(Mandatory=$true)]
    [string]$OutputHtmlPath = "D:\Development\XML_Parser\Resources\Output.html"
)

# --- 1. Helper Functions ---
function Get-LimitsString ($testResultNode) {
    if (-not $testResultNode) { return "" }

    $limits = $testResultNode.TestLimits.Limits
    if (-not $limits) { return "" }

    function Convert-Comparator($comp) {
        switch ($comp) {
            { $_ -match 'GE' } { return "&ge;" }
            { $_ -match 'GT' } { return "&gt;" }
            { $_ -match 'LE' } { return "&le;" }
            { $_ -match 'LT' } { return "&lt;" }
            { $_ -match 'EQ' } { return "=" }
            { $_ -match 'NE' } { return "&ne;" }
            default { return $comp }
        }
    }

    if ($limits.LimitPair) {
        $low = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "GE|GT" }
        $high = $limits.LimitPair.Limit | Where-Object { $_.comparator -match "LE|LT" }
        $segments = @()
        if ($low)  { $segments += "&uarr; $(Convert-Comparator $low.comparator) $($low.Datum.value)" }
        if ($high) { $segments += "&darr; $(Convert-Comparator $high.comparator) $($high.Datum.value)" }
        return $segments -join " | "
    }
    if ($limits.Expected) {
        return "$(Convert-Comparator $limits.Expected.comparator) $($limits.Expected.Datum.value)"
    }
    return ""
}

function Format-Timestamp ($timestamp) {
    if (-not $timestamp) { return "" }
    try {
        $dt = [datetime]$timestamp
        return $dt.ToString("HH:mm:ss - ddMMMyyyy").ToUpper()
    } catch {
        return $timestamp
    }
}

function Get-TestNode ($node, $level) {
    $results = @()

    $name = if ($node.callerName) { $node.callerName } else { $node.name }
    $status = $node.Outcome.value
    $timestamp = $node.endDateTime

    $numericResult = $node.TestResult | Where-Object { $_.name -eq 'Numeric' }

    $value = ""
    $units = ""
    $limits = ""

    if ($numericResult) {
        $value = $numericResult.TestData.Datum.value
        $units = $numericResult.TestData.Datum.nonStandardUnit
        if (-not $units) { $units = $numericResult.TestData.Datum.unit }
        $limits = Get-LimitsString $numericResult
    }

    $results += [PSCustomObject]@{
        Level     = $level
        Name      = $name
        Status    = $status
        Value     = $value
        Units     = $units
        Limits    = $limits
        Time      = $timestamp
        IsGroup   = ($node.LocalName -eq "TestGroup")
    }

    $children = $node.ChildNodes | Where-Object {
        $_.LocalName -in @("TestGroup", "Test", "SessionAction")
    }

    foreach ($child in $children) {
        $results += Get-TestNode $child ($level + 1)
    }

    return $results
}


# --- 2. Main Execution ---
Write-Host "Reading XML file: $XmlPath" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $XmlPath)) {
    Write-Error "File not found: $XmlPath"
    exit 1
}

[xml]$xml = Get-Content -LiteralPath $XmlPath

$uut = $xml.TestResultsCollection.TestResults.UUT
if (-not $uut) {
    Write-Error "Missing UUT node in XML; cannot summarize."
    exit 1
}

$serialNumber = $uut.SerialNumber
if ($serialNumber) { $serialNumber = $serialNumber.Trim() } else { $serialNumber = "[missing serial]" }

$partNumber = $uut.Definition.Identification.IdentificationNumbers.IdentificationNumber.number
if (-not $partNumber) { $partNumber = "[missing part]" }

$startTime = $xml.TestResultsCollection.TestResults.ResultSet.startDateTime
$startTimeFormatted = if ($startTime) { Format-Timestamp $startTime } else { "[missing start time]" }

$overallResult = $xml.TestResultsCollection.TestResults.ResultSet.Outcome.value
if (-not $overallResult) { $overallResult = "[unknown]" }

Write-Host "Parsing test data (this may take a moment)..." -ForegroundColor Cyan

$resultSet = $xml.TestResultsCollection.TestResults.ResultSet
$flatResults = Get-TestNode $resultSet 0

$totalTests = ($flatResults | Where-Object { -not $_.IsGroup }).Count
$passCount = ($flatResults | Where-Object { -not $_.IsGroup -and $_.Status -eq "Passed" }).Count
$failCount = ($flatResults | Where-Object { -not $_.IsGroup -and $_.Status -eq "Failed" }).Count

$renderRows = $flatResults


# --- 3. Generate HTML ---
Write-Host "Generating HTML..." -ForegroundColor Cyan

$htmlRows = ""

$rowIdCounter = 0
$groupStack = New-Object System.Collections.Generic.List[string]

foreach ($item in $renderRows) {
    while ($groupStack.Count -gt $item.Level) { $groupStack.RemoveAt($groupStack.Count - 1) }

    $parentId = $null
    if ($item.Level -gt 0 -and $groupStack.Count -ge $item.Level) {
        $parentId = $groupStack[$item.Level - 1]
    }

    $rowIdCounter++
    $rowId = "row$rowIdCounter"

    if ($item.IsGroup) {
        if ($groupStack.Count -eq $item.Level) { $groupStack.Add($rowId) }
        elseif ($groupStack.Count -gt $item.Level) { $groupStack[$item.Level] = $rowId }
        else {
            while ($groupStack.Count -lt $item.Level) { $groupStack.Add($null) }
            $groupStack.Add($rowId)
        }
    }

    $rowClass = ""
    if ($item.Status -eq "Failed") { $rowClass = "failed" }
    elseif ($item.IsGroup) { $rowClass = "group" }

    $statusKey = ($item.Status -replace "\s","").ToLower()
    if (-not $statusKey) { $statusKey = "notrun" }

    $indent = $item.Level * 20
    $nameStyle = "padding-left: $($indent)px;"
    if ($item.IsGroup) { $nameStyle += " font-weight: bold;" }

    $toggleMarkup = if ($item.IsGroup) { '<span class="caret" aria-hidden="true"></span>' } else { '<span class="dot status-' + $statusKey + '" aria-hidden="true"></span>' }

    $parentAttr = if ($parentId) { "data-parent=""$parentId""" } else { 'data-root="true"' }

    $displayTime = Format-Timestamp $item.Time

    $displayValue = $item.Value
    if ($item.Value -and $item.Units) { $displayValue = "$($item.Value) $($item.Units)" }
    elseif (-not $item.Value -and $item.Units) { $displayValue = $item.Units }

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


$htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Test Report - $serialNumber</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; color: #333; margin: 20px; background-color: #f9f9f9; }
        h1 { color: #2c3e50; border-bottom: 2px solid #ddd; padding-bottom: 10px; }

        .summary-box { background: #fff; padding: 15px; border: 1px solid #ddd; margin-bottom: 20px; border-radius: 4px; display: flex; gap: 30px; }
        .summary-item { display: flex; flex-direction: column; }
        .summary-label { font-size: 0.85em; color: #777; text-transform: uppercase; }
        .summary-value { font-size: 1.2em; font-weight: bold; }
        .pass-badge { color: #27ae60; }
        .fail-badge { color: #c0392b; }

        table { width: 100%; border-collapse: collapse; background: #fff; border: 1px solid #ddd; table-layout: auto; }
        th { background-color: #f1f1f1; text-align: left; padding: 10px; border-bottom: 2px solid #ddd; }
        td { padding: 8px 10px; border-bottom: 1px solid #eee; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

        /* Let columns size to content; bound name column and allow wrapping */
        th:nth-child(1), td:first-child { min-width: 240px; max-width: 45vw; }

        .group { background-color: #f8f9fa; color: #555; }
        .failed { background-color: #ffe6e6; color: #a00; font-weight: bold; }
        .failed .status-cell { color: #d00; }
        .meta { font-size: 0.85em; color: #999; }

        .name-cell { cursor: default; user-select: none; white-space: normal; word-break: break-word; }
        .name-cell .caret { display: inline-block; width: 10px; height: 10px; margin-right: 6px; border: solid #555; border-width: 0 2px 2px 0; transform: rotate(-45deg); transition: transform 0.2s ease; }
        .name-cell .dot { display: inline-block; width: 8px; height: 8px; margin: 0 8px 1px 2px; border-radius: 50%; background: #bbb; vertical-align: middle; }
        .group:not(.collapsed) .caret { transform: rotate(45deg); }
        tr[hidden] { display: none; }

        /* Status colors */
        .status-cell { font-weight: bold; }
        .status-passed { color: #27ae60; }
        .status-failed { color: #c0392b; }
        .status-inprogress, .status-interrupted { color: #d99000; }
        .status-notrun { color: #9aa0a6; }

        .dot.status-passed { background: #27ae60; }
        .dot.status-failed { background: #c0392b; }
        .dot.status-inprogress, .dot.status-interrupted { background: #d99000; }
        .dot.status-notrun { background: #bbb; }
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

            // Build parent -> children map and hide all non-root rows initially
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

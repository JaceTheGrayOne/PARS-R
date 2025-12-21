<#
.SYNOPSIS
    Extracts canonical Parity Data from a TestStand ATML/XML report.

.DESCRIPTION
    Parses an XML report to produce a JSON array of Canonical Step Records
    conforming to the PARS-R Parity Contract.
    
    Re-implements the traversal logic of trex.ps1 to ensure structural parity:
    1. Flatten XML tree (TestGroup/Test/SessionAction)
    2. Compute Path and Execution Ordinal
    3. Normalize Data (Limits, Status, Timestamp)

.PARAMETER XmlPath
    Path to the input XML file.

.PARAMETER OutPath
    Optional. Path to save the output JSON. If omitted, writes to stdout.

.EXAMPLE
    .\extract_xml.ps1 -XmlPath ".\Report.xml" -OutPath ".\canonical_xml.json"
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$XmlPath,

    [string]$OutPath
)

# 1. Validation
if (-not (Test-Path -LiteralPath $XmlPath)) {
    Write-Error "File not found: $XmlPath"
    exit 1
}

# 2. Helper Functions

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



function Format-ResultSetDisplayName ([string]$rawName) {
    if (-not $rawName) { return "" }
    $base = ($rawName -split '#', 2)[0]
    $leaf = [System.IO.Path]::GetFileName($base)
    if ($leaf -match '\.seq$') { $leaf = $leaf -replace '\.seq$', '' }
    $leaf = ($leaf -replace '_', ' ') -replace '\s{2,}', ' '
    return $leaf.Trim()
}

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

# 3. Traversal Logic (Matches Get-TestNode recursion)

function Get-RawNodes ($node, $level) {
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
    $limitData = $null
    $kind = "Step"

    if ($numericResult) {
        $value = $numericResult.TestData.Datum.value
        $units = $numericResult.TestData.Datum.nonStandardUnit
        if (-not $units) { $units = $numericResult.TestData.Datum.unit }
        $kind = "Measurement"
        $limitData = Get-LimitInfo $numericResult
    }

    if ($node.LocalName -in @("TestGroup", "SessionAction")) {
        $kind = "Group"
    }

    # Flattened Object (Internal use only)
    $results += [PSCustomObject]@{
        Level     = $level
        Name      = $name
        Status    = $status
        Value     = $value
        Units     = $units
        LimitData = $limitData
        Kind      = $kind
        Time      = $timestamp
        IsGroup   = ($node.LocalName -in @("TestGroup", "SessionAction"))
    }

    # Recursion
    $children = $node.ChildNodes | Where-Object {
        $_.NodeType -eq 'Element' -and $_.LocalName -in @("TestGroup", "Test", "SessionAction")
    }
    foreach ($child in $children) {
        $results += Get-RawNodes $child ($level + 1)
    }

    return $results
}

# 4. Main Execution

$content = Get-Content -LiteralPath $XmlPath -Raw
# Handle BOM or encoding issues if necessary, but [xml] usually handles it.
if (-not $content) { Write-Error "Empty file"; exit 1 }

try {
    [xml]$xml = $content
}
catch {
    Write-Error "Invalid XML: $($_.Exception.Message)"
    exit 1
}

$resultSet = $xml.TestResultsCollection.TestResults.ResultSet
if (-not $resultSet) {
    Write-Error "No ResultSet found in XML."
    exit 1
}

# A. Flatten Tree
$flatResults = Get-RawNodes $resultSet 0

if ($flatResults.Count -eq 0) {
    Write-Error "No records extracted from XML."
    exit 2
}

# B. Compute Parity Attributes (Path, Ordinal)
$canonicalRecords = @()

# Stack logic mirroring trex.ps1
$groupStack = New-Object System.Collections.Generic.List[string] # Only used for count logic
# Actually trex uses groupStack size to manage pathStack popping.
# We don't need row IDs here, but we need the stack DEPTH to track path.

$pathStack = New-Object System.Collections.Generic.List[string]
$ordinalTracker = @{} 

foreach ($item in $flatResults) {
    # Sync stacks based on Level
    # Corresponds to trex: while ($groupStack.Count -gt $item.Level) ...
    # We use pathStack directly since we don't care about row IDs, 
    # BUT we must perfectly mimic the "Unknown" gap filling logic.
    
    # Using a dummy stack for level tracking
    while ($groupStack.Count -gt $item.Level) {
        $groupStack.RemoveAt($groupStack.Count - 1)
        if ($pathStack.Count -gt $groupStack.Count) { $pathStack.RemoveAt($pathStack.Count - 1) }
    }

    # Calculate Path
    $parentPath = $pathStack -join '/'
    $currentPath = if ($parentPath) { "$parentPath/$($item.Name)" } else { $item.Name }

    # Calculate Ordinal
    $ordKey = "$parentPath|$($item.Name)|$($item.Kind)"
    if (-not $ordinalTracker.ContainsKey($ordKey)) { $ordinalTracker[$ordKey] = 0 }
    $ordinalTracker[$ordKey]++
    $ordinal = $ordinalTracker[$ordKey]

    # Handle Group Stack Pushing (for next iteration)
    if ($item.IsGroup) {
        if ($groupStack.Count -eq $item.Level) {
            $groupStack.Add("x") # Placeholder
            $pathStack.Add($item.Name)
        }
        elseif ($groupStack.Count -gt $item.Level) {
            $groupStack[$item.Level] = "x"
            while ($pathStack.Count -gt $item.Level) { $pathStack.RemoveAt($pathStack.Count - 1) }
            $pathStack.Add($item.Name)
        }
        else {
            # Gap filling
            while ($groupStack.Count -lt $item.Level) {
                $groupStack.Add("GAP")
                $pathStack.Add("Unknown")
            }
            $groupStack.Add("x")
            $pathStack.Add($item.Name)
        }
    }

    # Construct Final Record
    $cleanStatus = if ($item.Status) { $item.Status } else { "" }
    
    $cleanValue = if ($item.Value) { $item.Value } else { "" }

    $cleanUnits = if ($item.Units) { $item.Units } else { "" }
    $cleanTime = Format-Timestamp $item.Time

    $limits = [Ordered]@{
        Low          = if ($item.LimitData.Low) { $item.LimitData.Low } else { $null }
        LowComp      = if ($item.LimitData.LowComp) { $item.LimitData.LowComp } else { "NONE" }
        High         = if ($item.LimitData.High) { $item.LimitData.High } else { $null }
        HighComp     = if ($item.LimitData.HighComp) { $item.LimitData.HighComp } else { "NONE" }
        Expected     = if ($item.LimitData.Expected) { $item.LimitData.Expected } else { $null }
        ExpectedComp = if ($item.LimitData.ExpectedComp) { $item.LimitData.ExpectedComp } else { "NONE" }
    }

    $rec = [Ordered]@{
        CanonicalKey     = "$currentPath|$ordinal"
        ExecutionOrdinal = $ordinal
        Path             = $currentPath
        Kind             = $item.Kind
        StepName         = $item.Name
        Status           = $cleanStatus
        Value            = $cleanValue
        Units            = $cleanUnits
        Limits           = $limits
        Timestamp        = $cleanTime
    }

    $canonicalRecords += [PSCustomObject]$rec
}

# 5. Output
$json = $canonicalRecords | ConvertTo-Json -Depth 5

if ($OutPath) {
    $dir = Split-Path $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json | Set-Content -LiteralPath $OutPath -Encoding UTF8
    Write-Host "Extracted $($canonicalRecords.Count) records to $OutPath" -ForegroundColor Green
}
else {
    $json
}

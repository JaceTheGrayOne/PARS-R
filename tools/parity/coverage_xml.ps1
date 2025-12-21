<#
.SYNOPSIS
    Audits a TestStand ATML/XML report for data coverage and unhandled fields.

.DESCRIPTION
    Traverses the XML using the same scope as the defined Parity Contract
    (TestGroup/Test/SessionAction) and inventories valid data shapes.
    Identifies measurement types, limits, and result fields that are present
    in the source but potentially ignored by the current canonical model.

.PARAMETER XmlPath
    Path to the input XML file.

.PARAMETER OutPath
    Optional. Path to save the JSON report.

.PARAMETER MaxExamplesPerItem
    Maximum number of example paths to include for each unhandled category. Default 3.

.EXAMPLE
    pwsh .\tools\parity\coverage_xml.ps1 -XmlPath .\Test_Reports\report.xml -OutPath .\out\coverage.json
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$XmlPath,

    [string]$OutPath,

    [int]$MaxExamplesPerItem = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 1. Validation
if (-not (Test-Path -LiteralPath $XmlPath)) {
    Write-Error "File not found: $XmlPath"
    exit 1
}

# 2. Helpers
function Format-ResultSetDisplayName ([string]$rawName) {
    if (-not $rawName) { return "" }
    $base = ($rawName -split '#', 2)[0]
    $leaf = [System.IO.Path]::GetFileName($base)
    if ($leaf -match '\.seq$') { $leaf = $leaf -replace '\.seq$', '' }
    $leaf = ($leaf -replace '_', ' ') -replace '\s{2,}', ' '
    return $leaf.Trim()
}

function Get-XmlAttrValue {
    param(
        [Parameter(Mandatory)] [System.Xml.XmlElement] $Element,
        [Parameter(Mandatory)] [string] $Name
    )
    # XmlElement.GetAttribute returns "" if missing (never throws)
    return $Element.GetAttribute($Name)
}

function Select-Child {
    param(
        [Parameter(Mandatory)] $Node,
        [Parameter(Mandatory)] [string] $LocalName
    )
    return $Node.SelectSingleNode("./*[local-name()='$LocalName']")
}

function Select-Children {
    param(
        [Parameter(Mandatory)] $Node,
        [Parameter(Mandatory)] [string] $LocalName
    )
    return $Node.SelectNodes("./*[local-name()='$LocalName']")
}


# 3. Traversal & Inspection

function Get-CoverageNodes ($node, $level) {
    $results = @()

    # --- Name & Path Construction (Local) ---
    # Ignore non-element nodes (e.g., whitespace/text nodes)
    if (-not ($node -is [System.Xml.XmlElement])) {
        return @()
    }

    # --- Name & Path Construction (Local) ---
    $caller = $null
    if ($node.PSObject.Properties['callerName']) { $caller = $node.callerName }

    $nm = $null
    if ($node.PSObject.Properties['name']) { $nm = $node.name }

    $name = if ($caller) { $caller } else { $nm }
    if ($node.LocalName -eq 'ResultSet' -and $nm) {
        $name = Format-ResultSetDisplayName $nm
    }
    
    # Store minimal info needed for parent stack construction in the caller
    # We yield the node info, caller handles the hierarchy/path reconstruction?
    # No, we need to return the flat list. The Caller of Get-CoverageNodes needs to know IS_GROUP?
    # This function constructs the FLAT list of objects.
    
    # --- Inspection Logic ---
    $shapes = @()
    $unhandled = @()
    $comparators = @()

    # 1. Check Status
    $outcome = Select-Child -Node $node -LocalName 'Outcome'
    if ($outcome) {
        $outcomeVal = Get-XmlAttrValue -Element $outcome -Name 'value'
        if ($outcomeVal) { $shapes += "Outcome" }
    }


    # 2. Check Results (Iterate ALL TestResult children)
    # The canonical model ONLY looks at TestResult where name='Numeric'.
    $hasNumeric = $false
    
    # Handle single or array TestResult
    $trList = @(Select-Children -Node $node -LocalName 'TestResult')

    foreach ($tr in $trList) {
        $trName = Get-XmlAttrValue -Element $tr -Name 'name'

        $testData = Select-Child -Node $tr -LocalName 'TestData'
        $datum = if ($testData) { Select-Child -Node $testData -LocalName 'Datum' } else { $null }

        if ($datum) {
            $val = Get-XmlAttrValue -Element $datum -Name 'value'
            $type = Get-XmlAttrValue -Element $datum -Name 'type'

            if ($type -match "double|float|number" -or ($trName -eq 'Numeric')) {
                $shapes += "NumericResult"
                $hasNumeric = $true
            }
            elseif ($type -match "string|text") {
                $shapes += "StringResult"
            }
            elseif ($type -match "boolean") {
                $shapes += "BooleanResult"
            }
            elseif ($datum.ChildNodes.Count -gt 0) {
                $shapes += "ComplexResult"
            }
            else {
                $shapes += "UnknownDatum"
            }

            $unit = Get-XmlAttrValue -Element $datum -Name 'unit'
            $nsu = Get-XmlAttrValue -Element $datum -Name 'nonStandardUnit'
            if ($unit -or $nsu) {
                $shapes += "Units"
            }
        }

        # Parameters
        $params = Select-Child -Node $tr -LocalName 'Parameters'
        if ($params) { $shapes += "Parameters" }

        # Limits
        $testLimits = Select-Child -Node $tr -LocalName 'TestLimits'
        $limsNode = if ($testLimits) { Select-Child -Node $testLimits -LocalName 'Limits' } else { $null }

        if ($limsNode) {
            $limitPair = Select-Child -Node $limsNode -LocalName 'LimitPair'
            if ($limitPair) {
                $shapes += "LimitPair"
                $limitNodes = @(Select-Children -Node $limitPair -LocalName 'Limit')
                foreach ($l in $limitNodes) {
                    $comp = Get-XmlAttrValue -Element $l -Name 'comparator'
                    if ($comp) { $comparators += $comp }
                }
            }

            $expected = Select-Child -Node $limsNode -LocalName 'Expected'
            if ($expected) {
                $shapes += "Expected"
                $expComp = Get-XmlAttrValue -Element $expected -Name 'comparator'
                if ($expComp) { $comparators += $expComp }
            }
        }

        # Error
        $err = Select-Child -Node $tr -LocalName 'Error'
        if ($err) { $shapes += "ResultError" }
    }

    
    # Determine Unhandled
    # Canonical Model handles: Outcome, NumericResult, Units, LimitPair, Expected, Comparators.
    # Unhandled shapes: StringResult, BooleanResult, ComplexResult, Parameters, ResultError, UnknownDatum.
    # Also if there are MULTIPLE NumericResults? (Model picks First). 
    # For this audit, we just flag existence of unhandled TYPES.
    
    foreach ($s in $shapes) {
        if ($s -in @("Outcome", "NumericResult", "Units", "LimitPair", "Expected")) {
            # Handled
        }
        else {
            $unhandled += $s
        }
    }

    $item = [PSCustomObject]@{
        Name        = $name
        Level       = $level
        LocalName   = $node.LocalName # TestGroup, Test, SessionAction
        Shapes      = $shapes
        Comparators = $comparators
        Unhandled   = $unhandled
        IsGroup     = ($node.LocalName -in @("TestGroup", "SessionAction"))
    }
    
    $results += $item

    # Recursion
    $children = @($node.SelectNodes("./*[
    local-name()='TestGroup' or local-name()='Test' or local-name()='SessionAction'
]"))
    foreach ($child in $children) {
        $results += Get-CoverageNodes $child ($level + 1)
    }

    return $results
}

# 4. Main Execution

Write-Host "Loading XML: $XmlPath" -ForegroundColor Cyan
[xml]$xml = Get-Content -LiteralPath $XmlPath -Raw
# Namespace-safe: find the first ResultSet regardless of prefixes
$resultSet = $xml.SelectSingleNode("//*[local-name()='ResultSet'][1]")

if (-not $resultSet) {
    Write-Error "No ResultSet found (//*[local-name()='ResultSet'])."
    exit 1
}


$flatNodes = Get-CoverageNodes $resultSet 0

if ($flatNodes.Count -eq 0) {
    Write-Error "No traversable nodes found."
    exit 1
}

# --- Reconstruct Paths (Parity Logic) ---
# We need full paths for the Examples
$pathStack = New-Object System.Collections.Generic.List[string]
$groupStack = New-Object System.Collections.Generic.List[string] # Tracks depths
$annotatedNodes = @()

foreach ($item in $flatNodes) {
    # Sync stacks
    while ($groupStack.Count -gt $item.Level) {
        $groupStack.RemoveAt($groupStack.Count - 1)
        if ($pathStack.Count -gt $groupStack.Count) { $pathStack.RemoveAt($pathStack.Count - 1) }
    }

    $parentPath = $pathStack -join '/'
    $currentPath = if ($parentPath) { "$parentPath/$($item.Name)" } else { $item.Name }
    
    $item | Add-Member -MemberType NoteProperty -Name "StepPath" -Value $currentPath
    $annotatedNodes += $item

    if ($item.IsGroup) {
        # Mimic logic for stack pushing
        if ($groupStack.Count -eq $item.Level) {
            $groupStack.Add("x")
            $pathStack.Add($item.Name)
        }
        elseif ($groupStack.Count -gt $item.Level) {
            $groupStack[$item.Level] = "x"
            while ($pathStack.Count -gt $item.Level) { $pathStack.RemoveAt($pathStack.Count - 1) }
            $pathStack.Add($item.Name)
        }
        else {
            while ($groupStack.Count -lt $item.Level) {
                $groupStack.Add("GAP")
                $pathStack.Add("Unknown")
            }
            $groupStack.Add("x")
            $pathStack.Add($item.Name)
        }
    }
}

# 5. Aggregation
$countsLocalName = @{}
$countsResultShape = @{}
$countsUnhandled = @{}
$countsComparator = @{}
$unhandledExamples = @{} # Key: Shape -> List of Objects

foreach ($node in $annotatedNodes) {
    # Count LocalName
    $ln = $node.LocalName
    $countsLocalName[$ln] = [long]($countsLocalName[$ln] + 1)

    # Count ResultShapes (Unique per node? Or total occurrences? Usually unique per node is better for "How many nodes have X")
    # We will count "Nodes with X"
    $uniqueShapes = $node.Shapes | Select-Object -Unique
    foreach ($s in $uniqueShapes) {
        $countsResultShape[$s] = [long]($countsResultShape[$s] + 1)
    }
    
    # Count Unhandled
    $uniqueUnh = $node.Unhandled | Select-Object -Unique
    foreach ($u in $uniqueUnh) {
        $countsUnhandled[$u] = [long]($countsUnhandled[$u] + 1)
        
        # Collect Examples
        if (-not $unhandledExamples.ContainsKey($u)) { $unhandledExamples[$u] = @() }
        if ($unhandledExamples[$u].Count -lt $MaxExamplesPerItem) {
            $unhandledExamples[$u] += [PSCustomObject]@{
                StepPath      = $node.StepPath
                NodeLocalName = $node.LocalName
            }
        }
    }

    # Count Comparators (Total occurrences)
    foreach ($c in $node.Comparators) {
        $cNorm = $c.ToString().ToUpper()
        $countsComparator[$cNorm] = [long]($countsComparator[$cNorm] + 1)
    }
}

# Formatting UnhandledExamples for JSON
$unhandledOutput = @()
foreach ($key in ($unhandledExamples.Keys | Sort-Object)) {
    $unhandledOutput += [PSCustomObject]@{
        ShapeOrField = $key
        Count        = $countsUnhandled[$key]
        Examples     = $unhandledExamples[$key]
    }
}

$report = [Ordered]@{
    Summary           = [Ordered]@{
        TotalStepNodes          = $annotatedNodes.Count
        CountsByNodeLocalName   = $countsLocalName
        CountsByResultShape     = $countsResultShape
        CountsByUnhandledShape  = $countsUnhandled
        CountsByComparatorToken = $countsComparator
    }
    UnhandledExamples = $unhandledOutput
    Notes             = @(
        "Handled Set: Outcome, NumericResult, Units, LimitPair, Expected",
        "Unhandled Set: StringResult, BooleanResult, ComplexResult, Parameters, ResultError, UnknownDatum",
        "Comparators captured globally from all limit pairs/expected values."
    )
}

# 6. Output
Write-Host "`n--- Coverage Summary ---" -ForegroundColor Green
Write-Host "Total Nodes: $($annotatedNodes.Count)"
foreach ($key in $countsResultShape.Keys) {
    Write-Host "  $key : $($countsResultShape[$key])"
}
if ($unhandledOutput.Count -gt 0) {
    Write-Host "`n[!] Unhandled Shapes Detected:" -ForegroundColor Yellow
    foreach ($item in $unhandledOutput) {
        Write-Host "  $($item.ShapeOrField) ($($item.Count))"
    }
}
else {
    Write-Host "`nAll detected data shapes are covered by canonical model." -ForegroundColor Cyan
}

$json = $report | ConvertTo-Json -Depth 5

if ($OutPath) {
    $dir = Split-Path $OutPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json | Set-Content -LiteralPath $OutPath -Encoding UTF8
    Write-Host "`nReport saved to: $OutPath" -ForegroundColor Gray
}
else {
    $json
}

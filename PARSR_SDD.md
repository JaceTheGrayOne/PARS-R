---

# Quick-Start

PARS-R is a Windows-based toolchain that converts **NI TestStand ATML/XML test reports** into a **single, self-contained HTML report**.  
The generated HTML is structured, hierarchical, searchable, and visually annotated with pass/fail status, limits, timestamps, and grouping.

The system consists of:
- A Windows batch launcher (`pars-r.bat`)
- A PowerShell 7 script (`TREX.ps1`)
- Static web assets (`Web/`) that are inlined into the output HTML

---

### System Requirements

- Windows 10 or later
- PowerShell 7.0 or newer (`pwsh.exe`)

---

### Usage

- Launch `pars-r.bat`.

– When prompted, either:
  - Drag and drop a TestStand XML report into the console
  - Paste/type the full path to the XML file

- Parsed report will be generated as <reportname>.html next to the original XML input

---

### Output

The generated HTML file is:

- Fully portable and has no external JS/CSS dependencies
- Hierarchical with expandable/collapsible groups
- Annotated with:
  - Pass / Fail / Not Run indicators
  - Numeric values and units
  - Limit definitions
  - Timestamps
- Searchable and filterable via embedded JavaScript

---

### Failure Conditions

Conversion halts with explicit errors if:

- The XML file does not exist
- Any required asset file is missing:
  - `template.html`
  - `styles.css`
  - `app.js`

On failure state, the batch script preserves the console window for inspection.

---

# Software Design Document (SDD)

---

### Execution Flow

1. **Batch Script (`pars-r.bat`)**
   - Collects XML path from user
   - Resolves relative PowerShell script path
   - Invokes PowerShell with execution policy bypass
   - Opens resulting HTML on success

2. **PowerShell Script (`TREX.ps1`)**
   - Validates inputs and assets
   - Loads XML as a DOM
   - Flattens hierarchical test results
   - Generates HTML table rows
   - Inlines CSS and JavaScript
   - Writes final HTML file

---

### Input Data Model

The script expects a TestStand ATML structure containing:

- `TestResultsCollection`
- `TestResults`
- `ResultSet`
- `UUT`
- Nested `TestGroup`, `Test`, and `SessionAction` elements
- `Outcome`, `TestResult`, `TestLimits`, and `Datum` nodes

All accessed fields are directly referenced in code; no schema inference is used.

---

### Core Functional Components

#### XML Traversal (`Get-TestNode`)

- Recursively walks:
  - `ResultSet`
  - `TestGroup`
  - `Test`
  - `SessionAction`
- Produces a flattened, ordered list with depth levels preserved
- Assigns semantic types:
  - `Group`
  - `Measurement`
  - `Step`

This flattening enables linear HTML generation while preserving hierarchy.

---

#### Limit Processing

Functions:
- `Convert-Comparator`
- `Get-LimitsString`
- `Get-LimitInfo`

Behavior:
- Normalizes TestStand comparators (`GE`, `LT`, `EQ`, etc.)
- Supports:
  - Limit pairs (low/high)
  - Expected value limits
- Stores both display strings and structured data for JS usage

Justification:
- Separation of display and structured data enables both readable output and client-side filtering.

---

#### Timestamping

`Format-Timestamp`:
- Converts XML timestamps to NATO DTG (DDMMMYYYY HHMMSSZ)
- Falls back to raw value if parsing fails

---

#### HTML Row Generation

Each test/group produces a `<tr>` with:

- CSS classes encoding:
- Depth level
- Pass/fail state
- Thermal or phase keywords (`cold`, `hot`, `startup`, etc.)
- `data-*` attributes encoding:
- Hierarchical path
- Ordinal index
- Status
- Limits
- Values
- Timestamp

Justification:
- Heavy use of `data-*` attributes allows JavaScript logic without DOM re-parsing.

---

### Asset Inlining

The script:
- Reads `template.html`, `styles.css`, and `app.js` as raw text
- Injects them via literal string replacement
- Avoids regex replacement to preserve byte-level fidelity

Result:
- Output HTML is monolithic and dependency-free

---

### Metrics

Computed directly from flattened results:

- Total tests (non-group nodes)
- Passed tests
- Failed tests
- Overall result badge

These are injected into the HTML template as static values.

---

### Error Handling

- Hard-fail on missing inputs or assets
- Explicit error messages via `Write-Error`
- Non-zero exit code propagated back to batch launcher

No silent failures or fallback behavior are implemented.

---

### Versioning and Maintainability

Observed characteristics:
- Semantic versioning declared in script header
- Modularized web assets (HTML/CSS/JS separated)
- No external module dependencies

The design favors:
- Deterministic output
- Traceability from XML to HTML
- Ease of future UI iteration without parser changes

---

## Deliverables

PARS-R provides:
- Deterministic XML → HTML conversion
- Human-readable TestStand reports
- Fully portable output
- Clear separation between parsing logic and presentation

All documented behavior is directly verifiable from the provided files.
```

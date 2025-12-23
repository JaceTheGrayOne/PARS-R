# PARS-R — Software Design Document (SDD)
*Deliverable:* `PARSR_SDD.md`  
*Generated:* 2025-12-22  
*Audience:* Humans + AI agents (for creating a ChatGPT Project Instruction and for ongoing development assistance)

---

## 1. System Overview

**PARS-R** is a Windows/PowerShell toolchain that converts **NI TestStand ATML/XML test reports** into a **single, self-contained, human-readable HTML report**. The HTML is interactive (collapsible hierarchical groups) and visually emphasizes pass/fail status and measurement details.

A key design feature is a built-in **parity/verification contract**: the generated HTML includes `data-parity-*` attributes for each step row, enabling deterministic extraction and comparison against canonical data extracted from the XML source.

### 1.1 Primary goals
- Convert TestStand ATML/XML reports into an easy-to-read HTML report.
- Preserve hierarchical structure (groups/tests/session actions) with collapse/expand UX.
- Render measurement values, units, limits, and comparators safely and consistently.
- Provide deterministic verification that HTML content matches the XML source (no missing, extra, or corrupted step data).

### 1.2 Non-goals
- Editing the XML or modifying test results.
- Serving content from a web server (output is a standalone HTML file).
- Perfectly mirroring all XML metadata (focus is on report readability + parity contract fields).

### 1.3 Operating environment assumptions
- Windows host with **PowerShell 7+** (`pwsh.exe`) available (batch wrapper attempts to find it).
- Input is a TestStand **ATML/XML** report with the expected schema patterns used by the parser and parity tools.

---

## 2. Repository Layout

### 2.1 File inventory (excluding `.git/`)
| Path | Size (bytes) | SHA256 (12) | Purpose |
|---|---:|---|---|
| `.gitignore` | 364 | `212ee61cbb8d` | Git ignore rules (repo hygiene). |
| `GEMINI.md` | 5,637 | `1a66bfb75d90` | Project instruction/requirements doc geared for Gemini-based workflows; useful as requirements baseline. |
| `Test_Reports/Test_Report.html` | 1,216,464 | `642a12fa3656` | Sample input reports (XML) and sample/expected HTML output used for validation/regression. |
| `Test_Reports/Test_Report.xml` | 958,355 | `193a17e0624d` | Sample input reports (XML) and sample/expected HTML output used for validation/regression. |
| `Test_Reports/Test_Report_Gold.xml` | 958,356 | `57a7a87523ce` | Sample input reports (XML) and sample/expected HTML output used for validation/regression. |
| `out/canonical_html.json` | 841,479 | `f1126f0749d0` | Generated artifacts from parity runs (canonical JSON, diffs, reports). |
| `out/canonical_xml.json` | 841,479 | `f1126f0749d0` | Generated artifacts from parity runs (canonical JSON, diffs, reports). |
| `out/coverage_report.json` | 778 | `1a68ead4e110` | Generated artifacts from parity runs (canonical JSON, diffs, reports). |
| `out/parity_diff.json` | 190 | `33b23348fe6f` | Generated artifacts from parity runs (canonical JSON, diffs, reports). |
| `out/report.html` | 1,216,433 | `d3989c18238f` | Generated artifacts from parity runs (canonical JSON, diffs, reports). |
| `out/reverified.html` | 1,189,111 | `b0820a53ef28` | Generated artifacts from parity runs (canonical JSON, diffs, reports). |
| `pars-r.bat` | 1,610 | `a6c21139fe15` | Windows batch wrapper: prompts for input XML, calls pwsh to run TREX.ps1, opens output HTML in Edge. |
| `tools/parity/Compare-Parity.ps1` | 7,050 | `34b3ce2f883b` | Parity tool: compares canonical JSON sets; detects dropped/hallucinated/corrupted data; exits 0/1. |
| `tools/parity/coverage_xml.ps1` | 12,980 | `e792bd011cbd` | Parity tool: coverage analysis of XML traversal (helps ensure extractor visits expected nodes). |
| `tools/parity/extract_html.ps1` | 4,383 | `4685deadea2e` | Parity tool: parses generated HTML rows via data-parity-* attributes and emits canonical step records JSON. |
| `tools/parity/extract_xml.ps1` | 9,356 | `c067e7b93762` | Parity tool: traverses XML and emits canonical step records JSON (source-of-truth extraction). |
| `trex.ps1` | 38,324 | `076004fc25ae` | Primary converter: parses TestStand ATML/XML and emits self-contained interactive HTML report; embeds parity instrumentation. |
| `verify_parity.ps1` | 2,769 | `83d6ffc0cc00` | Convenience runner: generates HTML from XML, extracts canonical JSON from XML and HTML, compares parity, writes reports. |

### 2.2 Generated artifacts and test fixtures
- `Test_Reports/` contains sample XML + a sample HTML report used for validation/regression.
- `out/` contains outputs produced by parity runs (canonical JSON, diffs, HTML copies).

---

## 3. High-Level Architecture

### 3.1 Components
1. **User Entry Point (Windows)**
   - `pars-r.bat`
   - Responsibilities:
     - Ensure `TREX.ps1` exists next to the batch file.
     - Determine a `pwsh.exe` path.
     - Prompt for an input XML and output HTML path.
     - Run `TREX.ps1` with arguments.
     - On success, open the HTML in Edge.

2. **Converter**
   - `trex.ps1`
   - Responsibilities:
     - Load XML (ATML) from disk.
     - Traverse the report tree to flatten test steps and groups with levels.
     - Normalize and format values, timestamps, comparators, and limits.
     - Generate standalone HTML:
       - inline CSS + inline JS
       - hierarchical table rows
       - collapse/expand behavior
       - pass/fail indicator styling
     - Instrument each generated table row with `data-parity-*` attributes (parity contract).

3. **Verification Toolchain (Parity)**
   - `verify_parity.ps1` orchestrates:
     - generate HTML via `trex.ps1`
     - canonicalize XML via `tools/parity/extract_xml.ps1`
     - canonicalize HTML via `tools/parity/extract_html.ps1`
     - compare results via `tools/parity/Compare-Parity.ps1`
   - Supporting tools:
     - `tools/parity/coverage_xml.ps1` produces traversal coverage analysis from XML.

### 3.2 Data flow
`TestStand ATML/XML` → (**TREX**) → `Self-contained HTML (with data-parity-*)`  
`TestStand ATML/XML` → (**extract_xml**) → `canonical_xml.json`  
`HTML` → (**extract_html**) → `canonical_html.json`  
`canonical_xml.json` + `canonical_html.json` → (**Compare-Parity**) → `parity_diff.json` (+ exit code)

---

## 4. Execution & Usage

### 4.1 Primary conversion (interactive)
- Run: `pars-r.bat`
- Inputs:
  - XML path
  - Output HTML path
- Output:
  - HTML report written to disk, then opened in Edge on success.

### 4.2 Direct conversion (PowerShell)
Example:
```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\trex.ps1 `
  -XmlPath .\Test_Reports\Test_Report.xml `
  -OutputHtmlPath .\out\report.html
```

### 4.3 Parity verification (recommended during development)

`verify_parity.ps1` runs the HTML generation, canonical HTML extraction, and comparison **but expects canonical XML JSON to already exist**.

Example:
```powershell
# 1) Create canonical XML JSON (one-time or whenever traversal changes)
pwsh .\tools\parity\extract_xml.ps1 -XmlPath .\Test_Reports\Test_Report.xml -OutPath .\out\canonical_xml.json

# 2) Generate HTML + extract canonical HTML JSON + compare
pwsh .\verify_parity.ps1 -XmlPath .\Test_Reports\Test_Report.xml -OutDir .\out
```

Behavior:
- Writes `out/canonical_html.json`
- Compares against `-XmlCanonicalPath` if provided, otherwise uses `out/canonical_xml.json` (or `canonical_xml_v2.json` if present)
- Writes `out/parity_diff.json`
- Exits `0` when parity passes, `1` when it fails.

---

## 5. Core Data Model

### 5.1 Internal flattened node model (converter + XML extractor)
Both `trex.ps1` and `tools/parity/extract_xml.ps1` implement a recursive traversal that flattens the XML hierarchy into a list of items with:
- `Level` (indentation depth)
- `Name` (display name; prefers `callerName` when present)
- `Kind` (`Group`, `Step`, `Measurement`, etc.)
- `Status` (derived from `Outcome.value`)
- `Time` (typically `endDateTime`)
- Optional measurement fields:
  - `Value`
  - `Units`
  - `LimitData` (raw comparator/limit info)

Traversal focuses on elements:
- `TestGroup`
- `Test`
- `SessionAction`

### 5.2 Parity Contract — canonical record schema

The parity contract is the minimum guaranteed set of step data that must round-trip:
- extracted deterministically from XML
- embedded as HTML `data-parity-*` attributes
- re-extracted from HTML to verify correctness

**Canonical record fields** (as emitted by both extractors and consumed by `Compare-Parity.ps1`):

| Field | Type | Meaning |
|---|---|---|
| `CanonicalKey` | string | Deterministic key: `"{Path}|{ExecutionOrdinal}"` |
| `ExecutionOrdinal` | int | Occurrence counter per (parentPath, name, kind) used to disambiguate repeated items |
| `Path` | string | Hierarchical path using group names (delimiter is implementation-defined; treated as string) |
| `Kind` | string | Classification (`Group`, `Step`, `Measurement`, …) |
| `StepName` | string | Name displayed for the step/group |
| `Status` | string | Normalized outcome string |
| `Value` | string | Normalized value string |
| `Units` | string | Units string (if any) |
| `Limits` | object | Structured limit object, see below |
| `Timestamp` | string | Normalized timestamp string |

**Limits object**:
| Field | Type | Meaning |
|---|---|---|
| `Low` | string\|null | low limit value |
| `LowComp` | string | comparator token (e.g., `LT`, `LE`, `NONE`) |
| `High` | string\|null | high limit value |
| `HighComp` | string | comparator token |
| `Expected` | string\|null | expected value |
| `ExpectedComp` | string | comparator token |

### 5.3 Parity instrumentation in HTML

`trex.ps1` adds a set of attributes on each `<tr>` row that represents a step/group:

- `data-parity-path`
- `data-parity-name`
- `data-parity-ordinal`
- `data-parity-kind`
- `data-parity-status`
- `data-parity-value`
- `data-parity-units`
- `data-parity-low`
- `data-parity-lowcomp`
- `data-parity-high`
- `data-parity-highcomp`
- `data-parity-expected`
- `data-parity-expectedcomp`
- `data-parity-timestamp`

Design intent:
- HTML visual structure may change freely, as long as these attributes remain correct.
- `tools/parity/extract_html.ps1` relies only on these attributes (regex-based extraction) rather than visual markup.

---

## 6. Detailed Component Design

## 6.1 `pars-r.bat` — Batch wrapper

### Responsibilities
- Resolve script directory and locate `TREX.ps1`.
- Locate `pwsh.exe` (PowerShell 7) and call it with:
  - `-NoProfile`
  - `-ExecutionPolicy Bypass`
  - `-File TREX.ps1`
  - `-XmlPath ...`
  - `-OutputHtmlPath ...`

### Failure behavior
- If `TREX.ps1` is missing: show error and exit non-zero.
- If `TREX.ps1` returns non-zero: show error and keep window open.

---

## 6.2 `trex.ps1` — Converter

### 6.2.1 Parameters
- `-XmlPath` (mandatory)
- `-OutputHtmlPath` (mandatory; has a default path in script)

### 6.2.2 Major functions

#### `Convert-Comparator`
Maps symbolic comparator codes to HTML-safe equivalents for display (ensures comparator symbols do not break markup).

#### `Get-LimitInfo`
Extracts raw limit and comparator information from a test result node into a structured object:
- `Low`, `LowComp`, `High`, `HighComp`, `Expected`, `ExpectedComp`

#### Formatting helpers
- `Format-Timestamp`
- `Format-DisplayValue`
- `Format-ResultSetDisplayName`
- `Get-LimitsString` (human-readable rendering)
- `Get-LimitInfo` (canonical/parity-friendly structure)

#### `Get-TestNode`
Core recursive traversal:
- Determines node `Name` (prefers `callerName`).
- Determines `Status`, `Timestamp`.
- Detects numeric measurement result blocks:
  - `TestResult` with `name == 'Numeric'`
  - Reads value + units from `TestData.Datum`
  - Attaches limits via `Get-LimitInfo`
- Classifies `Kind`:
  - `Group` for `TestGroup` and `SessionAction`
  - `Measurement` for numeric results
  - otherwise `Step`
- Recurse into child `TestGroup`, `Test`, `SessionAction` elements.
- Returns a flattened list preserving hierarchy via `Level`.

### 6.2.3 HTML generation strategy
- Build a single HTML document with:
  - Inline CSS for styling
  - Inline JavaScript for interaction (collapse/expand)
- Render flattened results as table rows (`<tr>`) with:
  - indentation (based on `Level`)
  - pass/fail visual markers (based on `Status`)
  - value/unit/limit columns
  - group row styling for collapsible behavior
- Each row contains parity attributes (see §5.3).

### 6.2.4 Path & ordinal strategy (as used for parity)
- A **group stack** and **path stack** are maintained while iterating flattened items.
- When encountering a group item:
  - push/replace group ID and path segment at the current `Level`.
- When moving up levels:
  - truncate stacks to match the new depth.
- `ExecutionOrdinal` increments per `(parentPath, name, kind)` to disambiguate repeated items (not globally).
- `Path` is derived from the current path stack to provide a stable hierarchical identity.

### 6.2.5 Escaping & safety
- Values embedded into HTML and parity attributes are escaped to avoid broken markup:
  - replaces `&`, `"`, `<`, `>` with entities.
- Comparator rendering is HTML-safe (via `Convert-Comparator`).

---

## 6.3 Parity tools

### 6.3.1 `tools/parity/extract_xml.ps1`
Purpose:
- Re-implement traversal logic against the XML source to produce canonical records (contract schema).

Major steps:
1. Load XML.
2. Traverse nodes into an internal flattened list (Level/Name/Status/Value/Units/LimitData/Kind/Time).
3. Compute `Path` + `ExecutionOrdinal` deterministically using a path stack while iterating flattened results.
4. Normalize fields (status/value/units/timestamp) into consistent strings.
5. Emit canonical JSON array.

Key design constraint:
- Its traversal and classification must remain aligned with `trex.ps1` so canonical records correspond 1:1.

### 6.3.2 `tools/parity/extract_html.ps1`
Purpose:
- Extract canonical records from HTML, relying only on `data-parity-*` attributes.

Major steps:
1. Read HTML as text.
2. Regex-match `<tr ... data-parity-...>` rows.
3. Parse attributes into a record:
   - `Path`, `ExecutionOrdinal`, `Kind`, `StepName`, etc.
   - Reconstruct `Limits` object from the low/high/expected attribute set.
4. Emit canonical JSON array.

Design constraint:
- Must remain tolerant to visual/structural HTML changes as long as parity attributes remain intact.

### 6.3.3 `tools/parity/Compare-Parity.ps1`
Purpose:
- Compare canonical sets and report:
  1. **Dropped** records (present in XML canonical, missing in HTML canonical)
  2. **Hallucinated** records (present in HTML canonical, missing in XML canonical)
  3. **Corruption** (same key but different field values)

Comparison policy:
- “String first, numeric fallback” comparison to allow formatting differences such as `1` vs `1.0` while maintaining strictness for non-numeric strings.

Outputs:
- Optional JSON diff report written to `-OutDiffPath`
- Exit code: `0` for pass, `1` for fail.

### 6.3.4 `tools/parity/coverage_xml.ps1`
Purpose:
- Analyze traversal coverage over the XML to detect if the extractor is skipping or missing expected node types/paths.
- Used as a development aid when updating traversal rules.

### 6.3.5 `verify_parity.ps1`
Purpose:
- Single command to run the full verification pipeline.
- Ensures output directories exist.
- Produces `out/` artifacts for inspection.

---

## 7. Error Handling & Diagnostics

### 7.1 Converter (`trex.ps1`)
- Validates input path exists.
- Fails fast on XML load/parsing errors.
- Writes output HTML to the requested path; directory creation behavior should be validated in future enhancements (recommended: ensure directory exists).

### 7.2 Parity pipeline
- Each tool uses explicit parameters and should fail non-zero on:
  - missing files
  - parse errors
  - JSON read/write errors
- `verify_parity.ps1` propagates the comparer exit code.

---

## 8. Extension Points (for future development)

### 8.1 Schema robustness
- Add more tolerant extraction for variations in TestStand ATML schema:
  - alternate locations for units/values
  - additional result types beyond `Numeric`

### 8.2 UI/UX improvements (without breaking parity)
- Layout/styling changes are safe if `data-parity-*` attributes remain correct.
- Consider adding:
  - filtering/search in the HTML
  - summary statistics (pass rate, duration)
  - sticky headers, better responsiveness

### 8.3 Better canonical identity
- If XML contains stable step IDs, consider incorporating them into the canonical key (while retaining backward compatibility).

### 8.4 Automated regression suite
- Add a script to run parity verification on multiple fixture reports and fail CI on regressions.

---

## 9. Development Guidelines for AI-Assisted Workflows

When using an AI agent to modify PARS-R:
1. Treat `trex.ps1` and `tools/parity/extract_xml.ps1` as coupled: any traversal/classification change in one likely requires changes in the other.
2. Never change `data-parity-*` semantics without updating:
   - `tools/parity/extract_html.ps1`
   - `tools/parity/Compare-Parity.ps1`
   - and fixtures/regression outputs.
3. Prefer changes that preserve the parity contract and validate via `verify_parity.ps1`.

---

## 10. Quick Reference: Commands

```powershell
# Convert XML to HTML
pwsh -NoProfile -ExecutionPolicy Bypass -File .\trex.ps1 -XmlPath .\Test_Reports\Test_Report.xml -OutputHtmlPath .\out\report.html

# Run parity verification
pwsh .\verify_parity.ps1 -XmlPath .\Test_Reports\Test_Report.xml -OutDir .\out
```

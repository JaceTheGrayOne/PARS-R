        (() => {
            const tbody = document.querySelector('tbody');
            const rows = Array.from(tbody.querySelectorAll('tr'));
            const children = new Map();
            const globalToggle = document.getElementById('global-toggle');

            const lockColumnWidths = () => {
                const table = tbody.closest('table');
                const theadRow = table.querySelector('thead tr:first-child');
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

            /* ============================================================
               Filter Logic
               ============================================================ */
            const filterStep = document.getElementById('filter-step');
            const filterStatus = document.getElementById('filter-status');
            const filterSearch = document.getElementById('filter-search');

            const populateFilters = () => {
                const names = new Set();
                rows.forEach(r => {
                    // Only scan non-group leaf rows that have a parity name
                    // This creates a clean step list without "MainSequence", "Cleanup", etc.
                    if (!r.classList.contains('group') && r.hasAttribute('data-parity-name')) {
                        names.add(r.getAttribute('data-parity-name'));
                    }
                });
                Array.from(names).sort().forEach(n => {
                    const opt = document.createElement('option');
                    opt.value = n;
                    opt.textContent = n;
                    filterStep.appendChild(opt);
                });
            };

            const applyFilters = () => {
                const fStep = filterStep.value;
                const fStatus = filterStatus.value;
                const fSearch = filterSearch.value.trim().toLowerCase();
                const isSearchActive = !!fSearch;
                const isFilterActive = !!(fStep || fStatus);
                const isActive = isSearchActive || isFilterActive;

                // Step 0: Clean State
                rows.forEach(r => {
                    delete r.dataset.hasVisibleChild; // runtime flag for structure
                    delete r.dataset.isCandidate;     // runtime flag for direct match
                });

                // Step 1: Determine Candidates (Pass 1)
                rows.forEach(r => {
                    const isGroup = r.classList.contains('group');
                    const hasParityName = r.hasAttribute('data-parity-name');
                    
                    // Definition: "Test Row" is a non-group row with parity data.
                    const isTestRow = !isGroup && hasParityName;
                    
                    let isCandidate = false;

                    if (isTestRow) {
                        // Test Rows: Must match ALL active filters + Search
                        const matchStep = !fStep || r.getAttribute('data-parity-name') === fStep;
                        const matchStatus = !fStatus || r.getAttribute('data-parity-status') === fStatus;
                        const matchSearch = !isSearchActive || r.textContent.toLowerCase().includes(fSearch);
                        
                        isCandidate = matchStep && matchStatus && matchSearch;
                    } else {
                        // Generic Rows (Groups, Info): Match ONLY if Search is Active & Matches.
                        // Filters (Step/Status) do not apply to them directly.
                        if (isSearchActive) {
                            // If search is active, do we match text?
                            if (r.textContent.toLowerCase().includes(fSearch)) {
                                isCandidate = true;
                            }
                        }
                    }

                    if (isCandidate) {
                        r.dataset.isCandidate = 'true';
                        
                        // Propagate Visibility to Ancestors
                        let parentId = r.dataset.parent;
                        while(parentId) {
                            const parentRow = rowMap.get(parentId);
                            if (parentRow) {
                                parentRow.dataset.hasVisibleChild = 'true';
                                parentId = parentRow.dataset.parent;
                            } else {
                                break;
                            }
                        }
                    }
                });

                // Step 2: Render & Structure (Pass 2)
                if (!isActive) {
                    // Reset to Default State: All rows physically present, Groups collapsed.
                    // This implies: Roots visible, Children hidden by collapse logic.
                    
                    // First, ensure all rows are "unhidden" in the DOM sense
                    rows.forEach(r => {
                        if (r.dataset.parent) {
                            r.hidden = true; // Default tree state: only roots visible
                        } else {
                            r.hidden = false;
                        }
                        if (r.classList.contains('group')) {
                            r.classList.add('collapsed');
                            r.dataset.expanded = 'false';
                        }
                    });
                } else {
                    // Active Mode: Sparse Tree
                    rows.forEach(r => {
                        const isCand = r.dataset.isCandidate === 'true';
                        const hasVisChild = r.dataset.hasVisibleChild === 'true';

                        if (isCand || hasVisChild) {
                            r.hidden = false;
                            
                            // If it's a group and acts as a structural parent, EXPAND it.
                            if (r.classList.contains('group')) {
                                // If it has visible children, it MUST be expanded.
                                if (hasVisChild) {
                                    r.classList.remove('collapsed');
                                    r.dataset.expanded = 'true';
                                } else {
                                    // If it's just a candidate itself (matched search) but has no visible kids,
                                    // we can choose to expand or collapse. 
                                    // Collapsed is safer to avoid showing un-matched children.
                                    r.classList.add('collapsed');
                                    r.dataset.expanded = 'false';
                                }
                            }
                        } else {
                            r.hidden = true;
                        }
                    });
                }
            };

            // Helper: ID Map for fast parent lookup
            const rowMap = new Map();
            rows.forEach(r => rowMap.set(r.dataset.id, r));

            populateFilters();

            // Events
            filterStep.addEventListener('change', applyFilters);
            filterStatus.addEventListener('change', applyFilters);
            
            let debounceTimer;
            filterSearch.addEventListener('input', () => {
                clearTimeout(debounceTimer);
                debounceTimer = setTimeout(applyFilters, 250);
            });
        })();

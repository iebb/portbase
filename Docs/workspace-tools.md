# Portbase 1.5.0 workspace tools

| Improvement | Where to use it | Behavior |
| --- | --- | --- |
| Server search and filters | Servers | Search profiles, select an engine, or show read-only connections. |
| Duplicate connections | Server context menu → Duplicate | Creates a new profile identity and copies connection options and hydrated credentials. Persisted profile JSON remains redacted. |
| Editor line navigation | Console → Go to Line; Command-L | Shows logical line numbers and selects the requested line, including wrapped text and CRLF files. |
| Toggle SQL comments | Keyboard → Editing Tools; Command-/ | Comments or uncomments the selected SQL lines while retaining indentation and newlines. |
| Open and share query files | Console → Query Files | Imports UTF-8 SQL, JSON, or Redis commands and shares the current draft. Opening a file replaces the draft only after confirmation and never executes it. Files are limited to 2 MiB. |
| Execution history | Console → Library → History | Records success, failure, cancellation, duration, and connection context. Search or filter the list; loading an entry does not run it. |
| Editable saved queries | Library → Saved Queries → Edit | Change titles, notes, and connection context, with search and a current-connection filter. Missing connections fail clearly. |
| Complete cell inspection | Result cell → Inspect Cell | Select and copy full values, format JSON without changing numeric tokens, and export raw values. Binary hex/base64 previews are bounded; export retains the complete bytes. |
| Filter loaded rows | Results → Filter Loaded Rows | Match text, exact values, SQL NULL, or empty text across a selected column or all columns. The loaded-row count is explicit, and row actions retain their original row identity. |
| MongoDB index inspector | MongoDB Console → Indexes | Inspect ordered compound keys, uniqueness, sparse/hidden options, TTL, and the exact index definition. Metadata uses read-only execution. |

The history and saved-query additions preserve older library files. Connection changes are refused during a manual transaction. Opening scripts, loading library entries, inspecting cells, and filtering loaded rows do not execute database writes. Result filtering applies to the materialized result only; it does not change the server query or full-query export.

Redis key rows also respond across their full 44-point target.

The native controls and errors are localized in all ten app languages. The existing unrestricted saved connections and chart styles remain available without a payment screen.

Verification: 125 simulator tests passed with 11 external-service tests skipped; 16 final editor and localization checks passed; all 46 vendored MySQL tests passed. Temporary native UI checks passed on iPhone, iPad, and the Duo simulator, including a live MongoDB index fixture. All 30 localization catalogs passed validation. No physical-device check was performed.

The release and screenshot delivery state is recorded in [the 1.5.0 release record](../AppStore/1.5.0/release.json). The [screenshot gallery](../ReviewScreenshots/README.md) includes native iPhone and iPad captures.

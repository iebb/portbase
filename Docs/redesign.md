# Portbase workspace redesign

The iPhone, iPad, and Mac apps share one design system and a set of new workspace features. All database execution still goes through `DatabaseService` with the existing execution policies; none of the new surfaces runs SQL implicitly.

## Design system

`PortSQL/Views/DesignSystem.swift` defines the visual tokens and components used across all platforms:

- **Palette**: adaptive canvas, surface, sunken, and stroke colors with a single flat accent. Cards are flat with a hairline border; there are no decorative glows or shadows. `PortSQLPalette` reads these tokens, so existing screens adopt them automatically.
- **Accent and appearance**: six accents (Indigo, Ocean, Emerald, Sunset, Rose, Graphite), whose dark variants keep white button labels readable, and System/Light/Dark appearance, stored in `UserDefaults` (`Portbase.accent`, `Portbase.appearance`) and applied with `.portbaseTheme()`.
- **Components**: `PanelCard`, `PortbaseChip`, `PortbaseMetricTile`, `PortbaseEmptyState`, `PortbaseSectionHeading`, `BookmarkAvatar` (engine gradients), `ConnectionSecurityChips`, and `toolIconChrome()` for 44-point tool buttons. Liquid Glass is used on iOS/macOS 26 and later, with a material fallback.
- **Editor themes**: `EditorTheme.swift` provides Portbase, Midnight, Paper, Solarized, and Ember syntax palettes (`Portbase.editorTheme`). The UIKit and AppKit editors both use them, including the line-number gutter and caret.

## Features

| Feature | Where | Behavior |
| --- | --- | --- |
| Home | iOS Home tab; Mac Home destination (⌘0) | Current connection with database switcher, four quick actions, recent queries, 14-day activity (runs, success rate, median time), connections, and saved queries. Loading a recent or saved query never runs it. |
| Command palette | ⌘K on all platforms; Home search button; Mac toolbar | Fuzzy search across actions, destinations, connections, databases, tables, saved queries, and history. Keyboard navigation with ↑/↓, Return, and Esc. |
| Result insights | Results → Insights (SQL tables and MongoDB) | Per-column type, NULL ratio, distinct count, empty-text count, min/median/mean/max, histograms, temporal ranges, and most frequent values. Computed off the main thread from loaded rows only; no extra queries. SQL `NULL`, empty text, the literal string `NULL`, and binary bytes stay distinct. |
| SQL templates | Console tool row; Mac editor toolbar | Select, group-and-count, join, CTE, running total, and (for writable profiles) insert/update/delete/create-index templates. Identifiers are engine-quoted, write templates use named parameters, and inserting a template never executes it. |
| New SQLite database | Home empty state, command palette (all platforms); Mac sidebar | Creates an empty local SQLite file and a connection to it, then opens the console. The Mac-only sample database was removed. |
| Run status | Results chips; Mac editor status bar | Outcome and duration of the last console execution, plus row/column/truncation chips. |
| Settings | iOS Settings sheet; Mac Settings window (General, Appearance, Editor) | Appearance, accent, editor theme, iCloud status and Sync Now, library storage, version, and supported engines. |
| Engine picker | Connection editor | Brand-colored engine tiles replace the menu picker; port, authentication, and icon defaults still follow the selected engine. |
| Query Library | Console library button; Home → Query Library | History rows show outcome, duration, and connection with one-tap outcome filters; saved queries show engine and database. Loading an entry never runs it. |
| Keyboard and haptics | iPad hardware keyboard: ⌘1–⌘5 tabs, ⌘K search, ⌘, settings; Mac: ⌘0 Home, ⌘1–⌘4 destinations | iPhone and iPad give success or error haptics when a console run finishes. |

The console tab strip, Servers list (summary tiles, security chips, active indicator), Explorer sidebar (row-count badges) and table header chips, Charts grid, and status banners were restyled with the shared components.

## Tests

`PortSQLTests/WorkspaceInsightsAndPaletteTests.swift` covers insight statistics (NULL versus empty text, binary values, temporal ranges, constant histograms), activity aggregation, template quoting and UTF-16 insertion, palette ranking, and preference fallbacks.

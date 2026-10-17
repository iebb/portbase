import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UniformTypeIdentifiers

struct ResultGridSelection: Equatable {
    struct Cell: Equatable {
        var row: Int
        var column: Int
    }

    var anchor: Cell
    var end: Cell
    var rows: ClosedRange<Int> { min(anchor.row, end.row)...max(anchor.row, end.row) }
    var columns: ClosedRange<Int> { min(anchor.column, end.column)...max(anchor.column, end.column) }
    var count: Int { rows.count * columns.count }

    func contains(row: Int, column: Int) -> Bool {
        rows.contains(row) && columns.contains(column)
    }
}

struct ResultGridConfiguration: Codable, Equatable {
    var widths: [Int: Double] = [:]
    var pinned: Set<Int> = []
    var hidden: Set<Int> = []

    func visibleColumns(count: Int) -> [Int] {
        let visible = (0..<count).filter { !hidden.contains($0) }
        return visible.filter { pinned.contains($0) } + visible.filter { !pinned.contains($0) }
    }
}

/// A quick action in a result grid's header or cell menu. Both platforms' grids draw the same items
/// natively (an NSMenu on the Mac, a UIMenu on iOS), so the actions stay identical everywhere.
struct ResultGridMenuItem {
    enum Kind {
        case action(() -> Void)
        case submenu([ResultGridMenuItem])
        case separator
    }

    var title = ""
    var systemImage: String?
    var isEnabled = true
    var isDestructive = false
    var kind: Kind

    static func action(_ title: String, _ systemImage: String? = nil, enabled: Bool = true,
                       destructive: Bool = false, _ perform: @escaping () -> Void) -> Self {
        Self(title: title, systemImage: systemImage, isEnabled: enabled, isDestructive: destructive, kind: .action(perform))
    }

    static func submenu(_ title: String, _ systemImage: String?, _ items: [Self]) -> Self {
        Self(title: title, systemImage: systemImage, kind: .submenu(items))
    }

    static var separator: Self { Self(kind: .separator) }
}

struct ResultGridRowAction {
    let title: String
    var symbolName: String = "arrowshape.turn.up.right"
    let perform: () -> Void
}

enum ResultGridClipboard {
    struct Payload: Codable {
        let columns: [QueryColumn]
        let rows: [QueryRow]
    }

    static func payload(result: QueryResultTable, visibleColumns: [Int], selection: ResultGridSelection) -> Payload {
        let indexes = selection.columns.compactMap { visibleColumns.indices.contains($0) ? visibleColumns[$0] : nil }
        return Payload(
            columns: indexes.map { result.columns[$0] },
            rows: selection.rows.compactMap { row in
                guard result.rows.indices.contains(row) else { return nil }
                return QueryRow(cells: indexes.map { index in
                    result.rows[row].cells.indices.contains(index) ? result.rows[row].cells[index] : .null
                })
            }
        )
    }

    // Quoted strings distinguish empty text and the literal string "NULL" from SQL NULL.
    static func text(_ payload: Payload, headers: Bool) -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = headers ? [payload.columns.map { quote($0.name) }.joined(separator: "\t")] : []
        lines += payload.rows.map { row in
            row.cells.map { $0.isNull ? "NULL" : quote($0.displayValue) }.joined(separator: "\t")
        }
        return lines.joined(separator: "\n")
    }

    @MainActor static func copy(result: QueryResultTable, visibleColumns: [Int], selection: ResultGridSelection, headers: Bool = false) {
        let value = payload(result: result, visibleColumns: visibleColumns, selection: selection)
        var item: [String: Any] = [UTType.utf8PlainText.identifier: text(value, headers: headers)]
        if let data = try? JSONEncoder().encode(value) { item["ad.neko.portsql.typed-cells"] = data }
        PortbaseClipboard.copy(items: [item])
    }
}

struct ResultGridView: View {
    let result: QueryResultTable
    var fillsAvailableSpace = false
    var primaryKeys: Set<String> = []
    var sortedColumn: String?
    var sortDirection: String?
    var persistenceKey: String?
    var onSort: ((String) -> Void)?
    var onOpenRow: ((Int) -> Void)?
    var actionsForCell: ((Int, Int) -> [ResultGridRowAction])?
    /// Enables SQL INSERT copying with engine-specific literals.
    var copyEngine: DatabaseEngine?
    var copyTableName: String?
    /// Reports the loaded-row index of the focused cell's row, for detail panes.
    var onSelectRow: ((Int?) -> Void)?
    /// Controls placed before and after the grid's own tools, so a host can share one toolbar row.
    var leadingAccessory: AnyView?
    var trailingAccessory: AnyView?
    /// Sorts by a column in a direction (true is descending), or clears the sort with nil.
    var onSortDirection: ((String, Bool?) -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var configuration = ResultGridConfiguration()
    @State private var selection: ResultGridSelection?
    @State private var extendsSelection = false
    @State private var showsColumns = false
    @State private var focusedColumn: Int?
    @State private var filter = LoadedResultFilter()
    @State private var filteredRows: [Int]?
    @State private var showsFilter = false
    @State private var inspectedCell: ResultCellSelection?

    private var rowIndices: [Int] { filteredRows ?? Array(result.rows.indices) }
    private var displayedResult: QueryResultTable {
        guard let filteredRows else { return result }
        var table = result
        table.rows = filteredRows.map { result.rows[$0] }
        table.documents = result.documents.map { documents in filteredRows.compactMap { documents.indices.contains($0) ? documents[$0] : nil } }
        return table
    }

    private var visibleColumns: [Int] { configuration.visibleColumns(count: result.columns.count) }
    private var controlHeight: CGFloat {
#if canImport(UIKit)
        44
#else
        24
#endif
    }
    private var gridHeight: CGFloat? {
#if canImport(UIKit)
        min(600, max(132, CGFloat(rowIndices.count + 1) * rowHeight + 8))
#else
        fillsAvailableSpace ? nil : min(600, max(132, CGFloat(rowIndices.count + 1) * rowHeight + 8))
#endif
    }
    private var rowHeight: CGFloat {
#if canImport(UIKit)
        max(44, UIFont.preferredFont(forTextStyle: .footnote).lineHeight + 22)
#else
        30
#endif
    }
    private var configurationKey: String? {
        persistenceKey.map { "PortSQL.grid." + $0 + "." + result.columns.map { $0.name + ":" + $0.type }.joined(separator: "|") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.s) {
            if let leadingAccessory { leadingAccessory }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    Button { focusedColumn = nil; showsColumns = true } label: {
                        Label("Columns", systemImage: "tablecells")
                    }
                    .frame(minHeight: controlHeight)
                    Button { showsFilter = true } label: {
                        Label("Filter Loaded Rows", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .frame(minHeight: controlHeight)
                    Button {
                        if let cell = selection?.end, visibleColumns.indices.contains(cell.column) {
                            inspect(row: cell.row, column: visibleColumns[cell.column])
                        }
                    } label: { Label("Inspect Cell", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .frame(minHeight: controlHeight).disabled(selection == nil)
                    Toggle(isOn: $extendsSelection) {
                        Label("Range", systemImage: "rectangle.dashed")
                    }
                    .toggleStyle(.button)
                    .frame(minHeight: controlHeight)
                    .accessibilityLabel("Extend cell selection")
                    Menu {
                        Button("Copy Selected Cells") { copySelection() }.disabled(selection == nil)
                        Button("Copy with Headers") { copySelection(headers: true) }.disabled(selection == nil)
                        Section(selection == nil ? L10n.text("Copy All Rows As") : L10n.text("Copy Selection As")) {
                            ForEach(ResultCopyFormat.available(for: copyEngine)) { format in
                                Button(format.title, systemImage: format.systemImage) { copy(as: format) }
                            }
                        }
                        Button("Select All") { selectAll() }
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .menuStyle(.button)
                    .disabled(selection == nil && result.rows.isEmpty)
                    if let selection {
                        Text(L10n.format("Cells: %d", selection.count))
                            .font(.captionText.monospacedDigit()).foregroundStyle(.secondary)
                        Button { self.selection = nil; extendsSelection = false } label: {
                            Image(systemName: "xmark").frame(width: controlHeight, height: controlHeight)
                        }
                        .accessibilityLabel("Clear selection")
                    }
                }
                .buttonStyle(.portbaseToolbar)
                .font(.rowDetail)
#if os(macOS)
                .font(.bodyText).padding(.horizontal, Spacing.s)
#endif
            }
            if let trailingAccessory { trailingAccessory }
            }
#if os(macOS)
            .padding(.horizontal, leadingAccessory == nil ? 0 : Spacing.m)
            .frame(minHeight: leadingAccessory == nil ? nil : Sizes.toolbar)
            .background(leadingAccessory == nil ? Color.clear : PortSQLPalette.panel)
#endif
            if filter.isActive {
                HStack {
                    Text(L10n.format("Loaded rows: %d / %d", rowIndices.count, result.rows.count)).font(.captionText).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Filter") { filter = LoadedResultFilter() }.frame(minHeight: controlHeight)
                }
            }
            GridCollectionBridge(
                result: displayedResult, visibleColumns: visibleColumns,
                configuration: configuration, selection: $selection, extendsSelection: $extendsSelection,
                rowHeight: rowHeight, primaryKeys: primaryKeys, sortedColumn: sortedColumn, sortDirection: sortDirection,
                onSort: onSort,
                onOpenRow: onOpenRow == nil ? nil : { row in if rowIndices.indices.contains(row) { onOpenRow?(rowIndices[row]) } },
                actionsForCell: { row, column in rowIndices.indices.contains(row) ? actionsForCell?(rowIndices[row], column) ?? [] : [] },
                onInspectCell: { row, column in inspect(row: row, column: column) },
                onConfigureColumn: { focusedColumn = $0; showsColumns = true },
                onPinColumn: { index in togglePinned(index) },
                onHideColumn: { index in hideColumn(index) },
                copyFormats: ResultCopyFormat.available(for: copyEngine),
                onCopyAs: { copy(as: $0) },
                headerMenu: { headerMenu(for: $0) },
                cellMenu: { cellMenu(row: $0, column: $1) }
            )
            .frame(height: gridHeight)
#if os(macOS)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
            .id(dynamicTypeSize)
            .accessibilityLabel("Query results table")
        }
        .sheet(isPresented: $showsColumns) { columnSettings.portbaseDesktopSheetSize() }
        .sheet(isPresented: $showsFilter) { filterSettings.portbaseDesktopSheetSize(width: 480, height: 320) }
        .sheet(item: $inspectedCell) { ResultCellInspector(selection: $0).portbaseDesktopSheetSize() }
        .onChange(of: result.columns.map { $0.name + ":" + $0.type }) { _, _ in filter = LoadedResultFilter(); updateFilter() }
        .onChange(of: result) { _, _ in updateFilter() }
        .onChange(of: filter) { _, _ in updateFilter() }
        .onChange(of: selection) { _, value in
            guard let onSelectRow else { return }
            if let row = value?.end.row, rowIndices.indices.contains(row) { onSelectRow(rowIndices[row]) } else { onSelectRow(nil) }
        }
        .onAppear { updateFilter() }
        .onChange(of: configurationKey, initial: true) { _, key in
            selection = nil
            if let key, let data = UserDefaults.standard.data(forKey: key),
               let saved = try? JSONDecoder().decode(ResultGridConfiguration.self, from: data) {
                configuration = saved
            } else { configuration = ResultGridConfiguration() }
            if visibleColumns.isEmpty { configuration.hidden = [] }
        }
        .onChange(of: configuration) { _, newValue in
            if let key = configurationKey, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func inspect(row: Int, column: Int) {
        guard rowIndices.indices.contains(row), result.columns.indices.contains(column) else { return }
        let original = rowIndices[row]
        let value = result.rows[original].cells.indices.contains(column) ? result.rows[original].cells[column] : .null
        inspectedCell = ResultCellSelection(column: result.columns[column], cell: value, row: original)
    }

    private func updateFilter() {
        if let column = filter.column, !result.columns.indices.contains(column) { filter.column = nil }
        filteredRows = filter.isActive ? filter.matchingRows(in: result) : nil
        selection = nil; extendsSelection = false
    }

    private var filterSettings: some View {
        NavigationStack {
            Form {
                Picker("Column", selection: $filter.column) {
                    Text("All Columns").tag(Optional<Int>.none)
                    ForEach(result.columns.indices, id: \.self) { index in Text(result.columns[index].name).tag(Optional(index)) }
                }
                Picker("Match", selection: $filter.mode) {
                    ForEach(LoadedResultFilter.Mode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                if filter.mode == .contains || filter.mode == .equals {
                    TextField("Value", text: $filter.text).portbaseTextCapitalization(.never).autocorrectionDisabled()
                }
                Text(L10n.format("Loaded rows: %d / %d", rowIndices.count, result.rows.count))
                Text("Filters apply to loaded rows only.").font(.footnoteText).foregroundStyle(.secondary)
                Button("Clear Filter") { filter = LoadedResultFilter() }
            }
            .navigationTitle("Filter Loaded Rows")
            .portbaseTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsFilter = false } } }
        }
    }

    private var columnSettings: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
                        Section {
                            Toggle("Visible", isOn: Binding(
                                get: { !configuration.hidden.contains(index) },
                                set: { visible in
                                    if visible { configuration.hidden.remove(index) }
                                    else { hideColumn(index) }
                                    selection = nil
                                }
                            ))
                            .disabled(!configuration.hidden.contains(index) && visibleColumns.count == 1)
                            Toggle("Pinned", isOn: Binding(
                                get: { configuration.pinned.contains(index) },
                                set: { _ in togglePinned(index) }
                            ))
                            .disabled(configuration.hidden.contains(index))
                            VStack(alignment: .leading) {
                                HStack {
                                    Text("Width")
                                    Spacer()
                                    Text(L10n.format("%d pt", Int(width(for: index)))).monospacedDigit().foregroundStyle(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { width(for: index) },
                                    set: { configuration.widths[index] = $0 }
                                ), in: 64...640, step: 8)
                                .frame(minHeight: controlHeight)
                                .accessibilityLabel(L10n.format("Width of %@", column.name))
                            }
                        } header: {
                            Text(column.name + " · " + column.type).textCase(nil)
                        }
                        .id(index)
                    }
                    Button("Reset Columns") { configuration = ResultGridConfiguration(); selection = nil }
                }
                .onAppear { if let focusedColumn { proxy.scrollTo(focusedColumn, anchor: .top) } }
            }
            .navigationTitle("Columns")
            .portbaseTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsColumns = false } } }
        }
    }

    private func width(for index: Int) -> Double {
        configuration.widths[index] ?? Double(GridCollectionBridge.naturalWidth(result: result, column: index))
    }

    // MARK: Quick actions

    private func cellValue(row: Int, column: Int) -> QueryCell {
        guard rowIndices.indices.contains(row) else { return .null }
        let cells = result.rows[rowIndices[row]].cells
        return cells.indices.contains(column) ? cells[column] : .null
    }

    /// Actions for a column header: copy, sort, layout, and settings.
    func headerMenu(for column: Int) -> [ResultGridMenuItem] {
        guard result.columns.indices.contains(column) else { return [] }
        let name = result.columns[column].name
        var items: [ResultGridMenuItem] = [
            .action(L10n.text("Copy Column Name"), "doc.on.doc") { PortbaseClipboard.copy(name) },
        ]
        if let onSortDirection {
            items += [
                .separator,
                .action(L10n.text("Sort Ascending"), "arrow.up") { onSortDirection(name, false) },
                .action(L10n.text("Sort Descending"), "arrow.down") { onSortDirection(name, true) },
                .action(L10n.text("Clear Sort"), "arrow.up.arrow.down", enabled: sortedColumn != nil) { onSortDirection(name, nil) },
            ]
        }
        items += [
            .separator,
            .action(configuration.pinned.contains(column) ? L10n.text("Unpin Column") : L10n.text("Pin Column"), "pin") { togglePinned(column) },
            .action(L10n.text("Hide Column"), "eye.slash", enabled: visibleColumns.count > 1) { hideColumn(column) },
            .action(L10n.text("Hide Other Columns"), "eye.slash.circle", enabled: visibleColumns.count > 1) {
                configuration.hidden = Set(result.columns.indices).subtracting([column])
                configuration.pinned = configuration.pinned.intersection([column])
                selection = nil
            },
            .action(L10n.text("Show All Columns"), "eye", enabled: !configuration.hidden.isEmpty) {
                configuration.hidden = []
                selection = nil
            },
            .separator,
            .action(L10n.text("Fit Column Width"), "arrow.left.and.right") {
                configuration.widths[column] = Double(GridCollectionBridge.naturalWidth(result: result, column: column))
            },
            .action(L10n.text("Reset Column Widths"), "arrow.uturn.backward", enabled: !configuration.widths.isEmpty) {
                configuration.widths = [:]
            },
            .action(L10n.text("Column Settings…"), "slider.horizontal.3") { focusedColumn = column; showsColumns = true },
        ]
        return items
    }

    /// Actions for a cell: open, copy, filter the loaded rows by its value, and the host's row actions.
    func cellMenu(row: Int, column: Int) -> [ResultGridMenuItem] {
        guard rowIndices.indices.contains(row), result.columns.indices.contains(column) else { return [] }
        let value = cellValue(row: row, column: column)
        let name = result.columns[column].name
        var items: [ResultGridMenuItem] = [
            .action(L10n.text("Open in Value Editor"), "arrow.up.left.and.arrow.down.right") { inspect(row: row, column: column) },
        ]
        if let onOpenRow {
            items.append(.action(L10n.text("Open Row"), "rectangle.and.pencil.and.ellipsis") { onOpenRow(rowIndices[row]) })
        }
        items += [
            .separator,
            .action(L10n.text("Copy Value"), "doc.on.doc") { PortbaseClipboard.copy(value.isNull ? "NULL" : value.displayValue) },
            .action(L10n.text("Copy Row"), "list.bullet.rectangle") {
                guard !visibleColumns.isEmpty else { return }
                ResultGridClipboard.copy(result: displayedResult, visibleColumns: visibleColumns,
                                         selection: ResultGridSelection(anchor: .init(row: row, column: 0), end: .init(row: row, column: visibleColumns.count - 1)),
                                         headers: true)
            },
        ]
        if let selection, selection.count > 1 {
            items.append(.action(L10n.text("Copy Selected Cells"), "square.on.square") { copySelection() })
            items.append(.action(L10n.text("Copy with Headers"), "tablecells") { copySelection(headers: true) })
        }
        let formats = ResultCopyFormat.available(for: copyEngine)
        if !formats.isEmpty {
            items.append(.submenu(L10n.text("Copy As"), "doc.on.clipboard", formats.map { format in
                .action(format.title, format.systemImage) { copy(as: format) }
            }))
        }
        var filterItems: [ResultGridMenuItem] = value.isNull
            ? [.action(L10n.text("Only NULL"), "circle.slash") { filter = LoadedResultFilter(column: column, mode: .null) }]
            : [.action(L10n.format("Equal to “%@”", String(value.displayValue.prefix(40))), "equal") {
                filter = LoadedResultFilter(column: column, mode: .equals, text: value.displayValue)
            }]
        if filter.isActive {
            filterItems.append(.action(L10n.text("Clear Filter"), "xmark.circle") { filter = LoadedResultFilter() })
        }
        items += [.separator, .submenu(L10n.text("Filter Loaded Rows"), "line.3.horizontal.decrease.circle", filterItems)]
        let rowActions = actionsForCell?(rowIndices[row], column) ?? []
        if !rowActions.isEmpty {
            items.append(.separator)
            items += rowActions.map { action in .action(action.title, action.symbolName, action.perform) }
        }
        if let onSortDirection {
            items += [.separator, .submenu(L10n.format("Sort by %@", name), "arrow.up.arrow.down", [
                .action(L10n.text("Sort Ascending"), "arrow.up") { onSortDirection(name, false) },
                .action(L10n.text("Sort Descending"), "arrow.down") { onSortDirection(name, true) },
            ])]
        }
        return items
    }

    private func togglePinned(_ index: Int) {
        if configuration.pinned.contains(index) { configuration.pinned.remove(index) }
        else { configuration.pinned.insert(index) }
        selection = nil
    }

    private func hideColumn(_ index: Int) {
        guard visibleColumns.count > 1 else { return }
        configuration.hidden.insert(index)
        configuration.pinned.remove(index)
        selection = nil
    }

    private func selectAll() {
        guard !rowIndices.isEmpty, !visibleColumns.isEmpty else { return }
        selection = ResultGridSelection(anchor: .init(row: 0, column: 0), end: .init(row: rowIndices.count - 1, column: visibleColumns.count - 1))
    }

    private func copySelection(headers: Bool = false) {
        guard let selection else { return }
        ResultGridClipboard.copy(result: displayedResult, visibleColumns: visibleColumns, selection: selection, headers: headers)
    }

    /// Copies the selection, or every loaded row when nothing is selected, in the given format.
    private func copy(as format: ResultCopyFormat) {
        guard !rowIndices.isEmpty, !visibleColumns.isEmpty else { return }
        let range = selection ?? ResultGridSelection(anchor: .init(row: 0, column: 0),
                                                     end: .init(row: rowIndices.count - 1, column: visibleColumns.count - 1))
        let payload = ResultGridClipboard.payload(result: displayedResult, visibleColumns: visibleColumns, selection: range)
        PortbaseClipboard.copy(ResultCopyFormatter.text(payload, format: format, engine: copyEngine, table: copyTableName))
    }
}

#if canImport(UIKit)
private struct GridCollectionBridge: UIViewRepresentable {
    let result: QueryResultTable
    let visibleColumns: [Int]
    let configuration: ResultGridConfiguration
    @Binding var selection: ResultGridSelection?
    @Binding var extendsSelection: Bool
    let rowHeight: CGFloat
    let primaryKeys: Set<String>
    let sortedColumn: String?
    let sortDirection: String?
    var onSort: ((String) -> Void)?
    var onOpenRow: ((Int) -> Void)?
    var actionsForCell: ((Int, Int) -> [ResultGridRowAction])?
    let onInspectCell: (Int, Int) -> Void
    let onConfigureColumn: (Int) -> Void
    let onPinColumn: (Int) -> Void
    let onHideColumn: (Int) -> Void
    var copyFormats: [ResultCopyFormat] = []
    var onCopyAs: (ResultCopyFormat) -> Void = { _ in }
    var headerMenu: (Int) -> [ResultGridMenuItem] = { _ in [] }
    var cellMenu: (Int, Int) -> [ResultGridMenuItem] = { _, _ in [] }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ResultCollectionView {
        let layout = FrozenGridLayout()
        let view = ResultCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .secondarySystemGroupedBackground
        view.register(ResultCollectionCell.self, forCellWithReuseIdentifier: "cell")
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.alwaysBounceVertical = false
        view.alwaysBounceHorizontal = false
        view.contentInsetAdjustmentBehavior = .never
        view.isDirectionalLockEnabled = true
        view.keyboardDismissMode = .onDrag
        view.copySelection = { [weak coordinator = context.coordinator] in coordinator?.copySelectedCells() }
        view.selectAllCells = { [weak coordinator = context.coordinator] in coordinator?.selectAll() }
        view.moveSelection = { [weak coordinator = context.coordinator] row, column, extend in
            coordinator?.moveSelection(row: row, column: column, extend: extend)
        }
        context.coordinator.collectionView = view
        return view
    }

    func updateUIView(_ view: ResultCollectionView, context: Context) {
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        guard let layout = view.collectionViewLayout as? FrozenGridLayout else { return }
        let dataChanged = previous.result.rows.first?.id != result.rows.first?.id
            || previous.result.rows.count != result.rows.count || previous.visibleColumns != visibleColumns
            || previous.result.columns != result.columns || previous.result.rows.map(\.id) != result.rows.map(\.id)
        let layoutChanged = dataChanged || previous.configuration != configuration || layout.widths.isEmpty
            || layout.rowHeight != rowHeight
        if layoutChanged {
            layout.widths = [44] + visibleColumns.map { CGFloat(configuration.widths[$0] ?? Double(Self.naturalWidth(result: result, column: $0))) }
            layout.fixedWidthColumns = Set(visibleColumns.enumerated().compactMap { configuration.widths[$0.element] != nil ? $0.offset + 1 : nil })
            layout.requestedPinnedCount = visibleColumns.prefix { configuration.pinned.contains($0) }.count + 1
            layout.rowHeight = rowHeight
            layout.rowCount = result.rows.count + 1
            layout.invalidateLayout()
        }
        if dataChanged || layoutChanged { view.reloadData() }
        else {
            for path in view.indexPathsForVisibleItems {
                guard let cell = view.cellForItem(at: path) as? ResultCollectionCell else { continue }
                context.coordinator.configure(cell, at: path)
            }
        }
    }

    static func naturalWidth(result: QueryResultTable, column: Int) -> CGFloat {
        let font = PortbaseFonts.codeFont(TypeSize.footnote, textStyle: .footnote)
        let samples = [result.columns[column].name] + result.rows.prefix(40).map { row in
            guard row.cells.indices.contains(column) else { return "NULL" }
            let value = row.cells[column]
            return value.isNull ? "NULL" : (value.displayValue.isEmpty ? "\"\"" : String(value.displayValue.prefix(100)))
        }
        return min(208, max(64, ceil(samples.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 64) + 24))
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        static let headerColor = UIColor(PortSQLPalette.sunken)
        static let rowColor = UIColor(PortSQLPalette.surface)
        static let stripeColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: 0x191D27) : UIColor(rgb: 0xF8F9FC) }
        var parent: GridCollectionBridge
        weak var collectionView: ResultCollectionView?
        init(_ parent: GridCollectionBridge) { self.parent = parent }

        func numberOfSections(in collectionView: UICollectionView) -> Int { parent.result.rows.count + 1 }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { parent.visibleColumns.count + 1 }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! ResultCollectionCell
            configure(cell, at: indexPath)
            return cell
        }

        func configure(_ cell: ResultCollectionCell, at path: IndexPath) {
            let header = path.section == 0
            let rowNumber = path.item == 0
            let selected = !header && !rowNumber && parent.selection?.contains(row: path.section - 1, column: path.item - 1) == true
            cell.backgroundColor = selected ? UIColor(PortSQLPalette.accent).withAlphaComponent(0.19)
                : (header || rowNumber ? Self.headerColor : (path.section.isMultiple(of: 2) ? Self.stripeColor : Self.rowColor))
            cell.label.font = header ? PortbaseFonts.uiFont(TypeSize.caption, weight: .semibold, textStyle: .caption1)
                : PortbaseFonts.codeFont(TypeSize.footnote, textStyle: .footnote)
            cell.label.textColor = header || rowNumber ? .secondaryLabel : .label
            cell.label.textAlignment = rowNumber ? .center : .left
            cell.label.numberOfLines = 1
            cell.symbol.image = nil
            cell.accessibilityCustomActions = nil
            cell.accessibilityTraits = selected ? [.button, .selected] : .button
            cell.accessibilityHint = nil
            cell.accessibilityValue = nil
            cell.setNeedsLayout()
            if rowNumber {
                cell.label.text = header ? "#" : String(path.section)
                cell.accessibilityLabel = header ? L10n.text("Select All") : L10n.format("Open row %d", path.section)
                return
            }
            let index = parent.visibleColumns[path.item - 1]
            let column = parent.result.columns[index]
            if header {
                let sorted = parent.sortedColumn == column.name
                cell.symbol.image = parent.primaryKeys.contains(column.name) ? UIImage(systemName: "key.fill") : nil
                let title = NSMutableAttributedString(string: column.name + (sorted ? (parent.sortDirection == "DESC" ? " ↓" : " ↑") : ""),
                                                      attributes: [.font: PortbaseFonts.uiFont(TypeSize.caption, weight: .semibold, textStyle: .caption1),
                                                                   .foregroundColor: UIColor.label])
                // The column's type sits under its name, as in desktop SQL clients.
                if !column.type.isEmpty {
                    title.append(NSAttributedString(string: "\n" + column.type.lowercased(),
                                                    attributes: [.font: PortbaseFonts.uiFont(TypeSize.micro, textStyle: .caption2),
                                                                 .foregroundColor: UIColor.tertiaryLabel]))
                    cell.label.numberOfLines = 2
                }
                cell.label.attributedText = title
                cell.accessibilityLabel = column.name
                cell.accessibilityValue = ResultGridAccessibility.headerValue(column: column, isPrimaryKey: parent.primaryKeys.contains(column.name), sortDirection: sorted ? parent.sortDirection : nil)
                cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: L10n.text("Configure Column")) { [weak self] _ in
                    self?.parent.onConfigureColumn(index); return true
                }]
                return
            }
            let row = parent.result.rows[path.section - 1]
            let value = row.cells.indices.contains(index) ? row.cells[index] : .null
            cell.label.text = value.isNull ? "NULL" : (value.displayValue.isEmpty ? "\"\"" : value.displayValue)
            if value.isNull { cell.label.textColor = .tertiaryLabel }
            if case .integer = value { cell.label.textAlignment = .right }
            if case .decimal = value { cell.label.textAlignment = .right }
            cell.accessibilityLabel = L10n.format("Row %d, %@", path.section, column.name)
            cell.accessibilityValue = ResultGridAccessibility.rowLabel(columns: [column], cells: [value])
            cell.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: L10n.text("Inspect Cell")) { [weak self] _ in
                    self?.parent.onInspectCell(path.section - 1, index); return true
                },
                UIAccessibilityCustomAction(name: L10n.text("Copy")) { [weak self] _ in
                    self?.select(path); self?.copySelectedCells(); return true
                },
                UIAccessibilityCustomAction(name: L10n.text("Extend cell selection")) { [weak self] _ in
                    self?.parent.extendsSelection = true; self?.select(path); return true
                }
            ]
            if parent.onOpenRow != nil {
                cell.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: L10n.text("Open Row")) { [weak self] _ in
                    self?.parent.onOpenRow?(path.section - 1); return true
                })
            }
            for action in parent.actionsForCell?(path.section - 1, index) ?? [] {
                cell.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: action.title) { _ in action.perform(); return true })
            }
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            collectionView.becomeFirstResponder()
            if indexPath.section == 0 {
                if indexPath.item == 0 { selectAll() }
                else if let onSort = parent.onSort { onSort(parent.result.columns[parent.visibleColumns[indexPath.item - 1]].name) }
                else { parent.onConfigureColumn(parent.visibleColumns[indexPath.item - 1]) }
            } else if indexPath.item == 0 { parent.onOpenRow?(indexPath.section - 1) }
            else { select(indexPath) }
        }

        func select(_ path: IndexPath) {
            guard path.section > 0, path.item > 0 else { return }
            let cell = ResultGridSelection.Cell(row: path.section - 1, column: path.item - 1)
            parent.selection = ResultGridSelection(anchor: parent.extendsSelection ? (parent.selection?.anchor ?? cell) : cell, end: cell)
        }

        func copySelectedCells() {
            guard let selection = parent.selection else { return }
            ResultGridClipboard.copy(result: parent.result, visibleColumns: parent.visibleColumns, selection: selection)
        }

        func selectAll() {
            guard !parent.result.rows.isEmpty, !parent.visibleColumns.isEmpty else { return }
            parent.selection = ResultGridSelection(anchor: .init(row: 0, column: 0), end: .init(row: parent.result.rows.count - 1, column: parent.visibleColumns.count - 1))
        }

        func moveSelection(row: Int, column: Int, extend: Bool) {
            guard !parent.result.rows.isEmpty, !parent.visibleColumns.isEmpty else { return }
            let previous = parent.selection?.end ?? .init(row: 0, column: 0)
            let cell = ResultGridSelection.Cell(row: min(parent.result.rows.count - 1, max(0, previous.row + row)), column: min(parent.visibleColumns.count - 1, max(0, previous.column + column)))
            parent.selection = ResultGridSelection(anchor: extend ? (parent.selection?.anchor ?? previous) : cell, end: cell)
            guard let collectionView, let layout = collectionView.collectionViewLayout as? FrozenGridLayout,
                  let attributes = layout.layoutAttributesForItem(at: IndexPath(item: cell.column + 1, section: cell.row + 1)) else { return }
            var offset = collectionView.contentOffset
            let bounds = collectionView.bounds
            if cell.column + 1 >= layout.frozenColumnCount {
                if attributes.frame.minX < offset.x + layout.frozenColumnWidth { offset.x = attributes.frame.minX - layout.frozenColumnWidth }
                else if attributes.frame.maxX > offset.x + bounds.width { offset.x = attributes.frame.maxX - bounds.width }
            }
            if attributes.frame.minY < offset.y + parent.rowHeight { offset.y = attributes.frame.minY - parent.rowHeight }
            else if attributes.frame.maxY > offset.y + bounds.height { offset.y = attributes.frame.maxY - bounds.height }
            offset.x = min(max(0, offset.x), max(0, collectionView.contentSize.width - bounds.width))
            offset.y = min(max(0, offset.y), max(0, collectionView.contentSize.height - bounds.height))
            collectionView.setContentOffset(offset, animated: false)
        }

        /// Draws the shared quick actions as UIKit menu elements; separators become inline groups.
        static func menuElements(_ items: [ResultGridMenuItem]) -> [UIMenuElement] {
            var groups: [[UIMenuElement]] = [[]]
            for item in items {
                switch item.kind {
                case .separator: groups.append([])
                case .submenu(let children):
                    groups[groups.count - 1].append(UIMenu(title: item.title, image: item.systemImage.flatMap { UIImage(systemName: $0) }, children: menuElements(children)))
                case .action(let perform):
                    var attributes: UIMenuElement.Attributes = []
                    if !item.isEnabled { attributes.insert(.disabled) }
                    if item.isDestructive { attributes.insert(.destructive) }
                    groups[groups.count - 1].append(UIAction(title: item.title, image: item.systemImage.flatMap { UIImage(systemName: $0) }, attributes: attributes) { _ in perform() })
                }
            }
            return groups.filter { !$0.isEmpty }.map { UIMenu(options: .displayInline, children: $0) }
        }

        func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
            guard indexPath.item > 0 else { return nil }
            let index = parent.visibleColumns[indexPath.item - 1]
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return UIMenu() }
                if indexPath.section == 0 { return UIMenu(children: Self.menuElements(self.parent.headerMenu(index))) }
                self.select(indexPath)
                return UIMenu(children: Self.menuElements(self.parent.cellMenu(indexPath.section - 1, index)))
            }
        }
    }
}

private final class FrozenGridLayout: UICollectionViewLayout {
    var widths: [CGFloat] = []
    var fixedWidthColumns: Set<Int> = []
    var rowHeight: CGFloat = 44
    var rowCount = 0
    var requestedPinnedCount = 1
    private var offsets: [CGFloat] = []
    private var measuredWidths: [CGFloat] = []
    private var pinnedCount = 1
    var frozenColumnCount: Int { pinnedCount }
    var frozenColumnWidth: CGFloat { measuredWidths.prefix(pinnedCount).reduce(0, +) }

    override func prepare() {
        super.prepare()
        measuredWidths = widths
        let flexibleColumns = widths.indices.filter { $0 > 0 && !fixedWidthColumns.contains($0) }
        let extraWidth = max(0, (collectionView?.bounds.width ?? 0) - widths.reduce(0, +))
        if !flexibleColumns.isEmpty, extraWidth > 0 {
            for index in flexibleColumns { measuredWidths[index] += extraWidth / CGFloat(flexibleColumns.count) }
        }
        var offset: CGFloat = 0
        offsets = measuredWidths.map { width in defer { offset += width }; return offset }
        // Leave a usable scrolling region even when an iPad layout folds down to a phone width.
        let maxPinnedWidth = max(44, (collectionView?.bounds.width ?? 0) - 96)
        pinnedCount = 1
        for index in 1..<max(1, min(requestedPinnedCount, widths.count)) {
            guard offsets[index] + measuredWidths[index] <= maxPinnedWidth else { break }
            pinnedCount += 1
        }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: max(measuredWidths.reduce(0, +), collectionView?.bounds.width ?? 0), height: CGFloat(rowCount) * rowHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard rowCount > 0, !widths.isEmpty else { return [] }
        let startRow = max(1, Int(floor(rect.minY / rowHeight)))
        let endRow = min(rowCount - 1, Int(ceil(rect.maxY / rowHeight)))
        var rows = [0]
        if startRow <= endRow { rows += Array(startRow...endRow) }
        let columns = measuredWidths.indices.filter { $0 < pinnedCount || offsets[$0] + measuredWidths[$0] >= rect.minX && offsets[$0] <= rect.maxX }
        return rows.flatMap { row in columns.compactMap { column in layoutAttributesForItem(at: IndexPath(item: column, section: row)) } }
    }

    override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard measuredWidths.indices.contains(path.item), offsets.indices.contains(path.item), path.section < rowCount else { return nil }
        let value = UICollectionViewLayoutAttributes(forCellWith: path)
        let bounds = collectionView?.bounds ?? .zero
        let frozenColumn = path.item < pinnedCount
        let header = path.section == 0
        value.frame = CGRect(x: offsets[path.item] + (frozenColumn ? max(0, bounds.minX) : 0), y: header ? max(0, bounds.minY) : CGFloat(path.section) * rowHeight, width: measuredWidths[path.item], height: rowHeight)
        value.zIndex = header ? (frozenColumn ? 2_000 : 1_000) : (frozenColumn ? 100 : 0)
        return value
    }
}

private final class ResultCollectionCell: UICollectionViewCell {
    let label = UILabel()
    let symbol = UIImageView()
    private let bottom = UIView()
    private let trailing = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = true
        contentView.addSubview(label)
        symbol.tintColor = UIColor(PortSQLPalette.accent)
        symbol.contentMode = .scaleAspectFit
        contentView.addSubview(symbol)
        bottom.backgroundColor = .separator.withAlphaComponent(0.5)
        trailing.backgroundColor = .separator.withAlphaComponent(0.35)
        contentView.addSubview(bottom)
        contentView.addSubview(trailing)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.insetBy(dx: 8, dy: 4)
        if symbol.image != nil {
            symbol.frame = CGRect(x: 8, y: (bounds.height - 12) / 2, width: 12, height: 12)
            label.frame.origin.x += 16
            label.frame.size.width = max(0, label.frame.size.width - 16)
        } else { symbol.frame = .zero }
        bottom.frame = CGRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5)
        trailing.frame = CGRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height)
    }
}

private final class ResultCollectionView: UICollectionView {
    var copySelection: (() -> Void)?
    var selectAllCells: (() -> Void)?
    var moveSelection: ((Int, Int, Bool) -> Void)?
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let editing = [UIKeyCommand(title: L10n.text("Copy"), action: #selector(copyCells), input: "c", modifierFlags: .command),
         UIKeyCommand(title: L10n.text("Select All"), action: #selector(selectAllCellsCommand), input: "a", modifierFlags: .command)]
        let arrows = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow].flatMap { input in
            [UIKeyModifierFlags(), .shift].map { flags in
                let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(moveGridSelection(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        return editing + arrows
    }
    @objc private func copyCells() { copySelection?() }
    @objc private func selectAllCellsCommand() { selectAllCells?() }
    @objc private func moveGridSelection(_ command: UIKeyCommand) {
        let row = command.input == UIKeyCommand.inputUpArrow ? -1 : (command.input == UIKeyCommand.inputDownArrow ? 1 : 0)
        let column = command.input == UIKeyCommand.inputLeftArrow ? -1 : (command.input == UIKeyCommand.inputRightArrow ? 1 : 0)
        moveSelection?(row, column, command.modifierFlags.contains(.shift))
    }
}


#endif

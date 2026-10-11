import AppKit
import SwiftUI

private final class ResultTableView: NSTableView {
    var onSelectCell: ((Int, Int, Bool) -> Void)?
    var onCopy: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        if row >= 0, column >= 0 { onSelectCell?(row, column, event.modifierFlags.contains(.shift)) }
    }
    @objc func copy(_ sender: Any?) { onCopy?() }
}

struct GridCollectionBridge: NSViewRepresentable {
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let table = ResultTableView()
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.rowHeight = rowHeight; table.intercellSpacing = NSSize(width: 1, height: 1)
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openCell)
        table.onSelectCell = { [weak coordinator = context.coordinator] row, column, extend in
            coordinator?.select(row: row, column: column, extend: extend)
        }
        table.onCopy = { [weak coordinator = context.coordinator] in coordinator?.copySelection() }
        let menu = NSMenu(); menu.delegate = context.coordinator; table.menu = menu
        table.setAccessibilityLabel(L10n.text("Query results table"))
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? ResultTableView else { return }
        let old = context.coordinator.parent
        context.coordinator.parent = self
        if old.visibleColumns != visibleColumns || old.result.columns != result.columns || table.tableColumns.isEmpty {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for index in visibleColumns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = result.columns[index].name
                column.minWidth = 64; column.maxWidth = 800
                column.width = configuration.widths[index].map { CGFloat($0) } ?? Self.naturalWidth(result: result, column: index)
                column.headerCell.font = .systemFont(ofSize: 12, weight: .medium)
                table.addTableColumn(column)
            }
        }
        for (position, index) in visibleColumns.enumerated() where table.tableColumns.indices.contains(position) {
            let column = table.tableColumns[position]
            if let width = configuration.widths[index], old.configuration.widths[index] != width { column.width = width }
            let arrow = sortedColumn == result.columns[index].name ? (sortDirection == "DESC" ? " ▾" : " ▴") : ""
            let name = result.columns[index].name, type = result.columns[index].type
            column.title = name + arrow
            // Show the type beside the name in a quieter style, as desktop SQL clients do.
            let header = NSMutableAttributedString()
            if primaryKeys.contains(name), let key = NSImage(systemSymbolName: "key.fill", accessibilityDescription: L10n.text("Primary key")) {
                let attachment = NSTextAttachment()
                attachment.image = key.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
                header.append(NSAttributedString(attachment: attachment))
                header.append(NSAttributedString(string: " "))
            }
            header.append(NSAttributedString(string: name + arrow,
                                             attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
            if !type.isEmpty {
                header.append(NSAttributedString(string: "  " + type.lowercased(),
                                                 attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            column.headerCell.attributedStringValue = header
            column.headerToolTip = primaryKeys.contains(name) ? L10n.text("Primary key") + " · " + type : type
        }
        if old.result != result || old.selection != selection || old.visibleColumns != visibleColumns || table.numberOfRows != result.rows.count { table.reloadData() }
    }
    static func naturalWidth(result: QueryResultTable, column: Int) -> CGFloat {
        guard result.columns.indices.contains(column) else { return 160 }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let values = [result.columns[column].name] + result.rows.prefix(40).map { row in row.cells.indices.contains(column) ? String(row.cells[column].displayValue.prefix(100)) : "NULL" }
        return min(320, max(100, values.map { ($0 as NSString).size(withAttributes: [.font:font]).width + 24 }.max() ?? 160))
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency NSTableViewDataSource, @preconcurrency NSTableViewDelegate, @preconcurrency NSMenuDelegate {
        var parent: GridCollectionBridge
        fileprivate weak var table: ResultTableView?
        private var actions: [() -> Void] = []
        init(_ parent: GridCollectionBridge) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.result.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier, let index = Int(identifier.rawValue), parent.result.rows.indices.contains(row) else { return nil }
            let value = parent.result.rows[row].cells.indices.contains(index) ? parent.result.rows[row].cells[index] : .null
            let container = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? Self.makeCell(identifier)
            guard let field = container.textField else { return container }
            field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            field.stringValue = value.isNull ? "NULL" : value.displayValue.isEmpty ? "\"\"" : value.displayValue
            field.lineBreakMode = .byTruncatingTail
            field.textColor = value.isNull ? .tertiaryLabelColor : .labelColor
            switch value {
            case .integer, .decimal: field.alignment = .right
            default: field.alignment = .left
            }
            field.toolTip = value.isNull ? L10n.text("NULL") : value.displayValue.isEmpty ? L10n.text("Empty text") : value.displayValue
            field.setAccessibilityValue(field.toolTip)
            if let position = parent.visibleColumns.firstIndex(of: index), parent.selection?.contains(row: row, column: position) == true {
                field.drawsBackground = true; field.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15)
            } else { field.drawsBackground = false }
            return container
        }
        /// A cell with horizontal insets, so right-aligned numbers don't touch the next column.
        private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            if let index = Int(tableColumn.identifier.rawValue) { parent.onSort?(parent.result.columns[index].name) }
        }
        func select(row: Int, column: Int, extend: Bool) {
            let cell = ResultGridSelection.Cell(row: row, column: column)
            let anchor = (extend || parent.extendsSelection) ? parent.selection?.anchor ?? cell : cell
            parent.selection = ResultGridSelection(anchor: anchor, end: cell)
            table?.reloadData()
        }
        func copySelection(headers: Bool = false) {
            guard let selection = parent.selection else { return }
            ResultGridClipboard.copy(result: parent.result, visibleColumns: parent.visibleColumns, selection: selection, headers: headers)
        }
        @objc func openCell() {
            guard let table, table.clickedRow >= 0, parent.visibleColumns.indices.contains(table.clickedColumn) else { return }
            parent.onInspectCell(table.clickedRow, parent.visibleColumns[table.clickedColumn])
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems(); actions = []
            guard let table, table.clickedRow >= 0, parent.visibleColumns.indices.contains(table.clickedColumn) else { return }
            let row = table.clickedRow, column = parent.visibleColumns[table.clickedColumn]
            select(row: row, column: table.clickedColumn, extend: parent.extendsSelection)
            add("Inspect Cell", to: menu) { self.parent.onInspectCell(row, column) }
            add("Copy Selected Cells", to: menu) { self.copySelection() }
            add("Copy with Headers", to: menu) { self.copySelection(headers: true) }
            if !parent.copyFormats.isEmpty {
                let copyAs = NSMenuItem(title: L10n.text("Copy As"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for format in parent.copyFormats {
                    let item = NSMenuItem(title: format.title, action: #selector(performAction(_:)), keyEquivalent: "")
                    item.target = self; item.tag = actions.count
                    actions.append { self.parent.onCopyAs(format) }
                    submenu.addItem(item)
                }
                copyAs.submenu = submenu
                menu.addItem(copyAs)
            }
            if let onOpenRow = parent.onOpenRow { add("Open Row", to: menu) { onOpenRow(row) } }
            for action in parent.actionsForCell?(row, column) ?? [] { add(action.title, to: menu, action: action.perform) }
            menu.addItem(.separator())
            add("Configure Column", to: menu) { self.parent.onConfigureColumn(column) }
            add(parent.configuration.pinned.contains(column) ? "Unpin Column" : "Pin Column", to: menu) { self.parent.onPinColumn(column) }
            if parent.visibleColumns.count > 1 { add("Hide Column", to: menu) { self.parent.onHideColumn(column) } }
        }
        private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
            let item = NSMenuItem(title: L10n.text(title), action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = actions.count; actions.append(action); menu.addItem(item)
        }
        @objc private func performAction(_ item: NSMenuItem) { if actions.indices.contains(item.tag) { actions[item.tag]() } }
    }
}

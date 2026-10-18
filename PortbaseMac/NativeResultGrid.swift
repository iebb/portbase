import AppKit
import SwiftUI

private final class ResultTableView: NSTableView {
    var onSelectCell: ((Int, Int, Bool) -> Void)?
    var onCopy: (() -> Void)?
    var onEditSelection: (() -> Bool)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // The double-click action runs inside super and starts in-place editing; selecting again on
        // the second click would end that edit immediately, so only single clicks select.
        guard event.clickCount == 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        if row >= 0, column >= 0 { onSelectCell?(row, column, event.modifierFlags.contains(.shift)) }
    }
    @objc func copy(_ sender: Any?) { onCopy?() }
    /// Return edits the selected cell, as in spreadsheet-style database clients.
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           onEditSelection?() == true { return }
        super.keyDown(with: event)
    }
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
    /// Moves a column (by index) to a position among the visible columns.
    var onMoveColumn: (Int, Int) -> Void = { _, _ in }
    var copyFormats: [ResultCopyFormat] = []
    var onCopyAs: (ResultCopyFormat) -> Void = { _ in }
    var headerMenu: (Int) -> [ResultGridMenuItem] = { _ in [] }
    var cellMenu: (Int, Int) -> [ResultGridMenuItem] = { _, _ in [] }
    var pendingKeys: Set<ResultGridCellKey> = []
    var canEditCell: (Int, Int) -> Bool = { _, _ in false }
    var onCommitEdit: (Int, Int, String) -> String? = { _, _, _ in nil }

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
        // Flat, edge-to-edge rows like a spreadsheet rather than the inset style's rounded rows.
        table.style = .fullWidth
        // Selection is drawn per cell; the system's full-row highlight fought with it and with the editor.
        table.selectionHighlightStyle = .none
        // Drag a header to reorder columns; the order is remembered for the table.
        table.allowsColumnReordering = true
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.openCell)
        table.onSelectCell = { [weak coordinator = context.coordinator] row, column, extend in
            coordinator?.select(row: row, column: column, extend: extend)
        }
        table.onCopy = { [weak coordinator = context.coordinator] in coordinator?.copySelection() }
        table.onEditSelection = { [weak coordinator = context.coordinator] in coordinator?.editSelection() ?? false }
        let menu = NSMenu(); menu.delegate = context.coordinator; menu.autoenablesItems = false; table.menu = menu
        let headerMenu = NSMenu(); headerMenu.delegate = context.coordinator; headerMenu.autoenablesItems = false; table.headerView?.menu = headerMenu
        context.coordinator.headerMenu = headerMenu
        table.setAccessibilityLabel(L10n.text("Query results table"))
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? ResultTableView else { return }
        let old = context.coordinator.parent
        context.coordinator.parent = self
        // A column the user just dragged is already in place, so compare against the table itself.
        let shown = table.tableColumns.map(\.identifier.rawValue)
        if shown != visibleColumns.map(String.init) || old.result.columns != result.columns || table.tableColumns.isEmpty {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for index in visibleColumns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = result.columns[index].name
                column.minWidth = 64; column.maxWidth = 800
                column.width = configuration.widths[index].map { CGFloat($0) } ?? Self.naturalWidth(result: result, column: index)
                column.headerCell.font = PortbaseFonts.codeFont(TypeSize.detail, bold: true)
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
                                             attributes: [.font: PortbaseFonts.codeFont(TypeSize.detail, bold: true), .foregroundColor: NSColor.labelColor]))
            if !type.isEmpty {
                header.append(NSAttributedString(string: "  " + type.lowercased(),
                                                 attributes: [.font: PortbaseFonts.codeFont(TypeSize.micro), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            column.headerCell.attributedStringValue = header
            column.headerToolTip = primaryKeys.contains(name) ? L10n.text("Primary key") + " · " + type : type
        }
        let changed = old.result != result || old.selection != selection || old.visibleColumns != visibleColumns
            || old.pendingKeys != pendingKeys || table.numberOfRows != result.rows.count
        // Reloading would tear down the field being edited; the edit's own commit reloads afterwards.
        if changed, !context.coordinator.isEditing { table.reloadData() }
    }
    static func naturalWidth(result: QueryResultTable, column: Int) -> CGFloat {
        guard result.columns.indices.contains(column) else { return 160 }
        // Measure with the fonts cells and headers are drawn in, so values that fit aren't truncated.
        let font = PortbaseFonts.codeFont(TypeSize.code)
        let item = result.columns[column]
        let header = (item.name as NSString).size(withAttributes: [.font: PortbaseFonts.codeFont(TypeSize.detail, bold: true)]).width
            + (item.type.isEmpty ? 0 : ("  " + item.type.lowercased() as NSString).size(withAttributes: [.font: PortbaseFonts.codeFont(TypeSize.micro)]).width)
            + 20
        let values = result.rows.prefix(40).map { row in row.cells.indices.contains(column) ? String(row.cells[column].displayValue.prefix(100)) : "NULL" }
        let widest = values.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(360, max(100, header + 24, widest + 28))
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency NSTableViewDataSource, @preconcurrency NSTableViewDelegate, @preconcurrency NSMenuDelegate, @preconcurrency NSTextFieldDelegate {
        var parent: GridCollectionBridge
        fileprivate weak var table: ResultTableView?
        private var editing: (row: Int, column: Int, original: String, field: NSTextField, box: NSView)?
        var isEditing: Bool { editing != nil }
        private var actions: [() -> Void] = []
        init(_ parent: GridCollectionBridge) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.result.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier, let index = Int(identifier.rawValue), parent.result.rows.indices.contains(row) else { return nil }
            let value = parent.result.rows[row].cells.indices.contains(index) ? parent.result.rows[row].cells[index] : .null
            let container = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? Self.makeCell(identifier)
            guard let field = container.textField else { return container }
            field.font = PortbaseFonts.codeFont(TypeSize.code)
            field.stringValue = value.isNull ? "NULL" : value.displayValue.isEmpty ? "\"\"" : value.displayValue
            field.lineBreakMode = .byTruncatingTail
            field.textColor = value.isNull ? .tertiaryLabelColor : .labelColor
            switch value {
            case .integer, .decimal: field.alignment = .right
            default: field.alignment = .left
            }
            field.toolTip = value.isNull ? L10n.text("NULL") : value.displayValue.isEmpty ? L10n.text("Empty text") : value.displayValue
            field.setAccessibilityValue(field.toolTip)
            field.isEditable = false
            let pending = parent.pendingKeys.contains(ResultGridCellKey(row: row, column: index))
            if pending { field.setAccessibilityValue((field.toolTip ?? "") + ", " + L10n.text("Pending change")) }
            // Tint the whole cell, not just the text, for selection and staged edits.
            field.drawsBackground = false
            container.wantsLayer = true
            if let position = parent.visibleColumns.firstIndex(of: index), parent.selection?.contains(row: row, column: position) == true {
                container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            } else if pending {
                container.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.22).cgColor
            } else { container.layer?.backgroundColor = nil }
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
        func tableViewColumnDidMove(_ notification: Notification) {
            guard let table, let to = notification.userInfo?["NSNewColumn"] as? Int,
                  table.tableColumns.indices.contains(to), let index = Int(table.tableColumns[to].identifier.rawValue) else { return }
            parent.onMoveColumn(index, to)
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            if let index = Int(tableColumn.identifier.rawValue) { parent.onSort?(parent.result.columns[index].name) }
        }
        func select(row: Int, column: Int, extend: Bool) {
            if isEditing { finishEditing(commit: true) }
            let cell = ResultGridSelection.Cell(row: row, column: column)
            let anchor = (extend || parent.extendsSelection) ? parent.selection?.anchor ?? cell : cell
            parent.selection = ResultGridSelection(anchor: anchor, end: cell)
            table?.reloadData()
        }
        func copySelection(headers: Bool = false) {
            guard let selection = parent.selection else { return }
            ResultGridClipboard.copy(result: parent.result, visibleColumns: parent.visibleColumns, selection: selection, headers: headers)
        }
        /// Double-click edits a cell in place when its row can be updated, and opens the value viewer otherwise.
        @objc func openCell() {
            guard let table, table.clickedRow >= 0, parent.visibleColumns.indices.contains(table.clickedColumn) else { return }
            let row = table.clickedRow, index = parent.visibleColumns[table.clickedColumn]
            if parent.canEditCell(row, index) { beginEditing(row: row, position: table.clickedColumn) }
            else { parent.onInspectCell(row, index) }
        }

        /// Lays an editor exactly over the cell: the cell's own background, one accent border, and the
        /// grid's font and padding, so editing looks like the cell itself became editable.
        func beginEditing(row: Int, position: Int) {
            guard let table, parent.result.rows.indices.contains(row), parent.visibleColumns.indices.contains(position) else { return }
            table.scrollRowToVisible(row)
            table.scrollColumnToVisible(position)
            let index = parent.visibleColumns[position]
            let cells = parent.result.rows[row].cells
            let value = cells.indices.contains(index) ? cells[index] : .null
            let text = value.isNull ? "" : value.displayValue

            let box = NSView(frame: table.frameOfCell(atColumn: position, row: row))
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor(PortSQLPalette.surface).cgColor
            box.layer?.borderColor = NSColor(PortSQLPalette.accent).cgColor
            box.layer?.borderWidth = 2
            box.layer?.cornerRadius = 2
            box.autoresizingMask = []

            let field = NSTextField(string: text)
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = PortbaseFonts.codeFont(TypeSize.code)
            field.textColor = NSColor(PortSQLPalette.ink)
            field.placeholderString = value.isNull ? "NULL" : nil
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            field.alignment = .left
            field.delegate = self
            field.setAccessibilityLabel(parent.result.columns[index].name)
            field.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(field)
            NSLayoutConstraint.activate([
                // Matches the cell label's insets, so the text doesn't shift when editing starts.
                field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])
            table.addSubview(box)
            editing = (row, index, text, field, box)
            table.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        /// Starts editing the single selected cell; returns false when there is nothing editable selected.
        func editSelection() -> Bool {
            guard let selection = parent.selection, selection.anchor == selection.end,
                  parent.visibleColumns.indices.contains(selection.end.column),
                  parent.canEditCell(selection.end.row, parent.visibleColumns[selection.end.column]) else { return false }
            beginEditing(row: selection.end.row, position: selection.end.column)
            return true
        }

        /// Moves the editor to the next editable cell in the row, keeping what was typed in this one.
        private func moveEditing(by step: Int) {
            guard let editing, let position = parent.visibleColumns.firstIndex(of: editing.column) else { return }
            let row = editing.row
            finishEditing(commit: true)
            var next = position + step
            while parent.visibleColumns.indices.contains(next) {
                if parent.canEditCell(row, parent.visibleColumns[next]) {
                    parent.selection = ResultGridSelection(anchor: .init(row: row, column: next), end: .init(row: row, column: next))
                    // Let the reload from the commit settle before placing the next editor.
                    DispatchQueue.main.async { [weak self] in self?.beginEditing(row: row, position: next) }
                    return
                }
                next += step
            }
        }

        private func finishEditing(commit: Bool) {
            guard let editing else { return }
            self.editing = nil
            let text = editing.field.stringValue
            editing.field.delegate = nil
            editing.box.removeFromSuperview()
            if commit, text != editing.original, parent.onCommitEdit(editing.row, editing.column, text) != nil { NSSound.beep() }
            table?.reloadData()
            table?.window?.makeFirstResponder(table)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, field === editing?.field else { return }
            finishEditing(commit: true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard control === editing?.field else { return false }
            if selector == #selector(NSResponder.insertTab(_:)) { moveEditing(by: 1); return true }
            if selector == #selector(NSResponder.insertBacktab(_:)) { moveEditing(by: -1); return true }
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            // Escape restores the loaded or staged value without staging anything.
            editing?.field.abortEditing()
            finishEditing(commit: false)
            return true
        }
        weak var headerMenu: NSMenu?
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems(); actions = []
            guard let table else { return }
            if menu === headerMenu, let header = table.headerView, let event = NSApp.currentEvent {
                let position = header.column(at: header.convert(event.locationInWindow, from: nil))
                guard parent.visibleColumns.indices.contains(position) else { return }
                build(parent.headerMenu(parent.visibleColumns[position]), into: menu)
                return
            }
            guard table.clickedRow >= 0, parent.visibleColumns.indices.contains(table.clickedColumn) else { return }
            select(row: table.clickedRow, column: table.clickedColumn, extend: parent.extendsSelection)
            build(parent.cellMenu(table.clickedRow, parent.visibleColumns[table.clickedColumn]), into: menu)
        }
        private func build(_ items: [ResultGridMenuItem], into menu: NSMenu) {
            for item in items {
                switch item.kind {
                case .separator: menu.addItem(.separator())
                case .submenu(let children):
                    let entry = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                    let submenu = NSMenu(); build(children, into: submenu); entry.submenu = submenu
                    menu.addItem(entry)
                case .action(let perform):
                    let entry = NSMenuItem(title: item.title, action: #selector(performAction(_:)), keyEquivalent: "")
                    entry.target = self; entry.tag = actions.count; entry.isEnabled = item.isEnabled
                    if let symbol = item.systemImage { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                    actions.append(perform); menu.addItem(entry)
                }
            }
        }
        private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
            let item = NSMenuItem(title: L10n.text(title), action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self; item.tag = actions.count; actions.append(action); menu.addItem(item)
        }
        @objc private func performAction(_ item: NSMenuItem) { if actions.indices.contains(item.tag) { actions[item.tag]() } }
    }
}

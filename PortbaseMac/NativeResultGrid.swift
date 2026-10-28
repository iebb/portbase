import AppKit
import SwiftUI

private final class ResultTableView: NSTableView {
    var onSelectCell: ((Int, Int, Bool) -> Void)?
    var onCopy: (() -> Void)?
    var onEditSelection: (() -> Bool)?
    var onMoveSelection: ((Int, Int, Bool) -> Void)?
    var onTypeToEdit: ((String) -> Bool)?
    var onShortcut: ((ResultGridShortcut) -> Bool)?
    var onSelectAll: (() -> Void)?
    private var isSelectingCells = false
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        guard event.clickCount == 1, row >= 0, column >= 0 else { super.mouseDown(with: event); return }
        // NSTableView's tracking loop selects whole rows and consumes the drag. Track cells ourselves.
        window?.makeFirstResponder(self)
        isSelectingCells = true
        onSelectCell?(row, column, event.modifierFlags.contains(.shift))
    }
    override func mouseDragged(with event: NSEvent) {
        guard isSelectingCells, numberOfRows > 0, numberOfColumns > 0 else { super.mouseDragged(with: event); return }
        autoscroll(with: event)
        var point = convert(event.locationInWindow, from: nil)
        point.x = min(max(point.x, 0), max(0, bounds.width - 1))
        point.y = min(max(point.y, 0), max(0, rect(ofRow: numberOfRows - 1).maxY - 1))
        let row = row(at: point), column = column(at: point)
        if row >= 0, column >= 0 { onSelectCell?(row, column, true) }
    }
    override func mouseUp(with event: NSEvent) {
        if isSelectingCells { isSelectingCells = false }
        else { super.mouseUp(with: event) }
    }
    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func paste(_ sender: Any?) { if onShortcut?(.paste) != true { NSSound.beep() } }
    override func selectAll(_ sender: Any?) { onSelectAll?() }
    /// The app's Duplicate command (⌘D) clones the selected row here, as DataGrip's Clone Row.
    @objc func duplicateLines(_ sender: Any?) { if onShortcut?(.cloneRow) != true { NSSound.beep() } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Key equivalents reach every view; only the focused grid takes its own.
        guard window?.firstResponder === self, let shortcut = ResultGridShortcut.matching(event),
              onShortcut?(shortcut) == true else { return super.performKeyEquivalent(with: event) }
        return true
    }
    /// Return edits the selected cells, as in spreadsheet-style database clients, and typing replaces them.
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           onEditSelection?() == true { return }
        if event.modifierFlags.intersection([.command, .control]).isEmpty, let typed = event.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }),
           onTypeToEdit?(typed) == true { return }
        if [123, 124, 125, 126].contains(event.keyCode), event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            let row = event.keyCode == 126 ? -1 : (event.keyCode == 125 ? 1 : 0)
            let column = event.keyCode == 123 ? -1 : (event.keyCode == 124 ? 1 : 0)
            onMoveSelection?(row, column, event.modifierFlags.contains(.shift))
            return
        }
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
    var headerStyle: ResultHeaderStyle = .platformDefault
    var onSort: ((String) -> Void)?
    var onOpenRow: ((Int) -> Void)?
    var actionsForCell: ((Int, Int) -> [ResultGridRowAction])?
    let onInspectCell: (Int, Int) -> Void
    var onEditSelectedCells: () -> Bool = { false }
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
    var deletedRows: Set<Int> = []
    var canEditCell: (Int, Int) -> Bool = { _, _ in false }
    var onCommitEdit: (Int, Int, String) -> String? = { _, _, _ in nil }
    /// Whether one value typed in place can go into every selected cell, the value they share, and staging it.
    var canEditSelection: () -> Bool = { false }
    var selectionText: () -> String = { "" }
    var onCommitSelection: (String) -> String? = { _ in nil }
    var onShortcut: (ResultGridShortcut) -> Bool = { _ in false }
    /// Changes when the grid should scroll to the selection.
    var revealSelection = 0

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
        table.onMoveSelection = { [weak coordinator = context.coordinator] row, column, extend in
            coordinator?.moveSelection(row: row, column: column, extend: extend)
        }
        table.onTypeToEdit = { [weak coordinator = context.coordinator] text in coordinator?.editSelection(typing: text) ?? false }
        table.onShortcut = { [weak coordinator = context.coordinator] shortcut in coordinator?.parent.onShortcut(shortcut) ?? false }
        table.onSelectAll = { [weak coordinator = context.coordinator] in coordinator?.selectAll() }
        let menu = NSMenu(); menu.delegate = context.coordinator; menu.autoenablesItems = false; table.menu = menu
        // A type under the name needs a taller header. Its height is set before the table joins the scroll
        // view, which sizes the header's area once; the grid is rebuilt when the style changes.
        table.headerView = ResultHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: headerStyle == .typeBelow ? 30 : 26))
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
        if shown != visibleColumns.map(String.init) || old.result.columns != result.columns || table.tableColumns.isEmpty
            || old.headerStyle != headerStyle {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for index in visibleColumns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.headerCell = ResultHeaderCell(textCell: "")
                column.title = result.columns[index].name
                column.minWidth = 64; column.maxWidth = 800
                column.width = configuration.widths[index].map { CGFloat($0) } ?? Self.naturalWidth(result: result, column: index, headerStyle: headerStyle)
                column.headerCell.font = PortbaseFonts.codeFont(TypeSize.detail)
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
            // Two lines share the header's height, so they're set a little smaller.
            let below = headerStyle == .typeBelow
            header.append(NSAttributedString(string: name + arrow,
                                             attributes: [.font: PortbaseFonts.codeFont(below ? TypeSize.caption : TypeSize.detail), .foregroundColor: NSColor.labelColor]))
            if !type.isEmpty, headerStyle != .nameOnly {
                header.append(NSAttributedString(string: (below ? "\n" : "  ") + type.lowercased(),
                                                 attributes: [.font: PortbaseFonts.codeFont(below ? TypeSize.micro - 1 : TypeSize.micro), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            column.headerCell.wraps = headerStyle == .typeBelow
            column.headerCell.attributedStringValue = header
            // The cell's own value keeps one line, so the full title rides along as its represented object.
            column.headerCell.representedObject = header
            column.headerToolTip = primaryKeys.contains(name) ? L10n.text("Primary key") + " · " + type : type
        }
        let changed = old.result != result || old.selection != selection || old.visibleColumns != visibleColumns
            || old.pendingKeys != pendingKeys || old.deletedRows != deletedRows || table.numberOfRows != result.rows.count
        // Reloading would tear down the field being edited; the edit's own commit reloads afterwards.
        if changed, !context.coordinator.isEditing { table.reloadData() }
        if old.revealSelection != revealSelection, let end = selection?.end, end.row < table.numberOfRows {
            table.scrollRowToVisible(end.row)
            table.scrollColumnToVisible(end.column)
            table.window?.makeFirstResponder(table)
        }
    }
    static func naturalWidth(result: QueryResultTable, column: Int, headerStyle: ResultHeaderStyle = .platformDefault) -> CGFloat {
        guard result.columns.indices.contains(column) else { return 160 }
        // Measure with the fonts cells and headers are drawn in, so values that fit aren't truncated.
        let font = PortbaseFonts.codeFont(TypeSize.code)
        let item = result.columns[column]
        let nameWidth = (item.name as NSString).size(withAttributes: [.font: PortbaseFonts.codeFont(TypeSize.detail, bold: true)]).width
        let typeWidth = item.type.isEmpty ? 0 : ("  " + item.type.lowercased() as NSString).size(withAttributes: [.font: PortbaseFonts.codeFont(TypeSize.micro)]).width
        let title: CGFloat = switch headerStyle {
        case .nameAndType: nameWidth + typeWidth
        case .typeBelow: max(nameWidth, typeWidth)
        case .nameOnly: nameWidth
        }
        let header = title + 20
        let values = result.rows.prefix(40).map { row in row.cells.indices.contains(column) ? String(row.cells[column].displayValue.prefix(100)) : "NULL" }
        let widest = values.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(360, max(100, header + 24, widest + 28))
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency NSTableViewDataSource, @preconcurrency NSTableViewDelegate, @preconcurrency NSMenuDelegate, @preconcurrency NSTextFieldDelegate {
        var parent: GridCollectionBridge
        fileprivate weak var table: ResultTableView?
        /// The cell being edited in place; with `multi`, what's typed goes into every selected cell.
        private var editing: (row: Int, column: Int, original: String, field: NSTextField, box: NSView, multi: Bool)?
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
            let deleted = parent.deletedRows.contains(row)
            if deleted {
                field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor, .font: field.font as Any])
                field.setAccessibilityValue((field.toolTip ?? "") + ", " + L10n.text("Marked for deletion"))
            }
            // Tint the whole cell, not just the text, for selection and staged edits.
            field.drawsBackground = false
            container.wantsLayer = true
            if let position = parent.visibleColumns.firstIndex(of: index), parent.selection?.contains(row: row, column: position) == true {
                container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).resolvedCGColor(in: tableView)
            } else if deleted {
                container.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).resolvedCGColor(in: tableView)
            } else if pending {
                container.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.22).resolvedCGColor(in: tableView)
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
            guard parent.selection != ResultGridSelection(anchor: anchor, end: cell) else { return }
            parent.selection = ResultGridSelection(anchor: anchor, end: cell)
            table?.reloadData()
        }
        func moveSelection(row: Int, column: Int, extend: Bool) {
            guard !parent.result.rows.isEmpty, !parent.visibleColumns.isEmpty else { return }
            let previous = parent.selection?.end ?? .init(row: 0, column: 0)
            let nextRow = min(max(previous.row + row, 0), parent.result.rows.count - 1)
            let nextColumn = min(max(previous.column + column, 0), parent.visibleColumns.count - 1)
            select(row: nextRow, column: nextColumn, extend: extend)
            table?.scrollRowToVisible(nextRow)
            table?.scrollColumnToVisible(nextColumn)
        }
        func selectAll() {
            guard !parent.result.rows.isEmpty, !parent.visibleColumns.isEmpty else { return }
            if isEditing { finishEditing(commit: true) }
            parent.selection = ResultGridSelection(anchor: .init(row: 0, column: 0),
                                                   end: .init(row: parent.result.rows.count - 1, column: parent.visibleColumns.count - 1))
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
        /// Typing starts the editor with what was typed in place of the value; `multi` edits every selected cell.
        func beginEditing(row: Int, position: Int, typing: String? = nil, multi: Bool = false) {
            guard let table, parent.result.rows.indices.contains(row), parent.visibleColumns.indices.contains(position) else { return }
            table.scrollRowToVisible(row)
            table.scrollColumnToVisible(position)
            let index = parent.visibleColumns[position]
            let cells = parent.result.rows[row].cells
            let value = cells.indices.contains(index) ? cells[index] : .null
            let text = multi ? parent.selectionText() : value.isNull ? "" : value.displayValue

            let box = NSView(frame: table.frameOfCell(atColumn: position, row: row))
            box.wantsLayer = true
            box.layer?.backgroundColor = NSColor(PortSQLPalette.surface).resolvedCGColor(in: table)
            box.layer?.borderColor = NSColor(PortSQLPalette.accent).resolvedCGColor(in: table)
            box.layer?.borderWidth = 2
            box.layer?.cornerRadius = 2
            box.autoresizingMask = []

            let field = NSTextField(string: typing ?? text)
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = PortbaseFonts.codeFont(TypeSize.code)
            field.textColor = NSColor(PortSQLPalette.ink)
            field.placeholderString = !multi && value.isNull ? "NULL" : nil
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
            editing = (row, index, text, field, box, multi)
            table.window?.makeFirstResponder(field)
            if typing == nil { field.currentEditor()?.selectAll(nil) }
            else { field.currentEditor()?.moveToEndOfDocument(nil) }
        }

        /// Edits the selected cells in place, all of them at once for a range; returns false when they
        /// can't be edited. A range that can't take one typed value opens the bulk editor on Return.
        func editSelection(typing: String? = nil) -> Bool {
            guard let selection = parent.selection, parent.visibleColumns.indices.contains(selection.end.column) else { return false }
            if selection.count > 1 {
                guard parent.canEditSelection() else { return typing == nil && parent.onEditSelectedCells() }
                beginEditing(row: selection.end.row, position: selection.end.column, typing: typing, multi: true)
                return true
            }
            guard parent.canEditCell(selection.end.row, parent.visibleColumns[selection.end.column]) else { return false }
            beginEditing(row: selection.end.row, position: selection.end.column, typing: typing)
            return true
        }

        /// Moves the editor to the next editable cell in the row, keeping what was typed in this one.
        private func moveEditing(by step: Int) {
            guard let editing, !editing.multi, let position = parent.visibleColumns.firstIndex(of: editing.column) else {
                finishEditing(commit: true)
                return
            }
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
            if commit, text != editing.original {
                let failure = editing.multi ? parent.onCommitSelection(text) : parent.onCommitEdit(editing.row, editing.column, text)
                if failure != nil { NSSound.beep() }
            }
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
            if parent.selection?.contains(row: table.clickedRow, column: table.clickedColumn) != true {
                select(row: table.clickedRow, column: table.clickedColumn, extend: false)
            }
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
                    let entry = NSMenuItem(title: item.title, action: #selector(performAction(_:)), keyEquivalent: item.shortcut?.key ?? "")
                    if let shortcut = item.shortcut { entry.keyEquivalentModifierMask = shortcut.usesOption ? [.command, .option] : .command }
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

/// A header cell that centers its title vertically, so a name with its type on a second line fits the
/// taller header instead of running into the divider below it.
private final class ResultHeaderCell: NSTableHeaderCell {
    // No stored properties: NSCell copies itself bytewise, which doesn't retain Swift references.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let title = (representedObject as? NSAttributedString) ?? attributedStringValue
        guard title.length > 0 else { super.drawInterior(withFrame: cellFrame, in: controlView); return }
        let available = cellFrame.insetBy(dx: 5, dy: 0)
        // Each line on its own, stacked and centered as a block.
        var lines: [NSAttributedString] = []
        var start = 0
        let string = title.string as NSString
        while start <= string.length {
            let lineEnd = string.range(of: "\n", range: NSRange(location: start, length: string.length - start)).location
            let end = lineEnd == NSNotFound ? string.length : lineEnd
            lines.append(title.attributedSubstring(from: NSRange(location: start, length: end - start)))
            if lineEnd == NSNotFound { break }
            start = end + 1
        }
        let heights = lines.map { ceil($0.size().height) }
        let total = heights.reduce(0, +)
        var y = controlView.isFlipped ? available.minY + max(0, (available.height - total) / 2)
                                      : available.maxY - max(0, (available.height - total) / 2)
        for (line, height) in zip(lines, heights) {
            let rect = NSRect(x: available.minX, y: controlView.isFlipped ? y : y - height, width: available.width, height: height)
            line.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y += controlView.isFlipped ? height : -height
        }
    }
}

/// A header whose column titles take its full height, for the taller two-line header.
private final class ResultHeaderView: NSTableHeaderView {
    override func headerRect(ofColumn column: Int) -> NSRect {
        var rect = super.headerRect(ofColumn: column)
        rect.origin.y = bounds.minY
        rect.size.height = bounds.height
        return rect
    }
}

extension ResultGridShortcut {
    /// The shortcut a key press is, if any: Command with the key, and Option where the shortcut has it.
    static func matching(_ event: NSEvent) -> Self? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.keyCode == 51 ? "\u{8}" : (event.charactersIgnoringModifiers ?? "").lowercased()
        return allCases.first { $0.key == key && modifiers == ($0.usesOption ? [.command, .option] : .command) }
    }
}

extension NSColor {
    /// The color for a layer, resolved in the view's own light or dark appearance. A plain `cgColor`
    /// resolves in whatever appearance is current, which is the system's when Portbase is set to the
    /// other one, and then draws a dark fill in a light window.
    func resolvedCGColor(in view: NSView) -> CGColor {
        var color = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { color = self.cgColor }
        return color
    }
}

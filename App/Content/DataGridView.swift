import AppKit
import ElefantasCore
import SwiftUI

/// The data grid: a view-based NSTableView reading straight from the controller's page buffer.
/// SwiftUI passes `rowsVersion`/`columns` so the view updates whenever the page changes.
struct DataGridView: NSViewRepresentable {
    let controller: ContentController
    let rowsVersion: Int
    let columns: [ColumnInfo]
    let sort: SortSpec?
    let isEditable: Bool
    @Binding var selectedRows: IndexSet
    var onDeleteRequest: (IndexSet) -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> GridCoordinator { GridCoordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.coordinator = context.coordinator
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.usesAutomaticRowHeights = false
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = .separatorColor
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsTypeSelect = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(GridCoordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        table.setAccessibilityLabel(String(localized: "Table content"))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }
}

final class GridTableView: NSTableView {
    weak var coordinator: GridCoordinator?

    override func keyDown(with event: NSEvent) {
        // Return / Enter starts editing the selected row, like Sequel Ace.
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           selectedRow >= 0, let coordinator {
            coordinator.beginEditing(row: selectedRow, column: coordinator.preferredEditColumn)
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.copyRows(selectedRowIndexes)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-clicking outside the selection selects the clicked row first.
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

final class GridCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        addSubview(label)
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 4, y: floor((bounds.height - height) / 2), width: max(0, bounds.width - 8), height: height)
    }
}

@MainActor
final class GridCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
    var parent: DataGridView
    weak var table: GridTableView?

    private var columnNames: [String] = []
    private var lastRowsVersion = -1
    private var needsAutosize = true
    private var lastClickedColumn = 0
    private var editing: (row: Int, column: Int, original: String?)?
    private var editCancelled = false
    private var reloadAfterEditing = false

    static let font = NSFont.systemFont(ofSize: 12)
    static let nullFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    private static let cellID = NSUserInterfaceItemIdentifier("cell")

    init(parent: DataGridView) {
        self.parent = parent
    }

    private var controller: ContentController { parent.controller }

    var preferredEditColumn: Int {
        let names = columnNames
        if names.indices.contains(lastClickedColumn), controller.isColumnEditable(names[lastClickedColumn]) {
            return lastClickedColumn
        }
        return names.firstIndex { controller.isColumnEditable($0) } ?? 0
    }

    // MARK: - Sync from SwiftUI

    func sync() {
        guard let table else { return }
        let names = parent.columns.map(\.name)
        if names != columnNames {
            rebuildColumns(table, names: names)
            columnNames = names
            lastRowsVersion = -1
            needsAutosize = true
        }
        if parent.rowsVersion != lastRowsVersion {
            lastRowsVersion = parent.rowsVersion
            if editing != nil {
                reloadAfterEditing = true
            } else {
                table.reloadData()
            }
            if needsAutosize, !controller.rows.isEmpty {
                autosizeColumns(table)
                needsAutosize = false
            }
        }
        updateSortIndicators(table)
    }

    private func rebuildColumns(_ table: NSTableView, names: [String]) {
        for column in table.tableColumns.reversed() { table.removeTableColumn(column) }
        for (index, info) in parent.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = info.name
            column.headerToolTip = info.typeName.isEmpty ? info.name : "\(info.name) — \(info.typeName)"
            column.minWidth = 40
            column.maxWidth = 2000
            column.width = Self.textWidth(info.name, font: .boldSystemFont(ofSize: 12)) + 28
            table.addTableColumn(column)
        }
    }

    private func autosizeColumns(_ table: NSTableView) {
        let rows = controller.rows.prefix(40)
        for column in table.tableColumns {
            guard let index = Int(column.identifier.rawValue) else { continue }
            var width = Self.textWidth(column.title, font: .boldSystemFont(ofSize: 12)) + 28
            for row in rows where index < row.count {
                width = max(width, Self.textWidth(Self.displayText(row[index]), font: Self.font) + 14)
            }
            column.width = min(max(width, 60), 320)
        }
    }

    private func updateSortIndicators(_ table: NSTableView) {
        for column in table.tableColumns {
            let isSorted = parent.sort?.column == column.title
            let image = isSorted
                ? NSImage(named: parent.sort?.ascending == true ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
                : nil
            if table.indicatorImage(in: column) !== image { table.setIndicatorImage(image, in: column) }
        }
        table.highlightedTableColumn = table.tableColumns.first { $0.title == parent.sort?.column }
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Single-line, length-capped display form. NULL is shown as "NULL".
    static func displayText(_ value: String?) -> String {
        guard var text = value else { return "NULL" }
        if text.utf8.count > 1000 { text = String(text.prefix(300)) + "…" }
        if text.contains(where: \.isNewline) {
            text = text.replacingOccurrences(of: "\r\n", with: "↵")
                .replacingOccurrences(of: "\n", with: "↵")
                .replacingOccurrences(of: "\r", with: "↵")
        }
        return text
    }

    // MARK: - Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        controller.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let index = Int(tableColumn.identifier.rawValue) else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? GridCellView) ?? {
            let view = GridCellView(frame: .zero)
            view.identifier = Self.cellID
            return view
        }()
        let rows = controller.rows
        let value: String? = rows.indices.contains(row) && index < rows[row].count ? rows[row][index] : nil
        cell.label.stringValue = Self.displayText(value)
        cell.label.font = value == nil ? Self.nullFont : Self.font
        cell.label.textColor = value == nil ? .tertiaryLabelColor : .labelColor
        cell.label.isEditable = false
        cell.label.toolTip = (value?.utf8.count ?? 0) > 80 || (value?.contains(where: \.isNewline) ?? false)
            ? String(value!.prefix(2000)) : nil
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        controller.toggleSort(column: tableColumn.title)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table else { return }
        let selection = table.selectedRowIndexes
        DispatchQueue.main.async { [weak self] in self?.parent.selectedRows = selection }
    }

    // MARK: - Editing

    @objc func doubleClicked(_ sender: Any?) {
        guard let table else { return }
        let row = table.clickedRow
        let column = table.clickedColumn
        guard row >= 0, column >= 0 else { return }
        beginEditing(row: row, column: modelIndex(forDisplayedColumn: column))
    }

    private func modelIndex(forDisplayedColumn column: Int) -> Int {
        guard let table, table.tableColumns.indices.contains(column) else { return column }
        let index = Int(table.tableColumns[column].identifier.rawValue) ?? column
        lastClickedColumn = index
        return index
    }

    private func displayedColumn(forModelIndex index: Int) -> Int? {
        table?.tableColumns.firstIndex { $0.identifier.rawValue == String(index) }
    }

    func beginEditing(row: Int, column: Int) {
        guard let table, editing == nil, !controller.isLoading,
              columnNames.indices.contains(column), controller.rows.indices.contains(row) else { return }
        let name = columnNames[column]
        guard controller.isColumnEditable(name) else {
            if !parent.isEditable { NSSound.beep() }
            return
        }
        guard let displayed = displayedColumn(forModelIndex: column),
              let cell = table.view(atColumn: displayed, row: row, makeIfNecessary: true) as? GridCellView else { return }
        let original = controller.rows[row][column]
        editing = (row, column, original)
        editCancelled = false
        table.scrollColumnToVisible(displayed)
        let field = cell.label
        field.isEditable = true
        field.isSelectable = true
        field.font = Self.font
        field.textColor = .labelColor
        field.stringValue = original ?? ""
        field.delegate = self
        table.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editCancelled = true
            control.abortEditing()
            finishEditing(field: control as? NSTextField, commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditing(field: notification.object as? NSTextField, commit: !editCancelled)
    }

    private func finishEditing(field: NSTextField?, commit: Bool) {
        guard let edit = editing else { return }
        editing = nil
        field?.isEditable = false
        field?.isSelectable = false
        field?.delegate = nil
        let newValue = field?.stringValue ?? ""
        let changed = commit && !(edit.original == nil && newValue.isEmpty) && newValue != edit.original
        let column = columnNames[edit.column]

        if changed {
            commitValue(newValue, row: edit.row, column: column)
        }
        reloadRow(edit.row)
        if reloadAfterEditing {
            reloadAfterEditing = false
            table?.reloadData()
        }
        table?.window?.makeFirstResponder(table)
    }

    private func commitValue(_ value: String?, row: Int, column: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await controller.updateCell(row: row, column: column, value: value)
            } catch {
                parent.onError(error.localizedDescription)
                reloadRow(row)
            }
        }
    }

    private func reloadRow(_ row: Int) {
        guard let table, row < table.numberOfRows else { return }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    // MARK: - Copy

    func copyRows(_ indexes: IndexSet) {
        let rows = controller.rows
        let order = table?.tableColumns.compactMap { Int($0.identifier.rawValue) } ?? Array(columnNames.indices)
        let text = indexes.filter { $0 < rows.count }.map { r in
            order.map { c in c < rows[r].count ? (rows[r][c] ?? "NULL") : "" }.joined(separator: "\t")
        }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table else { return }
        let row = table.clickedRow
        let displayed = table.clickedColumn
        guard row >= 0 else { return }
        let column = displayed >= 0 ? modelIndex(forDisplayedColumn: displayed) : nil

        if let column {
            menu.addItem(item(String(localized: "Copy Cell"), #selector(copyCell(_:)), tag: column))
        }
        menu.addItem(item(String(localized: "Copy Rows"), #selector(copySelectedRows(_:))))
        if let column, columnNames.indices.contains(column), controller.isColumnEditable(columnNames[column]) {
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "Edit Cell"), #selector(editCell(_:)), tag: column))
            let nullable = !(parent.columns[column].notNull)
            let setNull = item(String(localized: "Set NULL"), #selector(setNull(_:)), tag: column)
            setNull.isEnabled = nullable
            menu.addItem(setNull)
        }
        if parent.isEditable {
            menu.addItem(.separator())
            let count = table.selectedRowIndexes.count
            menu.addItem(item(count > 1 ? String(localized: "Delete \(count) Rows…") : String(localized: "Delete Row…"),
                              #selector(deleteRows(_:))))
        }
    }

    private func item(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    @objc private func copyCell(_ sender: NSMenuItem) {
        guard let row = table?.clickedRow, controller.rows.indices.contains(row) else { return }
        let value = controller.rows[row][sender.tag] ?? "NULL"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func copySelectedRows(_ sender: Any?) {
        guard let table else { return }
        copyRows(table.selectedRowIndexes)
    }

    @objc private func editCell(_ sender: NSMenuItem) {
        guard let row = table?.clickedRow else { return }
        beginEditing(row: row, column: sender.tag)
    }

    @objc private func setNull(_ sender: NSMenuItem) {
        guard let row = table?.clickedRow, row >= 0, columnNames.indices.contains(sender.tag),
              controller.rows[row][sender.tag] != nil else { return }
        commitValue(nil, row: row, column: columnNames[sender.tag])
    }

    @objc private func deleteRows(_ sender: Any?) {
        guard let table, !table.selectedRowIndexes.isEmpty else { return }
        parent.onDeleteRequest(table.selectedRowIndexes)
    }
}

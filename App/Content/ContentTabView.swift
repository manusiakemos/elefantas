import ElefantasCore
import SwiftUI

struct ContentTabView: View {
    let controller: ContentController
    let relation: RelationInfo

    @State private var selectedRows = IndexSet()
    @State private var pendingDelete: IndexSet?
    @State private var showingAddRow = false
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(controller: controller)
                .id(relation.ref)
            Divider()
            banners
            DataGridView(
                controller: controller,
                rowsVersion: controller.rowsVersion,
                columns: controller.columns,
                sort: controller.sort,
                isEditable: controller.isEditable,
                selectedRows: $selectedRows,
                onDeleteRequest: { pendingDelete = $0 },
                onError: { actionError = $0 })
            Divider()
            footer
        }
        .onChange(of: controller.rowsVersion) { _, _ in
            selectedRows = selectedRows.filteredIndexSet { $0 < controller.rows.count }
        }
        .sheet(isPresented: $showingAddRow) {
            AddRowSheet(columns: controller.columns) { values in
                do {
                    try await controller.insertRow(values: values)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let rows = pendingDelete else { return }
                Task {
                    do {
                        try await controller.deleteRows(rows)
                        selectedRows = []
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Could not complete the change", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    private var deleteTitle: String {
        let n = pendingDelete?.count ?? 0
        return n == 1 ? String(localized: "Delete 1 row?") : String(localized: "Delete \(n) rows?")
    }

    @ViewBuilder private var banners: some View {
        if let error = controller.errorMessage {
            Banner(systemImage: "exclamationmark.triangle.fill", tint: .red, text: error)
        } else if let reason = controller.readOnlyReason {
            Banner(systemImage: "lock.fill", tint: .secondary, text: reason)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            ControlGroup {
                Button { showingAddRow = true } label: { Image(systemName: "plus") }
                    .help("Add row (⌥⌘A)")
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Button { pendingDelete = selectedRows } label: { Image(systemName: "minus") }
                    .help("Delete selected rows (⌘⌫)")
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(selectedRows.isEmpty)
            }
            .disabled(!controller.isEditable)
            .fixedSize()

            if controller.isLoading { ProgressView().controlSize(.small) }
            Text(rangeText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            countControl

            Spacer()

            Menu {
                ForEach([100, 500, 1000, 5000, 10000], id: \.self) { size in
                    Button {
                        controller.setPageSize(size)
                    } label: {
                        if size == controller.pageSize { Label("\(size) rows", systemImage: "checkmark") } else { Text("\(size) rows") }
                    }
                }
            } label: {
                Text("\(controller.pageSize) per page")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            ControlGroup {
                Button { controller.previousPage() } label: { Image(systemName: "chevron.left") }
                    .disabled(!controller.hasPreviousPage)
                    .help("Previous page")
                Button { controller.nextPage() } label: { Image(systemName: "chevron.right") }
                    .disabled(!controller.hasNextPage)
                    .help("Next page")
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .controlSize(.small)
    }

    @ViewBuilder private var countControl: some View {
        switch controller.total {
        case .counting:
            Button("Cancel count") { controller.cancelCount() }
                .buttonStyle(.link)
        case .exact:
            EmptyView()
        default:
            Button("Count rows") { controller.countRows() }
                .buttonStyle(.link)
                .help("Run an exact count(*) with the current filter")
        }
    }

    private var rangeText: String {
        let rows = controller.rows.count
        if rows == 0 { return controller.isLoading ? String(localized: "Loading…") : String(localized: "No rows") }
        let first = controller.offset + 1
        let last = controller.offset + rows
        let range = "\(first.formatted())–\(last.formatted())"
        switch controller.total {
        case .exact(let n): return String(localized: "Rows \(range) of \(n.formatted())")
        case .estimated(let n): return String(localized: "Rows \(range) of ~\(n.formatted(.number.notation(.compactName)))")
        case .counting: return String(localized: "Rows \(range) (counting…)")
        case .unknown: return String(localized: "Rows \(range)")
        }
    }
}

private struct Banner: View {
    let systemImage: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).lineLimit(3).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.08))
        Divider()
    }
}

// MARK: - Filter bar

private let rawWhereTag = "\u{0}raw-where"

struct FilterBar: View {
    let controller: ContentController
    @State private var column = ""
    @State private var op: FilterOperator = .equal
    @State private var value = ""
    @State private var secondValue = ""
    @State private var rawWhere = ""
    @FocusState private var valueFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Picker("Column", selection: $column) {
                Text("Column…").tag("")
                ForEach(controller.columns) { col in Text(col.name).tag(col.name) }
                Divider()
                Text("SQL WHERE…").tag(rawWhereTag)
            }
            .labelsHidden()
            .frame(width: 170)

            if column == rawWhereTag {
                TextField("Raw SQL condition, e.g. created_at > now() - interval '1 day'", text: $rawWhere)
                    .focused($valueFocused)
                    .onSubmit(apply)
                    .font(.system(.body, design: .monospaced))
                    .help("Executed as written after WHERE.")
            } else {
                Picker("Operator", selection: $op) {
                    ForEach(FilterOperator.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                .disabled(column.isEmpty)

                if op.valueCount >= 1 {
                    TextField(op == .inList ? "a, b, c" : "Value", text: $value)
                        .focused($valueFocused)
                        .onSubmit(apply)
                        .disabled(column.isEmpty)
                }
                if op.valueCount == 2 {
                    Text("and").foregroundStyle(.secondary)
                    TextField("Value", text: $secondValue)
                        .onSubmit(apply)
                        .disabled(column.isEmpty)
                }
                if op.valueCount == 0 { Spacer() }
            }

            Button("Filter", action: apply)
                .disabled(column.isEmpty)
            if controller.filter != .none {
                Button("Clear") { clear() }
            }
            // Hidden button that gives ⌘F to the filter field.
            Button("Focus Filter") { valueFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .frame(width: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func apply() {
        if column == rawWhereTag {
            controller.applyFilter(rawWhere.trimmingCharacters(in: .whitespaces).isEmpty ? .none : .rawWhere(rawWhere))
        } else if !column.isEmpty {
            controller.applyFilter(.column(ColumnFilter(column: column, op: op, value: value, secondValue: secondValue)))
        }
    }

    private func clear() {
        value = ""
        secondValue = ""
        rawWhere = ""
        controller.applyFilter(.none)
    }
}

// MARK: - Add row

struct AddRowSheet: View {
    let columns: [ColumnInfo]
    let onInsert: ([String: String?]) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: [String: String] = [:]
    @State private var isNull: Set<String> = []
    @State private var error: String?
    @State private var isSaving = false

    private var editableColumns: [ColumnInfo] { columns.filter { !$0.isGenerated } }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Row").font(.headline).padding(.top, 14)
            Form {
                ForEach(editableColumns) { col in
                    LabeledContent {
                        HStack {
                            TextField(col.name, text: binding(col.name), prompt: Text(placeholder(col)))
                                .labelsHidden()
                                .disabled(isNull.contains(col.name))
                            if !col.notNull {
                                Toggle("NULL", isOn: nullBinding(col.name))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(col.name)
                            Text(col.typeName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal).textSelection(.enabled)
            }
            HStack {
                Text("Empty fields use the column default.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { Task { await insert() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding(14)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 300, idealHeight: 480)
    }

    private func placeholder(_ col: ColumnInfo) -> String {
        if let def = col.defaultExpression { return "DEFAULT \(def)" }
        return col.notNull ? String(localized: "required") : "NULL"
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { text[name] ?? "" }, set: { text[name] = $0 })
    }

    private func nullBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { isNull.contains(name) }, set: { if $0 { isNull.insert(name) } else { isNull.remove(name) } })
    }

    private func insert() async {
        var values: [String: String?] = [:]
        for col in editableColumns {
            if isNull.contains(col.name) {
                values[col.name] = .some(nil)
            } else if let t = text[col.name], !t.isEmpty {
                values[col.name] = t
            }
        }
        isSaving = true
        defer { isSaving = false }
        if let failure = await onInsert(values) {
            error = failure
        } else {
            dismiss()
        }
    }
}

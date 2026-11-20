import ElefantasCore
import SwiftUI

struct ExplorerSidebar: View {
    @Bindable var explorer: ExplorerModel
    @Binding var selection: SidebarItem?
    @FocusState private var filterFocused: Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(explorer.visibleSchemas) { schema in
                DisclosureGroup(isExpanded: expandedBinding(schema.name)) {
                    schemaRows(schema.name)
                } label: {
                    Label(schema.name, systemImage: schema.isSystem ? "gearshape" : "square.stack.3d.up")
                        .lineLimit(1)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if explorer.isLoading && explorer.schemas.isEmpty {
                ProgressView()
            } else if let error = explorer.errorMessage, explorer.schemas.isEmpty {
                ContentUnavailableView("Could not load objects", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            }
        }
        .safeAreaInset(edge: .bottom) { filterBar }
    }

    @ViewBuilder private func schemaRows(_ schema: String) -> some View {
        if explorer.loadingSchemas.contains(schema) && explorer.contents[schema] == nil {
            ProgressView().controlSize(.small)
        }
        ForEach(explorer.relations(in: schema)) { relation in
            Label(relation.ref.name, systemImage: relation.kind.symbol)
                .lineLimit(1)
                .help(relation.kind.label)
                .tag(SidebarItem.relation(relation.ref))
        }
        let functions = explorer.functions(in: schema)
        if !functions.isEmpty {
            DisclosureGroup {
                ForEach(functions) { function in
                    Label(function.signature, systemImage: function.kind == .procedure ? "gearshape.2" : "function")
                        .lineLimit(1)
                        .tag(SidebarItem.function(function.oid))
                }
            } label: {
                Label("Functions (\(functions.count))", systemImage: "function")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter", text: $explorer.filterText)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                if !explorer.filterText.isEmpty {
                    Button { explorer.filterText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                Toggle(isOn: $explorer.showSystemSchemas) { Image(systemName: "gearshape") }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help("Show system schemas")
            }
            .padding(8)
            // Hidden button that gives ⌥⌘F to the filter field.
            Button("Filter Objects") { filterFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .hidden()
                .frame(height: 0)
        }
    }

    private func expandedBinding(_ schema: String) -> Binding<Bool> {
        Binding(
            get: { !explorer.filterText.isEmpty || explorer.expandedSchemas.contains(schema) },
            set: { expanded in
                if expanded {
                    explorer.expandedSchemas.insert(schema)
                    Task { await explorer.loadContents(schema) }
                } else {
                    explorer.expandedSchemas.remove(schema)
                }
            })
    }
}

extension RelationKind {
    var symbol: String {
        switch self {
        case .table: "tablecells"
        case .partitionedTable: "square.split.2x2"
        case .view: "eye"
        case .materializedView: "eye.square"
        case .foreignTable: "externaldrive.connected.to.line.below"
        }
    }

    var label: String {
        switch self {
        case .table: String(localized: "Table")
        case .partitionedTable: String(localized: "Partitioned table")
        case .view: String(localized: "View")
        case .materializedView: String(localized: "Materialized view")
        case .foreignTable: String(localized: "Foreign table")
        }
    }
}

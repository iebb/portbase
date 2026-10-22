import SwiftUI

/// The connection's tables and foreign keys as an entity-relationship diagram. Tapping a table brings its
/// relationships forward; Open browses it in the Explorer.
struct SchemaDiagramView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    var onOpen: (SchemaTableDescriptor) -> Void

    @State private var relationships: [SchemaRelationship]?
    @State private var error: String?
    @State private var includeUnrelated = false
    @State private var focused: String?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    private var layout: SchemaDiagramLayout {
        SchemaDiagramLayout.make(catalog: workspace.schemaCatalog, relationships: relationships ?? [], includeUnrelated: includeUnrelated)
    }

    var body: some View {
        NavigationStack {
            content
                .background(PortSQLPalette.sunken.ignoresSafeArea())
                .navigationTitle("Schema Diagram")
                .portbaseTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Toggle(isOn: $includeUnrelated) { Label("Show Unrelated Tables", systemImage: "square.grid.2x2") }
                            .help(L10n.text("Show Unrelated Tables"))
                        Button { zoom = max(0.4, zoom - 0.2) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                        Button { zoom = min(2, zoom + 0.2) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    }
                }
                .safeAreaInset(edge: .bottom) { focusBar }
        }
        .task(id: workspace.schemaCatalog.count) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let error {
            PortbaseEmptyState(title: L10n.text("Couldn’t load relationships"), message: error, systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if relationships == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if layout.nodes.isEmpty {
            PortbaseEmptyState(title: L10n.text("No foreign keys"), systemImage: "point.3.connected.trianglepath.dotted")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let layout = layout
            let scale = min(2.5, max(0.3, zoom * pinch))
            ScrollView([.horizontal, .vertical]) {
                diagram(layout)
                    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
            }
            .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in zoom = min(2.5, max(0.3, zoom * value.magnification)) })
        }
    }

    private func diagram(_ layout: SchemaDiagramLayout) -> some View {
        let frames = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.frame) })
        let related = focused.map { id in Set(layout.edges.filter { $0.from == id || $0.to == id }.flatMap { [$0.from, $0.to] }).union([id]) }
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { focused = nil }
            Canvas { context, _ in
                for edge in layout.edges {
                    guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
                    let active = focused.map { edge.from == $0 || edge.to == $0 } ?? true
                    // Leave from the side facing the other table; a self-reference loops out the right.
                    let forward = to.midX >= from.midX || edge.from == edge.to
                    let start = SchemaDiagramLayout.anchor(from, row: edge.fromRow, trailing: forward)
                    let end = SchemaDiagramLayout.anchor(to, row: edge.toRow, trailing: edge.from == edge.to ? true : !forward)
                    let bend = max(40, abs(end.x - start.x) / 2)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(to: end, control1: CGPoint(x: start.x + (forward ? bend : -bend), y: start.y),
                                  control2: CGPoint(x: end.x + (forward && edge.from != edge.to ? -bend : bend), y: end.y))
                    let color = active && focused != nil ? PortSQLPalette.accent : Color.secondary
                    context.stroke(path, with: .color(color.opacity(active ? 0.75 : 0.15)), lineWidth: active && focused != nil ? 1.6 : 1.1)
                    let dot = Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
                    context.fill(dot, with: .color(color.opacity(active ? 0.9 : 0.15)))
                }
            }
            .allowsHitTesting(false)
            ForEach(layout.nodes) { node in
                SchemaDiagramTable(node: node, isFocused: focused == node.id)
                    .opacity(related.map { $0.contains(node.id) ? 1 : 0.35 } ?? 1)
                    .offset(x: node.frame.minX, y: node.frame.minY)
                    .onTapGesture { focused = focused == node.id ? nil : node.id }
            }
        }
    }

    @ViewBuilder private var focusBar: some View {
        if let focused, let node = layout.nodes.first(where: { $0.id == focused }) {
            HStack(spacing: Spacing.m) {
                Text(verbatim: node.table.displayName).font(.rowTitle).lineLimit(1)
                Spacer()
                Button("Open") { dismiss(); onOpen(node.table) }.buttonStyle(.portbasePrimary)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .background(.bar)
        }
    }

    private func load() async {
        guard let profile = workspace.selectedBookmark else { relationships = []; return }
        do {
            relationships = try await DatabaseService.shared.schemaRelationships(catalog: workspace.schemaCatalog, profile: profile,
                                                                                database: workspace.activeDatabaseName)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = DatabaseErrorFormatter.message(for: error)
        }
    }
}

private struct SchemaDiagramTable: View {
    let node: SchemaDiagramLayout.Node
    let isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.xs) {
                Text(verbatim: node.table.name).font(.rowDetail.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(verbatim: node.table.schemaName).font(.captionText).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: SchemaDiagramLayout.headerHeight)
            Rectangle().fill(PortSQLPalette.stroke).frame(height: 1)
            ForEach(node.columns.indices, id: \.self) { index in
                let column = node.columns[index]
                HStack(spacing: 6) {
                    Image(systemName: column.isKey ? "key.fill" : column.isForeignKey ? "arrow.turn.down.right" : "circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(column.isKey || column.isForeignKey ? Color.secondary : Color.clear)
                        .frame(width: 12)
                    Text(verbatim: column.name).font(.codeCaption).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: column.type.lowercased()).font(.codeCaption).foregroundStyle(.tertiary).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: SchemaDiagramLayout.rowHeight)
            }
            if node.hiddenColumns > 0 {
                Text(L10n.format("+%d more", node.hiddenColumns)).font(.captionText).foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).frame(height: SchemaDiagramLayout.rowHeight)
            }
        }
        .padding(.bottom, 8 - 1)
        .frame(width: node.frame.width, height: node.frame.height, alignment: .topLeading)
        .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? PortSQLPalette.accent : PortSQLPalette.stroke, lineWidth: isFocused ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.table.displayName)
        .accessibilityValue(node.columns.map(\.name).joined(separator: ", "))
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
    }
}

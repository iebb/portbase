import SwiftUI

struct ConsoleTabBar: View {
    @EnvironmentObject private var consoles: ConsoleStore
    @State private var renamingID: UUID?
    @State private var title = ""
    @State private var closingID: UUID?
    @State private var discardingID: UUID?

    var body: some View {
        HStack(spacing: Spacing.s) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(consoles.consoles) { console in
                            tab(console)
                                .id(console.id)
                        }
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                }
                .onChange(of: consoles.selectedID) { _, id in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            Menu {
                Button("New Console", systemImage: "plus") { consoles.add() }
                Button("Close Console", systemImage: "xmark") { close(consoles.selectedID) }
                if let closed = consoles.closed.first {
                    Button("Reopen Closed Console", systemImage: "arrow.uturn.backward") { consoles.add(restoring: closed) }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.toolSymbol)
                    .foregroundStyle(PortSQLPalette.accent)
                    .frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
            } primaryAction: {
                consoles.add()
            }
            .accessibilityLabel("Consoles")
            .accessibilityHint("Opens a new console. Hold for more options.")
            .padding(.trailing, Spacing.xs)
        }
        .background(PortSQLPalette.panel)
        .overlay(alignment: .bottom) { Divider() }
        .confirmationDialog("Discard Changes and Close Console?", isPresented: Binding(get: { discardingID != nil }, set: { if !$0 { discardingID = nil } })) {
            Button("Discard Changes", role: .destructive) { if let discardingID { close(discardingID, discardingEdits: true) }; discardingID = nil }
            Button("Keep Editing", role: .cancel) { discardingID = nil }
        } message: {
            Text("Cell edits in this console haven't been submitted.")
        }
        .confirmationDialog("Roll Back and Close Console?", isPresented: Binding(get: { closingID != nil }, set: { if !$0 { closingID = nil } })) {
            Button("Rollback and Close", role: .destructive) {
                if let closingID { consoles.close(closingID, rollback: true) }
                closingID = nil
            }
            Button("Cancel", role: .cancel) { closingID = nil }
        }
        .alert("Rename Console", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("Name", text: $title)
            Button("Save") { if let id = renamingID { consoles.rename(id, title: title) }; renamingID = nil }
            Button("Cancel", role: .cancel) { renamingID = nil }
        }
    }

    private func tab(_ console: QueryConsole) -> some View {
        let selected = consoles.selectedID == console.id
        return HStack(spacing: Spacing.xs) {
            Button { consoles.select(console.id) } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: console.workspace.isRunning ? "bolt.fill" : "terminal")
                        .font(.captionStrong)
                        .foregroundStyle(selected ? PortSQLPalette.accent : .secondary)
                        .symbolEffect(.pulse, isActive: console.workspace.isRunning)
                    Text(console.title)
                        .font(.rowDetail.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? PortSQLPalette.ink : .secondary)
                        .lineLimit(1)
                    if console.workspace.hasOpenTransaction {
                        Circle().fill(Color.orange).frame(width: Sizes.dot, height: Sizes.dot)
                            .accessibilityLabel("Transaction open")
                    }
                }
                .padding(.leading, Spacing.m)
                .padding(.trailing, consoles.consoles.count > 1 ? Spacing.xxxs : Spacing.m)
                .frame(minHeight: Sizes.tabStrip)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if consoles.consoles.count > 1 {
                Button { close(console.id) } label: {
                    Image(systemName: "xmark")
                        .font(.badgeText)
                        .foregroundStyle(.secondary)
                        .frame(width: Sizes.iconTileSmall, height: Sizes.tabStrip)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("Close %@", console.title))
            }
        }
        .frame(minHeight: Sizes.touchTarget)
        .background {
            RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                .fill(selected ? PortSQLPalette.surface : Color.clear)
                .shadow(color: selected ? Color.black.opacity(0.08) : .clear, radius: 4, x: 0, y: 1)
        }
        .overlay { RoundedRectangle(cornerRadius: Radius.button, style: .continuous).strokeBorder(selected ? PortSQLPalette.stroke : .clear, lineWidth: 1) }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { title = console.title; renamingID = console.id }
            Button("Close", systemImage: "xmark") { close(console.id) }
        }
    }

    /// Asks before closing a console with unsubmitted cell edits, then before rolling back an open transaction.
    private func close(_ id: UUID, discardingEdits: Bool = false) {
        let workspace = consoles.consoles.first(where: { $0.id == id })?.workspace
        if !discardingEdits, workspace?.pendingCellEdits.isEmpty == false { discardingID = id }
        else if workspace?.hasOpenTransaction == true { closingID = id }
        else { consoles.close(id) }
    }
}

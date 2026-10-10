import SwiftUI

struct ConsoleTabBar: View {
    @EnvironmentObject private var consoles: ConsoleStore
    @State private var renamingID: UUID?
    @State private var title = ""
    @State private var closingID: UUID?

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(consoles.consoles) { console in
                            tab(console)
                                .id(console.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
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
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(PortSQLPalette.accent)
                    .frame(width: 44, height: 44)
            } primaryAction: {
                consoles.add()
            }
            .accessibilityLabel("Consoles")
            .accessibilityHint("Opens a new console. Hold for more options.")
            .padding(.trailing, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
        return HStack(spacing: 6) {
            Button { consoles.select(console.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: console.workspace.isRunning ? "bolt.fill" : "terminal")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(selected ? PortSQLPalette.accent : .secondary)
                        .symbolEffect(.pulse, isActive: console.workspace.isRunning)
                    Text(console.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? PortSQLPalette.ink : .secondary)
                        .lineLimit(1)
                    if console.workspace.hasOpenTransaction {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                            .accessibilityLabel("Transaction open")
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, consoles.consoles.count > 1 ? 2 : 12)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if consoles.consoles.count > 1 {
                Button { close(console.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("Close %@", console.title))
            }
        }
        .frame(minHeight: 44)
        .background {
            Capsule()
                .fill(selected ? PortSQLPalette.surface : Color.clear)
                .shadow(color: selected ? Color.black.opacity(0.08) : .clear, radius: 4, x: 0, y: 1)
        }
        .overlay { Capsule().strokeBorder(selected ? PortSQLPalette.stroke : .clear, lineWidth: 1) }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { title = console.title; renamingID = console.id }
            Button("Close", systemImage: "xmark") { close(console.id) }
        }
    }

    private func close(_ id: UUID) {
        if consoles.consoles.first(where: { $0.id == id })?.workspace.hasOpenTransaction == true { closingID = id }
        else { consoles.close(id) }
    }
}

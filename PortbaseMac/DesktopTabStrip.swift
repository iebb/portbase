import AppKit
import SwiftUI

// MARK: - Tabs

/// The window's tab strip, in the title bar like Termius: a home tab, a tab per open connection,
/// and a button that opens a server in a new tab.
struct DesktopTabStrip: View {
    @EnvironmentObject private var consoles: ConsoleStore
    @Binding var showsHome: Bool
    let onOpen: (UUID) -> Void
    let onNewConsole: () -> Void
    let onNewConnection: () -> Void
    @State private var renamingID: UUID?
    @State private var title = ""
    @State private var closingID: UUID?
    @State private var discardingID: UUID?
    @State private var showsPicker = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xxs) {
                    homeTab
                    Divider().frame(height: Spacing.l).padding(.horizontal, Spacing.xxs)
                    ForEach(consoles.consoles) { console in
                        DesktopSessionTab(console: console, workspace: console.workspace,
                                          isSelected: !showsHome && consoles.selectedID == console.id,
                                          onSelect: { consoles.select(console.id); showsHome = false },
                                          onClose: { close(console.id) },
                                          onRename: { title = console.title; renamingID = console.id },
                                          onCloseOthers: { for other in consoles.consoles where other.id != console.id { close(other.id) } })
                            .id(console.id)
                    }
                    Button { showsPicker = true } label: {
                        Image(systemName: "plus").font(.captionStrong).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PortSQLPalette.muted)
                    .help(L10n.text("Open a server in a new tab"))
                    .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                        DesktopServerPicker(compact: true, onOpen: { id in showsPicker = false; onOpen(id) },
                                            onNewConnection: { showsPicker = false; onNewConnection() },
                                            onEmptyConsole: { showsPicker = false; onNewConsole() })
                            .frame(width: 340, height: 420)
                    }
                }
                .padding(.vertical, Spacing.xxxs)
            }
            .onChange(of: consoles.selectedID) { _, id in withAnimation { proxy.scrollTo(id) } }
        }
        .confirmationDialog("Discard Changes and Close Console?", isPresented: Binding(get: { discardingID != nil }, set: { if !$0 { discardingID = nil } })) {
            Button("Discard Changes", role: .destructive) { if let discardingID { close(discardingID, discardingEdits: true) }; discardingID = nil }
            Button("Keep Editing", role: .cancel) { discardingID = nil }
        } message: {
            Text("Cell edits in this console haven't been submitted.")
        }
        .confirmationDialog("Roll Back and Close Console?", isPresented: Binding(get: { closingID != nil }, set: { if !$0 { closingID = nil } })) {
            Button("Rollback and Close", role: .destructive) { if let closingID { consoles.close(closingID, rollback: true) }; closingID = nil }
            Button("Cancel", role: .cancel) { closingID = nil }
        }
        .alert("Rename Console", isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
            TextField("Name", text: $title)
            Button("Save") { if let id = renamingID { consoles.rename(id, title: title) }; renamingID = nil }
            Button("Cancel", role: .cancel) { renamingID = nil }
        }
    }

    private var homeTab: some View {
        Button { showsHome = true } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "square.grid.2x2.fill")
                    .foregroundStyle(showsHome ? PortSQLPalette.accent : PortSQLPalette.muted)
                Text("Portbase")
                    .fontWeight(showsHome ? .semibold : .medium)
                    .foregroundStyle(showsHome ? PortSQLPalette.ink : PortSQLPalette.muted)
            }
            .font(.bodyText)
            .padding(.horizontal, Spacing.m)
            .frame(height: 28)
            .modifier(DesktopTabChrome(isSelected: showsHome, isHovered: false))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Home")
        .accessibilityAddTraits(showsHome ? [.isButton, .isSelected] : .isButton)
    }

    /// Asks before closing a console with unsubmitted cell edits, then before rolling back an open transaction.
    private func close(_ id: UUID, discardingEdits: Bool = false) {
        let workspace = consoles.consoles.first(where: { $0.id == id })?.workspace
        if !discardingEdits, workspace?.hasPendingChanges == true { discardingID = id }
        else if workspace?.hasOpenTransaction == true { closingID = id }
        else {
            consoles.close(id)
            if consoles.consoles.count == 1, consoles.active.workspace.selectedBookmarkID == nil { showsHome = true }
        }
    }
}

struct DesktopTabChrome: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(isSelected ? PortSQLPalette.surface : (isHovered ? PortSQLPalette.surface.opacity(0.5) : Color.clear),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(PortSQLPalette.stroke)
                }
            }
    }
}

/// A connection tab: the server's icon and name, its activity, and a close button.
struct DesktopSessionTab: View {
    let console: QueryConsole
    /// Observed so the tab follows the connection, running state, and open transaction.
    @ObservedObject var workspace: WorkspaceViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onCloseOthers: () -> Void
    @State private var isHovered = false

    private var title: String {
        if console.hasCustomTitle { return console.title }
        return workspace.selectedBookmark?.displayTitle ?? console.title
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Group {
                if let profile = workspace.selectedBookmark {
                    BookmarkAvatar(profile: profile, size: 18, cornerRadius: 5)
                } else {
                    Image(systemName: "terminal").foregroundStyle(PortSQLPalette.muted).frame(width: 18)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if workspace.isRunning {
                    Circle().fill(PortSQLPalette.accent).frame(width: 7, height: 7)
                        .overlay { Circle().strokeBorder(PortSQLPalette.surface, lineWidth: 1.5) }
                        .offset(x: 2, y: 2)
                        .symbolEffect(.pulse)
                }
            }
            Text(title)
                .lineLimit(1)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? PortSQLPalette.ink : PortSQLPalette.muted)
            if let database = workspace.activeDatabaseName, !database.isEmpty, workspace.selectedBookmark?.engine.isLocal == false {
                Text(database).font(.captionText).foregroundStyle(PortSQLPalette.muted).lineLimit(1)
            }
            if workspace.hasOpenTransaction {
                Circle().fill(Color.orange).frame(width: Sizes.dot, height: Sizes.dot).help(L10n.text("Open transaction"))
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PortSQLPalette.muted)
            .opacity(isSelected || isHovered ? 1 : 0)
            .accessibilityLabel("Close Console")
        }
        .font(.bodyText)
        .padding(.leading, Spacing.s)
        .padding(.trailing, Spacing.xs)
        .frame(height: 28)
        .frame(maxWidth: 240)
        .modifier(DesktopTabChrome(isSelected: isSelected, isHovered: isHovered))
        .overlay(alignment: .bottom) {
            // The connection's environment color underlines its tab, as Termius colors its hosts.
            if let environment = workspace.selectedBookmark?.environment, environment != .none {
                Capsule().fill(environment.color).frame(height: 2).padding(.horizontal, Spacing.s)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .help(workspace.selectedBookmark?.endpointSummary ?? title)
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Close", action: onClose)
            Button("Close Other Tabs", action: onCloseOthers)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A tab inside a connection tab. A previewed table's title is italic until it's kept, by a double click
/// or from the menu, as in an editor.
struct DesktopSubTab: View {
    let tab: SessionTabSet.Tab
    let title: String
    let symbol: String
    let chat: AssistantSession?
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onKeep: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: TypeSize.detail, weight: .semibold))
                .frame(width: TypeSize.detail + 4)
            Group {
                if let chat { DesktopChatTitle(session: chat, fallback: title) } else { Text(title) }
            }
            .font(PortbaseFonts.ui(TypeSize.detail, isSelected ? .semibold : .medium))
            .italic(tab.isPreview)
            .lineLimit(1)
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isSelected || isHovered ? 1 : 0)
                .accessibilityLabel(L10n.text("Close Tab"))
            }
        }
        .foregroundStyle(isSelected ? PortSQLPalette.accent : (isHovered ? PortSQLPalette.ink : PortSQLPalette.muted))
        .padding(.leading, Spacing.s)
        .padding(.trailing, canClose ? Spacing.xxs : Spacing.s)
        .frame(minHeight: Sizes.control)
        .frame(maxWidth: 200)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.button + 1, style: .continuous)
                    .fill(PortSQLPalette.accentSoft)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.button + 1, style: .continuous)
                            .strokeBorder(PortSQLPalette.accent.opacity(0.25), lineWidth: 1)
                    }
            } else if isHovered {
                RoundedRectangle(cornerRadius: Radius.button + 1, style: .continuous).fill(PortSQLPalette.ink.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        // Simultaneous, so a single click switches tabs without waiting to rule out a double click.
        .simultaneousGesture(TapGesture(count: 2).onEnded(onKeep))
        .onHover { isHovered = $0 }
        .help(helpText)
        .contextMenu {
            if tab.isPreview { Button("Keep Open", action: onKeep) }
            if canClose { Button("Close Tab", action: onClose) }
            Button("Close Other Tabs", action: onCloseOthers)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var helpText: String {
        if case .table(let name) = tab.kind { return name }
        return title
    }
}

/// A chat tab is titled by its first question.
struct DesktopChatTitle: View {
    @ObservedObject var session: AssistantSession
    let fallback: String

    var body: some View {
        Text(session.turns.first { $0.role == .user }?.text.replacingOccurrences(of: "\n", with: " ") ?? fallback)
            .truncationMode(.tail)
    }
}

/// Saved servers to open, as Termius offers hosts in a new tab.
struct DesktopServerPicker: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    var compact = false
    let onOpen: (UUID) -> Void
    let onNewConnection: () -> Void
    var onEmptyConsole: (() -> Void)?
    @State private var search = ""

    private var matches: [ConnectionProfile] {
        bookmarks.bookmarks.filter {
            search.isEmpty || [$0.displayTitle, $0.host, $0.engine.rawValue].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if !compact {
                Text("Choose a server").font(.sectionTitle).foregroundStyle(PortSQLPalette.ink)
            }
            PortbaseSearchField(prompt: L10n.text("Search servers"), text: $search)
                .font(.bodyText)
                .portbaseFieldChrome()
            ScrollView {
                LazyVStack(spacing: Spacing.xxs) {
                    ForEach(matches) { profile in
                        Button { onOpen(profile.id) } label: {
                            HStack(spacing: Spacing.s) {
                                BookmarkAvatar(profile: profile, size: Sizes.avatar, cornerRadius: Radius.chip)
                                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                    Text(profile.displayTitle).font(.rowTitle).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
                                    Text(profile.engine.isLocal ? profile.engine.rawValue : profile.endpointSummary)
                                        .font(.captionText).foregroundStyle(PortSQLPalette.muted).lineLimit(1)
                                }
                                Spacer(minLength: Spacing.xs)
                                if profile.environment != .none {
                                    Circle().fill(profile.environment.color).frame(width: Sizes.dot, height: Sizes.dot)
                                }
                            }
                            .padding(.horizontal, Spacing.s)
                            .frame(minHeight: Sizes.row)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(DesktopPickerRowStyle())
                    }
                }
            }
            Divider()
            HStack {
                Button("New Connection", systemImage: "plus", action: onNewConnection)
                if let onEmptyConsole {
                    Spacer()
                    Button("Empty Console", systemImage: "terminal", action: onEmptyConsole)
                }
            }
            .buttonStyle(.portbaseToolbar)
            .font(.bodyText)
        }
        .padding(compact ? Spacing.m : Spacing.xl)
        .frame(maxWidth: compact ? .infinity : 520, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
    }
}

struct DesktopPickerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? PortSQLPalette.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .onHoverBackground()
    }
}

private extension View {
    func onHoverBackground() -> some View { modifier(HoverBackground()) }
}

struct HoverBackground: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(hovered ? PortSQLPalette.sunken : Color.clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .onHover { hovered = $0 }
    }
}

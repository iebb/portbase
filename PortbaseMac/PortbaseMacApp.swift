import AppKit
import SwiftUI

@main
struct PortbaseMacApp: App {
    @StateObject private var bookmarks = BookmarkStore(cloudSyncEnabled: !WorkspaceFileStore.isTestHost)
    @StateObject private var library = WorkspaceLibraryStore(directory: WorkspaceFileStore.directory, cloudSyncEnabled: !WorkspaceFileStore.isTestHost)
    @StateObject private var consoles = ConsoleStore()
    @NSApplicationDelegateAdaptor(PortbaseAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Portbase", id: "workspace") {
            DesktopWorkspaceView()
                .formStyle(.grouped)
                .environmentObject(bookmarks)
                .environmentObject(library)
                .environmentObject(consoles)
                .environmentObject(consoles.active.workspace)
                .task {
                    consoles.configure(bookmarks: bookmarks, library: library)
                    delegate.consoles = consoles
                }
                .frame(minWidth: 900, minHeight: 600)
                .portbaseTheme()
        }
        .defaultSize(width: 1280, height: 840)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands { DesktopCommands(consoles: consoles) }

        Settings {
            DesktopSettingsView()
                .environmentObject(bookmarks)
                .environmentObject(library)
                .environmentObject(consoles)
                .portbaseTheme()
        }
    }
}

final class PortbaseAppDelegate: NSObject, NSApplicationDelegate {
    weak var consoles: ConsoleStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if consoles?.consoles.contains(where: { $0.workspace.hasOpenTransaction }) == true {
            let alert = NSAlert()
            alert.messageText = L10n.text("Roll Back and Quit?")
            alert.informativeText = L10n.text("Pending transactions will be rolled back.")
            alert.addButton(withTitle: L10n.text("Roll Back and Quit"))
            alert.addButton(withTitle: L10n.text("Cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        consoles?.suspend()
        return .terminateNow
    }
}

struct DesktopCommands: Commands {
    @ObservedObject var consoles: ConsoleStore
    @FocusedObject private var workspace: WorkspaceViewModel?
    @AppStorage("Portbase.editorFontSize") private var editorFontSize = 13.0
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Connection") { workspace?.createBookmark() }.keyboardShortcut("n")
            Button("New Console") { consoles.add() }.keyboardShortcut("t")
            Button("Open Script…") { DesktopScriptActions.open(consoles: consoles) }.keyboardShortcut("o")
            Button("Save Script…") { if let workspace { DesktopScriptActions.save(workspace: workspace) } }.keyboardShortcut("s")
            Button("Save Query") { workspace?.saveSnippet() }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Home") { NotificationCenter.default.post(name: .portbaseShowHome, object: nil) }
                .keyboardShortcut("0", modifiers: [.command])
            Button("Search…") { NotificationCenter.default.post(name: .portbaseShowCommandPalette, object: nil) }
                .keyboardShortcut("k", modifiers: [.command])
            Divider()
            ForEach(Array([DesktopWorkspaceView.Destination.console, .explorer, .structure, .charts].enumerated()), id: \.offset) { index, item in
                Button(L10n.text(item.title)) { NotificationCenter.default.post(name: .portbaseShowDestination, object: item.rawValue) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
            }
        }
        CommandGroup(after: .textEditing) {
            Button("Find and Replace") {
                let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
            }.keyboardShortcut("f")
            Divider()
            Button("Increase Text Size") { editorFontSize = min(24, editorFontSize + 1) }.keyboardShortcut("+")
            Button("Decrease Text Size") { editorFontSize = max(10, editorFontSize - 1) }.keyboardShortcut("-")
        }
        CommandMenu("Query") {
            Button("Run Query") { workspace?.runQuery() }.keyboardShortcut(.return)
                .disabled(workspace?.selectedBookmark == nil || workspace?.isRunning == true)
            Button("Run All") { workspace?.runQuery(entireBuffer: true) }.keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(workspace?.selectedBookmark == nil || workspace?.isRunning == true)
            Button("Cancel Query") { workspace?.cancelQuery() }.keyboardShortcut(".")
                .disabled(workspace?.isRunning != true)
            Divider()
            Button("Format") { workspace?.formatQuery() }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Explain") { workspace?.runExplain() }.keyboardShortcut("e", modifiers: [.command, .option])
            Button("Refresh Schema") { workspace?.refreshSchemaCatalog() }.keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Commit") { workspace?.finishTransaction(commit: true) }.disabled(workspace?.hasOpenTransaction != true)
            Button("Rollback") { workspace?.finishTransaction(commit: false) }.disabled(workspace?.hasOpenTransaction != true)
        }
    }
}

@MainActor enum DesktopScriptActions {
    static func open(consoles: ConsoleStore) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.text, .json, .data]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try ScriptFileService.read(url)
            consoles.add(); let workspace = consoles.active.workspace
            workspace.queryText = text; workspace.queryCursorOffset = 0; workspace.querySelectionLength = 0
            workspace.activeBoundQuery = nil
            if workspace.isDocumentDatabase { workspace.mongoDraft.mode = .command }
            consoles.rename(consoles.selectedID, title: url.lastPathComponent)
        } catch { consoles.active.workspace.errorMessage = error.localizedDescription }
    }
    static func save(workspace: WorkspaceViewModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = workspace.usesJSONEditor ? "query.json" : workspace.selectedBookmark?.engine == .redis ? "query.redis" : "query.sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            let script: String
            if workspace.isDocumentDatabase, workspace.mongoDraft.mode != .command {
                script = try workspace.mongoDraft.command(fallbackCollection: workspace.selectedExplorerTable?.name)
            } else {
                script = workspace.activeBoundQuery?.sql == workspace.queryText ? workspace.activeBoundQuery?.sourceSQL ?? workspace.queryText : workspace.queryText
            }
            try Data(script.utf8).write(to: url, options: .atomic)
        } catch { workspace.errorMessage = error.localizedDescription }
    }
}

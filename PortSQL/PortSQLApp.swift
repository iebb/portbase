#if !os(macOS)
import SwiftUI

@main
struct PortSQLApp: App {
    @StateObject private var bookmarkStore = BookmarkStore(cloudSyncEnabled: !WorkspaceFileStore.isTestHost)
    @StateObject private var libraryStore = WorkspaceLibraryStore(directory: WorkspaceFileStore.directory, cloudSyncEnabled: !WorkspaceFileStore.isTestHost)
    @StateObject private var consoles = ConsoleStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PortbaseFonts.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bookmarkStore)
                .environmentObject(libraryStore)
                .environmentObject(consoles.active.workspace)
                .environmentObject(consoles.active.workspace.editor)
                .environmentObject(consoles)
                .task {
                    consoles.configure(bookmarks: bookmarkStore, library: libraryStore)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { bookmarkStore.refreshSecrets() }
                    else if phase == .background { consoles.suspend() }
                    else if phase == .inactive { consoles.save() }
                }
        }
    }
}

#endif

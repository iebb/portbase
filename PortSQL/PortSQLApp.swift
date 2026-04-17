import SwiftUI

@main
struct PortSQLApp: App {
    @StateObject private var bookmarkStore = BookmarkStore()
    @StateObject private var libraryStore = WorkspaceLibraryStore()
    @StateObject private var workspace = WorkspaceViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bookmarkStore)
                .environmentObject(libraryStore)
                .environmentObject(workspace)
                .task {
                    workspace.configure(bookmarkStore: bookmarkStore, libraryStore: libraryStore)
                }
        }
    }
}

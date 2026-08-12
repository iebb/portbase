import SwiftUI

@main
struct PortSQLApp: App {
    @StateObject private var bookmarkStore = BookmarkStore()
    @StateObject private var libraryStore = WorkspaceLibraryStore()
    @StateObject private var workspace = WorkspaceViewModel()
    @StateObject private var purchaseStore = PurchaseStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bookmarkStore)
                .environmentObject(libraryStore)
                .environmentObject(workspace)
                .environmentObject(purchaseStore)
                .task {
                    workspace.configure(
                        bookmarkStore: bookmarkStore,
                        libraryStore: libraryStore,
                        purchaseStore: purchaseStore
                    )
                    await purchaseStore.configure()
                }
        }
    }
}

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var library: WorkspaceLibraryStore

    var body: some View {
        Form {
            Section {
                AboutHeader()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: Spacing.s, leading: 0, bottom: Spacing.s, trailing: 0))
            }

            AppearanceSettingsSection()
            EditorThemeSettingsSection()

            Section {
                CloudStatusRow()
                Button {
                    bookmarks.synchronizeCloud()
                    library.synchronizeCloud()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                if let error = bookmarks.cloudSyncError ?? library.cloudSyncError {
                    Text(error).font(.footnoteText).foregroundStyle(.red)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Connections, saved queries, and chart configurations sync with iCloud. Passwords, keys, query history, results, and SQLite files stay on this device.")
            }

            Section("Library") {
                NavigationLink {
                    LibraryStorageView()
                } label: {
                    LabeledContent {
                        Text(L10n.format("Saved: %d", library.snippets.count))
                    } label: {
                        Label("Library Storage", systemImage: "archivebox")
                    }
                }
            }

            Section {
                FlowChips(items: DatabaseEngine.allCases.map { ($0.rawValue, $0.symbolName, $0.tint) })
                    .padding(.vertical, Spacing.xxs)
            } header: {
                Text("Supported Engines")
            } footer: {
                Text("Database passwords, SSH keys, and private CA certificates stay in this device’s Keychain.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

struct AboutHeader: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            PortbaseLogoMark(size: 56)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(verbatim: "Portbase").font(.pageTitle)
                Text(versionLabel).font(.rowDetail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return L10n.format("Version %@ (%@)", version, build)
    }
}

struct AppearanceSettingsSection: View {
    @AppStorage(PortbaseAccent.storageKey) private var accent = PortbaseAccent.indigo.rawValue
    @AppStorage(PortbaseAppearance.storageKey) private var appearance = PortbaseAppearance.system.rawValue

    var body: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(PortbaseAppearance.allCases) { option in
                    Label(option.title, systemImage: option.symbolName).tag(option.rawValue)
                }
            }
#if os(iOS)
            .pickerStyle(.segmented)
            .labelsHidden()
#endif

            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Accent Color").font(.rowDetail)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: Spacing.m)], spacing: Spacing.m) {
                    ForEach(PortbaseAccent.allCases) { option in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { accent = option.rawValue }
                        } label: {
                            VStack(spacing: Spacing.xs) {
                                Circle()
                                    .fill(LinearGradient(colors: option.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: Sizes.iconTile, height: Sizes.iconTile)
                                    .overlay {
                                        if accent == option.rawValue {
                                            Image(systemName: "checkmark").font(.captionText.weight(.heavy)).foregroundStyle(.white)
                                        }
                                    }
                                    .padding(Spacing.xxs)
                                    .overlay {
                                        Circle().strokeBorder(accent == option.rawValue ? option.gradient[0] : .clear, lineWidth: 2)
                                    }
                                Text(option.title).font(.microText).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(minWidth: Sizes.touchTarget, minHeight: Sizes.touchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(accent == option.rawValue ? .isSelected : [])
                    }
                }
            }
            .padding(.vertical, Spacing.xxs)
        } header: {
            Text("Appearance")
        }
    }
}

struct EditorThemeSettingsSection: View {
    @AppStorage(EditorTheme.storageKey) private var themeName = EditorTheme.portbase.rawValue

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.m)], spacing: Spacing.m) {
                ForEach(EditorTheme.allCases) { theme in
                    Button {
                        themeName = theme.rawValue
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            EditorThemePreview(theme: theme, isSelected: themeName == theme.rawValue)
                            HStack(spacing: Spacing.xxs) {
                                Text(theme.title).font(.captionStrong).foregroundStyle(PortSQLPalette.ink)
                                if themeName == theme.rawValue {
                                    Image(systemName: "checkmark.circle.fill").font(.captionText).foregroundStyle(PortSQLPalette.accent)
                                }
                            }
                            Text(theme.subtitle).font(.microText).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(themeName == theme.rawValue ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, Spacing.xs)
        } header: {
            Text("Editor Theme")
        }
    }
}

private struct CloudStatusRow: View {
    var body: some View {
        let available = FileManager.default.ubiquityIdentityToken != nil
        LabeledContent {
            PortbaseChip(title: available ? L10n.text("iCloud available") : L10n.text("Unavailable"),
                         systemImage: available ? "checkmark.icloud.fill" : "icloud.slash", tint: available ? .green : .orange)
        } label: {
            Label("Status", systemImage: "icloud")
        }
    }
}

/// Wrapping chips for short labels.
struct FlowChips: View {
    let items: [(String, String, Color)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Spacing.s)], alignment: .leading, spacing: Spacing.s) {
            ForEach(items, id: \.0) { item in
                PortbaseChip(title: item.0, systemImage: item.1, tint: item.2)
            }
        }
    }
}

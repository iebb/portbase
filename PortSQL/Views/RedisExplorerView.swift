import SwiftUI

private struct RedisKeySelection: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let database: String
    let key: RedisKey
}

private struct RedisMutationSelection: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let database: String
    let key: RedisKey?
    let type: String
    let action: RedisMutationAction
    var value: Data? = nil
}

private enum RedisMutationAction { case write, delete, expire, persist }
private enum RedisByteEncoding: String, CaseIterable { case utf8 = "UTF-8", base64 = "Base64" }

struct RedisExplorerView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var databaseText = "0"
    @State private var pattern = "*"
    @State private var keyType = ""
    @State private var keys: [RedisKey] = []
    @State private var cursor = "0"
    @State private var started = false
    @State private var truncated = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var tableMode = false
    @State private var selection: RedisKeySelection?
    @State private var mutation: RedisMutationSelection?
    @State private var table = QueryResultTable.empty

    private var database: String { workspace.activeDatabaseName ?? "0" }
    private var contextID: String { (workspace.selectedBookmark?.id.uuidString ?? "") + ":" + database }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PanelCard {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        HStack {
                            Text("Redis keys").font(.cardTitle)
                            Spacer()
                            if let profile = workspace.selectedBookmark, !profile.isReadOnly {
                                Button {
                                    mutation = RedisMutationSelection(profile: profile, database: database, key: nil, type: "string", action: .write)
                                } label: { Image(systemName: "plus").frame(width: Sizes.control, height: Sizes.control) }
                                .accessibilityLabel("Create Key")
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack { databaseControl; patternControl }
                            VStack(alignment: .leading) { databaseControl; patternControl }
                        }
                        HStack {
                            Picker("Key type", selection: $keyType) {
                                Text("All types").tag("")
                                ForEach(RedisCommandService.keyTypes, id: \.self) { Text(verbatim: $0).tag($0) }
                            }
                            Spacer()
                            Button {
                                if isLoading { task?.cancel() } else { scan(reset: true) }
                            } label: {
                                Label(L10n.text(isLoading ? "Stop" : "Scan"), systemImage: isLoading ? "stop.fill" : "arrow.clockwise")
                                    .frame(minHeight: Sizes.control)
                            }.buttonStyle(.borderedProminent).disabled(workspace.selectedBookmark == nil)
                        }
                        if let error { Text(error).font(.captionText).foregroundStyle(.red).textSelection(.enabled) }
                    }
                }
                if started {
                    PanelCard {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            HStack {
                                Text(L10n.format("Loaded keys: %d", keys.count)).font(.rowDetail.monospacedDigit())
                                Spacer()
                                Picker("Display", selection: $tableMode) {
                                    Text("Keys").tag(false)
                                    Text("Table").tag(true)
                                }.pickerStyle(.segmented).frame(maxWidth: 180)
                            }
                            if tableMode {
                                ResultGridView(result: table, persistenceKey: "redis.keys", onOpenRow: { index in
                                    if keys.indices.contains(index) { open(keys[index]) }
                                })
                            } else {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(keys) { key in
                                        Button { open(key) } label: {
                                            HStack {
                                                Text(key.displayName).font(.codeDetail)
                                                    .lineLimit(2).multilineTextAlignment(.leading)
                                                Spacer()
                                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                            }.frame(minHeight: Sizes.control)
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                        Divider()
                                    }
                                }
                            }
                            if isLoading { ProgressView() }
                            if truncated {
                                Text("The key limit was reached. Narrow the pattern and scan again.").font(.captionText).foregroundStyle(.secondary)
                            } else if cursor != "0" {
                                Button("Load More Keys") { scan(reset: false) }.frame(minHeight: Sizes.control).disabled(isLoading)
                            } else if !isLoading {
                                Text("Scan complete").font(.captionText).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.padding()
        }
#if !os(macOS)
        .navigationTitle("Explorer")
        .portbaseTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: PortbaseToolbar.leading) { ConnectionSwitcherButton() }
        }
#endif
        .onChange(of: contextID, initial: true) { _, _ in
            task?.cancel(); generation = UUID(); isLoading = false
            keys = []; cursor = "0"; started = false; truncated = false; error = nil
            databaseText = database; selection = nil; mutation = nil
        }
        .onDisappear { task?.cancel() }
        .sheet(item: $selection) { value in
            RedisKeyInspector(profile: value.profile, database: value.database, key: value.key).portbaseDesktopSheetSize()
        }
        .sheet(item: $mutation) { value in
            RedisMutationEditor(selection: value) { scan(reset: true) }.portbaseDesktopSheetSize()
        }
    }

    private var databaseControl: some View {
        HStack {
            Text("Database").font(.rowDetail)
            TextField("Database number", text: $databaseText).portbaseKeyboardType(.numberPad)
                .textFieldStyle(.roundedBorder).frame(minWidth: 56, maxWidth: 100)
            Button("Use") {
                guard let value = Int32(databaseText), value >= 0 else { error = RedisClientError.invalidDatabase.localizedDescription; return }
                workspace.selectDatabase(String(value)); error = nil
            }.frame(minWidth: Sizes.control, minHeight: Sizes.control).disabled(isLoading)
        }
    }

    private var patternControl: some View {
        HStack {
            Text("Pattern").font(.rowDetail)
            TextField("Key pattern", text: $pattern).font(.codeText)
                .portbaseTextCapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
        }
    }

    private func scan(reset: Bool) {
        guard let profile = workspace.selectedBookmark else { return }
        task?.cancel()
        let token = UUID(); generation = token
        let selectedDatabase = database
        let requestedCursor = reset ? "0" : cursor
        let requestedPattern = Data(pattern.utf8)
        let requestedType = keyType.isEmpty ? nil : keyType
        if reset { keys = []; cursor = "0"; truncated = false }
        isLoading = true; started = true; error = nil
        task = Task {
            do {
                let page = try await DatabaseService.shared.scanRedisKeys(profile: profile, database: selectedDatabase,
                    cursor: requestedCursor, pattern: requestedPattern, type: requestedType, policy: .readOnly)
                try Task.checkCancellation()
                guard generation == token else { return }
                var known = Set(keys.map(\.bytes))
                let additions = page.keys.filter { known.insert($0.bytes).inserted }
                truncated = page.isTruncated || keys.count + additions.count > RedisCommandService.maximumRows
                keys += additions.prefix(max(0, RedisCommandService.maximumRows - keys.count))
                cursor = page.cursor
                table = QueryResultTable(columns: [QueryColumn(name: L10n.text("Key"), type: "bytes")],
                    rows: keys.map { QueryRow(cells: [RedisBytes.cell($0.bytes)]) }, executionSummary: "", generatedMutation: nil,
                    profiles: [], sourceTableReference: nil, isTruncated: truncated)
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
            if generation == token { isLoading = false; task = nil }
        }
    }

    private func open(_ key: RedisKey) {
        guard let profile = workspace.selectedBookmark else { return }
        selection = RedisKeySelection(profile: profile, database: database, key: key)
    }
}

struct RedisKeyInspector: View {
    let profile: ConnectionProfile
    let database: String
    let key: RedisKey
    @Environment(\.dismiss) private var dismiss
    @State private var inspection: RedisKeyInspection?
    @State private var task: Task<Void, Never>?
    @State private var isLoading = false
    @State private var error: String?
    @State private var mutation: RedisMutationSelection?
    @State private var currentCursor = "0"
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    PanelCard {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text(key.displayName).font(.codeText).textSelection(.enabled)
                            LabeledContent("Database", value: database)
                            if let inspection {
                                LabeledContent("Type", value: inspection.type)
                                LabeledContent("Expiration", value: inspection.ttlDescription)
                                if let length = inspection.length { LabeledContent("Length", value: String(length)) }
                                if !profile.isReadOnly, inspection.type != "none" {
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: Spacing.l) { mutationButtons(for: inspection) }
                                            .fixedSize(horizontal: true, vertical: false)
                                        VStack(alignment: .leading, spacing: Spacing.xxs) { mutationButtons(for: inspection) }
                                    }.disabled(isLoading)
                                }
                            }
                            if let error { Text(error).font(.captionText).foregroundStyle(.red).textSelection(.enabled) }
                        }
                    }
                    if let inspection {
                        PanelCard {
                            VStack(alignment: .leading, spacing: Spacing.s) {
                                ResultGridView(result: inspection.result, persistenceKey: "redis.value." + inspection.type)
                                if inspection.result.isTruncated == true {
                                    Text("The reply was truncated. Use a smaller range in the command editor.").font(.captionText).foregroundStyle(.secondary)
                                }
                                if let next = inspection.nextCursor {
                                    Button("Next Page") { load(cursor: next) }.frame(minHeight: Sizes.control).disabled(isLoading)
                                }
                                DisclosureGroup("Command") {
                                    Text(inspection.result.sourceQuery ?? "").font(.codeCaption).textSelection(.enabled)
                                }.frame(minHeight: Sizes.control)
                            }
                        }
                    }
                    if isLoading { ProgressView() }
                }.padding()
            }
            .navigationTitle("Redis value")
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: PortbaseToolbar.trailing) {
                    Button {
                        if isLoading { task?.cancel() } else { load(cursor: "0") }
                    } label: { Image(systemName: isLoading ? "stop.fill" : "arrow.clockwise").frame(width: Sizes.control, height: Sizes.control) }
                        .accessibilityLabel(L10n.text(isLoading ? "Stop" : "Refresh"))
                }
            }
            .task { load(cursor: "0") }
            .onDisappear { task?.cancel() }
            .sheet(item: $mutation) { value in RedisMutationEditor(selection: value) { load(cursor: "0") } }
        }
    }

    @ViewBuilder
    private func mutationButtons(for inspection: RedisKeyInspection) -> some View {
        if inspection.type != "string" || completeString != nil {
            Button("Write Value") { mutate(.write) }.frame(minWidth: Sizes.control, minHeight: Sizes.control)
        }
        Menu {
            Button("Set Expiration") { mutate(.expire) }
            Button("Remove Expiration") { mutate(.persist) }
                .disabled(inspection.ttlMilliseconds < 0)
            Button("Delete Key", role: .destructive) { mutate(.delete) }
        } label: {
            Label("Edit", systemImage: "ellipsis.circle").frame(minWidth: Sizes.control, minHeight: Sizes.control)
        }
    }

    private var completeString: Data? {
        guard let inspection, inspection.type == "string", currentCursor == "0", inspection.nextCursor == nil,
              let cell = inspection.result.rows.first?.cells.first else { return nil }
        switch cell {
        case .text(let value): return Data(value.utf8)
        case .binary(let value): return value
        default: return nil
        }
    }

    private func mutate(_ action: RedisMutationAction) {
        mutation = RedisMutationSelection(profile: profile, database: database, key: key, type: inspection?.type ?? "string",
                                          action: action, value: action == .write ? completeString : nil)
    }

    private func load(cursor: String) {
        task?.cancel(); isLoading = true; error = nil
        let token = UUID(); generation = token
        task = Task {
            do {
                let value = try await DatabaseService.shared.inspectRedisKey(profile: profile, database: database, key: key,
                                                                             cursor: cursor, policy: .readOnly)
                try Task.checkCancellation()
                guard generation == token else { return }
                inspection = value; currentCursor = cursor
            } catch is CancellationError { }
            catch { if generation == token { self.error = error.localizedDescription } }
            if generation == token { isLoading = false; task = nil }
        }
    }
}

private struct RedisMutationEditor: View {
    let selection: RedisMutationSelection
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var keyText = ""
    @State private var keyEncoding: RedisByteEncoding = .utf8
    @State private var type = "string"
    @State private var field = ""
    @State private var fieldEncoding: RedisByteEncoding = .utf8
    @State private var value = ""
    @State private var valueEncoding: RedisByteEncoding = .utf8
    @State private var score = "0"
    @State private var ttl = "60000"
    @State private var isRunning = false
    @State private var outcomeUnknown = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Connection", value: selection.profile.name)
                    LabeledContent("Database", value: selection.database)
                    if let key = selection.key {
                        LabeledContent("Key") { Text(key.displayName).font(.codeDetail).textSelection(.enabled) }
                    } else {
                        byteField("Key", text: $keyText, encoding: $keyEncoding)
                        Picker("Key type", selection: $type) {
                            ForEach(RedisCommandService.keyTypes, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                    }
                }
                if selection.action == .write {
                    Section {
                        if type == "hash" || type == "stream" { byteField("Field", text: $field, encoding: $fieldEncoding) }
                        if type == "zset" { TextField("Score", text: $score).portbaseKeyboardType(.numbersAndPunctuation) }
                        byteField(type == "set" || type == "zset" ? "Member" : "Value", text: $value, encoding: $valueEncoding)
                    }
                } else if selection.action == .expire {
                    Section { TextField("Expiration in milliseconds", text: $ttl).portbaseKeyboardType(.numberPad) }
                }
                Section("Command") {
                    if let command = try? command() {
                        Text(command.preview).font(.codeDetail).textSelection(.enabled)
                    } else {
                        Text("Complete the fields to preview the command.").foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if isRunning { ProgressView("Saving") }
            }
            .disabled(isRunning)
            .navigationTitle(selection.action == .delete ? L10n.text("Delete Key") : L10n.text("Review Redis Write"))
            .portbaseTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isRunning)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text(isRunning ? "Stop" : "Cancel")) {
                        if isRunning { task?.cancel() } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { run() }
                        .disabled(isRunning || outcomeUnknown || selection.profile.isReadOnly || (try? command()) == nil)
                }
            }
            .onAppear {
                type = selection.type
                if let bytes = selection.value {
                    if case .text(let text) = RedisBytes.cell(bytes) { value = text }
                    else { valueEncoding = .base64; value = bytes.base64EncodedString() }
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func byteField(_ title: String, text: Binding<String>, encoding: Binding<RedisByteEncoding>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(L10n.text(title)).font(.rowDetail)
                Spacer()
                Picker("Encoding", selection: Binding(get: { encoding.wrappedValue }, set: { next in
                    do {
                        let current = try bytes(text.wrappedValue, encoding.wrappedValue)
                        if next == .base64 { text.wrappedValue = current.base64EncodedString() }
                        else {
                            guard let decoded = String(data: current, encoding: .utf8) else { throw RedisClientError.invalidCommand }
                            text.wrappedValue = decoded
                        }
                        encoding.wrappedValue = next
                        error = nil
                    } catch { self.error = error.localizedDescription }
                })) {
                    ForEach(RedisByteEncoding.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 200)
            }
            TextField(L10n.text(title), text: text, axis: .vertical)
                .font(.codeText).portbaseTextCapitalization(.never).autocorrectionDisabled()
        }
    }

    private func bytes(_ value: String, _ encoding: RedisByteEncoding) throws -> Data {
        if encoding == .utf8 { return Data(value.utf8) }
        guard let data = Data(base64Encoded: value) else { throw RedisClientError.invalidCommand }
        return data
    }

    private func command() throws -> RedisCommand {
        let key = try selection.key?.bytes ?? bytes(keyText, keyEncoding)
        switch selection.action {
        case .delete: return try RedisCommandService.command("UNLINK", [key])
        case .persist: return try RedisCommandService.command("PERSIST", [key])
        case .expire:
            guard let milliseconds = Int64(ttl), milliseconds > 0 else { throw RedisClientError.invalidCommand }
            return try RedisCommandService.command("PEXPIRE", [key, Data(ttl.utf8)])
        case .write:
            let value = try bytes(value, valueEncoding)
            switch type {
            case "string": return try RedisCommandService.command("SET", [key, value, Data("KEEPTTL".utf8)])
            case "hash": return try RedisCommandService.command("HSET", [key, bytes(field, fieldEncoding), value])
            case "list": return try RedisCommandService.command("RPUSH", [key, value])
            case "set": return try RedisCommandService.command("SADD", [key, value])
            case "zset": return try RedisCommandService.command("ZADD", [key, Data(score.utf8), value])
            case "stream": return try RedisCommandService.command("XADD", [key, Data("*".utf8), bytes(field, fieldEncoding), value])
            default: throw RedisClientError.unsupportedKeyType
            }
        }
    }

    private func run() {
        do {
            let command = try command()
            isRunning = true; error = nil
            task = Task {
                do {
                    _ = try await DatabaseService.shared.execute(query: command.preview, profile: selection.profile,
                        database: selection.database, policy: .userQuery(confirmed: true))
                    isRunning = false; task = nil
                    onSaved(); dismiss()
                } catch {
                    if case RedisClientError.writeOutcomeUnknown = error { outcomeUnknown = true }
                    self.error = error.localizedDescription
                    isRunning = false; task = nil
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

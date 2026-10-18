import SwiftUI
import UniformTypeIdentifiers

/// One conversation with the assistant, kept per console so it survives closing the sheet.
@MainActor
final class AssistantSession: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let role: AssistantMessage.Role
        let text: String
        let segments: [AssistantReplySegment]
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isSending = false
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?

    func send(_ prompt: String, context: AssistantContext, settings: AssistantSettings) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        turns.append(Turn(role: .user, text: text, segments: [.text(text)]))
        let system = AssistantPromptBuilder.systemPrompt(context: context, settings: settings)
        let messages = turns.map { AssistantMessage(role: $0.role, text: $0.text) }
        let apiKey = AssistantAPIKeyStore.load()
        isSending = true
        errorMessage = nil
        task = Task {
            do {
                let reply = try await AssistantClient.send(settings: settings, apiKey: apiKey, system: system, messages: messages)
                turns.append(Turn(role: .assistant, text: reply, segments: AssistantReplyParser.segments(reply)))
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = DatabaseErrorFormatter.message(for: error)
            }
            isSending = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isSending = false
    }

    func reset() {
        cancel()
        turns = []
        errorMessage = nil
    }
}

/// Asks the configured model about the current database. Replies can put queries in the console or
/// build charts, but nothing runs without the user: queries are inserted, and chart queries go through
/// the console's normal path, where writes still ask for confirmation.
struct AssistantSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @ObservedObject var session: AssistantSession
    var onShowConsole: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var settings: AssistantSettings = {
        AssistantSettingsSync.pull()
        return .load()
    }()
    @State private var apiKey = AssistantAPIKeyStore.load()
    @State private var prompt = ""
    @State private var showsContext = false
    @State private var showsSetup = false
    @FocusState private var promptFocused: Bool

    private var isConfigured: Bool { settings.isConfigured(apiKey: apiKey) }
    private var context: AssistantContext? { workspace.assistantContext(includingSampleRows: settings.includesSampleRows) }

    var body: some View {
        PortbaseSheet(L10n.text("Ask AI"), subtitle: subtitle) {
            if showsSetup || !isConfigured {
                Form { AssistantSettingsSections(settings: $settings, apiKey: $apiKey) }
                    .portbaseForm()
            } else {
                conversation
            }
        } footer: {
            if showsSetup || !isConfigured {
                Spacer(minLength: 0)
                Button("Done") { showsSetup = false; promptFocused = true }
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isConfigured)
            } else {
                composer
            }
        }
        .portbaseSheetNavigation()
        .onAppear { promptFocused = isConfigured }
    }

    private var subtitle: String {
        guard let bookmark = workspace.selectedBookmark else { return L10n.text("Choose a connection to include its schema.") }
        return [settings.provider == .anthropic ? settings.model : settings.model.isEmpty ? settings.provider.title : settings.model,
                bookmark.displayTitle, workspace.activeDatabaseName].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            contextBar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        if session.turns.isEmpty { suggestions }
                        ForEach(session.turns) { turn in
                            turnView(turn).id(turn.id)
                        }
                        if session.isSending {
                            HStack(spacing: Spacing.s) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.captionText).foregroundStyle(PortSQLPalette.muted)
                            }
                            .id("progress")
                        }
                        if let error = session.errorMessage {
                            StatusBanner(title: L10n.text("The request failed"), message: error, tint: .red)
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.m)
                }
                .onChange(of: session.turns.count) { _, _ in
                    withAnimation { proxy.scrollTo(session.turns.last?.id, anchor: .top) }
                }
                .onChange(of: session.isSending) { _, sending in
                    if sending { withAnimation { proxy.scrollTo("progress", anchor: .bottom) } }
                }
            }
        }
    }

    /// What the model will be told, summarized, with the exact text one tap away.
    private var contextBar: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                if let context {
                    PortbaseChip(title: L10n.format("Tables: %d", context.tables.count), systemImage: "tablecells", tint: PortSQLPalette.accent)
                }
                if !settings.documents.isEmpty {
                    PortbaseChip(title: L10n.format("Files: %d", settings.documents.count), systemImage: "doc.text", tint: .teal)
                }
                PortbaseChip(title: settings.includesSampleRows ? L10n.text("Sample rows on") : L10n.text("No row data"),
                             systemImage: settings.includesSampleRows ? "eye" : "eye.slash",
                             tint: settings.includesSampleRows ? .orange : .secondary)
                Spacer(minLength: Spacing.s)
                Button { withAnimation(.snappy) { showsContext.toggle() } } label: {
                    Label(showsContext ? L10n.text("Hide Context") : L10n.text("What's Sent"), systemImage: "doc.text.magnifyingglass")
                        .font(.captionStrong)
                }
                .buttonStyle(.portbaseToolbar)
                Menu {
                    Button("New Conversation", systemImage: "square.and.pencil") { session.reset(); prompt = "" }
                        .disabled(session.turns.isEmpty)
                    Button("AI Settings", systemImage: "gearshape") { showsSetup = true }
                } label: {
                    Image(systemName: "ellipsis").frame(width: Sizes.tool, height: Sizes.tool)
                }
                .portbaseToolbarMenu()
                .accessibilityLabel("More")
            }
            if showsContext, let context {
                ScrollView {
                    PortbaseCodeBlock(text: AssistantPromptBuilder.contextDescription(context: context, settings: settings))
                }
                .frame(maxHeight: 220)
                Text("Connection hosts, user names, and passwords are never sent.")
                    .font(.captionText)
                    .foregroundStyle(PortSQLPalette.muted)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.s)
        .overlay(alignment: .bottom) { Rectangle().fill(PortSQLPalette.stroke).frame(height: 1) }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Ask about this database, or describe the query or chart you need.")
                .font(.rowDetail)
                .foregroundStyle(PortSQLPalette.muted)
            ForEach([
                L10n.text("Explain how these tables relate"),
                L10n.text("Write a query for the 10 most recent rows of the busiest table"),
                L10n.text("Chart a count over time from a table with dates"),
            ], id: \.self) { example in
                Button { prompt = example; promptFocused = true } label: {
                    Label(example, systemImage: "sparkles")
                        .font(.rowDetail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.portbaseSecondary)
            }
        }
    }

    @ViewBuilder private func turnView(_ turn: AssistantSession.Turn) -> some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: Spacing.xxxl)
                Text(turn.text)
                    .font(.bodyText)
                    .foregroundStyle(PortSQLPalette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .background(PortSQLPalette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(Array(turn.segments.enumerated()), id: \.offset) { _, segment in
                    segmentView(segment)
                }
            }
        }
    }

    @ViewBuilder private func segmentView(_ segment: AssistantReplySegment) -> some View {
        switch segment {
        case .text(let text):
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                .font(.bodyText)
                .foregroundStyle(PortSQLPalette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(_, let code):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                PortbaseCodeBlock(text: code)
                HStack(spacing: Spacing.s) {
                    Button("Insert", systemImage: "text.insert") { use(code, replacing: false) }
                        .buttonStyle(.portbaseSecondary)
                    Button("Replace Query", systemImage: "arrow.left.arrow.right") { use(code, replacing: true) }
                        .buttonStyle(.portbaseSecondary)
                    Button("Copy", systemImage: "doc.on.doc") { PortbaseClipboard.copy(code) }
                        .buttonStyle(.portbaseToolbar)
                }
                .font(.captionStrong)
            }
        case .chart(let chart):
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "chart.bar.xaxis").foregroundStyle(PortSQLPalette.accent)
                    Text(chart.title ?? L10n.text("Suggested Chart")).font(.rowTitle).foregroundStyle(PortSQLPalette.ink)
                    Spacer(minLength: 0)
                    Text(chart.chartType.title + " · " + chart.x + " → " + chart.y.joined(separator: ", "))
                        .font(.captionText)
                        .foregroundStyle(PortSQLPalette.muted)
                        .lineLimit(1)
                }
                PortbaseCodeBlock(text: chart.query)
                HStack(spacing: Spacing.s) {
                    Button("Run and Chart", systemImage: "play.fill") {
                        workspace.runAssistantChart(chart)
                        dismiss()
                        onShowConsole()
                    }
                    .buttonStyle(.portbasePrimary)
                    Button("Insert Query", systemImage: "text.insert") { use(chart.query, replacing: false) }
                        .buttonStyle(.portbaseSecondary)
                }
                .font(.captionStrong)
            }
            .padding(Spacing.m)
            .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(PortSQLPalette.stroke, lineWidth: 1) }
        }
    }

    private func use(_ sql: String, replacing: Bool) {
        workspace.applyAssistantQuery(sql, replacing: replacing)
        dismiss()
        onShowConsole()
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Spacing.s) {
            TextField(L10n.text("Ask about your data…"), text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.bodyText)
                .focused($promptFocused)
                .onSubmit(send)
                .padding(.vertical, Spacing.xs)
                .portbaseFieldChrome()
            if session.isSending {
                Button("Stop", systemImage: "stop.fill") { session.cancel() }
                    .buttonStyle(.portbaseSecondary)
            } else {
                Button("Send", systemImage: "arrow.up") { send() }
                    .buttonStyle(.portbasePrimary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || context == nil)
            }
        }
    }

    private func send() {
        guard let context else { return }
        session.send(prompt, context: context, settings: settings)
        prompt = ""
    }
}

/// Provider, key, instructions, reference files, and data sharing, for use inside a Form.
struct AssistantSettingsSections: View {
    @Binding var settings: AssistantSettings
    @Binding var apiKey: String
    @State private var importsFile = false
    @State private var importError: String?

    var body: some View {
        Section {
            LabeledContent("Provider") {
                PortbaseSegmentedPicker(selection: Binding(get: { settings.provider }, set: changeProvider),
                                        options: AssistantProvider.allCases.map { PortbaseChoice(value: $0, title: $0.title) })
            }
            TextField("Endpoint", text: $settings.baseURL)
                .autocorrectionDisabled()
                .portbaseTextCapitalization(.never)
                .portbaseKeyboardType(.URL)
            TextField("Model", text: $settings.model, prompt: Text(settings.provider == .anthropic ? "claude-opus-5-5" : "gpt-…, llama3.1, …"))
                .autocorrectionDisabled()
                .portbaseTextCapitalization(.never)
            SecureField(settings.provider == .anthropic ? L10n.text("API key") : L10n.text("API key (optional for local servers)"), text: $apiKey)
        } header: {
            Text("AI Provider")
        } footer: {
            Text("The API key stays in this device’s Keychain. Requests go straight from this device to the provider you choose.")
        }

        Section {
            TextEditor(text: $settings.instructions)
                .font(.codeDetail)
                .frame(minHeight: 90)
                .accessibilityLabel("Instructions")
        } header: {
            Text("Instructions")
        } footer: {
            Text("Sent with every request, for example naming conventions, time zones, or which tables matter.")
        }

        Section {
            ForEach(settings.documents) { document in
                HStack {
                    Label(document.name, systemImage: "doc.text")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(document.text.utf8.count), countStyle: .file))
                        .font(.captionText)
                        .foregroundStyle(PortSQLPalette.muted)
                    Button(role: .destructive) { settings.documents.removeAll { $0.id == document.id } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.format("Remove %@", document.name))
                }
            }
            Button("Add File…", systemImage: "plus") { importsFile = true }
                .disabled(settings.documents.count >= AssistantSettings.maximumDocuments)
            if let importError { Text(importError).font(.captionText).foregroundStyle(.red) }
        } header: {
            Text("Reference Files")
        } footer: {
            Text("Text files such as DDL, ORM models, or docs, up to 200 KB each. Their contents are sent with every request.")
        }

        Section {
            Toggle("Include sample rows", isOn: $settings.includesSampleRows)
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Sends up to 5 rows of the last result so answers can match real values. Off by default because it shares data with the provider.")
                Text("These settings sync through iCloud to your other devices. The API key stays on each device, and reference files larger than 256 KB in total stay on this device.")
            }
        }
        .onChange(of: settings) { _, value in value.save() }
        // Another device changed the settings: show its copy.
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            if AssistantSettingsSync.pull() { settings = .load() }
        }
        .onChange(of: apiKey) { _, value in AssistantAPIKeyStore.save(value) }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.plainText, .text, .sourceCode, .json, .data],
                      allowsMultipleSelection: false) { result in importFile(result) }
    }

    /// Switching provider swaps in its endpoint and model unless the user had changed them.
    private func changeProvider(_ provider: AssistantProvider) {
        let previous = settings.provider
        if settings.baseURL == previous.defaultBaseURL || settings.baseURL.isEmpty { settings.baseURL = provider.defaultBaseURL }
        if settings.model == previous.defaultModel || settings.model.isEmpty { settings.model = provider.defaultModel }
        settings.provider = provider
    }

    private func importFile(_ result: Result<[URL], Error>) {
        importError = nil
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard data.count <= AssistantSettings.maximumDocumentBytes else {
                importError = L10n.text("Choose a text file of 200 KB or less.")
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                importError = L10n.text("This file isn't UTF-8 text.")
                return
            }
            settings.documents.append(AssistantContextDocument(name: url.lastPathComponent, text: text))
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// A standalone page for the assistant settings, for the Settings screens.
struct AssistantSettingsView: View {
    @State private var settings: AssistantSettings = {
        AssistantSettingsSync.pull()
        return .load()
    }()
    @State private var apiKey = AssistantAPIKeyStore.load()

    var body: some View {
        Form { AssistantSettingsSections(settings: $settings, apiKey: $apiKey) }
            .portbaseForm()
            .navigationTitle("AI Assistant")
    }
}

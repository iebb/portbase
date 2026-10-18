import SwiftUI
import UniformTypeIdentifiers

/// One conversation with the assistant, kept per console so it survives switching away.
@MainActor
final class AssistantSession: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let role: AssistantMessage.Role
        let text: String
        let segments: [AssistantReplySegment]
        /// The model that wrote an assistant turn.
        var model: String?
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isSending = false
    /// This chat's provider and model; nil uses the default for new chats.
    @Published var providerID: UUID?
    @Published var model: String?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?

    func send(_ prompt: String, context: AssistantContext, settings: AssistantSettings) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        turns.append(Turn(role: .user, text: text, segments: [.text(text)]))
        request(context: context, settings: settings)
    }

    /// Sends the conversation again after a failed request.
    func retry(context: AssistantContext, settings: AssistantSettings) {
        guard !isSending, turns.last?.role == .user else { return }
        request(context: context, settings: settings)
    }

    private func request(context: AssistantContext, settings: AssistantSettings) {
        let system = AssistantPromptBuilder.systemPrompt(context: context, settings: settings)
        let messages = turns.map { AssistantMessage(role: $0.role, text: $0.text) }
        let apiKey = AssistantAPIKeyStore.load(for: settings.activeProvider.id)
        let model = settings.activeProvider.name + " · " + settings.model
        isSending = true
        errorMessage = nil
        task = Task {
            do {
                let reply = try await AssistantClient.send(settings: settings, apiKey: apiKey, system: system, messages: messages)
                turns.append(Turn(role: .assistant, text: reply, segments: AssistantReplyParser.segments(reply), model: model))
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

/// The assistant on iPhone and iPad: the chat in a sheet.
struct AssistantSheet: View {
    @ObservedObject var session: AssistantSession
    var onShowConsole: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AssistantChatView(session: session, onClose: { dismiss() }, onShowConsole: {
            dismiss()
            onShowConsole()
        })
        .portbaseSheetNavigation()
    }
}

/// A chat with the configured model about the current database. Replies can put queries in the
/// console or build charts, but nothing runs without the user: queries are inserted, and chart queries
/// go through the console's normal path, where writes still ask for confirmation.
struct AssistantChatView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @ObservedObject var session: AssistantSession
    /// Shown as a close button when the chat is in a sheet.
    var onClose: (() -> Void)?
    var onShowConsole: () -> Void = {}
    @State private var settings: AssistantSettings = {
        AssistantSettingsSync.pull()
        return .load()
    }()
    @State private var apiKey = ""
    @State private var prompt = ""
    @State private var showsContext = false
    @State private var showsSettings = false
    @State private var isLoadingModels = false
    @State private var modelsError: String?
    @FocusState private var promptFocused: Bool

    /// The settings with this chat's provider and model applied.
    private var chatSettings: AssistantSettings { settings.choosing(providerID: session.providerID, model: session.model) }
    private var chatProvider: AssistantProviderConfig { chatSettings.activeProvider }
    private var isConfigured: Bool { chatSettings.isConfigured(apiKey: apiKey) }
    private var context: AssistantContext? { workspace.assistantContext(includingSampleRows: settings.includesSampleRows) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isConfigured {
                conversation
                composer
            } else {
                setup
            }
        }
        .background(PortSQLPalette.canvasTop)
        .onAppear {
            apiKey = AssistantAPIKeyStore.load(for: chatProvider.id)
            promptFocused = isConfigured
            if isConfigured, settings.providers.contains(where: { $0.models.isEmpty }) { refreshModels() }
        }
        .onChange(of: chatProvider.id) { _, id in apiKey = AssistantAPIKeyStore.load(for: id) }
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            if AssistantSettingsSync.pull() { settings = .load() }
        }
        .sheet(isPresented: $showsSettings, onDismiss: {
            settings = .load()
            apiKey = AssistantAPIKeyStore.load(for: chatProvider.id)
        }) {
            AssistantSettingsSheet()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "sparkles")
                .font(.cardTitle)
                .foregroundStyle(.white)
                .frame(width: Sizes.avatar, height: Sizes.avatar)
                .background(PortSQLPalette.accentGradient, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text("Ask AI").font(.rowTitle.weight(.semibold)).foregroundStyle(PortSQLPalette.ink)
                Text(contextSummary).font(.captionText).foregroundStyle(PortSQLPalette.muted).lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            if isConfigured { modelMenu }
            Menu {
                Button("New Conversation", systemImage: "square.and.pencil") { session.reset(); prompt = "" }
                    .disabled(session.turns.isEmpty && session.errorMessage == nil)
                Button(showsContext ? L10n.text("Hide Context") : L10n.text("What's Sent"), systemImage: "doc.text.magnifyingglass") {
                    withAnimation(.snappy) { showsContext.toggle() }
                }
                Divider()
                Button("AI Settings", systemImage: "gearshape") { showsSettings = true }
            } label: {
                Image(systemName: "ellipsis").frame(width: Sizes.tool, height: Sizes.tool)
            }
            .portbaseToolbarMenu()
            .accessibilityLabel("More")
            if let onClose { PortbaseCloseButton(action: onClose) }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .background(PortSQLPalette.panel)
    }

    private var contextSummary: String {
        guard let bookmark = workspace.selectedBookmark else { return L10n.text("Choose a connection to include its schema.") }
        var parts = [bookmark.displayTitle, workspace.activeDatabaseName].compactMap { $0 }
        if let context { parts.append(L10n.format("Tables: %d", context.tables.count)) }
        return parts.joined(separator: " · ")
    }

    /// Every provider's models, as their models endpoints listed them. The choice is this chat's own.
    private var modelMenu: some View {
        Menu {
            ForEach(settings.providers) { provider in
                Section(provider.name) {
                    let models = provider.models.isEmpty
                        ? (provider.model.isEmpty ? [] : [AssistantModelInfo(id: provider.model)])
                        : provider.models
                    if models.isEmpty {
                        Text("No models listed")
                    }
                    ForEach(models) { model in
                        Button { select(model.id, of: provider) } label: {
                            if provider.id == chatProvider.id && chatProvider.model == model.id {
                                Label(model.title, systemImage: "checkmark")
                            } else {
                                Text(model.title)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Make Default for New Chats", systemImage: "star") { makeDefault() }
                .disabled(settings.activeProvider.id == chatProvider.id && settings.activeProvider.model == chatProvider.model)
            Button("Refresh Models", systemImage: "arrow.clockwise") { refreshModels() }
                .disabled(isLoadingModels)
            Button("Manage Providers…", systemImage: "server.rack") { showsSettings = true }
        } label: {
            HStack(spacing: Spacing.xxs) {
                if isLoadingModels { ProgressView().controlSize(.mini) }
                if settings.providers.count > 1 {
                    Text(chatProvider.name).foregroundStyle(PortSQLPalette.muted).lineLimit(1)
                }
                Text(activeModelTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(.captionStrong)
            .foregroundStyle(PortSQLPalette.ink)
            .padding(.horizontal, Spacing.m)
            .frame(height: Sizes.control)
            .background(PortSQLPalette.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(modelsError == nil ? PortSQLPalette.stroke : Color.orange.opacity(0.6)) }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help(modelsError ?? L10n.text("The model this chat uses"))
        .accessibilityLabel(L10n.format("Model %@", activeModelTitle))
    }

    private var activeModelTitle: String {
        let provider = chatProvider
        return provider.models.first { $0.id == provider.model }?.title ?? (provider.model.isEmpty ? provider.name : provider.model)
    }

    /// Picks a model for this chat only; other chats and the default stay as they are.
    private func select(_ model: String, of provider: AssistantProviderConfig) {
        session.providerID = provider.id
        session.model = model
        apiKey = AssistantAPIKeyStore.load(for: provider.id)
    }

    private func makeDefault() {
        let chosen = chatProvider
        settings.selectedProviderID = chosen.id
        if let index = settings.providers.firstIndex(where: { $0.id == chosen.id }) { settings.providers[index].model = chosen.model }
        settings.save()
    }

    /// Asks every provider which models it offers and remembers the lists.
    private func refreshModels() {
        let providers = settings.providers
        isLoadingModels = true
        modelsError = nil
        Task {
            var failures: [String] = []
            await withTaskGroup(of: (UUID, Result<[AssistantModelInfo], Error>).self) { group in
                for provider in providers {
                    let key = AssistantAPIKeyStore.load(for: provider.id)
                    // A provider that can't be asked yet, such as one without its key, is skipped.
                    guard (try? AssistantClient.modelsRequest(for: provider, apiKey: key)) != nil else { continue }
                    group.addTask {
                        do { return (provider.id, .success(try await AssistantClient.listModels(for: provider, apiKey: key))) }
                        catch { return (provider.id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    guard let index = settings.providers.firstIndex(where: { $0.id == id }) else { continue }
                    switch result {
                    case .success(let models):
                        settings.providers[index].models = models
                        if settings.providers[index].model.isEmpty, let first = models.first { settings.providers[index].model = first.id }
                    case .failure(let error):
                        failures.append(settings.providers[index].name + ": " + DatabaseErrorFormatter.message(for: error))
                    }
                }
            }
            settings.save()
            modelsError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            isLoadingModels = false
        }
    }

    // MARK: Setup

    private var setup: some View {
        VStack(spacing: Spacing.m) {
            Spacer(minLength: 0)
            Image(systemName: "sparkles").font(.emptyStateSymbol).foregroundStyle(PortSQLPalette.accent)
            Text("Set up an AI provider").font(.sectionTitle).foregroundStyle(PortSQLPalette.ink)
            Text("Add Anthropic, OpenAI, OpenRouter, a local server such as Ollama or LM Studio, or any OpenAI-compatible endpoint. Keys sync to your devices through iCloud Keychain.")
                .font(.footnoteText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Set Up Providers", systemImage: "gearshape") { showsSettings = true }
                .buttonStyle(.portbasePrimary)
            Spacer(minLength: 0)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.l) {
                    if showsContext, let context { contextPanel(context) }
                    if session.turns.isEmpty { suggestions }
                    ForEach(session.turns) { turn in
                        turnView(turn).id(turn.id)
                    }
                    if session.isSending { thinking.id("progress") }
                    if let error = session.errorMessage { failure(error).id("error") }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.l)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.turns.count) { _, _ in
                withAnimation { proxy.scrollTo(session.turns.last?.id, anchor: .top) }
            }
            .onChange(of: session.isSending) { _, sending in
                if sending { withAnimation { proxy.scrollTo("progress", anchor: .bottom) } }
            }
        }
    }

    /// What the model will be told, with the exact text.
    private func contextPanel(_ context: AssistantContext) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                PortbaseChip(title: L10n.format("Tables: %d", context.tables.count), systemImage: "tablecells", tint: PortSQLPalette.accent)
                if !settings.documents.isEmpty {
                    PortbaseChip(title: L10n.format("Files: %d", settings.documents.count), systemImage: "doc.text", tint: .teal)
                }
                PortbaseChip(title: settings.includesSampleRows ? L10n.text("Sample rows on") : L10n.text("No row data"),
                             systemImage: settings.includesSampleRows ? "eye" : "eye.slash",
                             tint: settings.includesSampleRows ? .orange : .secondary)
            }
            ScrollView {
                PortbaseCodeBlock(text: AssistantPromptBuilder.contextDescription(context: context, settings: settings))
            }
            .frame(maxHeight: 240)
            Text("Connection hosts, user names, and passwords are never sent.")
                .font(.captionText)
                .foregroundStyle(PortSQLPalette.muted)
        }
        .padding(Spacing.m)
        .portbaseCardSurface(radius: Radius.card)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Ask about this database, or describe the query or chart you need.")
                .font(.rowDetail)
                .foregroundStyle(PortSQLPalette.muted)
            ForEach([
                L10n.text("Explain how these tables relate"),
                L10n.text("Write a query for the 10 most recent rows of the busiest table"),
                L10n.text("Chart a count over time from a table with dates"),
            ], id: \.self) { example in
                Button { prompt = example; promptFocused = true } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "sparkles").foregroundStyle(PortSQLPalette.accent)
                        Text(example).foregroundStyle(PortSQLPalette.ink).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.captionStrong).foregroundStyle(PortSQLPalette.muted)
                    }
                    .font(.rowDetail)
                    .padding(Spacing.m)
                    .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(PortSQLPalette.stroke) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, Spacing.l)
    }

    @ViewBuilder private func turnView(_ turn: AssistantSession.Turn) -> some View {
        if turn.role == .user {
            HStack {
                Spacer(minLength: Spacing.xxxl * 2)
                Text(turn.text)
                    .font(.bodyText)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.s)
                    .background(PortSQLPalette.accent, in: RoundedRectangle(cornerRadius: Radius.card + 2, style: .continuous))
            }
        } else {
            HStack(alignment: .top, spacing: Spacing.s) {
                assistantAvatar
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ForEach(Array(turn.segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(segment)
                    }
                    if let model = turn.model {
                        Text(model).font(.microText).foregroundStyle(PortSQLPalette.muted)
                    }
                }
            }
        }
    }

    private var assistantAvatar: some View {
        Image(systemName: "sparkles")
            .font(.captionStrong)
            .foregroundStyle(PortSQLPalette.accent)
            .frame(width: 26, height: 26)
            .background(PortSQLPalette.accentSoft, in: Circle())
            .accessibilityHidden(true)
    }

    private var thinking: some View {
        HStack(spacing: Spacing.s) {
            assistantAvatar
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Thinking…").font(.captionText).foregroundStyle(PortSQLPalette.muted)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(PortSQLPalette.surface, in: Capsule())
            Spacer()
            Button("Stop", systemImage: "stop.fill") { session.cancel() }
                .buttonStyle(.portbaseToolbar)
                .font(.captionStrong)
        }
    }

    private func failure(_ error: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("The request failed").font(.rowTitle).foregroundStyle(PortSQLPalette.ink)
                Text(error).font(.footnoteText).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: Spacing.s)
            if session.turns.last?.role == .user, let context {
                Button("Retry", systemImage: "arrow.clockwise") { session.retry(context: context, settings: chatSettings) }
                    .buttonStyle(.portbaseSecondary)
            }
        }
        .padding(Spacing.m)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    @ViewBuilder private func segmentView(_ segment: AssistantReplySegment) -> some View {
        switch segment {
        case .text(let text):
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                .font(.bodyText)
                .foregroundStyle(PortSQLPalette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.s) {
                    Text(language.isEmpty ? "code" : language).font(.microText.weight(.semibold)).foregroundStyle(PortSQLPalette.muted)
                    Spacer()
                    Button { use(code, replacing: false) } label: { Label("Insert", systemImage: "text.insert") }
                    Button { use(code, replacing: true) } label: { Label("Replace Query", systemImage: "arrow.left.arrow.right") }
                    Button { PortbaseClipboard.copy(code) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                .font(.captionStrong)
                .buttonStyle(.portbaseToolbar)
                .padding(.horizontal, Spacing.m)
                .frame(height: Sizes.control + Spacing.xxs)
                .background(PortSQLPalette.sunken)
                ScrollView(.horizontal) {
                    Text(verbatim: code)
                        .font(.codeCaption)
                        .foregroundStyle(PortSQLPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(Spacing.m)
                }
            }
            .background(PortSQLPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(PortSQLPalette.stroke) }
        case .chart(let chart):
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: chart.chartType.symbolName).foregroundStyle(PortSQLPalette.accent)
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
        onShowConsole()
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: Spacing.xs) {
            HStack(alignment: .bottom, spacing: Spacing.s) {
                TextField(L10n.text("Ask about your data…"), text: $prompt, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .font(.bodyText)
                    .focused($promptFocused)
                    .onSubmit(send)
                    .padding(.vertical, Spacing.xs)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(canSend ? PortSQLPalette.accent : PortSQLPalette.muted.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
            .padding(.leading, Spacing.m)
            .padding(.trailing, Spacing.xs)
            .padding(.vertical, Spacing.xs)
            .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card + 4, style: .continuous).strokeBorder(PortSQLPalette.stroke) }
            Text(context == nil ? L10n.text("Choose a connection to include its schema.")
                                : L10n.text("Replies are suggestions; nothing runs until you run it."))
                .font(.microText)
                .foregroundStyle(PortSQLPalette.muted)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !session.isSending && context != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend, let context else { return }
        session.send(prompt, context: context, settings: chatSettings)
        prompt = ""
    }
}

// MARK: - Settings

/// The assistant settings in a sheet, opened from the chat.
struct AssistantSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings: AssistantSettings = {
        AssistantSettingsSync.pull()
        return .load()
    }()

    var body: some View {
        PortbaseSheet(L10n.text("AI Settings"), onClose: { dismiss() }) {
            Form { AssistantSettingsSections(settings: $settings) }
                .portbaseForm()
        } footer: {
            Button("Done") { dismiss() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
        }
        .portbaseSheetNavigation()
#if os(macOS)
        .frame(width: 600, height: 640)
#endif
    }
}

/// Providers, instructions, reference files, and data sharing, for use inside a Form.
struct AssistantSettingsSections: View {
    @Binding var settings: AssistantSettings
    @State private var importsFile = false
    @State private var importError: String?
    @State private var editing: ProviderEdit?

    private struct ProviderEdit: Identifiable {
        var provider: AssistantProviderConfig
        var isNew: Bool
        var id: UUID { provider.id }
    }

    var body: some View {
        Section {
            ForEach(settings.providers) { provider in
                let active = provider.id == settings.activeProvider.id
                HStack(spacing: Spacing.s) {
                    Button { settings.selectedProviderID = provider.id } label: {
                        Image(systemName: active ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(active ? PortSQLPalette.accent : PortSQLPalette.muted)
                            .frame(minWidth: Sizes.tool, minHeight: Sizes.tool)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.format("Use %@", provider.name))
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text(provider.name).font(.rowTitle).foregroundStyle(PortSQLPalette.ink)
                        Text([provider.kind.title, provider.model.isEmpty ? L10n.text("No model chosen") : provider.model].joined(separator: " · "))
                            .font(.captionText).foregroundStyle(PortSQLPalette.muted).lineLimit(1)
                    }
                    Spacer(minLength: Spacing.s)
                    Button("Edit…") { editing = ProviderEdit(provider: provider, isNew: false) }
                        .buttonStyle(.borderless)
                }
            }
            Menu {
                ForEach(AssistantProviderPreset.allCases) { preset in
                    Button(preset.title) { editing = ProviderEdit(provider: preset.configuration, isNew: true) }
                }
            } label: {
                Label("Add Provider", systemImage: "plus")
            }
        } header: {
            Text("AI Providers")
        } footer: {
            Text("The checked provider and its model are the default for new chats; each chat can pick its own. API keys sync through iCloud Keychain, and requests go straight from this device to the provider.")
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
                Text("These settings sync through iCloud to your other devices, and API keys through iCloud Keychain. Reference files larger than 256 KB in total stay on this device.")
            }
        }
        .onChange(of: settings) { _, value in value.save() }
        // Another device changed the settings: show its copy.
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            if AssistantSettingsSync.pull() { settings = .load() }
        }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.plainText, .text, .sourceCode, .json, .data],
                      allowsMultipleSelection: false) { result in importFile(result) }
        .sheet(item: $editing) { edit in
            AssistantProviderEditor(
                provider: edit.provider,
                isNew: edit.isNew,
                canDelete: !edit.isNew && settings.providers.count > 1,
                onSave: { provider in
                    if let index = settings.providers.firstIndex(where: { $0.id == provider.id }) {
                        settings.providers[index] = provider
                    } else {
                        settings.providers.append(provider)
                        settings.selectedProviderID = provider.id
                    }
                },
                onDelete: {
                    settings.providers.removeAll { $0.id == edit.provider.id }
                    if settings.selectedProviderID == edit.provider.id { settings.selectedProviderID = settings.providers.first?.id }
                    AssistantAPIKeyStore.save("", for: edit.provider.id)
                }
            )
        }
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

/// One provider's name, API, endpoint, key, and model, with the model list fetched from its models endpoint.
struct AssistantProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AssistantProviderConfig
    @State private var apiKey: String
    @State private var isLoading = false
    @State private var error: String?
    let isNew: Bool
    let canDelete: Bool
    let onSave: (AssistantProviderConfig) -> Void
    let onDelete: () -> Void

    init(provider: AssistantProviderConfig, isNew: Bool, canDelete: Bool,
         onSave: @escaping (AssistantProviderConfig) -> Void, onDelete: @escaping () -> Void) {
        _draft = State(initialValue: provider)
        _apiKey = State(initialValue: isNew ? "" : AssistantAPIKeyStore.load(for: provider.id))
        self.isNew = isNew
        self.canDelete = canDelete
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host != nil
    }

    var body: some View {
        PortbaseSheet(isNew ? L10n.text("Add Provider") : draft.name, onClose: { dismiss() }) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    LabeledContent("API") {
                        PortbaseSegmentedPicker(selection: $draft.kind,
                                                options: AssistantProvider.allCases.map { PortbaseChoice(value: $0, title: $0.title) })
                    }
                    TextField("Endpoint", text: $draft.baseURL, prompt: Text(verbatim: draft.kind.defaultBaseURL))
                        .autocorrectionDisabled()
                        .portbaseTextCapitalization(.never)
                        .portbaseKeyboardType(.URL)
                    SecureField(draft.kind == .anthropic ? L10n.text("API key") : L10n.text("API key (optional for local servers)"), text: $apiKey)
                } footer: {
                    Text("The API key syncs to your other devices through iCloud Keychain.")
                }
                Section {
                    if !draft.models.isEmpty {
                        Picker("Model", selection: $draft.model) {
                            if !draft.models.contains(where: { $0.id == draft.model }) {
                                Text(draft.model.isEmpty ? L10n.text("Choose a model") : draft.model).tag(draft.model)
                            }
                            ForEach(draft.models) { Text($0.title).tag($0.id) }
                        }
                    }
                    TextField(draft.models.isEmpty ? L10n.text("Model") : L10n.text("Or enter a model ID"), text: $draft.model)
                        .autocorrectionDisabled()
                        .portbaseTextCapitalization(.never)
                    Button {
                        fetchModels()
                    } label: {
                        HStack(spacing: Spacing.xs) {
                            if isLoading { ProgressView().controlSize(.small) }
                            Text(draft.models.isEmpty ? L10n.text("Fetch Models") : L10n.text("Refresh Models"))
                        }
                    }
                    .disabled(isLoading || !canSave)
                    if let error { Text(error).font(.captionText).foregroundStyle(.red).textSelection(.enabled) }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Models are listed from the provider’s models endpoint.")
                }
            }
            .portbaseForm()
        } footer: {
            if canDelete {
                Button("Delete", role: .destructive) { onDelete(); dismiss() }
                    .buttonStyle(.portbaseSecondary)
                    .tint(.red)
            }
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(.portbaseSecondary)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                AssistantAPIKeyStore.save(apiKey, for: draft.id)
                onSave(draft)
                dismiss()
            }
            .buttonStyle(.portbasePrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .portbaseSheetNavigation()
#if os(macOS)
        .frame(width: 520, height: 520)
#endif
    }

    private func fetchModels() {
        isLoading = true
        error = nil
        let provider = draft
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let models = try await AssistantClient.listModels(for: provider, apiKey: key)
                draft.models = models
                if draft.model.isEmpty, let first = models.first { draft.model = first.id }
                if models.isEmpty { error = L10n.text("The provider listed no models.") }
            } catch let failure {
                error = DatabaseErrorFormatter.message(for: failure)
            }
            isLoading = false
        }
    }
}

/// A standalone page for the assistant settings, for the Settings screens.
struct AssistantSettingsView: View {
    @State private var settings: AssistantSettings = {
        AssistantSettingsSync.pull()
        return .load()
    }()

    var body: some View {
        Form { AssistantSettingsSections(settings: $settings) }
            .portbaseForm()
            .navigationTitle("AI Assistant")
    }
}

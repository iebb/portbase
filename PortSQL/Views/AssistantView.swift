import SwiftUI
import UniformTypeIdentifiers

/// One conversation with the assistant, kept per console so it survives switching away. When the
/// approval mode allows, the assistant runs queries as tool calls: read-only ones per the mode, changes
/// only after the user confirms each one.
@MainActor
final class AssistantSession: ObservableObject {
    /// A query the assistant asked to run, and what became of it.
    struct QueryStep: Equatable {
        enum State: Equatable {
            case awaitingApproval
            case running
            case completed(rows: Int, milliseconds: Int)
            case declined
            case blocked(String)
            case failed(String)
        }
        let query: String
        let purpose: String?
        /// Set when the query changes data or schema, or is blocked; nil for read-only queries.
        let assessment: SQLSafetyAssessment?
        var state: State
        var result: QueryResultTable?
    }

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let role: AssistantMessage.Role
        let text: String
        let segments: [AssistantReplySegment]
        /// The provider and model that wrote an assistant turn.
        var model: String?
        var step: QueryStep?
    }

    static let maximumSteps = 8

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isSending = false
    @Published var errorMessage: String?
    /// This chat's provider and model; nil uses the default for new chats.
    @Published var providerID: UUID?
    @Published var model: String?
    /// The conversation as sent to the model, tool calls and results included.
    private var history: [AssistantMessage] = []
    private var approvals: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var task: Task<Void, Never>?
    /// Sends the conversation to the model; replaceable so tests can script replies.
    var respond: (AssistantSettings, String, String, [AssistantMessage], Bool) async throws -> AssistantReply = { settings, key, system, messages, tools in
        try await AssistantClient.respond(settings: settings, apiKey: key, system: system, messages: messages, tools: tools)
    }

    /// Finishes when the current exchange does, for tests.
    func waitUntilIdle() async { await task?.value }

    func send(_ prompt: String, context: AssistantContext, settings: AssistantSettings, runner: AssistantQueryRunner?) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        turns.append(Turn(role: .user, text: text, segments: [.text(text)]))
        history.append(AssistantMessage(role: .user, text: text))
        converse(context: context, settings: settings, runner: runner)
    }

    /// Sends the conversation again after a failed request.
    func retry(context: AssistantContext, settings: AssistantSettings, runner: AssistantQueryRunner?) {
        guard !isSending, history.last?.role == .user else { return }
        converse(context: context, settings: settings, runner: runner)
    }

    /// Approves or declines a query waiting for the user.
    func decide(_ turnID: UUID, approved: Bool) {
        approvals.removeValue(forKey: turnID)?.resume(returning: approved)
    }

    private func converse(context: AssistantContext, settings: AssistantSettings, runner: AssistantQueryRunner?) {
        let runner = runner.flatMap { AssistantQueryRunner.supports($0.engine) ? $0 : nil }
        let tools = settings.approvalMode.runsQueries && runner != nil
        let system = AssistantPromptBuilder.systemPrompt(context: context, settings: settings, toolsEnabled: tools)
        let apiKey = AssistantAPIKeyStore.load(for: settings.activeProvider.id)
        let label = settings.activeProvider.name + " · " + settings.model
        isSending = true
        errorMessage = nil
        task = Task {
            defer { isSending = false }
            do {
                for _ in 0..<Self.maximumSteps {
                    let reply = try await respond(settings, apiKey, system, history, tools)
                    history.append(AssistantMessage(role: .assistant, text: reply.text, toolCalls: reply.toolCalls))
                    if !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        turns.append(Turn(role: .assistant, text: reply.text, segments: AssistantReplyParser.segments(reply.text), model: label))
                    }
                    guard let runner, !reply.toolCalls.isEmpty else { return }
                    var results: [AssistantToolResult] = []
                    for call in reply.toolCalls {
                        // Every call needs a result, even when the user stopped the conversation part way.
                        if Task.isCancelled {
                            results.append(AssistantToolResult(callID: call.id, content: "The user stopped the conversation.", isError: true))
                        } else {
                            results.append(await perform(call, runner: runner, mode: settings.approvalMode))
                        }
                    }
                    history.append(AssistantMessage(role: .user, text: "", toolResults: results))
                    if Task.isCancelled { return }
                }
                errorMessage = L10n.text("The assistant stopped after several steps. Ask it to continue if you need more.")
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = DatabaseErrorFormatter.message(for: error)
            }
        }
    }

    private func perform(_ call: AssistantToolCall, runner: AssistantQueryRunner, mode: AssistantApprovalMode) async -> AssistantToolResult {
        guard call.name == AssistantTools.runQuery,
              let query = call.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return AssistantToolResult(callID: call.id, content: "Unknown tool, or no query was given.", isError: true)
        }
        let assessment = SQLSafetyService.assessment(for: query, readOnly: runner.isReadOnly, engine: runner.engine)
        let turn = Turn(role: .assistant, text: "", segments: [],
                        step: QueryStep(query: query, purpose: call.arguments["purpose"], assessment: assessment, state: .running))
        turns.append(turn)
        if let assessment, assessment.blocksExecution {
            update(turn.id) { $0.state = .blocked(assessment.message) }
            return AssistantToolResult(callID: call.id, content: "Blocked: \(assessment.title). \(assessment.message)", isError: true)
        }
        // Changes always ask; read-only queries ask unless the mode runs them on their own.
        if mode == .askEveryQuery || assessment != nil {
            update(turn.id) { $0.state = .awaitingApproval }
            let approved = await withCheckedContinuation { continuation in approvals[turn.id] = continuation }
            guard approved else {
                update(turn.id) { $0.state = .declined }
                return AssistantToolResult(callID: call.id, content: "The user declined to run this query.", isError: true)
            }
        }
        update(turn.id) { $0.state = .running }
        let started = Date()
        do {
            let output = try await runner.run(query, assessment == nil ? .readOnly : .userQuery(confirmed: true))
            let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
            update(turn.id) {
                $0.state = .completed(rows: output.rows.count, milliseconds: milliseconds)
                $0.result = output
            }
            return AssistantToolResult(callID: call.id, content: AssistantToolOutput.summary(output))
        } catch {
            let message = DatabaseErrorFormatter.message(for: error)
            update(turn.id) { $0.state = .failed(message) }
            return AssistantToolResult(callID: call.id, content: "The query failed: " + message, isError: true)
        }
    }

    private func update(_ turnID: UUID, _ change: (inout QueryStep) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }), var step = turns[index].step else { return }
        change(&step)
        turns[index].step = step
    }

    func cancel() {
        for continuation in approvals.values { continuation.resume(returning: false) }
        approvals = [:]
        task?.cancel()
        task = nil
        isSending = false
    }

    func reset() {
        cancel()
        turns = []
        history = []
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
    /// Names typed to confirm destructive queries on production, per step.
    @State private var typedConfirmations: [UUID: String] = [:]
    @FocusState private var promptFocused: Bool

    /// Runs the assistant's queries on this tab's connection through DatabaseService.
    private var runner: AssistantQueryRunner? {
        guard let profile = workspace.selectedBookmark else { return nil }
        let database = workspace.activeDatabaseName
        return AssistantQueryRunner(engine: profile.engine, isReadOnly: profile.isReadOnly, environment: profile.environment) { sql, policy in
            try await DatabaseService.shared.execute(query: sql, profile: profile, database: database, policy: policy)
        }
    }

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
            AssistantSettingsSync.pull()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantSettingsDidChange)) { _ in settings = .load() }
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
                Picker(selection: Binding(get: { settings.approvalMode }, set: { mode in
                    settings.approvalMode = mode
                    settings.save()
                })) {
                    ForEach(AssistantApprovalMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Running Queries", systemImage: "play.circle")
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
                    if session.isSending, !session.turns.contains(where: { $0.step?.state == .awaitingApproval }) { thinking.id("progress") }
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
        if let step = turn.step {
            HStack(alignment: .top, spacing: Spacing.s) {
                assistantAvatar
                stepView(turn.id, step)
            }
        } else if turn.role == .user {
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

    // MARK: Queries

    /// A query the assistant ran or wants to run: its SQL, the user's decision, and its result inline.
    private func stepView(_ id: UUID, _ step: AssistantSession.QueryStep) -> some View {
        let destructive = step.assessment?.isDestructive == true
        let waiting = step.state == .awaitingApproval
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                stepIcon(step)
                Text(stepTitle(step)).font(.rowTitle).foregroundStyle(PortSQLPalette.ink)
                Spacer(minLength: Spacing.s)
                if case .completed(let rows, let milliseconds) = step.state {
                    Text(L10n.format("%1$d rows · %2$d ms", rows, milliseconds))
                        .font(.captionText.monospacedDigit())
                        .foregroundStyle(PortSQLPalette.muted)
                }
            }
            if let purpose = step.purpose, !purpose.isEmpty {
                Text(purpose).font(.captionText).foregroundStyle(PortSQLPalette.muted)
            }
            ScrollView(.horizontal) {
                Text(verbatim: step.query)
                    .font(.codeCaption)
                    .foregroundStyle(PortSQLPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(Spacing.s)
            }
            .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            switch step.state {
            case .awaitingApproval:
                approvalControls(id, step)
            case .running:
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Running…").font(.captionText).foregroundStyle(PortSQLPalette.muted)
                }
            case .completed:
                if let result = step.result {
                    if result.columns.isEmpty {
                        Text(result.executionSummary).font(.captionText).foregroundStyle(PortSQLPalette.muted)
                    } else {
                        ChartTableView(result: result, rowLimit: 200)
                            .frame(height: min(260, CGFloat(min(result.rows.count, 8)) * 26 + 30))
                    }
                }
                HStack(spacing: Spacing.s) {
                    Button { use(step.query, replacing: false) } label: { Label("Open in Console", systemImage: "terminal") }
                    Button { PortbaseClipboard.copy(step.query) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                .font(.captionStrong)
                .buttonStyle(.portbaseToolbar)
            case .declined:
                Text("Not run.").font(.captionText).foregroundStyle(PortSQLPalette.muted)
            case .blocked(let message), .failed(let message):
                Text(message).font(.captionText).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(Spacing.m)
        .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(waiting ? (destructive ? Color.red : Color.orange).opacity(0.6) : PortSQLPalette.stroke, lineWidth: waiting ? 1.5 : 1)
        }
    }

    private func stepTitle(_ step: AssistantSession.QueryStep) -> String {
        switch step.state {
        case .awaitingApproval:
            step.assessment?.isDestructive == true ? L10n.text("Wants to make a destructive change")
                : step.assessment != nil ? L10n.text("Wants to change data") : L10n.text("Wants to run a query")
        case .running: L10n.text("Running a query")
        case .completed: L10n.text("Ran a query")
        case .declined: L10n.text("You declined this query")
        case .blocked: L10n.text("Query blocked")
        case .failed: L10n.text("Query failed")
        }
    }

    @ViewBuilder private func stepIcon(_ step: AssistantSession.QueryStep) -> some View {
        switch step.state {
        case .awaitingApproval: Image(systemName: "hand.raised.fill").foregroundStyle(step.assessment?.isDestructive == true ? .red : .orange)
        case .running: Image(systemName: "play.circle.fill").foregroundStyle(PortSQLPalette.accent)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(PortSQLPalette.accent)
        case .declined: Image(systemName: "xmark.circle").foregroundStyle(PortSQLPalette.muted)
        case .blocked, .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    /// Run or Don't Run. Changes say what they do; destructive ones on production need the object's
    /// name typed, as in the console's confirmation.
    @ViewBuilder private func approvalControls(_ id: UUID, _ step: AssistantSession.QueryStep) -> some View {
        let destructive = step.assessment?.isDestructive == true
        let production = workspace.selectedBookmark?.environment == .production
        let target = destructive && production ? step.assessment?.target : nil
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let assessment = step.assessment {
                HStack(alignment: .top, spacing: Spacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(destructive ? .red : .orange)
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text(assessment.title).font(.rowDetail.weight(.semibold)).foregroundStyle(PortSQLPalette.ink)
                        Text(assessment.message).font(.captionText).foregroundStyle(.secondary)
                        if production {
                            Text("You're connected to a production database.").font(.captionText).foregroundStyle(.red)
                        }
                    }
                }
            }
            if let target {
                TextField(L10n.format("Type %@ to confirm", target), text: Binding(get: { typedConfirmations[id] ?? "" },
                                                                                  set: { typedConfirmations[id] = $0 }))
                    .textFieldStyle(.plain)
                    .font(.codeText)
                    .autocorrectionDisabled()
                    .portbaseTextCapitalization(.never)
                    .portbaseFieldChrome()
            }
            HStack(spacing: Spacing.s) {
                let blocked = target.map { (typedConfirmations[id] ?? "").trimmingCharacters(in: .whitespaces) != $0 } ?? false
                if destructive {
                    Button(step.assessment?.actionTitle ?? L10n.text("Run"), systemImage: "exclamationmark.triangle.fill") {
                        session.decide(id, approved: true)
                    }
                    .buttonStyle(.portbaseDestructive)
                    .disabled(blocked)
                } else {
                    Button("Run", systemImage: "play.fill") { session.decide(id, approved: true) }
                        .buttonStyle(.portbasePrimary)
                }
                Button("Don't Run") { session.decide(id, approved: false) }
                    .buttonStyle(.portbaseSecondary)
            }
            .font(.captionStrong)
        }
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
                Button("Retry", systemImage: "arrow.clockwise") { session.retry(context: context, settings: chatSettings, runner: runner) }
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
            Text(context == nil ? L10n.text("Choose a connection to include its schema.") : composerHint)
                .font(.microText)
                .foregroundStyle(PortSQLPalette.muted)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }

    private var composerHint: String {
        guard settings.approvalMode.runsQueries, let engine = workspace.selectedBookmark?.engine, AssistantQueryRunner.supports(engine) else {
            return L10n.text("Replies are suggestions; nothing runs until you run it.")
        }
        return settings.approvalMode.summary + " " + L10n.text("Changes to data always ask.")
    }

    private var canSend: Bool {
        !session.isSending && context != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend, let context else { return }
        session.send(prompt, context: context, settings: chatSettings, runner: runner)
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
            Picker("Running Queries", selection: $settings.approvalMode) {
                ForEach(AssistantApprovalMode.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Agent")
        } footer: {
            Text(settings.approvalMode.summary + " " + L10n.text("Changes to data always ask, and destructive ones need a stronger confirmation. Results of queries the assistant runs, up to 50 rows, are sent to the provider."))
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
                Text("These settings, reference files included, sync to your other devices as an encrypted file in iCloud Drive whose key is in iCloud Keychain. API keys sync through iCloud Keychain.")
            }
        }
        .onChange(of: settings) { _, value in value.save() }
        // Another device changed the settings: show its copy.
        .onReceive(NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification)) { _ in
            AssistantSettingsSync.pull()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantSettingsDidChange)) { _ in settings = .load() }
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
                    LabeledTextField("Name", text: $draft.name)
                    LabeledContent("API") {
                        PortbaseSegmentedPicker(selection: $draft.kind,
                                                options: AssistantProvider.allCases.map { PortbaseChoice(value: $0, title: $0.title) })
                    }
                    LabeledTextField(verbatim: L10n.text("Endpoint"), text: $draft.baseURL, prompt: draft.kind.defaultBaseURL)
                        .autocorrectionDisabled()
                        .portbaseTextCapitalization(.never)
                        .portbaseKeyboardType(.URL)
                    LabeledTextField(verbatim: L10n.text("API key"), text: $apiKey,
                                     prompt: draft.kind == .anthropic ? nil : L10n.text("Optional for local servers"), isSecure: true)
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
                    LabeledTextField(verbatim: draft.models.isEmpty ? L10n.text("Model") : L10n.text("Or enter a model ID"), text: $draft.model)
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

import SwiftUI
import UniformTypeIdentifiers

struct DataTransferMenu: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var presentation: DataTransferPresentation?

    var body: some View {
        Menu {
            Button {
                present(.importData)
            } label: { Label("Import Data…", systemImage: "square.and.arrow.down") }
            .disabled(workspace.selectedBookmark?.isReadOnly != false || workspace.selectedBookmark?.engine.supportsDataImport != true)
            Button {
                present(.exportData)
            } label: { Label("Export All Rows…", systemImage: "square.and.arrow.up") }
            .disabled(workspace.selectedBookmark?.engine.supportsFullExport != true)
        } label: {
            Label("Data Transfer", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
                .toolIconChrome()
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(workspace.selectedBookmark == nil)
        .sheet(item: $presentation) { item in
            DataTransferSheet(presentation: item).portbaseDesktopSheetSize(width: 680, height: 500)
        }
    }

    private func present(_ mode: DataTransferMode) {
        guard let profile = workspace.selectedBookmark else { return }
        presentation = DataTransferPresentation(mode: mode, profile: profile, database: workspace.activeDatabaseName,
            schema: workspace.schemaCatalog, table: workspace.selectedExplorerTable, query: workspace.transferBoundQuery)
    }
}

enum DataTransferMode { case importData, exportData }

struct DataTransferPresentation: Identifiable {
    let id = UUID()
    let mode: DataTransferMode
    let profile: ConnectionProfile
    let database: String?
    let schema: [SchemaTableDescriptor]
    let table: SchemaTableDescriptor?
    let query: BoundQuery?
}

private struct StagedImportFileError: Error {
    let url: URL
    let underlying: Error
}

struct DataTransferSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DataTransferViewModel
    @State private var showsFileImporter = false
    @State private var confirmsImport = false

    init(presentation: DataTransferPresentation) {
        _model = StateObject(wrappedValue: DataTransferViewModel(presentation: presentation))
    }

    var body: some View {
        PortbaseSheet(model.presentation.mode == .importData ? L10n.text("Import Data") : L10n.text("Export Data")) {
            Form {
                Section {
                    LabeledContent("Connection", value: model.presentation.profile.name)
                    if let database = model.presentation.database { LabeledContent("Database", value: database) }
                }
                if model.presentation.mode == .importData { importSections }
                else { exportSections }
                if let progress = model.progress, model.isWorking {
                    Section {
                        if let total = progress.total, total > 0 {
                            ProgressView(value: Double(progress.completed), total: Double(total)) { Text(progress.label) }
                        } else { ProgressView(progress.label) }
                        Button("Cancel", role: .cancel) { model.cancel() }
                            .frame(minHeight: Sizes.control)
                    }
                }
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                if let result = model.result {
                    Section {
                        Text(L10n.format(model.presentation.mode == .importData ? "Imported %@." : "Exported %@.", L10n.plural("row_count", count: result.rowCount)))
                        if let url = result.fileURL { ShareLink(item: url) { Label("Save or Share", systemImage: "square.and.arrow.up") } }
                    }
                }
            }
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.commaSeparatedText, .json, .plainText]) { result in
                switch result {
                case .success(let url): model.loadFile(url)
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
            .confirmationDialog("Confirm Import", isPresented: $confirmsImport, titleVisibility: .visible) {
                Button(L10n.format("Import %d records", model.source?.rowCount ?? 0), role: .destructive) { model.runImport() }
            } message: {
                Text(L10n.format("Insert into %@?", model.destinationLabel))
            }
        } footer: {
            Button("Done") { dismiss() }
                .buttonStyle(.portbaseSecondary)
                .disabled(model.isWorking)
        }
        .portbaseSheetNavigation()
        .interactiveDismissDisabled(model.isWorking)
        .onDisappear { model.close() }
    }

    @ViewBuilder private var importSections: some View {
        Section("File") {
            Button { showsFileImporter = true } label: {
                Label(model.sourceFileName ?? L10n.text("Choose CSV or JSON"), systemImage: "doc")
            }.disabled(model.isWorking)
            Picker("Format", selection: $model.importFormat) {
                ForEach(DataImportFormat.allCases) { Text($0.title).tag($0) }
            }.disabled(model.isWorking)
            .onChange(of: model.importFormat) { _, _ in model.rereadFile() }
            if model.importFormat == .csv {
                Toggle("First row contains column names", isOn: $model.hasHeader)
                    .disabled(model.isWorking)
                    .onChange(of: model.hasHeader) { _, _ in model.rereadFile() }
                Text("Unquoted NULL is null; \\M is a missing field. Quote these values to import their text.")
                    .font(.footnoteText).foregroundStyle(.secondary)
            }
            if let source = model.source { Text(L10n.plural("row_count", count: source.rowCount)).foregroundStyle(.secondary) }
        }
        destinationSection
        if model.source != nil {
            Section("Column Mapping") {
                ForEach($model.mappings) { $mapping in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(mapping.sourceName).font(.codeDetail)
                        HStack {
                            if model.namesFreely {
                                TextField("Destination field", text: $mapping.targetName)
                                    .portbaseTextCapitalization(.never).autocorrectionDisabled()
                            } else {
                                Picker("Destination column", selection: $mapping.targetName) {
                                    Text("Skip").tag("")
                                    ForEach(model.importableColumns, id: \.name) { Text($0.name).tag($0.name) }
                                }
                                .labelsHidden()
                            }
                            Spacer()
                            Picker("Value type", selection: $mapping.valueType) {
                                ForEach(DataImportValueType.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden()
                        }
                    }.frame(minHeight: Sizes.control)
                }
            }.disabled(model.isWorking)
            Section("Preview") {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        ForEach(Array((model.source?.preview ?? []).enumerated()), id: \.offset) { index, row in
                            Text(model.preview(row: row, number: index + 1))
                                .font(.codeCaption).textSelection(.enabled)
                        }
                    }.padding(.vertical, Spacing.xxs)
                }.frame(maxHeight: 220)
            }
            Section("Statement") {
                Text(model.statementPreview).font(.codeCaption).textSelection(.enabled)
                Text(model.presentation.profile.engine == .mongodb
                     ? L10n.text("MongoDB commits each batch. Cancelled or failed imports can leave inserted documents.")
                     : model.presentation.profile.engine.importsInBatches
                        ? L10n.text("Each batch is written as it's sent. A cancelled or failed import keeps the records already written.")
                        : L10n.text("SQL imports use one transaction. An error before commit rolls back the file."))
                    .font(.footnoteText).foregroundStyle(.secondary)
                Button("Import Data", role: .destructive) { confirmsImport = true }
                    .disabled(!model.canImport || model.isWorking || model.result != nil)
                    .frame(minHeight: Sizes.control)
            }
        }
    }

    @ViewBuilder private var destinationSection: some View {
        Section(model.presentation.mode == .importData ? L10n.text("Destination") : L10n.text("Table")) {
            switch model.presentation.profile.engine {
            case .mongodb:
                TextField("Collection", text: $model.collectionName)
                    .portbaseTextCapitalization(.never).autocorrectionDisabled()
                    .disabled(model.isWorking)
            case .elasticsearch:
                TextField("Index", text: $model.collectionName)
                    .portbaseTextCapitalization(.never).autocorrectionDisabled()
                    .disabled(model.isWorking)
            case .redis:
                if model.presentation.mode == .importData {
                    TextField("Key prefix", text: $model.collectionName)
                        .portbaseTextCapitalization(.never).autocorrectionDisabled()
                        .disabled(model.isWorking)
                    // Each record becomes a hash named by this column, after the prefix.
                    Picker("Key column", selection: $model.keyColumn) {
                        Text("Select").tag("")
                        ForEach(model.source?.columnNames ?? [], id: \.self) { Text($0).tag($0) }
                    }.disabled(model.isWorking)
                } else {
                    TextField("Key pattern", text: $model.collectionName)
                        .font(.codeText)
                        .portbaseTextCapitalization(.never).autocorrectionDisabled()
                        .disabled(model.isWorking)
                }
            default:
                Picker("Table", selection: $model.selectedTableName) {
                    Text("Select table").tag("")
                    ForEach(model.presentation.schema, id: \.displayName) { Text($0.displayName).tag($0.displayName) }
                }.disabled(model.isWorking)
                .onChange(of: model.selectedTableName) { _, _ in model.resetMappings() }
            }
        }
    }

    @ViewBuilder private var exportSections: some View {
        Section {
            PortbaseSegmentedPicker(selection: $model.exportsQuery, options: [
                PortbaseChoice(value: true, title: L10n.text("Query")),
                PortbaseChoice(value: false, title: model.sourceTitle),
            ], fills: true)
            .disabled(model.isWorking)
            .accessibilityLabel("Source")
            Picker("Format", selection: $model.exportFormat) {
                Text("CSV").tag(QueryResultExportFormat.csv)
                Text("JSON").tag(QueryResultExportFormat.json)
            }.disabled(model.isWorking)
            if model.presentation.profile.engine == .mongodb, model.exportFormat == .csv {
                Text("MongoDB CSV fields use Extended JSON to preserve BSON types.")
                    .font(.footnoteText).foregroundStyle(.secondary)
            }
            Stepper(L10n.format("Timeout: %d s", model.timeoutSeconds), value: $model.timeoutSeconds, in: 1...300, step: 5)
                .disabled(model.isWorking)
        }
        if !model.exportsQuery { destinationSection }
        Section("Statement") {
            if let query = model.exportQuery {
                Text(query.sql).font(.codeCaption).textSelection(.enabled)
                if !query.values.isEmpty {
                    Text(query.values.enumerated().map { "\($0.offset + 1): \($0.element.previewLiteral)" }.joined(separator: "\n"))
                        .font(.codeCaption).textSelection(.enabled)
                }
            } else { Text("Select a query or table to export.").foregroundStyle(.secondary) }
            Button("Export All Rows") { model.runExport() }
                .disabled(model.exportQuery == nil || model.isWorking)
                .frame(minHeight: Sizes.control)
        }
    }
}

@MainActor private final class DataTransferViewModel: ObservableObject {
    let presentation: DataTransferPresentation
    @Published var importFormat: DataImportFormat = .csv
    @Published var exportFormat: QueryResultExportFormat = .csv
    @Published var hasHeader = true
    @Published var nullToken = "NULL"
    @Published var source: DataImportSource?
    @Published var sourceFileName: String?
    @Published var mappings: [DataImportColumnMapping] = []
    @Published var selectedTableName: String
    @Published var collectionName: String
    /// Redis: the source column whose value names each hash.
    @Published var keyColumn = ""
    @Published var exportsQuery: Bool
    @Published var timeoutSeconds = 30
    @Published var isWorking = false
    @Published var progress: DataTransferProgress?
    @Published var result: DataTransferResult?
    @Published var errorMessage: String?
    private var stagedFileURL: URL?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()

    init(presentation: DataTransferPresentation) {
        self.presentation = presentation
        selectedTableName = presentation.table?.displayName ?? ""
        collectionName = presentation.table?.name ?? ""
        exportsQuery = presentation.query?.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if presentation.profile.engine == .mongodb || presentation.profile.engine == .elasticsearch { exportFormat = .json }
        if presentation.profile.engine == .redis { collectionName = "*" }
    }

    /// Whether destination fields are typed names rather than columns picked from a table.
    var namesFreely: Bool { [.mongodb, .elasticsearch, .redis].contains(presentation.profile.engine) }

    /// What a whole-source export reads: a table, collection, index or set of keys.
    var sourceTitle: String {
        switch presentation.profile.engine {
        case .mongodb: L10n.text("Collection")
        case .elasticsearch: L10n.text("Index")
        case .redis: L10n.text("Keys")
        default: L10n.text("Table")
        }
    }

    var destination: SchemaTableDescriptor? { presentation.schema.first { $0.displayName == selectedTableName } }
    var destinationLabel: String { namesFreely ? collectionName : selectedTableName }
    var importableColumns: [SchemaColumnDescriptor] { destination?.columns.filter { !DataTransferCodec.isBinaryColumn($0.type) } ?? [] }
    var plan: DataImportPlan? {
        guard let source else { return nil }
        return DataImportPlan(source: source, schemaName: destination?.schemaName ?? "",
            tableName: namesFreely ? collectionName : destination?.name ?? "", mappings: mappings,
            keyColumn: presentation.profile.engine == .redis ? keyColumn : nil)
    }
    var canImport: Bool { presentation.profile.isReadOnly == false && plan.flatMap { try? $0.statement(engine: presentation.profile.engine) } != nil }
    var statementPreview: String {
        guard let plan else { return "" }
        if presentation.profile.engine == .mongodb, let row = source?.preview.first,
           let document = try? DataTransferCodec.mongoDocument(record: row, mappings: mappings, row: 1) {
            return "{\"insert\": " + DataTransferCodec.jsonString(collectionName) + ", \"documents\": [" + MongoExtendedJSON.encode(document, canonical: true) + "], \"ordered\": true}"
        }
        return (try? plan.statement(engine: presentation.profile.engine)) ?? L10n.text("Select a destination and map each included field to a different column.")
    }
    var exportQuery: BoundQuery? {
        if exportsQuery {
            guard let query = presentation.query, !query.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return query
        }
        switch presentation.profile.engine {
        case .mongodb:
            guard !collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return BoundQuery(sql: "{\"find\":" + DataTransferCodec.jsonString(collectionName) + ",\"filter\":{},\"batchSize\":100}", values: [])
        case .elasticsearch:
            let index = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let command = try? ElasticsearchDataTransfer.searchAll(index: index) else { return nil }
            return BoundQuery(sql: command.preview, values: [])
        case .redis:
            let pattern = collectionName.isEmpty ? "*" : collectionName
            return BoundQuery(sql: "SCAN 0 MATCH " + RedisCommandService.quote(Data(pattern.utf8)) + " COUNT 1000", values: [])
        default: break
        }
        guard let destination else { return nil }
        return BoundQuery(sql: "SELECT * FROM " + DataTransferCodec.qualifiedTable(schema: destination.schemaName, table: destination.name, engine: presentation.profile.engine), values: [])
    }

    func resetMappings() {
        mappings = (source?.columnNames ?? []).map { source in
            let column = importableColumns.first { $0.name.caseInsensitiveCompare(source) == .orderedSame }
            return DataImportColumnMapping(sourceName: source, targetName: namesFreely ? source : column?.name ?? "")
        }
        if presentation.profile.engine == .redis, let first = source?.columnNames.first, keyColumn.isEmpty || source?.columnNames.contains(keyColumn) == false {
            // The first column names the hashes by default, and isn't also written as a field.
            keyColumn = first
            if let index = mappings.firstIndex(where: { $0.sourceName == first }) { mappings[index].targetName = "" }
        }
        result = nil
    }

    func preview(row: DataImportRecord, number: Int) -> String {
        if presentation.profile.engine == .mongodb, let document = try? DataTransferCodec.mongoDocument(record: row, mappings: mappings, row: number) {
            return "\(number): " + String(MongoExtendedJSON.encode(document, canonical: true).prefix(600))
        }
        return mappings.filter { !$0.targetName.isEmpty }.map { mapping in
            guard let value = row.fields[mapping.sourceName] else { return "\(mapping.targetName): —" }
            let type = mapping.valueType == .automatic
                ? DataTransferCodec.sqlValueType(for: importableColumns.first(where: { $0.name == mapping.targetName })?.type ?? "") : mapping.valueType
            guard let bound = try? DataTransferCodec.boundValue(value, type: type, column: mapping.targetName, row: number) else {
                return "\(mapping.targetName): " + L10n.text("Invalid value")
            }
            return "\(mapping.targetName): " + String(bound.previewLiteral.prefix(180))
        }.joined(separator: "  ·  ")
    }

    func loadFile(_ url: URL) {
        cancel()
        removeStagedFile()
        source = nil; result = nil; errorMessage = nil
        importFormat = url.pathExtension.lowercased() == "csv" ? .csv : .json
        sourceFileName = url.lastPathComponent
        let id = UUID(); operationID = id
        isWorking = true; progress = .init(phase: .reading, completed: 0, total: nil)
        let format = importFormat, header = hasHeader, null = nullToken
        let callback = progressCallback(id: id)
        operation = Task { [weak self] in
            let worker = Task.detached {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let copy = try DataExportWriter.temporaryURL(extension: format.rawValue)
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    try Task.checkCancellation()
                    let source = try DataTransferCodec.inspect(url: copy, format: format, hasHeader: header, nullToken: null, progress: callback)
                    return source
                } catch { throw StagedImportFileError(url: copy, underlying: error) }
            }
            do {
                let source = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.operationID == id else { try? FileManager.default.removeItem(at: source.url); return }
                self.stagedFileURL = source.url; self.source = source; self.resetMappings(); self.isWorking = false
            } catch let failure as StagedImportFileError {
                guard let self, self.operationID == id else { try? FileManager.default.removeItem(at: failure.url); return }
                // Keep the staged file so format/header changes can recover from a parsing error.
                if FileManager.default.fileExists(atPath: failure.url.path) { self.stagedFileURL = failure.url }
                self.finish(error: failure.underlying, id: id)
            } catch { self?.finish(error: error, id: id) }
        }
    }

    func rereadFile() {
        guard !isWorking, let url = stagedFileURL else { return }
        let id = UUID(); operationID = id
        let format = importFormat, header = hasHeader, null = nullToken
        source = nil; result = nil; errorMessage = nil
        isWorking = true; progress = .init(phase: .reading, completed: 0, total: nil)
        let callback = progressCallback(id: id)
        operation = Task { [weak self] in
            let worker = Task.detached { try DataTransferCodec.inspect(url: url, format: format, hasHeader: header, nullToken: null, progress: callback) }
            do {
                let source = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.operationID == id else { return }
                self.source = source; self.resetMappings(); self.isWorking = false
            } catch { self?.finish(error: error, id: id) }
        }
    }

    func runImport() {
        guard let plan, canImport, !isWorking else { return }
        let id = start(.importing)
        let profile = presentation.profile, database = presentation.database, timeout = timeoutSeconds
        let callback = progressCallback(id: id)
        operation = Task { [weak self] in
            do {
                let result = try await DatabaseService.shared.importData(plan: plan, profile: profile, database: database,
                    policy: .mutation(), timeoutSeconds: timeout, progress: callback)
                guard let self, self.operationID == id else { return }
                self.result = result; self.isWorking = false
            } catch { self?.finish(error: error, id: id) }
        }
    }

    func runExport() {
        guard let query = exportQuery, !isWorking else { return }
        let id = start(.exporting)
        let profile = presentation.profile, database = presentation.database, timeout = timeoutSeconds, format = exportFormat
        let callback = progressCallback(id: id)
        operation = Task { [weak self] in
            do {
                let result = try await DatabaseService.shared.exportData(query: query, profile: profile, database: database,
                    format: format, policy: .readOnly, timeoutSeconds: timeout, progress: callback)
                guard let self, self.operationID == id else { return }
                self.result = result; self.isWorking = false
            } catch { self?.finish(error: error, id: id) }
        }
    }

    func cancel() { operation?.cancel() }
    func close() { operationID = UUID(); cancel(); removeStagedFile() }
    func removeStagedFile() { if let stagedFileURL { try? FileManager.default.removeItem(at: stagedFileURL) }; stagedFileURL = nil }
    private func start(_ phase: DataTransferProgress.Phase) -> UUID {
        let id = UUID(); operationID = id; isWorking = true; errorMessage = nil; result = nil
        progress = .init(phase: phase, completed: 0, total: phase == .importing ? source?.rowCount : nil)
        return id
    }
    private func finish(error: Error, id: UUID) {
        guard operationID == id else { return }
        isWorking = false
        errorMessage = error is CancellationError ? L10n.text("Cancelled") : error.localizedDescription
    }
    private func progressCallback(id: UUID) -> @Sendable (DataTransferProgress) -> Void {
        { [weak self] update in Task { @MainActor in if self?.operationID == id { self?.progress = update } } }
    }
}

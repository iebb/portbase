import Foundation

@MainActor
final class WorkspaceLibraryStore: ObservableObject {
    @Published private(set) var trash: [DeletedLibraryItem] = []
    @Published private(set) var storageError: String?
    @Published private(set) var cloudSyncError: String?
    private var queryCloudCollection: WorkspaceCloudCollection<SavedQuerySnippet>?
    private var chartCloudCollection: WorkspaceCloudCollection<SavedVisualizationPreset>?
    private var deletedChartIDs: Set<UUID> = []
    private var canSave = true
    private var failedWrites: Set<URL> = []
    private var canSyncCharts = true
    private enum ChartFileError: Error { case invalidData }
    private struct Recovery: Codable { var trash: [DeletedLibraryItem]; var deletedChartIDs: Set<UUID> }
    private var recoveryURL: URL { snippetsURL.deletingLastPathComponent().appendingPathComponent("library-recovery.json") }

    @Published private(set) var history: [QueryHistoryEntry] = []
    @Published private(set) var snippets: [SavedQuerySnippet] = []
    @Published private(set) var visualizations: [SavedVisualizationPreset] = []
    @Published private(set) var visualizationPreviewCache: [UUID: QueryResultTable] = [:]

    private let fileManager = FileManager.default
    private let historyURL: URL
    private let snippetsURL: URL
    private let visualizationsURL: URL
    private let visualizationPreviewCacheURL: URL
    private let cloudVisualizationsURL: URL?
    private let legacyVisualizationsURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keyValueStore = NSUbiquitousKeyValueStore.default
    private let cloudSyncEnabled: Bool
    private let visualizationsSyncKey = "visualization-presets-yaml"

    init(directory directoryOverride: URL? = nil, cloudSyncEnabled: Bool = true) {
        self.cloudSyncEnabled = cloudSyncEnabled
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = directoryOverride ?? support.appendingPathComponent("PortSQL", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        historyURL = directory.appendingPathComponent("query-history.json")
        snippetsURL = directory.appendingPathComponent("query-snippets.json")
        visualizationsURL = directory.appendingPathComponent("visualization-presets.yml")
        visualizationPreviewCacheURL = directory.appendingPathComponent("visualization-preview-cache.json")
        legacyVisualizationsURL = directory.appendingPathComponent("visualization-presets.json")
        if cloudSyncEnabled, let ubiquityRoot = fileManager.url(forUbiquityContainerIdentifier: nil) {
            let cloudDirectory = ubiquityRoot
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("PortSQL", isDirectory: true)
            try? fileManager.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
            cloudVisualizationsURL = cloudDirectory.appendingPathComponent("visualization-presets.yml")
        } else {
            cloudVisualizationsURL = nil
        }
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: keyValueStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mergeVisualizationsFromCloud()
                self?.mergeQueriesFromCloud()
            }
        }
        if cloudSyncEnabled { keyValueStore.synchronize() }
        load()
        if cloudSyncEnabled && canSave {
            queryCloudCollection = WorkspaceCloudCollection(key: "portsql.saved-queries.v1",
                url: directory.appendingPathComponent("saved-query-sync.json"), initial: snippets, initialDate: { $0.updatedAt ?? $0.createdAt })
            mergeQueriesFromCloud()
            chartCloudCollection = WorkspaceCloudCollection(key: "portsql.charts.v2",
                url: directory.appendingPathComponent("chart-sync.json"), initial: visualizations, initialDate: { $0.updatedAt },
                quotaMessage: L10n.text("Charts are saved on this device. The library exceeds the iCloud sync limit."))
            let deletions = Dictionary(uniqueKeysWithValues: deletedChartIDs.map { id in
                let date = trash.first { item in if case .chart(let value) = item.content { return value.id == id }; return false }?.deletedAt
                    ?? chartCloudCollection?.state.records.first(where: { $0.id == id })?.updatedAt ?? .now
                return (id, date)
            })
            chartCloudCollection?.seedDeletions(deletions)
            mergeVisualizationsFromCloud()
        }
    }

    func addHistory(_ entry: QueryHistoryEntry) {
        history.insert(entry, at: 0)
        history = Array(history.prefix(200))
        persistHistory()
    }

    func addHistory(title: String, sql: String, connectionName: String, summary: String) {
        addHistory(QueryHistoryEntry(title: title, sql: sql, connectionName: connectionName, summary: summary))
    }

    func saveSnippet(title: String, sql: String, note: String = "", bookmarkID: UUID? = nil, database: String? = nil, engine: DatabaseEngine? = nil) {
        let snippet = SavedQuerySnippet(title: title, sql: sql, note: note, bookmarkID: bookmarkID, database: database, engine: engine)
        snippets.removeAll { $0.title == title && $0.sql == sql }
        snippets.insert(snippet, at: 0)
        // Saved work is retained until the user explicitly deletes it.
        persistSnippets()
    }

    func updateSnippet(_ snippet: SavedQuerySnippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }),
              !snippet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var updated = snippet
        updated.updatedAt = .now
        snippets[index] = updated
        persistSnippets()
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistHistory()
    }

    func deleteSnippets(at offsets: IndexSet) {
        let previousTrash = trash
        let validOffsets = IndexSet(offsets.filter { snippets.indices.contains($0) })
        for index in validOffsets {
            trash.insert(DeletedLibraryItem(content: .snippet(snippets[index])), at: 0)
        }
        guard persistRecovery() else { trash = previousTrash; return }
        snippets.remove(atOffsets: validOffsets)
        persistSnippets()
    }

    @discardableResult
    func saveVisualization(_ preset: SavedVisualizationPreset) -> Bool {
        var stored = preset
        stored.updatedAt = .now
        if stored.createdAt > stored.updatedAt {
            stored.createdAt = stored.updatedAt
        }
        visualizations.removeAll { $0.id == stored.id }
        visualizations.insert(stored, at: 0)
        visualizations.sort { $0.updatedAt > $1.updatedAt }
        guard persistVisualizations(pushToCloud: false) else { return false }
        let previousDeleted = deletedChartIDs
        deletedChartIDs.remove(stored.id)
        guard persistRecovery() else { deletedChartIDs = previousDeleted; return false }
        pruneVisualizationPreviewCache()
        return persistVisualizations(pushToCloud: true)
    }

    func deleteVisualizations(at offsets: IndexSet) {
        let values = offsets.compactMap { visualizations.indices.contains($0) ? visualizations[$0] : nil }
        for value in values { deleteVisualization(value) }
    }

    func deleteVisualization(_ preset: SavedVisualizationPreset) {
        let previousTrash = trash
        let previousDeleted = deletedChartIDs
        trash.insert(DeletedLibraryItem(content: .chart(preset)), at: 0)
        deletedChartIDs.insert(preset.id)
        guard persistRecovery() else {
            trash = previousTrash; deletedChartIDs = previousDeleted; return
        }
        visualizations.removeAll { $0.id == preset.id }
        visualizationPreviewCache.removeValue(forKey: preset.id)
        persistVisualizationPreviewCache()
        persistVisualizations(pushToCloud: true)
    }

    func restore(_ item: DeletedLibraryItem) {
        switch item.content {
        case .snippet(let snippet):
            snippets.removeAll { $0.id == snippet.id }
            snippets.insert(snippet, at: 0)
            guard persistSnippets() else { return }
        case .chart(let chart): guard saveVisualization(chart) else { return }
        }
        let previousTrash = trash
        trash.removeAll { $0.id == item.id }
        if !persistRecovery() { trash = previousTrash }
    }

    func permanentlyDelete(_ item: DeletedLibraryItem) {
        let previousTrash = trash
        trash.removeAll { $0.id == item.id }
        if !persistRecovery() { trash = previousTrash }
    }

    func clearPreviews() {
        visualizationPreviewCache = [:]
        persistVisualizationPreviewCache()
    }

    func clearHistory() { history = []; persistHistory() }

    var previewStorageSize: String {
        let count = (try? Data(contentsOf: visualizationPreviewCacheURL).count) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    @discardableResult
    private func persistRecovery() -> Bool {
        guard let data = try? encoder.encode(Recovery(trash: trash, deletedChartIDs: deletedChartIDs)) else { return false }
        return write(data, to: recoveryURL)
    }

    @discardableResult
    private func write(_ data: Data, to url: URL) -> Bool {
        guard canSave else { return false }
        do {
            try WorkspaceFileStore.write(data, to: url)
            failedWrites.remove(url)
            if canSyncCharts && failedWrites.isEmpty { storageError = nil }
            return true
        } catch {
            failedWrites.insert(url)
            storageError = L10n.text("Saved work could not be written. Free some device storage and try again.")
            return false
        }
    }

    func cachedVisualizationPreview(for presetID: UUID) -> QueryResultTable? {
        visualizationPreviewCache[presetID]
    }

    func cacheVisualizationPreview(_ result: QueryResultTable, for presetID: UUID) {
        visualizationPreviewCache[presetID] = result
        pruneVisualizationPreviewCache()
        persistVisualizationPreviewCache()
    }

    private func load() {
        var mergedVisualizations: [SavedVisualizationPreset] = []

        do {
            if let recovery = try WorkspaceFileStore.read(Recovery.self, from: recoveryURL, decoder: decoder) {
                trash = recovery.trash; deletedChartIDs = recovery.deletedChartIDs
            }
            history = try WorkspaceFileStore.read([QueryHistoryEntry].self, from: historyURL, decoder: decoder) ?? []
            snippets = try WorkspaceFileStore.read([SavedQuerySnippet].self, from: snippetsURL, decoder: decoder) ?? []
        } catch {
            canSave = false
            storageError = L10n.text("Saved work could not be loaded. The original files have been preserved.")
        }
        if let data = try? Data(contentsOf: visualizationPreviewCacheURL),
           let decoded = try? decoder.decode([UUID: QueryResultTable].self, from: data) {
            visualizationPreviewCache = decoded
        }
        do {
            mergedVisualizations = try readVisualizations(from: visualizationsURL)
                ?? WorkspaceFileStore.read([SavedVisualizationPreset].self, from: legacyVisualizationsURL, decoder: decoder)
                ?? []
        } catch {
            canSave = false
            storageError = L10n.text("Saved work could not be loaded. The original files have been preserved.")
        }
        if let cloudVisualizationsURL, fileManager.fileExists(atPath: cloudVisualizationsURL.path) {
            do {
                let yaml = try String(contentsOf: cloudVisualizationsURL, encoding: .utf8)
                mergedVisualizations = merge(local: mergedVisualizations, remote: try decodeVisualizations(yaml: yaml))
            } catch {
                canSyncCharts = false
                storageError = L10n.text("Saved work could not be loaded. The original files have been preserved.")
            }
        }
        visualizations = mergedVisualizations.filter { !deletedChartIDs.contains($0.id) }
        pruneVisualizationPreviewCache()
        mergeVisualizationsFromCloud()
        persistVisualizationPreviewCache()
        persistVisualizations(pushToCloud: true)
    }

    private func persistHistory() {
        guard let data = try? encoder.encode(history) else { return }
        write(data, to: historyURL)
    }

    @discardableResult
    private func persistSnippets(pushToCloud: Bool = true) -> Bool {
        guard let data = try? encoder.encode(snippets) else { return false }
        guard write(data, to: snippetsURL) else { return false }
        if pushToCloud {
            queryCloudCollection?.save(snippets)
            cloudSyncError = queryCloudCollection?.errorMessage
        }
        return true
    }

    func synchronizeCloud() {
        guard cloudSyncEnabled else { return }
        keyValueStore.synchronize()
        mergeVisualizationsFromCloud()
        mergeQueriesFromCloud()
    }

    private func mergeQueriesFromCloud() {
        guard cloudSyncEnabled, canSave, let queryCloudCollection else { return }
        if let merged = queryCloudCollection.mergeCloud(), merged != snippets {
            snippets = merged
            persistSnippets(pushToCloud: false)
        }
        cloudSyncError = queryCloudCollection.errorMessage
    }

    private func persistVisualizationPreviewCache() {
        guard let data = try? encoder.encode(visualizationPreviewCache) else { return }
        write(data, to: visualizationPreviewCacheURL)
    }

    @discardableResult
    private func persistVisualizations(pushToCloud: Bool) -> Bool {
        guard canSave else { return false }
        let yaml = encodeVisualizations(visualizations)
        guard write(Data(yaml.utf8), to: visualizationsURL) else { return false }
        guard canSyncCharts else { return true }
        if let cloudVisualizationsURL {
            try? yaml.write(to: cloudVisualizationsURL, atomically: true, encoding: .utf8)
        }
        guard cloudSyncEnabled, pushToCloud else { return true }
        chartCloudCollection?.save(visualizations)
        chartCloudCollection?.noteLegacySnapshot(visualizations)
        cloudSyncError = chartCloudCollection?.errorMessage ?? queryCloudCollection?.errorMessage
        guard WorkspaceCloudQuota.canStore(yaml, forKey: visualizationsSyncKey, in: keyValueStore) else {
            storageError = L10n.text("Charts are saved on this device. The library exceeds the iCloud sync limit.")
            return true
        }
        keyValueStore.set(yaml, forKey: visualizationsSyncKey)
        keyValueStore.synchronize()
        return true
    }

    private func mergeVisualizationsFromCloud() {
        guard cloudSyncEnabled else { return }
        if let chartCloudCollection {
            guard chartCloudCollection.mergeCloud() != nil else { cloudSyncError = chartCloudCollection.errorMessage; return }
            if let yaml = keyValueStore.string(forKey: visualizationsSyncKey) {
                do {
                    _ = chartCloudCollection.ingestLegacy(try decodeVisualizations(yaml: yaml), initialDate: { $0.updatedAt }, usesIntrinsicRevision: true)
                } catch {
                    cloudSyncError = L10n.text("Saved work could not be loaded. The original files have been preserved.")
                    return
                }
            }
            deletedChartIDs = Set(chartCloudCollection.state.records.filter { $0.value == nil }.map(\.id))
            let values = chartCloudCollection.state.values.sorted { $0.updatedAt > $1.updatedAt }
            if values != visualizations {
                visualizations = values
                persistRecovery()
                pruneVisualizationPreviewCache()
                persistVisualizations(pushToCloud: false)
            }
            cloudSyncError = chartCloudCollection.errorMessage ?? queryCloudCollection?.errorMessage
            return
        }
        guard let yaml = keyValueStore.string(forKey: visualizationsSyncKey) else {
            return
        }
        let remote: [SavedVisualizationPreset]
        do { remote = try decodeVisualizations(yaml: yaml) }
        catch {
            canSyncCharts = false
            storageError = L10n.text("Saved work could not be loaded. The original files have been preserved.")
            return
        }

        let merged = merge(local: visualizations, remote: remote)
        guard merged != visualizations else { return }
        visualizations = merged
        persistVisualizations(pushToCloud: false)
    }

    private func merge(local: [SavedVisualizationPreset], remote: [SavedVisualizationPreset]) -> [SavedVisualizationPreset] {
        var map: [UUID: SavedVisualizationPreset] = [:]
        for preset in local + remote where !deletedChartIDs.contains(preset.id) {
            if let existing = map[preset.id] {
                map[preset.id] = existing.updatedAt >= preset.updatedAt ? existing : preset
            } else {
                map[preset.id] = preset
            }
        }
        return map.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func pruneVisualizationPreviewCache() {
        let validIDs = Set(visualizations.map(\.id))
        visualizationPreviewCache = visualizationPreviewCache.filter { validIDs.contains($0.key) }
    }

    private func encodeVisualizations(_ presets: [SavedVisualizationPreset]) -> String {
        let formatter = ISO8601DateFormatter()
        return presets.map { preset in
            [
                "- id: \(yamlQuoted(preset.id.uuidString))",
                "  title: \(yamlQuoted(preset.title))",
                "  chartType: \(yamlQuoted(preset.chartType.rawValue))",
                "  chartTitle: \(yamlQuoted(preset.chartTitle))",
                "  xField: \(yamlQuoted(preset.xField))",
                "  yField: \(yamlQuoted(preset.yField))",
                "  yFields: \(yamlStringArray(preset.resolvedYFields))",
                "  groupField: \(yamlOptional(preset.groupField))",
                "  labelField: \(yamlOptional(preset.labelField))",
                "  xAxisTitle: \(yamlQuoted(preset.xAxisTitle))",
                "  yAxisTitle: \(yamlQuoted(preset.yAxisTitle))",
                "  xAxisMode: \(yamlQuoted(preset.xAxisMode.rawValue))",
                "  usesUnlimitedRows: \(preset.usesUnlimitedRows ? "true" : "false")",
                "  connectionName: \(yamlQuoted(preset.connectionName))",
                "  connectionProfileID: \(yamlOptional(preset.connectionProfileID?.uuidString))",
                "  databaseName: \(yamlOptional(preset.databaseName))",
                "  sourceTableReference: \(yamlOptional(preset.sourceTableReference))",
                "  sourceQuery: \(yamlOptional(preset.sourceQuery))",
                "  createdAt: \(yamlQuoted(formatter.string(from: preset.createdAt)))",
                "  updatedAt: \(yamlQuoted(formatter.string(from: preset.updatedAt)))"
            ].joined(separator: "\n")
        }
        .joined(separator: "\n")
    }

    private func readVisualizations(from url: URL) throws -> [SavedVisualizationPreset]? {
        let backup = url.appendingPathExtension("backup")
        guard fileManager.fileExists(atPath: url.path) else {
            guard fileManager.fileExists(atPath: backup.path) else { return nil }
            return try decodeVisualizations(yaml: String(contentsOf: backup, encoding: .utf8))
        }
        do { return try decodeVisualizations(yaml: String(contentsOf: url, encoding: .utf8)) }
        catch {
            guard let recovered = try? decodeVisualizations(yaml: String(contentsOf: backup, encoding: .utf8)) else { throw error }
            // Move the damaged primary aside before any automatic save can replace the good backup.
            try fileManager.moveItem(at: url, to: url.appendingPathExtension("damaged-" + UUID().uuidString))
            return recovered
        }
    }

    private func decodeVisualizations(yaml: String) throws -> [SavedVisualizationPreset] {
        let formatter = ISO8601DateFormatter()
        var items: [[String: String]] = []
        var current: [String: String] = [:]

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                continue
            }
            if line.hasPrefix("- ") {
                if !current.isEmpty {
                    items.append(current)
                    current = [:]
                }
                try parseYAMLLine(String(line.dropFirst(2)), into: &current)
            } else if line.hasPrefix("  "), !current.isEmpty {
                try parseYAMLLine(String(line.dropFirst(2)), into: &current)
            } else { throw ChartFileError.invalidData }
        }
        if !current.isEmpty {
            items.append(current)
        }

        var seen = Set<UUID>()
        return try items.map { item in
            guard let idString = try yamlDecoded(item["id"]),
                  let id = UUID(uuidString: idString),
                  seen.insert(id).inserted,
                  let title = try yamlDecoded(item["title"]),
                  let chartTypeRaw = try yamlDecoded(item["chartType"]),
                  let chartType = VisualizationChartType(rawValue: chartTypeRaw),
                  let chartTitle = try yamlDecoded(item["chartTitle"]),
                  let xField = try yamlDecoded(item["xField"]),
                  let yField = try yamlDecoded(item["yField"]),
                  let xAxisTitle = try yamlDecoded(item["xAxisTitle"]),
                  let yAxisTitle = try yamlDecoded(item["yAxisTitle"]),
                  let xAxisModeRaw = try yamlDecoded(item["xAxisMode"]),
                  let xAxisMode = VisualizationFieldMode(rawValue: xAxisModeRaw),
                  let connectionName = try yamlDecoded(item["connectionName"]),
                  let createdAtString = try yamlDecoded(item["createdAt"]),
                  let createdAt = formatter.date(from: createdAtString),
                  let updatedAtString = try yamlDecoded(item["updatedAt"]),
                  let updatedAt = formatter.date(from: updatedAtString) else {
                throw ChartFileError.invalidData
            }
            guard item["usesUnlimitedRows"] == nil || yamlBool(item["usesUnlimitedRows"]) != nil,
                  item["yFields"] == nil || yamlStringArrayDecoded(item["yFields"]) != nil else { throw ChartFileError.invalidData }
            let usesUnlimitedRows = yamlBool(item["usesUnlimitedRows"]) ?? false
            let profileIDString = try yamlDecoded(item["connectionProfileID"])
            let connectionProfileID = profileIDString.flatMap(UUID.init(uuidString:))
            guard profileIDString == nil || connectionProfileID != nil else { throw ChartFileError.invalidData }
            let yFields = yamlStringArrayDecoded(item["yFields"]) ?? [yField]

            return SavedVisualizationPreset(
                id: id,
                title: title,
                chartType: chartType,
                chartTitle: chartTitle,
                xField: xField,
                yField: yField,
                yFields: yFields,
                groupField: try yamlDecoded(item["groupField"]),
                labelField: try yamlDecoded(item["labelField"]),
                xAxisTitle: xAxisTitle,
                yAxisTitle: yAxisTitle,
                xAxisMode: xAxisMode,
                usesUnlimitedRows: usesUnlimitedRows,
                connectionName: connectionName,
                connectionProfileID: connectionProfileID,
                databaseName: try yamlDecoded(item["databaseName"]),
                sourceTableReference: try yamlDecoded(item["sourceTableReference"]),
                sourceQuery: try yamlDecoded(item["sourceQuery"]),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private func parseYAMLLine(_ line: String, into dictionary: inout [String: String]) throws {
        guard let separator = line.firstIndex(of: ":") else { throw ChartFileError.invalidData }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let valueStart = line.index(after: separator)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty, dictionary[key] == nil else { throw ChartFileError.invalidData }
        dictionary[key] = value
    }

    private func yamlQuoted(_ value: String) -> String {
        // JSON strings are valid YAML scalars and escape tabs and all other control characters.
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    private func yamlOptional(_ value: String?) -> String {
        guard let value else { return "null" }
        return yamlQuoted(value)
    }

    private func yamlStringArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private func yamlDecoded(_ value: String?) throws -> String? {
        guard let value else { return nil }
        if value == "null" {
            return nil
        }
        guard value.hasPrefix("\"") else { throw ChartFileError.invalidData }
        // Previous versions wrote literal tabs inside quoted SQL; preserve those existing drafts.
        let compatible = value.replacingOccurrences(of: "\t", with: "\\t")
        guard let data = compatible.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else { throw ChartFileError.invalidData }
        return decoded
    }

    private func yamlBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private func yamlStringArrayDecoded(_ value: String?) -> [String]? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

import Foundation

@MainActor
final class WorkspaceLibraryStore: ObservableObject {
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
    private let visualizationsSyncKey = "visualization-presets-yaml"

    init() {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("PortSQL", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        historyURL = directory.appendingPathComponent("query-history.json")
        snippetsURL = directory.appendingPathComponent("query-snippets.json")
        visualizationsURL = directory.appendingPathComponent("visualization-presets.yml")
        visualizationPreviewCacheURL = directory.appendingPathComponent("visualization-preview-cache.json")
        legacyVisualizationsURL = directory.appendingPathComponent("visualization-presets.json")
        if let ubiquityRoot = fileManager.url(forUbiquityContainerIdentifier: nil) {
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
            }
        }
        keyValueStore.synchronize()
        load()
    }

    func addHistory(title: String, sql: String, connectionName: String, summary: String) {
        let entry = QueryHistoryEntry(title: title, sql: sql, connectionName: connectionName, summary: summary)
        history.removeAll { $0.sql == sql && $0.connectionName == connectionName }
        history.insert(entry, at: 0)
        history = Array(history.prefix(60))
        persistHistory()
    }

    func saveSnippet(title: String, sql: String, note: String = "") {
        let snippet = SavedQuerySnippet(title: title, sql: sql, note: note)
        snippets.removeAll { $0.title == title && $0.sql == sql }
        snippets.insert(snippet, at: 0)
        snippets = Array(snippets.prefix(40))
        persistSnippets()
    }

    func deleteHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistHistory()
    }

    func deleteSnippets(at offsets: IndexSet) {
        snippets.remove(atOffsets: offsets)
        persistSnippets()
    }

    func saveVisualization(_ preset: SavedVisualizationPreset) {
        var stored = preset
        stored.updatedAt = .now
        if stored.createdAt > stored.updatedAt {
            stored.createdAt = stored.updatedAt
        }
        visualizations.removeAll { $0.id == stored.id }
        visualizations.insert(stored, at: 0)
        visualizations.sort { $0.updatedAt > $1.updatedAt }
        visualizations = Array(visualizations.prefix(50))
        pruneVisualizationPreviewCache()
        persistVisualizations(pushToCloud: true)
    }

    func deleteVisualizations(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            visualizations.indices.contains(index) ? visualizations[index].id : nil
        }
        visualizations.remove(atOffsets: offsets)
        ids.forEach { visualizationPreviewCache.removeValue(forKey: $0) }
        persistVisualizationPreviewCache()
        persistVisualizations(pushToCloud: true)
    }

    func deleteVisualization(_ preset: SavedVisualizationPreset) {
        visualizations.removeAll { $0.id == preset.id }
        visualizationPreviewCache.removeValue(forKey: preset.id)
        persistVisualizationPreviewCache()
        persistVisualizations(pushToCloud: true)
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

        if let data = try? Data(contentsOf: historyURL),
           let decoded = try? decoder.decode([QueryHistoryEntry].self, from: data) {
            history = decoded
        }
        if let data = try? Data(contentsOf: snippetsURL),
           let decoded = try? decoder.decode([SavedQuerySnippet].self, from: data) {
            snippets = decoded
        }
        if let data = try? Data(contentsOf: visualizationPreviewCacheURL),
           let decoded = try? decoder.decode([UUID: QueryResultTable].self, from: data) {
            visualizationPreviewCache = decoded
        }
        if let yaml = try? String(contentsOf: visualizationsURL, encoding: .utf8) {
            mergedVisualizations = decodeVisualizations(yaml: yaml)
        } else if let data = try? Data(contentsOf: legacyVisualizationsURL),
                  let decoded = try? decoder.decode([SavedVisualizationPreset].self, from: data) {
            mergedVisualizations = decoded
        }
        if let cloudVisualizationsURL,
           let yaml = try? String(contentsOf: cloudVisualizationsURL, encoding: .utf8) {
            mergedVisualizations = merge(local: mergedVisualizations, remote: decodeVisualizations(yaml: yaml))
        }
        visualizations = mergedVisualizations
        pruneVisualizationPreviewCache()
        mergeVisualizationsFromCloud()
        persistVisualizationPreviewCache()
        persistVisualizations(pushToCloud: true)
    }

    private func persistHistory() {
        guard let data = try? encoder.encode(history) else { return }
        try? data.write(to: historyURL, options: [.atomic])
    }

    private func persistSnippets() {
        guard let data = try? encoder.encode(snippets) else { return }
        try? data.write(to: snippetsURL, options: [.atomic])
    }

    private func persistVisualizationPreviewCache() {
        guard let data = try? encoder.encode(visualizationPreviewCache) else { return }
        try? data.write(to: visualizationPreviewCacheURL, options: [.atomic])
    }

    private func persistVisualizations(pushToCloud: Bool) {
        let yaml = encodeVisualizations(visualizations)
        try? yaml.write(to: visualizationsURL, atomically: true, encoding: .utf8)
        if let cloudVisualizationsURL {
            try? yaml.write(to: cloudVisualizationsURL, atomically: true, encoding: .utf8)
        }
        guard pushToCloud else { return }
        keyValueStore.set(yaml, forKey: visualizationsSyncKey)
        keyValueStore.synchronize()
    }

    private func mergeVisualizationsFromCloud() {
        guard let yaml = keyValueStore.string(forKey: visualizationsSyncKey) else {
            return
        }
        let remote = decodeVisualizations(yaml: yaml)

        let merged = merge(local: visualizations, remote: remote)
        guard merged != visualizations else { return }
        visualizations = merged
        persistVisualizations(pushToCloud: false)
    }

    private func merge(local: [SavedVisualizationPreset], remote: [SavedVisualizationPreset]) -> [SavedVisualizationPreset] {
        var map: [UUID: SavedVisualizationPreset] = [:]
        for preset in local + remote {
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

    private func decodeVisualizations(yaml: String) -> [SavedVisualizationPreset] {
        let formatter = ISO8601DateFormatter()
        var items: [[String: String]] = []
        var current: [String: String] = [:]

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if line.hasPrefix("- ") {
                if !current.isEmpty {
                    items.append(current)
                    current = [:]
                }
                parseYAMLLine(String(line.dropFirst(2)), into: &current)
            } else if line.hasPrefix("  ") {
                parseYAMLLine(String(line.dropFirst(2)), into: &current)
            }
        }
        if !current.isEmpty {
            items.append(current)
        }

        return items.compactMap { item in
            guard let idString = yamlDecoded(item["id"]),
                  let id = UUID(uuidString: idString),
                  let title = yamlDecoded(item["title"]),
                  let chartTypeRaw = yamlDecoded(item["chartType"]),
                  let chartType = VisualizationChartType(rawValue: chartTypeRaw),
                  let chartTitle = yamlDecoded(item["chartTitle"]),
                  let xField = yamlDecoded(item["xField"]),
                  let yField = yamlDecoded(item["yField"]),
                  let xAxisTitle = yamlDecoded(item["xAxisTitle"]),
                  let yAxisTitle = yamlDecoded(item["yAxisTitle"]),
                  let xAxisModeRaw = yamlDecoded(item["xAxisMode"]),
                  let xAxisMode = VisualizationFieldMode(rawValue: xAxisModeRaw),
                  let connectionName = yamlDecoded(item["connectionName"]),
                  let createdAtString = yamlDecoded(item["createdAt"]),
                  let createdAt = formatter.date(from: createdAtString),
                  let updatedAtString = yamlDecoded(item["updatedAt"]),
                  let updatedAt = formatter.date(from: updatedAtString) else {
                return nil
            }
            let usesUnlimitedRows = yamlBool(item["usesUnlimitedRows"]) ?? false
            let connectionProfileID = yamlDecoded(item["connectionProfileID"]).flatMap(UUID.init(uuidString:))
            let yFields = yamlStringArrayDecoded(item["yFields"]) ?? [yField]

            return SavedVisualizationPreset(
                id: id,
                title: title,
                chartType: chartType,
                chartTitle: chartTitle,
                xField: xField,
                yField: yField,
                yFields: yFields,
                groupField: yamlDecoded(item["groupField"]),
                labelField: yamlDecoded(item["labelField"]),
                xAxisTitle: xAxisTitle,
                yAxisTitle: yAxisTitle,
                xAxisMode: xAxisMode,
                usesUnlimitedRows: usesUnlimitedRows,
                connectionName: connectionName,
                connectionProfileID: connectionProfileID,
                databaseName: yamlDecoded(item["databaseName"]),
                sourceTableReference: yamlDecoded(item["sourceTableReference"]),
                sourceQuery: yamlDecoded(item["sourceQuery"]),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private func parseYAMLLine(_ line: String, into dictionary: inout [String: String]) {
        guard let separator = line.firstIndex(of: ":") else { return }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let valueStart = line.index(after: separator)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        dictionary[key] = value
    }

    private func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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

    private func yamlDecoded(_ value: String?) -> String? {
        guard let value else { return nil }
        if value == "null" {
            return nil
        }
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(String.self, from: data) else {
            return value
        }
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

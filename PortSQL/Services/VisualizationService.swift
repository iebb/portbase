import Foundation

enum VisualizationService {
    static func fieldDescriptors(for result: QueryResultTable) -> [VisualizationFieldDescriptor] {
        result.columns.enumerated().map { index, column in
            let values = result.rows.map { row -> String in
                guard let cell = row.cells[safe: index], cell != .null else { return "" }
                if result.documents != nil, cell == .json("{\"$missing\":true}") { return "" }
                return cell.displayValue
            }
            let nonEmptyValues = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let sample = nonEmptyValues.first ?? ""
            let distinctCount = Set(nonEmptyValues).count
            let sampleValues = Array(nonEmptyValues.prefix(200))
            let numericHits = sampleValues.filter { parsedNumber(from: $0) != nil }.count
            let dateHits = sampleValues.filter { parsedDate(from: $0, sourceType: column.type) != nil }.count
            let numericByType = isNumericSourceType(column.type)
            let dateByType = isDateSourceType(column.type)
            let supportsNumeric = numericByType || confidence(hitCount: numericHits, total: sampleValues.count) >= 0.75
            let supportsDate = dateByType || confidence(hitCount: dateHits, total: sampleValues.count) >= 0.75

            return VisualizationFieldDescriptor(
                name: column.name,
                sourceType: column.type,
                nonEmptyCount: nonEmptyValues.count,
                distinctCount: distinctCount,
                sampleValue: sample,
                supportsCategory: true,
                supportsNumeric: supportsNumeric,
                supportsDate: supportsDate
            )
        }
    }

    static func defaultPreset(
        for result: QueryResultTable,
        connectionProfileID: UUID?,
        connectionName: String,
        databaseName: String?,
        sourceTableReference: String?
    ) -> SavedVisualizationPreset {
        let descriptors = fieldDescriptors(for: result)
        let scalarFields = result.documents == nil ? descriptors : descriptors.enumerated().compactMap { index, field in
            result.rows.contains { row in
                guard let cell = row.cells[safe: index] else { return false }
                switch cell {
                case .null, .json, .binary: return false
                default: return true
                }
            } ? field : nil
        }
        let xField = defaultXField(from: scalarFields.isEmpty ? descriptors : scalarFields)
        let yField = defaultYField(from: descriptors, excluding: xField)
        let yFields = yField.isEmpty ? [] : [yField]
        let xDescriptor = descriptors.first(where: { $0.name == xField })
        let titleBase = sourceTableReference ?? connectionName
        return SavedVisualizationPreset(
            title: generatedTitle(chartType: .bar, xField: xField, yFields: yFields, source: titleBase),
            chartType: defaultChartType(for: xDescriptor),
            chartTitle: titleBase.isEmpty ? "Query Visualization" : titleBase,
            xField: xField,
            yField: yField,
            yFields: yFields,
            groupField: nil,
            labelField: nil,
            xAxisTitle: xField,
            yAxisTitle: yField,
            xAxisMode: preferredXMode(for: xDescriptor),
            usesUnlimitedRows: false,
            connectionName: connectionName,
            connectionProfileID: connectionProfileID,
            databaseName: databaseName,
            sourceTableReference: sourceTableReference,
            sourceQuery: result.sourceQuery
        )
    }

    static func reconciledPreset(
        _ preset: SavedVisualizationPreset?,
        for result: QueryResultTable,
        connectionProfileID: UUID?,
        connectionName: String,
        databaseName: String?,
        sourceTableReference: String?
    ) -> SavedVisualizationPreset {
        let descriptors = fieldDescriptors(for: result)
        let defaults = defaultPreset(
            for: result,
            connectionProfileID: connectionProfileID,
            connectionName: connectionName,
            databaseName: databaseName,
            sourceTableReference: sourceTableReference
        )
        guard let preset else { return defaults }

        var reconciled = preset
        let validNumericFieldNames = Set(descriptors.filter(\.supportsNumeric).map(\.name))
        reconciled.connectionName = connectionName
        reconciled.connectionProfileID = connectionProfileID ?? preset.connectionProfileID
        reconciled.databaseName = databaseName
        reconciled.sourceTableReference = sourceTableReference
        reconciled.sourceQuery = result.sourceQuery ?? preset.sourceQuery
        if descriptors.first(where: { $0.name == preset.xField }) == nil {
            reconciled.xField = defaults.xField
        }
        let reconciledYFields = reconciled.resolvedYFields.filter { validNumericFieldNames.contains($0) }
        if reconciledYFields.isEmpty {
            reconciled.yField = defaults.yField
            reconciled.yFields = defaults.resolvedYFields
        } else {
            reconciled.yFields = reconciledYFields
            reconciled.yField = reconciledYFields[0]
        }
        if let groupField = reconciled.groupField,
           descriptors.first(where: { $0.name == groupField }) == nil {
            reconciled.groupField = nil
        }
        if let labelField = reconciled.labelField,
           descriptors.first(where: { $0.name == labelField }) == nil {
            reconciled.labelField = nil
        }
        if reconciled.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reconciled.title = defaults.title
        }
        if reconciled.chartTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reconciled.chartTitle = defaults.chartTitle
        }
        if reconciled.xAxisTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reconciled.xAxisTitle = reconciled.xField
        }
        if reconciled.yAxisTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reconciled.yAxisTitle = reconciled.yFieldsSummary
        }
        if let descriptor = descriptors.first(where: { $0.name == reconciled.xField }),
           !supportedXModes(for: descriptor).contains(reconciled.xAxisMode) {
            reconciled.xAxisMode = preferredXMode(for: descriptor)
        }
        return reconciled
    }

    static func supportedXModes(for field: VisualizationFieldDescriptor) -> [VisualizationFieldMode] {
        var modes: [VisualizationFieldMode] = [.automatic, .category]
        if field.supportsNumeric {
            modes.append(.number)
        }
        if field.supportsDate {
            modes.append(.date)
        }
        return modes
    }

    static func resolvedXMode(for preset: SavedVisualizationPreset, fields: [VisualizationFieldDescriptor]) -> VisualizationFieldMode {
        guard let descriptor = fields.first(where: { $0.name == preset.xField }) else {
            return .category
        }
        switch preset.xAxisMode {
        case .automatic:
            return preferredXMode(for: descriptor)
        case .category, .number, .date:
            return supportedXModes(for: descriptor).contains(preset.xAxisMode) ? preset.xAxisMode : preferredXMode(for: descriptor)
        }
    }

    static func chartPoints(for result: QueryResultTable, preset: SavedVisualizationPreset, fields suppliedFields: [VisualizationFieldDescriptor]? = nil) -> [VisualizationPlotPoint] {
        let fields = suppliedFields ?? fieldDescriptors(for: result)
        let yFields = preset.resolvedYFields
        guard let xIndex = result.columns.firstIndex(where: { $0.name == preset.xField }),
              !yFields.isEmpty else {
            return []
        }
        let yFieldIndexes = yFields.compactMap { fieldName in
            result.columns.firstIndex(where: { $0.name == fieldName }).map { (fieldName, $0) }
        }
        guard !yFieldIndexes.isEmpty else { return [] }
        let xMode = resolvedXMode(for: preset, fields: fields)
        let xSourceType = result.columns[safe: xIndex]?.type ?? ""
        let groupIndex = preset.groupField.flatMap { fieldName in
            result.columns.firstIndex(where: { $0.name == fieldName })
        }
        let labelIndex = preset.labelField.flatMap { fieldName in
            result.columns.firstIndex(where: { $0.name == fieldName })
        }

        let chartDateFormatter = makeChartDateFormatter()
        var buckets: [String: VisualizationPlotPoint] = [:]
        for row in result.rows {
            let xCell = row.cells[safe: xIndex] ?? .null
            let rawX = xCell.displayValue
            let xText: String
            let xNumber: Double?
            let xDate: Date?
            switch xMode {
            case .category:
                xText = xCell.isNull ? L10n.text("NULL") : (rawX.isEmpty ? L10n.text("empty string") : rawX)
                xNumber = nil
                xDate = nil
            case .number:
                guard let number = parsedNumber(from: rawX) else { continue }
                xText = format(number: number)
                xNumber = number
                xDate = nil
            case .date:
                guard let date = parsedDate(from: rawX, sourceType: xSourceType) else { continue }
                xText = chartDateFormatter.string(from: date)
                xNumber = nil
                xDate = date
            case .automatic:
                xText = rawX
                xNumber = nil
                xDate = nil
            }

            // Read single cells; `row.values` would format the whole row on every access.
            let group = groupIndex
                .flatMap { row.cells[safe: $0]?.displayValue.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let label = labelIndex
                .flatMap { row.cells[safe: $0]?.displayValue.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }

            for (metricName, yIndex) in yFieldIndexes {
                let rawY = row.cells[safe: yIndex]?.displayValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let yValue = parsedNumber(from: rawY) else { continue }

                let seriesGroup = stackedSeriesName(metric: metricName, group: group, preset: preset)
                // NULL, empty text, and text that reads "NULL" stay separate categories.
                let categoryIdentity = xMode == .category ? (xCell.isNull ? "\u{0}null" : "v:" + rawX) : xText
                let identifierComponents: [String] = [
                    xMode.rawValue,
                    categoryIdentity,
                    xNumber.map { String($0) } ?? "",
                    xDate.map { String($0.timeIntervalSince1970) } ?? "",
                    seriesGroup ?? "",
                    metricName
                ]
                let identifier = identifierComponents.map { "\($0.utf8.count):\($0)" }.joined()

                if buckets[identifier] != nil {
                    buckets[identifier]!.yValue += yValue
                    buckets[identifier]!.sourceRowIDs.append(row.id)
                    if buckets[identifier]!.label == nil { buckets[identifier]!.label = label }
                } else {
                    buckets[identifier] = VisualizationPlotPoint(
                        id: identifier,
                        xText: xText,
                        xNumber: xNumber,
                        xDate: xDate,
                        yValue: yValue,
                        group: seriesGroup,
                        label: label,
                        metric: metricName,
                        sourceRowIDs: [row.id]
                    )
                }
            }
        }

        return buckets.values.filter { $0.yValue.isFinite }.sorted { lhs, rhs in
            switch xMode {
            case .date:
                return (lhs.xDate ?? .distantPast) < (rhs.xDate ?? .distantPast)
            case .number:
                return (lhs.xNumber ?? 0) < (rhs.xNumber ?? 0)
            case .category, .automatic:
                if lhs.group == rhs.group {
                    return lhs.xText.localizedCaseInsensitiveCompare(rhs.xText) == .orderedAscending
                }
                return (lhs.group ?? "").localizedCaseInsensitiveCompare(rhs.group ?? "") == .orderedAscending
            }
        }
    }

    static func dateBounds(for result: QueryResultTable, field: String) -> ClosedRange<Date>? {
        guard let index = result.columns.firstIndex(where: { $0.name == field }) else { return nil }
        let dates = result.rows.compactMap { row in
            row.cells[safe: index].flatMap { $0.isNull ? nil : parsedDate(from: $0.displayValue, sourceType: result.columns[index].type) }
        }
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return first...last
    }

    static func filteredResult(_ result: QueryResultTable, dateFilter: VisualizationDateFilter?) -> QueryResultTable {
        guard let dateFilter else { return result }
        guard let index = result.columns.firstIndex(where: { $0.name == dateFilter.field }) else { return subset(result, rowIDs: []) }
        let rowIDs = result.rows.compactMap { row -> UUID? in
            guard let cell = row.cells[safe: index], !cell.isNull,
                  let date = parsedDate(from: cell.displayValue, sourceType: result.columns[index].type),
                  date >= dateFilter.start && date < dateFilter.end else { return nil }
            return row.id
        }
        return subset(result, rowIDs: Set(rowIDs))
    }

    static func matchingResult(_ result: QueryResultTable, point: VisualizationPlotPoint) -> QueryResultTable {
        subset(result, rowIDs: Set(point.sourceRowIDs))
    }

    private static func subset(_ result: QueryResultTable, rowIDs: Set<UUID>) -> QueryResultTable {
        let offsets = result.rows.indices.filter { rowIDs.contains(result.rows[$0].id) }
        var subset = result
        subset.rows = offsets.map { result.rows[$0] }
        subset.profiles = []
        subset.isExplorerGenerated = false
        subset.generatedMutation = nil
        subset.affectedRowCount = nil
        if let documents = result.documents {
            subset.documents = offsets.compactMap { documents.indices.contains($0) ? documents[$0] : nil }
        }
        subset.executionSummary = L10n.format("Loaded rows: %d / %d", subset.rows.count, result.rows.count)
        return subset
    }

    static func isCompatible(_ preset: SavedVisualizationPreset, with result: QueryResultTable) -> Bool {
        let descriptors = fieldDescriptors(for: result)
        guard descriptors.contains(where: { $0.name == preset.xField }) else { return false }
        let validNumericNames = Set(descriptors.filter(\.supportsNumeric).map(\.name))
        guard !preset.resolvedYFields.isEmpty,
              preset.resolvedYFields.allSatisfy({ validNumericNames.contains($0) }) else { return false }
        if let groupField = preset.groupField,
           !descriptors.contains(where: { $0.name == groupField }) {
            return false
        }
        if let labelField = preset.labelField,
           !descriptors.contains(where: { $0.name == labelField }) {
            return false
        }
        return true
    }

    static func generatedTitle(chartType: VisualizationChartType, xField: String, yFields: [String], source: String?) -> String {
        let yTitle: String
        switch yFields.count {
        case 0:
            yTitle = ""
        case 1:
            yTitle = yFields[0]
        case 2:
            yTitle = yFields.joined(separator: " + ")
        default:
            yTitle = "\(yFields[0]) + \(yFields.count - 1)"
        }
        // The source shows beside the title already; the title says what is measured.
        return xField.isEmpty ? yTitle : L10n.format("%1$@ by %2$@", yTitle, xField)
    }

    static func unlimitedQuery(from sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sql }

        var normalized = trimmed
        var hadSemicolon = false
        if normalized.hasSuffix(";") {
            normalized.removeLast()
            hadSemicolon = true
        }

        normalized = normalized.replacingOccurrences(
            of: #"(?is)\s+OFFSET\s+\d+\s*$"#,
            with: "",
            options: [.regularExpression]
        )
        normalized = normalized.replacingOccurrences(
            of: #"(?is)\s+LIMIT\s+\d+\s*$"#,
            with: "",
            options: [.regularExpression]
        )

        let result = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return hadSemicolon ? result + ";" : result
    }

    static func queryWithoutLimitAndOffset(_ sql: String) -> String {
        unlimitedQuery(from: sql)
    }

    static func queryWithoutTrailingOrderBy(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sql }

        var normalized = trimmed
        var hadSemicolon = false
        if normalized.hasSuffix(";") {
            normalized.removeLast()
            hadSemicolon = true
        }

        normalized = queryWithoutLimitAndOffset(normalized)
        normalized = normalized.replacingOccurrences(
            of: #"(?is)\s+ORDER\s+BY\s+[\s\S]*$"#,
            with: "",
            options: [.regularExpression]
        )

        let result = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return hadSemicolon && !result.isEmpty ? result + ";" : result
    }

    private static func defaultXField(from fields: [VisualizationFieldDescriptor]) -> String {
        if let date = fields.first(where: \.supportsDate) {
            return date.name
        }
        if let category = fields.first(where: { !$0.supportsNumeric }) {
            return category.name
        }
        return fields.first?.name ?? ""
    }

    private static func defaultYField(from fields: [VisualizationFieldDescriptor], excluding xField: String) -> String {
        let candidates = fields.filter { $0.supportsNumeric && $0.name != xField }
        let measures = candidates.filter {
            let name = $0.name.split(separator: ".").last?.lowercased() ?? ""
            return name != "id" && name != "_id" && name != "uuid" && !name.hasSuffix("_id")
        }
        if let metric = measures.first(where: { isNumericSourceType($0.sourceType) }) ?? measures.first ?? candidates.first {
            return metric.name
        }
        return fields.first(where: \.supportsNumeric)?.name ?? fields.first?.name ?? ""
    }

    private static func defaultChartType(for field: VisualizationFieldDescriptor?) -> VisualizationChartType {
        if let field, field.supportsDate || field.supportsNumeric {
            return .line
        }
        return .bar
    }

    private static func preferredXMode(for field: VisualizationFieldDescriptor?) -> VisualizationFieldMode {
        guard let field else { return .category }
        if field.supportsDate {
            return .date
        }
        if field.supportsNumeric {
            return .number
        }
        return .category
    }

    private static func stackedSeriesName(metric: String, group: String?, preset: SavedVisualizationPreset) -> String? {
        if preset.resolvedYFields.count > 1 {
            if let group, !group.isEmpty {
                return "\(metric) • \(group)"
            }
            return metric
        }
        return group
    }

    private static func confidence(hitCount: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(hitCount) / Double(total)
    }

    private static func isNumericSourceType(_ type: String) -> Bool {
        let lowered = type.lowercased()
        return ["int", "integer", "bigint", "smallint", "decimal", "numeric", "double", "float", "real", "serial"].contains {
            lowered.contains($0)
        }
    }

    private static func isDateSourceType(_ type: String) -> Bool {
        let lowered = type.lowercased()
        return ["date", "time", "timestamp", "datetime"].contains { lowered.contains($0) }
    }

    static func parsedNumber(from raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = Double(trimmed) {
            return direct.isFinite ? direct : nil
        }
        guard let value = groupedNumberFormatter.number(from: trimmed)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    // Formatters are thread-safe; building one per value made charting large results slow.
    nonisolated(unsafe) private static let groupedNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func parsedDate(from raw: String, sourceType: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = dateParser.parse(trimmed) { return date }
        if isDateSourceType(sourceType), let number = parsedNumber(from: trimmed) {
            return parsedTimestamp(number)
        }
        if let number = parsedNumber(from: trimmed) {
            return parsedTimestamp(number)
        }
        return nil
    }

    private static func parsedTimestamp(_ number: Double) -> Date? {
        let secondsRange = 946_684_800.0 ... 4_102_444_800.0
        let millisecondsRange = 946_684_800_000.0 ... 4_102_444_800_000.0
        if secondsRange.contains(number) {
            return Date(timeIntervalSince1970: number)
        }
        if millisecondsRange.contains(number) {
            return Date(timeIntervalSince1970: number / 1_000)
        }
        return nil
    }

    private static func format(number: Double) -> String {
        if let integer = Int(exactly: number) {
            return String(integer)
        }
        return String(number)
    }

    private static func makeISO8601Formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    private static func makeChartDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private static func makeTextDateFormatters() -> [DateFormatter] {
        let formats = [
            "yyyy-MM-dd",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy/MM/dd",
            "yyyy/MM/dd HH:mm:ss",
            "MM/dd/yyyy",
            "MM/dd/yyyy HH:mm:ss"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }

    private static let dateParser = DateParser()

    private final class DateParser: @unchecked Sendable {
        private let lock = NSLock()
        private let textFormatters = VisualizationService.makeTextDateFormatters()
        private let fractional = VisualizationService.makeISO8601Formatter(fractional: true)
        private let basic = VisualizationService.makeISO8601Formatter(fractional: false)

        func parse(_ text: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            // ISO parsing comes first so an offset or fractional second is never discarded.
            if let date = fractional.date(from: text) ?? basic.date(from: text) { return date }
            for formatter in textFormatters {
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

import Foundation

enum VisualizationService {
    static func fieldDescriptors(for result: QueryResultTable) -> [VisualizationFieldDescriptor] {
        result.columns.enumerated().map { index, column in
            let values = result.rows.map { $0.values[safe: index] ?? "" }
            let nonEmptyValues = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let sample = nonEmptyValues.first ?? ""
            let distinctCount = Set(nonEmptyValues).count
            let numericHits = nonEmptyValues.filter { parsedNumber(from: $0) != nil }.count
            let dateHits = nonEmptyValues.filter { parsedDate(from: $0, sourceType: column.type) != nil }.count
            let numericByType = isNumericSourceType(column.type)
            let dateByType = isDateSourceType(column.type)
            let supportsNumeric = numericByType || confidence(hitCount: numericHits, total: nonEmptyValues.count) >= 0.75
            let supportsDate = dateByType || confidence(hitCount: dateHits, total: nonEmptyValues.count) >= 0.75

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
        let xField = defaultXField(from: descriptors)
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

    static func chartPoints(for result: QueryResultTable, preset: SavedVisualizationPreset) -> [VisualizationPlotPoint] {
        let fields = fieldDescriptors(for: result)
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

        var buckets: [String: VisualizationPlotPoint] = [:]
        for row in result.rows {
            let rawX = row.values[safe: xIndex]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let xText: String
            let xNumber: Double?
            let xDate: Date?
            switch xMode {
            case .category:
                xText = rawX.isEmpty ? "—" : rawX
                xNumber = nil
                xDate = nil
            case .number:
                guard let number = parsedNumber(from: rawX) else { continue }
                xText = format(number: number)
                xNumber = number
                xDate = nil
            case .date:
                guard let date = parsedDate(from: rawX, sourceType: xSourceType) else { continue }
                xText = makeChartDateFormatter().string(from: date)
                xNumber = nil
                xDate = date
            case .automatic:
                xText = rawX
                xNumber = nil
                xDate = nil
            }

            let group = groupIndex
                .flatMap { row.values[safe: $0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let label = labelIndex
                .flatMap { row.values[safe: $0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }

            for (metricName, yIndex) in yFieldIndexes {
                let rawY = row.values[safe: yIndex]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let yValue = parsedNumber(from: rawY) else { continue }

                let seriesGroup = stackedSeriesName(metric: metricName, group: group, preset: preset)
                let identifierComponents: [String] = [
                    xMode.rawValue,
                    xText,
                    xNumber.map { String($0) } ?? "",
                    xDate.map { String($0.timeIntervalSince1970) } ?? "",
                    seriesGroup ?? "",
                    metricName
                ]
                let identifier = identifierComponents.joined(separator: "|")

                if var existing = buckets[identifier] {
                    existing = VisualizationPlotPoint(
                        id: existing.id,
                        xText: existing.xText,
                        xNumber: existing.xNumber,
                        xDate: existing.xDate,
                        yValue: existing.yValue + yValue,
                        group: existing.group,
                        label: existing.label ?? label,
                        metric: existing.metric
                    )
                    buckets[identifier] = existing
                } else {
                    buckets[identifier] = VisualizationPlotPoint(
                        id: identifier,
                        xText: xText,
                        xNumber: xNumber,
                        xDate: xDate,
                        yValue: yValue,
                        group: seriesGroup,
                        label: label,
                        metric: metricName
                    )
                }
            }
        }

        return buckets.values.sorted { lhs, rhs in
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
        let axisTitle = [yTitle, "by", xField].filter { !$0.isEmpty }.joined(separator: " ")
        if let source, !source.isEmpty {
            return "\(source) • \(chartType.title) • \(axisTitle)"
        }
        return "\(chartType.title) • \(axisTitle)"
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
        if let metric = fields.first(where: { $0.supportsNumeric && $0.name != xField }) {
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
            return direct
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        return formatter.number(from: trimmed)?.doubleValue
    }

    static func parsedDate(from raw: String, sourceType: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for formatter in makeTextDateFormatters() {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        let fractionalFormatter = makeISO8601Formatter(fractional: true)
        let basicFormatter = makeISO8601Formatter(fractional: false)
        if let date = fractionalFormatter.date(from: trimmed) ?? basicFormatter.date(from: trimmed) {
            return date
        }
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
        if number.rounded() == number {
            return String(Int(number))
        }
        return String(format: "%.2f", number)
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

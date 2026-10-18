import Foundation

/// What a chart draws, built from a result off the main thread and remembered per result and setup,
/// so scrolling, resizing, and switching pages never recompute it.
struct ChartRenderData: Sendable {
    var result: QueryResultTable
    var points: [VisualizationPlotPoint]
    var xMode: VisualizationFieldMode
    var dateFields: [VisualizationFieldDescriptor]
    /// Points before small pie slices were combined or dense series thinned.
    var plottedPointCount: Int

    static let empty = ChartRenderData(result: .empty, points: [], xMode: .category, dateFields: [], plottedPointCount: 0)

    /// Line, area, and point series are thinned to this many points, keeping their shape.
    static let maximumSeriesPoints = 600

    static func build(result: QueryResultTable, preset: SavedVisualizationPreset, dateFilter: VisualizationDateFilter?) -> ChartRenderData {
        let fields = VisualizationService.fieldDescriptors(for: result)
        let filtered = VisualizationService.filteredResult(result, dateFilter: dateFilter)
        let xMode = VisualizationService.resolvedXMode(for: preset, fields: fields)
        let points = VisualizationService.chartPoints(for: filtered, preset: preset, fields: fields)
        var drawn = preset.topLimit.map { topLimited(points, limit: $0, xMode: xMode) } ?? points
        if let order = preset.sortOrder, xMode == .category || xMode == .automatic { drawn = sorted(drawn, by: order) }
        if preset.presentation == nil {
            switch preset.chartType {
            // Largest slice first, with "Other" always last whatever its size.
            case .pie, .donut:
                drawn = drawn.filter { $0.yValue > 0 }.sorted { lhs, rhs in
                    isOther(lhs) != isOther(rhs) ? isOther(rhs) : lhs.yValue > rhs.yValue
                }
            case .line, .area, .point: drawn = thinned(drawn, xMode: xMode, limit: maximumSeriesPoints)
            case .bar, .rule: break
            }
        }
        return ChartRenderData(result: filtered, points: drawn, xMode: xMode, dateFields: fields.filter(\.supportsDate),
                               plottedPointCount: points.count)
    }

    static func isOther(_ point: VisualizationPlotPoint) -> Bool { point.id.hasPrefix("portbase.other") }

    /// Orders categories by their total or their label; charts place categories in the order they first
    /// appear. "Other" stays last.
    static func sorted(_ points: [VisualizationPlotPoint], by order: ChartSortOrder) -> [VisualizationPlotPoint] {
        var totals: [String: Double] = [:]
        for point in points { totals[point.xText, default: 0] += point.yValue }
        let other = L10n.text("Other")
        return points.enumerated().sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            if (left.xText == other) != (right.xText == other) { return right.xText == other }
            if left.xText != right.xText {
                switch order {
                case .valueDescending: if totals[left.xText]! != totals[right.xText]! { return totals[left.xText]! > totals[right.xText]! }
                case .valueAscending: if totals[left.xText]! != totals[right.xText]! { return totals[left.xText]! < totals[right.xText]! }
                case .label: break
                }
                return left.xText.localizedStandardCompare(right.xText) == .orderedAscending
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The chart's Top K: with a group field, the K largest series; otherwise the K largest x values.
    /// The rest are summed into "Other" where the x axis has categories; a date or number axis has no
    /// place for "Other", so there the rest are left out.
    static func topLimited(_ points: [VisualizationPlotPoint], limit: Int, xMode: VisualizationFieldMode) -> [VisualizationPlotPoint] {
        guard limit > 0 else { return points }
        if points.contains(where: { $0.group != nil }) { return limitedSeries(points, keep: limit) }
        var totals: [String: Double] = [:]
        for point in points { totals[xKey(point), default: 0] += abs(point.yValue) }
        guard totals.count > limit else { return points }
        let kept = Set(totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key))
        let keptPoints = points.filter { kept.contains(xKey($0)) }
        guard xMode == .category || xMode == .automatic else { return keptPoints }
        var others: [String: VisualizationPlotPoint] = [:]
        var order: [String] = []
        for point in points where !kept.contains(xKey(point)) {
            let metric = point.metric ?? ""
            if others[metric] == nil {
                order.append(metric)
                others[metric] = VisualizationPlotPoint(id: "portbase.other|" + metric, xText: L10n.text("Other"), xNumber: nil, xDate: nil,
                                                        yValue: 0, group: nil, label: nil, metric: point.metric, sourceRowIDs: [])
            }
            others[metric]!.yValue += point.yValue
            others[metric]!.sourceRowIDs += point.sourceRowIDs
        }
        return keptPoints + order.compactMap { others[$0] }
    }

    private static func xKey(_ point: VisualizationPlotPoint) -> String {
        [point.xText, point.xNumber.map { String($0) } ?? "", point.xDate.map { String($0.timeIntervalSince1970) } ?? ""].joined(separator: "\u{1F}")
    }

    /// Keeps the K largest groups and sums the rest into an "Other" series at each x value.
    static func limitedSeries(_ points: [VisualizationPlotPoint], keep limit: Int) -> [VisualizationPlotPoint] {
        var totals: [String: Double] = [:]
        for point in points { if let group = point.group { totals[group, default: 0] += abs(point.yValue) } }
        guard totals.count > limit else { return points }
        let kept = Set(totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key))
        let otherName = L10n.text("Other")
        var result: [VisualizationPlotPoint] = []
        var others: [String: Int] = [:]
        for point in points {
            guard let group = point.group, !kept.contains(group) else { result.append(point); continue }
            let key = xKey(point)
            if let index = others[key] {
                result[index].yValue += point.yValue
                result[index].sourceRowIDs += point.sourceRowIDs
            } else {
                others[key] = result.count
                result.append(VisualizationPlotPoint(id: "portbase.other|" + key, xText: point.xText, xNumber: point.xNumber, xDate: point.xDate,
                                                     yValue: point.yValue, group: otherName, label: nil, metric: point.metric,
                                                     sourceRowIDs: point.sourceRowIDs))
            }
        }
        return result
    }

    /// Thins each series with largest-triangle-three-buckets, which keeps peaks and dips.
    static func thinned(_ points: [VisualizationPlotPoint], xMode: VisualizationFieldMode, limit: Int) -> [VisualizationPlotPoint] {
        let series = Dictionary(grouping: points.indices) { points[$0].group ?? points[$0].metric ?? "" }
        guard series.values.contains(where: { $0.count > limit }) else { return points }
        var kept = Set<Int>()
        for indices in series.values {
            guard indices.count > limit else { kept.formUnion(indices); continue }
            let xs = indices.enumerated().map { offset, index -> Double in
                switch xMode {
                case .date: points[index].xDate?.timeIntervalSince1970 ?? Double(offset)
                case .number: points[index].xNumber ?? Double(offset)
                case .category, .automatic: Double(offset)
                }
            }
            let ys = indices.map { points[$0].yValue }
            kept.formUnion(largestTriangleThreeBuckets(xs: xs, ys: ys, threshold: limit).map { indices[$0] })
        }
        return points.indices.filter(kept.contains).map { points[$0] }
    }

    /// Indexes of the points to keep, always including the first and last.
    static func largestTriangleThreeBuckets(xs: [Double], ys: [Double], threshold: Int) -> [Int] {
        let count = xs.count
        guard threshold >= 3, count > threshold else { return Array(0..<count) }
        var sampled = [0]
        let bucketSize = Double(count - 2) / Double(threshold - 2)
        var anchor = 0
        for bucket in 0..<(threshold - 2) {
            let averageStart = min(Int(Double(bucket + 1) * bucketSize) + 1, count - 1)
            let averageEnd = max(min(Int(Double(bucket + 2) * bucketSize) + 1, count), averageStart + 1)
            var averageX = 0.0, averageY = 0.0
            for index in averageStart..<averageEnd { averageX += xs[index]; averageY += ys[index] }
            averageX /= Double(averageEnd - averageStart)
            averageY /= Double(averageEnd - averageStart)

            let rangeStart = Int(Double(bucket) * bucketSize) + 1
            let rangeEnd = max(min(Int(Double(bucket + 1) * bucketSize) + 1, count - 1), rangeStart + 1)
            var largest = -1.0
            var chosen = rangeStart
            for index in rangeStart..<rangeEnd {
                let area = abs((xs[anchor] - averageX) * (ys[index] - ys[anchor]) - (xs[anchor] - xs[index]) * (averageY - ys[anchor]))
                if area > largest { largest = area; chosen = index }
            }
            sampled.append(chosen)
            anchor = chosen
        }
        sampled.append(count - 1)
        return sampled
    }
}

/// Identifies one rendering: a particular result with a particular chart setup and filter.
struct ChartRenderKey: Hashable, Sendable {
    let result: String
    let chartType: VisualizationChartType
    let xField: String
    let yFields: [String]
    let groupField: String?
    let labelField: String?
    let xAxisMode: VisualizationFieldMode
    let topLimit: Int?
    let presentation: ChartPresentation?
    let sortOrder: ChartSortOrder?
    let dateFilter: VisualizationDateFilter?

    init(result: QueryResultTable, preset: SavedVisualizationPreset, dateFilter: VisualizationDateFilter?) {
        self.result = result.chartFingerprint
        chartType = preset.chartType
        xField = preset.xField
        yFields = preset.resolvedYFields
        groupField = preset.groupField
        labelField = preset.labelField
        xAxisMode = preset.xAxisMode
        topLimit = preset.topLimit
        presentation = preset.presentation
        sortOrder = preset.sortOrder
        self.dateFilter = dateFilter
    }
}

/// Remembers recent renderings so a chart that reappears draws immediately.
@MainActor final class ChartRenderStore {
    static let shared = ChartRenderStore()
    private var entries: [ChartRenderKey: ChartRenderData] = [:]
    private var order: [ChartRenderKey] = []
    private let capacity = 48

    func cached(_ key: ChartRenderKey) -> ChartRenderData? { entries[key] }

    func render(_ key: ChartRenderKey, result: QueryResultTable, preset: SavedVisualizationPreset,
                dateFilter: VisualizationDateFilter?) async -> ChartRenderData {
        if let cached = entries[key] { return cached }
        let data = await Task.detached(priority: .userInitiated) {
            ChartRenderData.build(result: result, preset: preset, dateFilter: dateFilter)
        }.value
        entries[key] = data
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > capacity { entries[order.removeFirst()] = nil }
        return data
    }
}

extension QueryResultTable {
    /// A cheap identity for a result: its shape plus its first and last rows. Rows get fresh IDs
    /// whenever a result is fetched or decoded, so a new fetch never matches an old one.
    var chartFingerprint: String {
        var hasher = Hasher()
        hasher.combine(rows.first?.cells)
        hasher.combine(rows.last?.cells)
        return [String(rows.count), rows.first?.id.uuidString ?? "", rows.last?.id.uuidString ?? "",
                String(hasher.finalize()), columns.map(\.name).joined(separator: "\u{1F}")].joined(separator: "|")
    }
}

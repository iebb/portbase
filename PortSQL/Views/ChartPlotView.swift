import Charts
import SwiftUI

/// Series colors shared by every chart, ordered so neighbors contrast.
enum ChartPalette {
    static let colors: [Color] = [
        PortSQLPalette.accent,
        Color(hex: 0x3B82F6), Color(hex: 0xF59E0B), Color(hex: 0xEC4899), Color(hex: 0x8B5CF6),
        Color(hex: 0x14B8A6), Color(hex: 0xEF4444), Color(hex: 0x84CC16), Color(hex: 0x0EA5E9),
    ]
    static let other = Color(hex: 0x9CA3AF)
}

struct VisualizationChartPlot: View {
    let preset: SavedVisualizationPreset
    let points: [VisualizationPlotPoint]
    let xMode: VisualizationFieldMode
    var compact: Bool
    var selectedPointID: String?
    var onSelect: ((VisualizationPlotPoint) -> Void)?
    /// A fixed height, or nil to fill the space offered, as dashboard tiles do.
    var height: CGFloat? = 300

    private var selectedPoint: VisualizationPlotPoint? { points.first { $0.id == selectedPointID } }
    private var groupLabel: String { L10n.text("Group") }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            switch preset.chartType {
            case .pie, .donut: sectorChart
            default: cartesianChart
            }
            if preset.showsLegend, !legend.isEmpty { legendRow }
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
    }

    // MARK: Legend

    private struct LegendEntry: Identifiable {
        let name: String
        let color: Color
        var detail: String?
        var id: String { name }
    }

    /// Series in order of size, "Other" last, each with its fixed color.
    private var seriesDomain: [String] {
        var totals: [String: Double] = [:]
        for point in points { if let group = point.group { totals[group, default: 0] += abs(point.yValue) } }
        let other = L10n.text("Other")
        return totals.keys.sorted { lhs, rhs in
            if (lhs == other) != (rhs == other) { return rhs == other }
            return totals[lhs]! == totals[rhs]! ? lhs < rhs : totals[lhs]! > totals[rhs]!
        }
    }

    private func seriesColors(_ domain: [String]) -> [Color] {
        let other = L10n.text("Other")
        return domain.enumerated().map { $1 == other ? ChartPalette.other : ChartPalette.colors[$0 % ChartPalette.colors.count] }
    }

    private var legend: [LegendEntry] {
        switch preset.chartType {
        case .pie, .donut:
            let total = points.reduce(0) { $0 + $1.yValue }
            return zip(points.map(sectorTitle), sectorColors).enumerated().map { index, entry in
                LegendEntry(name: entry.0, color: entry.1,
                            detail: total > 0 ? (points[index].yValue / total).formatted(.percent.precision(.fractionLength(0))) : nil)
            }
        default:
            let domain = seriesDomain
            return zip(domain, seriesColors(domain)).map { LegendEntry(name: $0, color: $1) }
        }
    }

    /// One scrolling line, however many series there are.
    private var legendRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.m) {
                ForEach(legend) { entry in
                    HStack(spacing: Spacing.xxs) {
                        Circle().fill(entry.color).frame(width: 7, height: 7)
                        Text(entry.name).foregroundStyle(PortSQLPalette.ink)
                        if let detail = entry.detail { Text(detail).foregroundStyle(PortSQLPalette.muted).monospacedDigit() }
                    }
                    .font(.microText)
                    .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Cartesian charts

    private var cartesianChart: some View {
        Chart {
            switch xMode {
            case .date: marks { $0.xDate }
            case .number: marks { $0.xNumber }
            case .category, .automatic: marks { $0.xText }
            }
            selectionMark
        }
        .chartForegroundStyleScale(domain: seriesDomain, range: seriesColors(seriesDomain))
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: compact ? 4 : 6)) { _ in
                AxisValueLabel().font(.microText).foregroundStyle(PortSQLPalette.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: compact ? 3 : 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(PortSQLPalette.stroke)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number, format: .number.notation(.compactName)).font(.microText).foregroundStyle(PortSQLPalette.muted)
                    }
                }
            }
        }
        .chartXAxisLabel(compact ? "" : preset.xAxisTitle)
        .chartYAxisLabel(compact ? "" : preset.yAxisTitle)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let plotFrame = geometry[frame]
                        guard plotFrame.contains(location) else { return }
                        selectPoint(at: CGPoint(x: location.x - plotFrame.minX, y: location.y - plotFrame.minY), proxy: proxy)
                    }
                    .allowsHitTesting(onSelect != nil)
                    .accessibilityHidden(true)
            }
        }
    }

    @ChartContentBuilder
    private func marks<X: Plottable>(_ x: @escaping (VisualizationPlotPoint) -> X?) -> some ChartContent {
        ForEach(points) { point in
            if let value = x(point) {
                mark(point, x: .value(preset.xAxisTitle, value))
            }
        }
    }

    @ChartContentBuilder
    private func mark<X: Plottable>(_ point: VisualizationPlotPoint, x: PlottableValue<X>) -> some ChartContent {
        let y = PlottableValue.value(preset.yAxisTitle, point.yValue)
        let dimmed = selectedPointID != nil && selectedPointID != point.id
        switch preset.chartType {
        case .line:
            if let group = point.group {
                LineMark(x: x, y: y, series: .value(groupLabel, group))
                    .foregroundStyle(by: .value(groupLabel, group))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else {
                AreaMark(x: x, y: y)
                    .foregroundStyle(areaFill)
                    .interpolationMethod(.monotone)
                LineMark(x: x, y: y)
                    .foregroundStyle(PortSQLPalette.accent)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            if points.count <= 24 || point.id == selectedPointID {
                PointMark(x: x, y: y)
                    .seriesStyle(point.group, label: groupLabel, fallback: PortSQLPalette.accent)
                    .symbolSize(point.id == selectedPointID ? 60 : 22)
                    .labeled(annotationText(for: point))
            }
        case .area:
            if let group = point.group {
                AreaMark(x: x, y: y)
                    .foregroundStyle(by: .value(groupLabel, group))
                    .interpolationMethod(.monotone)
                    .opacity(0.85)
                    .labeled(annotationText(for: point))
            } else {
                // A single area reads best as a filled band with its edge drawn.
                AreaMark(x: x, y: y)
                    .foregroundStyle(LinearGradient(colors: [PortSQLPalette.accent.opacity(0.5), PortSQLPalette.accent.opacity(0.06)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                    .labeled(annotationText(for: point))
                LineMark(x: x, y: y)
                    .foregroundStyle(PortSQLPalette.accent)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        case .point:
            PointMark(x: x, y: y)
                .seriesStyle(point.group, label: groupLabel, fallback: PortSQLPalette.accent)
                .symbolSize(point.id == selectedPointID ? 70 : 30)
                .opacity(dimmed ? 0.4 : 0.9)
                .labeled(annotationText(for: point))
        case .rule:
            RuleMark(y: y)
                .seriesStyle(point.group, label: groupLabel, fallback: PortSQLPalette.accent)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .annotation(position: .trailing, alignment: .leading) { annotation(point.label ?? point.xText) }
        case .bar, .pie, .donut:
            BarMark(x: x, y: y)
                .seriesStyle(point.group, label: groupLabel, fallback: barFill)
                .cornerRadius(compact ? 3 : 4)
                .opacity(dimmed ? 0.45 : 1)
                .labeled(annotationText(for: point))
        }
    }

    @ChartContentBuilder
    private var selectionMark: some ChartContent {
        if let point = selectedPoint, preset.chartType != .bar {
            if preset.chartType == .rule {
                RuleMark(y: .value(preset.yAxisTitle, point.yValue))
                    .foregroundStyle(PortSQLPalette.muted).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            } else if let date = point.xDate {
                RuleMark(x: .value(preset.xAxisTitle, date))
                    .foregroundStyle(PortSQLPalette.muted).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            } else if let number = point.xNumber {
                RuleMark(x: .value(preset.xAxisTitle, number))
                    .foregroundStyle(PortSQLPalette.muted).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            } else {
                RuleMark(x: .value(preset.xAxisTitle, point.xText))
                    .foregroundStyle(PortSQLPalette.muted).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
    }

    private var barFill: LinearGradient {
        LinearGradient(colors: [PortSQLPalette.accent, PortSQLPalette.accent.opacity(0.72)], startPoint: .top, endPoint: .bottom)
    }

    private var areaFill: LinearGradient {
        LinearGradient(colors: [PortSQLPalette.accent.opacity(0.32), PortSQLPalette.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom)
    }

    // MARK: Pie and donut

    private var sectorChart: some View {
        let total = points.reduce(0) { $0 + $1.yValue }
        let titles = points.map(sectorTitle)
        let colors = sectorColors
        let donut = preset.chartType == .donut
        return Chart(points) { point in
            SectorMark(
                angle: .value(preset.yAxisTitle, point.yValue),
                innerRadius: .ratio(donut ? 0.62 : 0),
                outerRadius: .ratio(point.id == selectedPointID ? 1 : 0.96),
                angularInset: points.count > 1 ? 1 : 0
            )
            .cornerRadius(donut ? 3 : 2)
            .foregroundStyle(by: .value(L10n.text("Category"), sectorTitle(for: point)))
            .opacity(selectedPointID == nil || selectedPointID == point.id ? 1 : 0.4)
            .annotation(position: .overlay) {
                if total > 0, point.yValue / total >= 0.08 {
                    Text((point.yValue / total).formatted(.percent.precision(.fractionLength(0))))
                        .font(.badgeText)
                        .foregroundStyle(.white)
                }
            }
        }
        .chartForegroundStyleScale(domain: titles, range: colors)
        .chartLegend(.hidden)
        // Selection follows clicks and taps only. The built-in angle selection tracks the pointer on the
        // Mac, which re-selected (and toggled) the slice under the mouse as it moved.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame, total > 0 else { return }
                        if let point = sector(at: location, in: geometry[frame], total: total, donut: donut) { onSelect?(point) }
                    }
                    .allowsHitTesting(onSelect != nil)
                    .accessibilityHidden(true)
            }
        }
        .chartBackground { proxy in
            GeometryReader { geometry in
                if donut, let frame = proxy.plotFrame {
                    let plot = geometry[frame]
                    VStack(spacing: Spacing.xxxs) {
                        Text(selectedPoint.map(sectorTitle) ?? L10n.text("Total"))
                            .font(.microText)
                            .foregroundStyle(PortSQLPalette.muted)
                            .lineLimit(1)
                        Text(selectedPoint?.yValue ?? total, format: .number.notation(.compactName))
                            .font(.cardTitle.weight(.bold))
                            .foregroundStyle(PortSQLPalette.ink)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: plot.width * 0.5)
                    .position(x: plot.midX, y: plot.midY)
                }
            }
        }
    }

    /// The slice under a point in the plot: its angle clockwise from twelve o'clock, inside the ring.
    private func sector(at location: CGPoint, in plot: CGRect, total: Double, donut: Bool) -> VisualizationPlotPoint? {
        let radius = min(plot.width, plot.height) / 2
        let dx = location.x - plot.midX, dy = location.y - plot.midY
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance <= radius, !donut || distance >= radius * 0.55 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let value = angle / (2 * .pi) * total
        var running: Double = 0
        for point in points {
            running += point.yValue
            if value <= running { return point }
        }
        return points.last
    }

    private var sectorColors: [Color] {
        points.enumerated().map { index, point in
            point.id == "portbase.other" ? ChartPalette.other : ChartPalette.colors[index % ChartPalette.colors.count]
        }
    }

    // MARK: Selection

    private func selectPoint(at location: CGPoint, proxy: ChartProxy) {
        guard onSelect != nil else { return }
        if preset.chartType == .rule {
            if let point = points.min(by: {
                abs((proxy.position(forY: $0.yValue) ?? 0) - location.y) < abs((proxy.position(forY: $1.yValue) ?? 0) - location.y)
            }) { onSelect?(point) }
            return
        }
        let positioned = points.compactMap { point -> (VisualizationPlotPoint, CGFloat)? in
            let x: CGFloat?
            switch xMode {
            case .date: x = point.xDate.flatMap { proxy.position(forX: $0) }
            case .number: x = point.xNumber.flatMap { proxy.position(forX: $0) }
            case .category, .automatic: x = proxy.position(forX: point.xText)
            }
            return x.map { (point, $0) }
        }
        guard let nearestX = positioned.min(by: { abs($0.1 - location.x) < abs($1.1 - location.x) })?.1 else { return }
        let candidates = positioned.filter { abs($0.1 - nearestX) < 1 }.map(\.0)
        let stacked = preset.chartType == .bar || preset.chartType == .area
        var positive: Double = 0
        var negative: Double = 0
        var nearest: (VisualizationPlotPoint, CGFloat)?
        for point in candidates {
            let start = stacked ? (point.yValue >= 0 ? positive : negative) : point.yValue
            let end = stacked ? start + point.yValue : point.yValue
            if point.yValue >= 0 { positive = end } else { negative = end }
            guard let yStart = proxy.position(forY: start), let yEnd = proxy.position(forY: end) else { continue }
            let low = min(yStart, yEnd), high = max(yStart, yEnd)
            let distance = location.y < low ? low - location.y : (location.y > high ? location.y - high : 0)
            if nearest == nil || distance < nearest!.1 { nearest = (point, distance) }
        }
        if let point = nearest?.0 { onSelect?(point) }
    }

    // MARK: Labels

    private var shouldAnnotate: Bool {
        preset.labelField != nil && points.count <= (compact ? 8 : 12)
    }

    private func annotationText(for point: VisualizationPlotPoint) -> String? {
        guard shouldAnnotate else { return nil }
        let text = (point.label ?? point.xText).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func sectorTitle(for point: VisualizationPlotPoint) -> String {
        if let group = point.group { return "\(group) • \(point.xText)" }
        return point.xText
    }

    private func annotation(_ text: String) -> some View {
        Text(text).font(.badgeText).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
    }
}

private extension ChartContent {
    /// Colors a mark by its series when it has one, or with the single-series style.
    @ChartContentBuilder
    func seriesStyle<S: ShapeStyle>(_ group: String?, label: String, fallback: S) -> some ChartContent {
        if let group {
            foregroundStyle(by: .value(label, group))
        } else {
            foregroundStyle(fallback)
        }
    }

    @ChartContentBuilder
    func labeled(_ text: String?) -> some ChartContent {
        if let text {
            annotation(position: .top) {
                Text(text).font(.badgeText).foregroundStyle(PortSQLPalette.ink).lineLimit(1)
            }
        } else {
            self
        }
    }
}

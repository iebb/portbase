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
    /// Bars drawn sideways, with categories down the side and values along the bottom.
    private var horizontalBars: Bool { preset.chartType == .bar && preset.isHorizontal }

    var body: some View {
        Group {
            if preset.showsLegend, !legend.isEmpty, preset.legendPosition == .right {
                // Beside the plot, the legend lists every entry in a column that scrolls when it's long.
                HStack(alignment: .top, spacing: Spacing.m) {
                    plot
                    legendColumn
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    plot
                    if preset.showsLegend, !legend.isEmpty { legendRow }
                }
            }
        }
        .frame(height: height)
        .frame(maxHeight: height == nil ? .infinity : nil)
    }

    @ViewBuilder private var plot: some View {
        switch preset.chartType {
        case .pie, .donut: sectorChart
        default: cartesianChart
        }
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

    private var legendColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(legend) { entry in
                    HStack(spacing: Spacing.xxs) {
                        Circle().fill(entry.color).frame(width: 7, height: 7)
                        Text(entry.name).foregroundStyle(PortSQLPalette.ink).truncationMode(.middle)
                        if let detail = entry.detail {
                            Spacer(minLength: Spacing.xxs)
                            Text(detail).foregroundStyle(PortSQLPalette.muted).monospacedDigit()
                        }
                    }
                    .font(.microText)
                    .lineLimit(1)
                }
            }
            .padding(.vertical, Spacing.xxs)
        }
        .frame(minWidth: 80, idealWidth: 140, maxWidth: 180, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: false)
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
            if horizontalBars { valueAxis(position: .bottom, desiredCount: compact ? 4 : 6) } else { categoryAxis(position: .bottom) }
        }
        .chartYAxis {
            if horizontalBars { categoryAxis(position: .leading) } else { valueAxis(position: .leading, desiredCount: compact ? 3 : 5) }
        }
        .chartXAxisLabel(compact ? "" : (horizontalBars ? preset.yAxisTitle : preset.xAxisTitle))
        .chartYAxisLabel(compact ? "" : (horizontalBars ? preset.xAxisTitle : preset.yAxisTitle))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let frame = proxy.plotFrame {
                    let plot = geometry[frame]
                    ChartInteractionLayer(
                        plot: plot,
                        pointAt: { location in nearestPoint(at: CGPoint(x: location.x - plot.minX, y: location.y - plot.minY), proxy: proxy) },
                        anchor: { point in anchor(for: point, proxy: proxy).map { CGPoint(x: $0.x + plot.minX, y: $0.y + plot.minY) } },
                        title: pointTitle,
                        value: valueText,
                        onSelect: onSelect
                    )
                }
            }
        }
    }

    private func valueAxis(position: AxisMarkPosition, desiredCount: Int) -> some AxisContent {
        AxisMarks(position: position, values: .automatic(desiredCount: desiredCount)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(PortSQLPalette.stroke)
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    if preset.barLayout == .normalized && preset.chartType == .bar {
                        // 100% stacks run from 0 to 100.
                        Text(verbatim: number.formatted(.number.precision(.fractionLength(0))) + "%")
                            .font(.microText).foregroundStyle(PortSQLPalette.muted)
                    } else {
                        Text(number, format: .number.notation(.compactName))
                            .font(.microText).foregroundStyle(PortSQLPalette.muted)
                    }
                }
            }
        }
    }

    private func categoryAxis(position: AxisMarkPosition) -> some AxisContent {
        // Sideways bars have room for every category name down the side.
        AxisMarks(position: position, values: .automatic(desiredCount: horizontalBars ? nil : (compact ? 4 : 6))) { _ in
            AxisValueLabel().font(.microText).foregroundStyle(PortSQLPalette.muted)
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
                    .labeled(labelText(for: point))
            }
        case .area:
            if let group = point.group {
                AreaMark(x: x, y: y)
                    .foregroundStyle(by: .value(groupLabel, group))
                    .interpolationMethod(.monotone)
                    .opacity(0.85)
                    .labeled(labelText(for: point))
            } else {
                // A single area reads best as a filled band with its edge drawn.
                AreaMark(x: x, y: y)
                    .foregroundStyle(LinearGradient(colors: [PortSQLPalette.accent.opacity(0.5), PortSQLPalette.accent.opacity(0.06)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                    .labeled(labelText(for: point))
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
                .labeled(labelText(for: point))
        case .rule:
            RuleMark(y: y)
                .seriesStyle(point.group, label: groupLabel, fallback: PortSQLPalette.accent)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .annotation(position: .trailing, alignment: .leading) { annotation(point.label ?? point.xText) }
        case .bar, .pie, .donut:
            barMark(point, x: x, y: y, dimmed: dimmed)
        }
    }

    @ChartContentBuilder
    private func barMark<X: Plottable>(_ point: VisualizationPlotPoint, x: PlottableValue<X>, y: PlottableValue<Double>, dimmed: Bool) -> some ChartContent {
        let stacking: MarkStackingMethod = preset.barLayout == .normalized ? .normalized : .standard
        let sideBySide = preset.barLayout == .grouped ? point.group : nil
        // Stacked series have no room above each piece, so their values sit inside it.
        let inside = point.group != nil && preset.barLayout != .grouped
        if horizontalBars {
            BarMark(x: y, y: x, stacking: stacking)
                .seriesStyle(point.group, label: groupLabel, fallback: barFill)
                .positioned(by: sideBySide, label: groupLabel)
                .cornerRadius(compact ? 3 : 4)
                .opacity(dimmed ? 0.45 : 1)
                .labeled(labelText(for: point), position: inside ? .overlay : .trailing, inverse: inside)
        } else {
            BarMark(x: x, y: y, stacking: stacking)
                .seriesStyle(point.group, label: groupLabel, fallback: barFill)
                .positioned(by: sideBySide, label: groupLabel)
                .cornerRadius(compact ? 3 : 4)
                .opacity(dimmed ? 0.45 : 1)
                .labeled(labelText(for: point), position: inside ? .overlay : .top, inverse: inside)
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
                if let frame = proxy.plotFrame, total > 0 {
                    let plot = geometry[frame]
                    ChartInteractionLayer(
                        plot: plot,
                        pointAt: { sector(at: $0, in: plot, total: total, donut: donut) },
                        anchor: { sectorAnchor(for: $0, in: plot, total: total, donut: donut) },
                        title: sectorTitle,
                        value: { point in valueText(point) + "  " + (point.yValue / total).formatted(.percent.precision(.fractionLength(0...1))) },
                        onSelect: onSelect
                    )
                }
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

    /// The middle of a slice's ring, where its tooltip points.
    private func sectorAnchor(for point: VisualizationPlotPoint, in plot: CGRect, total: Double, donut: Bool) -> CGPoint? {
        guard let index = points.firstIndex(where: { $0.id == point.id }) else { return nil }
        let before = points[..<index].reduce(0) { $0 + $1.yValue }
        let angle = (before + point.yValue / 2) / total * 2 * .pi
        let radius = min(plot.width, plot.height) / 2 * (donut ? 0.81 : 0.6)
        return CGPoint(x: plot.midX + sin(angle) * radius, y: plot.midY - cos(angle) * radius)
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
            ChartRenderData.isOther(point) ? ChartPalette.other : ChartPalette.colors[index % ChartPalette.colors.count]
        }
    }

    // MARK: Selection

    /// The point under a location in the plot: the nearest category or date, then the series whose
    /// piece of a stack, line, or dot is closest along the value axis.
    private func nearestPoint(at location: CGPoint, proxy: ChartProxy) -> VisualizationPlotPoint? {
        if preset.chartType == .rule {
            return points.min(by: {
                abs((proxy.position(forY: $0.yValue) ?? 0) - location.y) < abs((proxy.position(forY: $1.yValue) ?? 0) - location.y)
            })
        }
        let along = horizontalBars ? location.y : location.x
        let across = horizontalBars ? location.x : location.y
        let positioned = points.compactMap { point in categoryPosition(of: point, proxy: proxy).map { (point, $0) } }
        guard let nearest = positioned.min(by: { abs($0.1 - along) < abs($1.1 - along) })?.1 else { return nil }
        let candidates = positioned.filter { abs($0.1 - nearest) < 1 }.map(\.0)
        var best: (VisualizationPlotPoint, CGFloat)?
        for (point, range) in valueRanges(candidates) {
            guard let start = valuePosition(range.lowerBound, proxy: proxy), let end = valuePosition(range.upperBound, proxy: proxy) else { continue }
            let low = min(start, end), high = max(start, end)
            let distance = across < low ? low - across : (across > high ? across - high : 0)
            if best == nil || distance < best!.1 { best = (point, distance) }
        }
        return best?.0
    }

    /// Where a hovered point's tooltip points: the end of its bar or stack piece, or the point itself.
    private func anchor(for point: VisualizationPlotPoint, proxy: ChartProxy) -> CGPoint? {
        guard let category = categoryPosition(of: point, proxy: proxy) else { return nil }
        let sameCategory = points.filter { categoryPosition(of: $0, proxy: proxy).map { abs($0 - category) < 1 } ?? false }
        guard let range = valueRanges(sameCategory).first(where: { $0.0.id == point.id })?.1,
              let value = valuePosition(range.upperBound, proxy: proxy) else { return nil }
        return horizontalBars ? CGPoint(x: value, y: category) : CGPoint(x: category, y: value)
    }

    private func categoryPosition(of point: VisualizationPlotPoint, proxy: ChartProxy) -> CGFloat? {
        if horizontalBars { return proxy.position(forY: point.xText) }
        switch xMode {
        case .date: return point.xDate.flatMap { proxy.position(forX: $0) }
        case .number: return point.xNumber.flatMap { proxy.position(forX: $0) }
        case .category, .automatic: return proxy.position(forX: point.xText)
        }
    }

    private func valuePosition(_ value: Double, proxy: ChartProxy) -> CGFloat? {
        horizontalBars ? proxy.position(forX: value) : proxy.position(forY: value)
    }

    /// Each point's span along the value axis within its category: stacked pieces follow one another,
    /// as Swift Charts stacks them; 100% stacks are shares of the category's total, from 0 to 100.
    private func valueRanges(_ candidates: [VisualizationPlotPoint]) -> [(VisualizationPlotPoint, ClosedRange<Double>)] {
        let stacked = (preset.chartType == .bar && preset.barLayout != .grouped) || (preset.chartType == .area && candidates.contains { $0.group != nil })
        guard stacked else { return candidates.map { ($0, min(0, $0.yValue)...max(0, $0.yValue)) } }
        let total = candidates.reduce(0) { $0 + abs($1.yValue) }
        let scale = preset.chartType == .bar && preset.barLayout == .normalized && total > 0 ? 100 / total : 1
        var positive: Double = 0, negative: Double = 0
        return candidates.map { point in
            let value = point.yValue * scale
            let start = value >= 0 ? positive : negative
            let end = start + value
            if value >= 0 { positive = end } else { negative = end }
            return (point, min(start, end)...max(start, end))
        }
    }

    private func pointTitle(_ point: VisualizationPlotPoint) -> String {
        [point.xText, point.group ?? (preset.resolvedYFields.count > 1 ? point.metric : nil)].compactMap { $0 }.joined(separator: " · ")
    }

    private func valueText(_ point: VisualizationPlotPoint) -> String {
        point.yValue.formatted(.number.precision(.significantDigits(1...10)))
    }

    // MARK: Labels

    private var shouldAnnotate: Bool {
        preset.labelField != nil && points.count <= (compact ? 8 : 12)
    }

    /// The label drawn on a mark: its value when the chart shows values, otherwise its label field.
    private func labelText(for point: VisualizationPlotPoint) -> String? {
        if preset.showsValues { return point.yValue.formatted(.number.notation(.compactName)) }
        return annotationText(for: point)
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
    func labeled(_ text: String?, position: AnnotationPosition = .top, inverse: Bool = false) -> some ChartContent {
        if let text {
            annotation(position: position, spacing: 2) {
                Text(text).font(.badgeText).foregroundStyle(inverse ? Color.white : PortSQLPalette.ink).lineLimit(1)
            }
        } else {
            self
        }
    }

    /// Places series side by side within a category instead of stacking them.
    @ChartContentBuilder
    func positioned(by group: String?, label: String) -> some ChartContent {
        if let group {
            position(by: .value(label, group))
        } else {
            self
        }
    }
}

/// Clicks select a point; hovering with a pointer shows its value in a bubble. The hover state lives
/// here, apart from the chart, so moving the pointer redraws only the bubble, and only when the point
/// under it changes.
private struct ChartInteractionLayer: View {
    let plot: CGRect
    let pointAt: (CGPoint) -> VisualizationPlotPoint?
    let anchor: (VisualizationPlotPoint) -> CGPoint?
    let title: (VisualizationPlotPoint) -> String
    let value: (VisualizationPlotPoint) -> String
    let onSelect: ((VisualizationPlotPoint) -> Void)?
    @State private var hovered: VisualizationPlotPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard plot.contains(location), let point = pointAt(location) else { return }
                        onSelect?(point)
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let point = plot.contains(location) ? pointAt(location) : nil
                            if point?.id != hovered?.id { hovered = point }
                        case .ended:
                            hovered = nil
                        }
                    }
                if let hovered, let point = anchor(hovered) {
                    bubble(hovered)
                        .fixedSize()
                        .position(x: min(max(point.x, 70), geometry.size.width - 70), y: max(point.y - 26, 18))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func bubble(_ point: VisualizationPlotPoint) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title(point)).font(.microText).foregroundStyle(PortSQLPalette.muted).lineLimit(1)
            Text(value(point)).font(.captionStrong).monospacedDigit().foregroundStyle(PortSQLPalette.ink)
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xxs)
        .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(PortSQLPalette.stroke) }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

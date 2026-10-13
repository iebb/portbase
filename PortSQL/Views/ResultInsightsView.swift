import Charts
import SwiftUI

/// Column statistics for the loaded rows of a result.
struct ResultInsightsView: View {
    let result: QueryResultTable
    @State private var insights = ResultInsights.empty
    @State private var isComputing = true
    @State private var filter = ""

    private var visibleColumns: [ColumnInsight] {
        filter.isEmpty ? insights.columns : insights.columns.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            if isComputing {
                LoadingStateView(title: L10n.text("Analyzing results"), message: L10n.text("Summarizing loaded rows."))
            } else if insights.columns.isEmpty {
                Text("Run a query to see column insights.")
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                summary
                if insights.columns.count > 6 {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter columns", text: $filter)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .portbaseTextCapitalization(.never)
                    }
                    .padding(.horizontal, Spacing.m)
                    .frame(minHeight: Sizes.control)
                    .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Spacing.m)], alignment: .leading, spacing: Spacing.m) {
                    ForEach(visibleColumns) { column in
                        ColumnInsightCard(column: column)
                    }
                }
                Text("Statistics describe loaded rows only. They do not query the database again.")
                    .font(.captionText)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: result) {
            isComputing = true
            let snapshot = result
            let computed = await Task.detached(priority: .userInitiated) { ResultInsightsService.insights(for: snapshot) }.value
            guard !Task.isCancelled else { return }
            insights = computed
            isComputing = false
        }
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.s)], spacing: Spacing.s) {
            PortbaseMetricTile(title: L10n.text("Loaded rows"), value: insights.rowCount.formatted(), systemImage: "list.number",
                               tint: Color(hex: 0x6366F1), footnote: result.isTruncated == true ? L10n.text("Result truncated") : nil)
            PortbaseMetricTile(title: L10n.text("Columns"), value: insights.columns.count.formatted(), systemImage: "tablecells", tint: Color(hex: 0x0EA5E9))
            PortbaseMetricTile(title: L10n.text("Completeness"), value: insights.completeness.formatted(.percent.precision(.fractionLength(0...1))),
                               systemImage: "checkmark.circle.fill", tint: Color(hex: 0x10B981), footnote: L10n.text("Non-NULL cells"))
            PortbaseMetricTile(title: L10n.text("Numeric columns"), value: insights.numericColumnCount.formatted(), systemImage: "number",
                               tint: Color(hex: 0xF97316))
        }
    }
}

private struct ColumnInsightCard: View {
    let column: ColumnInsight

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(.rowDetail)
                    .foregroundStyle(tint)
                    .frame(width: Sizes.iconBadge, height: Sizes.iconBadge)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(column.name).font(.rowTitle).lineLimit(1)
                    Text(column.type.isEmpty ? kindTitle : column.type)
                        .font(.codeCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if column.isUnique {
                    PortbaseChip(title: L10n.text("Unique"), systemImage: "key.fill", tint: PortSQLPalette.accent)
                }
            }

            HStack(spacing: Spacing.m) {
                stat(L10n.text("Distinct"), column.distinctCount.formatted())
                stat("NULL", column.nullRatio.formatted(.percent.precision(.fractionLength(0...1))))
                if column.emptyTextCount > 0 { stat(L10n.text("Empty"), column.emptyTextCount.formatted()) }
            }

            ProgressView(value: 1 - column.nullRatio)
                .tint(column.nullRatio > 0.5 ? .orange : .green)
                .accessibilityLabel("Filled values")
                .accessibilityValue((1 - column.nullRatio).formatted(.percent.precision(.fractionLength(0))))

            if let numeric = column.numeric {
                HStack(spacing: Spacing.m) {
                    stat(L10n.text("Min"), format(numeric.minimum))
                    stat(L10n.text("Median"), format(numeric.median))
                    stat(L10n.text("Mean"), format(numeric.mean))
                    stat(L10n.text("Max"), format(numeric.maximum))
                }
                Chart(numeric.bins) { bin in
                    BarMark(x: .value("Range", bin.id), y: .value("Rows", bin.count))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .bottom, endPoint: .top))
                        .cornerRadius(3)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 64)
                .accessibilityLabel("Value distribution")
            } else if let earliest = column.earliest, let latest = column.latest {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Label(earliest, systemImage: "arrow.down.to.line").lineLimit(1)
                    Label(latest, systemImage: "arrow.up.to.line").lineLimit(1)
                }
                .font(.codeCaption)
                .foregroundStyle(.secondary)
            }

            if column.numeric == nil, !column.topValues.isEmpty, column.distinctCount < column.rowCount {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Most frequent").font(.captionStrong).foregroundStyle(.secondary)
                    let peak = max(1, column.topValues.first?.count ?? 1)
                    ForEach(column.topValues) { value in
                        HStack(spacing: Spacing.s) {
                            Text(value.value.isEmpty ? "\"\"" : value.value)
                                .font(.codeCaption)
                                .lineLimit(1)
                                .frame(maxWidth: 120, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule().fill(tint.opacity(0.75))
                                    .frame(width: max(4, proxy.size.width * CGFloat(value.count) / CGFloat(peak)))
                            }
                            .frame(height: 6)
                            Text(value.count.formatted()).font(.microText.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .portbaseCardSurface()
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(title).font(.badgeText).foregroundStyle(.secondary)
            Text(value).font(.rowTitle.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return Int64(value).formatted() }
        return value.formatted(.number.precision(.significantDigits(1...6)))
    }

    private var kindTitle: String {
        switch column.kind {
        case .numeric: L10n.text("Number")
        case .temporal: L10n.text("Date and time")
        case .boolean: L10n.text("Boolean")
        case .text: L10n.text("Text")
        case .json: "JSON"
        case .binary: L10n.text("Binary")
        case .empty: "NULL"
        }
    }

    private var symbol: String {
        switch column.kind {
        case .numeric: "number"
        case .temporal: "calendar"
        case .boolean: "switch.2"
        case .text: "textformat"
        case .json: "curlybraces"
        case .binary: "doc.zipper"
        case .empty: "circle.dashed"
        }
    }

    private var tint: Color {
        switch column.kind {
        case .numeric: Color(hex: 0x6366F1)
        case .temporal: Color(hex: 0x0EA5E9)
        case .boolean: Color(hex: 0x10B981)
        case .text: Color(hex: 0xF97316)
        case .json: Color(hex: 0xA855F7)
        case .binary: Color(hex: 0x64748B)
        case .empty: .gray
        }
    }
}

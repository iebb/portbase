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
                ProgressView().frame(maxWidth: .infinity, minHeight: 90)
            } else if insights.columns.isEmpty {
                Color.clear.frame(maxWidth: .infinity, minHeight: 90)
            } else {
                facts
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
                // Flat sections between hairlines, top-aligned so a short column doesn't center on a tall neighbor.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Spacing.xl, alignment: .top)], alignment: .leading, spacing: 0) {
                    ForEach(visibleColumns) { column in
                        ColumnInsightSection(column: column)
                    }
                }
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

    /// Rows, columns and completeness as one line of secondary text.
    private var facts: some View {
        let line = Text(verbatim: [
            L10n.plural("row_count", count: insights.rowCount),
            L10n.plural("column_count", count: insights.columns.count),
            L10n.format("%@ non-NULL", insights.completeness.formatted(.percent.precision(.fractionLength(0...1)))),
        ].joined(separator: " · ")).foregroundColor(.secondary)
        return (result.isTruncated == true
                ? line + Text(verbatim: " · ").foregroundColor(.secondary) + Text(L10n.text("Result truncated")).foregroundColor(.orange)
                : line)
            .font(.captionText.monospacedDigit())
    }
}

private struct ColumnInsightSection: View {
    let column: ColumnInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            content.padding(.vertical, Spacing.m)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
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
                    Label("Unique", systemImage: "key")
                        .font(.captionText)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: Spacing.m) {
                stat(L10n.text("Distinct"), column.distinctCount.formatted())
                // Mostly-NULL columns are the one fact here worth a warning color.
                stat("NULL", column.nullRatio.formatted(.percent.precision(.fractionLength(0...1))), warning: column.nullRatio > 0.5)
                if column.emptyTextCount > 0 { stat(L10n.text("Empty"), column.emptyTextCount.formatted()) }
            }

            if let numeric = column.numeric {
                HStack(spacing: Spacing.m) {
                    stat(L10n.text("Min"), format(numeric.minimum))
                    stat(L10n.text("Median"), format(numeric.median))
                    stat(L10n.text("Mean"), format(numeric.mean))
                    stat(L10n.text("Max"), format(numeric.maximum))
                }
                Chart(numeric.bins) { bin in
                    BarMark(x: .value("Range", bin.id), y: .value("Rows", bin.count))
                        .foregroundStyle(PortSQLPalette.accent.opacity(0.7))
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
                    // Labels can repeat when different typed values print alike, so rows are identified by position.
                    ForEach(Array(column.topValues.enumerated()), id: \.offset) { _, value in
                        HStack(spacing: Spacing.s) {
                            Text(value.value.isEmpty ? "\"\"" : value.value)
                                .font(.codeCaption)
                                .lineLimit(1)
                                .frame(maxWidth: 120, alignment: .leading)
                            GeometryReader { proxy in
                                Rectangle().fill(PortSQLPalette.accent.opacity(0.7))
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func stat(_ title: String, _ value: String, warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            Text(title).font(.badgeText).foregroundStyle(.secondary)
            Text(value).font(.rowTitle.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(warning ? Color.orange : PortSQLPalette.ink)
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
}

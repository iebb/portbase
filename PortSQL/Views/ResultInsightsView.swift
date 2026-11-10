import Charts
import SwiftUI

/// Column statistics for the loaded rows of a result.
struct ResultInsightsView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let result: QueryResultTable
    @State private var insights = ResultInsights.empty
    @State private var isComputing = true
    @State private var filter = ""
    /// Figures over every row the query would return, computed by the database when asked.
    @State private var serverProfile: ServerResultProfile?
    @State private var profiling: Task<Void, Never>?
    @State private var profileError: String?

    /// Offered when the loaded rows are only part of the result: a truncated query or one page of a table.
    private var canProfileAllRows: Bool {
        guard let engine = workspace.selectedBookmark?.engine, result.isTruncated == true || result.isExplorerGenerated == true else { return false }
        return ColumnProfileService.canProfile(result, engine: engine)
    }

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
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    facts
                    Spacer(minLength: 0)
                    if canProfileAllRows { profileButton }
                }
                if let profileError { ExecutionErrorLine(message: profileError) }
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
                        ColumnInsightSection(column: column, server: serverProfile?.columns[column.id], serverRows: serverProfile?.rowCount)
                    }
                }
            }
        }
        .onDisappear { profiling?.cancel() }
        .task(id: result) {
            profiling?.cancel(); profiling = nil
            serverProfile = nil; profileError = nil
            isComputing = true
            let snapshot = result
            let computed = await Task.detached(priority: .userInitiated) { ResultInsightsService.insights(for: snapshot) }.value
            guard !Task.isCancelled else { return }
            insights = computed
            isComputing = false
        }
    }

    private var profileButton: some View {
        Button {
            if let profiling { profiling.cancel(); self.profiling = nil } else { profileAllRows() }
        } label: {
            if profiling != nil {
                HStack(spacing: Spacing.xs) { ProgressView().controlSize(.small); Text("Stop") }
            } else {
                Label("Profile All Rows", systemImage: "sum")
            }
        }
        .buttonStyle(.portbaseSecondary)
        .controlSize(.small)
    }

    /// Asks the database for every column's figures over all rows, read-only, in one aggregate query.
    private func profileAllRows() {
        guard let profile = workspace.selectedBookmark else { return }
        let snapshot = result, database = workspace.activeDatabaseName
        let kinds = Dictionary(uniqueKeysWithValues: insights.columns.map { ($0.id, $0.kind) })
        profileError = nil
        profiling = Task {
            do {
                let summary = try await ColumnProfileService.run(result: snapshot, kinds: kinds, profile: profile, database: database)
                guard !Task.isCancelled, snapshot == result else { return }
                serverProfile = summary
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { profileError = DatabaseErrorFormatter.message(for: error) }
            }
            profiling = nil
        }
    }

    /// Rows, columns and completeness as one line of secondary text, with the full count once profiled.
    private var facts: some View {
        var parts = [
            L10n.plural("row_count", count: insights.rowCount),
            L10n.plural("column_count", count: insights.columns.count),
            L10n.format("%@ non-NULL", insights.completeness.formatted(.percent.precision(.fractionLength(0...1)))),
        ]
        if let serverProfile { parts.append(L10n.format("All rows: %@", serverProfile.rowCount.formatted())) }
        let line = Text(verbatim: parts.joined(separator: " · ")).foregroundColor(.secondary)
        return (result.isTruncated == true
                ? line + Text(verbatim: " · ").foregroundColor(.secondary) + Text(L10n.text("Result truncated")).foregroundColor(.orange)
                : line)
            .font(.captionText.monospacedDigit())
    }
}

private struct ColumnInsightSection: View {
    let column: ColumnInsight
    var server: ServerColumnProfile?
    var serverRows: Int?

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

            if let server, let serverRows { serverLine(server, rows: serverRows) }

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

    /// The database's figures over every row, as one line under the loaded rows' own.
    private func serverLine(_ server: ServerColumnProfile, rows: Int) -> some View {
        let nulls = rows > 0 ? Double(rows - server.nonNull) / Double(rows) : 0
        var parts = [L10n.text("All rows")]
        if let distinct = server.distinct { parts.append(L10n.format("%@ distinct", distinct.formatted())) }
        parts.append(nulls.formatted(.percent.precision(.fractionLength(0...1))) + " NULL")
        if let minimum = server.minimum, let maximum = server.maximum {
            parts.append(String(minimum.prefix(24)) + " – " + String(maximum.prefix(24)))
        }
        if let average = server.average, let value = Double(average) {
            parts.append(L10n.format("Average %@", value.formatted(.number.precision(.significantDigits(1...6)))))
        }
        return Text(verbatim: parts.joined(separator: " · "))
            .font(.codeCaption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
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

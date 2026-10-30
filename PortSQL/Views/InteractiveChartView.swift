import Charts
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A chart's rows as a plain, scrolling table: the query's columns, NULLs marked, the first K rows
/// when the chart has a Top K.
struct ChartTableView: View {
    let result: QueryResultTable
    var rowLimit: Int?

    private var rows: ArraySlice<QueryRow> { rowLimit.map { result.rows.prefix($0) } ?? result.rows[...] }

    /// Widths from the header and the first rows, so columns fit their values without measuring every cell.
    private var widths: [CGFloat] {
        result.columns.indices.map { index in
            let values = result.rows.prefix(50).map { $0.cells.indices.contains(index) ? $0.cells[index].displayValue.count : 4 }
            let characters = max(result.columns[index].name.count, values.max() ?? 0)
            return min(260, max(72, CGFloat(characters) * 7.4 + 20))
        }
    }

    var body: some View {
        let widths = widths
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { offset, row in
                        HStack(spacing: 0) {
                            ForEach(result.columns.indices, id: \.self) { index in
                                let cell = row.cells.indices.contains(index) ? row.cells[index] : .null
                                Text(cell.isNull ? "NULL" : cell.displayValue)
                                    .font(.codeCaption)
                                    .italic(cell.isNull)
                                    .foregroundStyle(cell.isNull ? PortSQLPalette.muted : PortSQLPalette.ink)
                                    .lineLimit(1)
                                    .frame(width: widths[index], alignment: .leading)
                                    .padding(.horizontal, Spacing.s)
                            }
                        }
                        .frame(height: 26)
                        .background(offset.isMultiple(of: 2) ? Color.clear : PortSQLPalette.sunken.opacity(0.5))
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(Array(result.columns.enumerated()), id: \.offset) { index, column in
                            Text(column.name)
                                .font(.captionStrong)
                                .foregroundStyle(PortSQLPalette.muted)
                                .lineLimit(1)
                                .frame(width: widths[index], alignment: .leading)
                                .padding(.horizontal, Spacing.s)
                        }
                    }
                    .frame(height: 28)
                    .background(PortSQLPalette.sunken)
                }
            }
        }
        .overlay {
            if result.rows.isEmpty { Text("No rows").font(.rowDetail).foregroundStyle(.secondary) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(PortSQLPalette.stroke) }
    }
}

/// A chart as one headline number: the total of its first metric, with a sparkline over a date axis.
struct ChartNumberView: View {
    let preset: SavedVisualizationPreset
    let data: ChartRenderData

    private var metric: String? { preset.resolvedYFields.first }
    private var values: [VisualizationPlotPoint] {
        data.points.filter { $0.metric == nil || $0.metric == metric }
    }

    var body: some View {
        let values = values
        let total = values.reduce(0) { $0 + $1.yValue }
        VStack(spacing: Spacing.s) {
            Spacer(minLength: 0)
            Text(values.isEmpty ? "—" : total.formatted(.number.precision(.significantDigits(1...10))))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(PortSQLPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .textSelection(.enabled)
            Text(preset.yAxisTitle.isEmpty ? (metric ?? "") : preset.yAxisTitle)
                .font(.rowDetail)
                .foregroundStyle(PortSQLPalette.muted)
                .lineLimit(1)
            if data.xMode == .date, values.count > 1 {
                Chart(values) { point in
                    if let date = point.xDate {
                        AreaMark(x: .value("x", date), y: .value("y", point.yValue))
                            .foregroundStyle(LinearGradient(colors: [PortSQLPalette.accent.opacity(0.3), PortSQLPalette.accent.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("x", date), y: .value("y", point.yValue))
                            .foregroundStyle(PortSQLPalette.accent)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(maxHeight: 64)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Actions a dashboard tile's menu sends to its chart.
enum ChartPreviewAction: Equatable {
    case inspect
    case export(ChartExportFormat)
}

struct VisualizationChartPreview: View {
    let preset: SavedVisualizationPreset
    let result: QueryResultTable
    /// Dashboard tiles: the chart fills the tile and its actions come from the tile's menu.
    var compact: Bool
    var action: Binding<ChartPreviewAction?> = .constant(nil)
    /// The plot's height outside dashboard tiles, where it fills the tile instead.
    var plotHeight: CGFloat = 300
    @State private var dateFilter: VisualizationDateFilter?
    @State private var showsDateFilter = false
    @State private var showsPointList = false
    @State private var selectedPointID: String?
    @State private var drilldown: ChartDrilldown?
    @State private var shareItem: ChartShareItem?
    @State private var exportError: String?
    @State private var rendered: (key: ChartRenderKey, data: ChartRenderData)?

    private var key: ChartRenderKey { ChartRenderKey(result: result, preset: preset, dateFilter: dateFilter) }
    /// The latest rendering, or the previous one while a new one is built, so charts never blank out.
    private var data: ChartRenderData? { rendered?.data ?? ChartRenderStore.shared.cached(key) }
    private var selectedPoint: VisualizationPlotPoint? { data?.points.first { $0.id == selectedPointID } }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Spacing.xs : Spacing.s) {
            if !compact { toolbar }
            chart
            if let point = selectedPoint { selectionBar(point) }
            if !compact, let data { footer(data) }
        }
        .task(id: key) {
            let key = key
            if let cached = ChartRenderStore.shared.cached(key) {
                rendered = (key, cached)
            } else {
                let data = await ChartRenderStore.shared.render(key, result: result, preset: preset, dateFilter: dateFilter)
                guard !Task.isCancelled else { return }
                rendered = (key, data)
            }
            if let selectedPointID, !(rendered?.data.points.contains { $0.id == selectedPointID } ?? false) { self.selectedPointID = nil }
        }
        .onChange(of: action.wrappedValue) { _, request in
            guard let request else { return }
            action.wrappedValue = nil
            switch request {
            case .inspect: showsPointList = true
            case .export(let format): export(format)
            }
        }
        .sheet(isPresented: $showsDateFilter) {
            ChartDateFilterSheet(result: result, fields: data?.dateFields ?? [], current: dateFilter) { dateFilter = $0 }
        }
        .sheet(isPresented: $showsPointList) {
            ChartPointList(points: data?.points ?? []) { selectedPointID = $0.id }
        }
        .sheet(item: $drilldown) { ChartDrilldownView(drilldown: $0) }
        .sheet(item: $shareItem) { ChartShareSheet(url: $0.url) }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    @ViewBuilder private var chart: some View {
        if let data, let presentation = preset.presentation {
            switch presentation {
            case .table:
                ChartTableView(result: data.result, rowLimit: preset.topLimit)
                    .frame(height: compact ? nil : plotHeight)
                    .frame(maxHeight: compact ? .infinity : nil)
            case .number:
                ChartNumberView(preset: preset, data: data)
                    .frame(height: compact ? nil : plotHeight)
                    .frame(maxHeight: compact ? .infinity : nil)
            }
        } else if let data {
            if data.points.isEmpty {
                ContentUnavailableView("No plottable rows", systemImage: "chart.bar.doc.horizontal")
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? nil : plotHeight)
                    .frame(maxHeight: compact ? .infinity : nil)
            } else {
                VisualizationChartPlot(preset: preset, points: data.points, xMode: data.xMode, compact: compact,
                                       selectedPointID: selectedPointID, onSelect: { point in
                                           selectedPointID = selectedPointID == point.id ? nil : point.id
                                       }, height: compact ? nil : plotHeight)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .frame(height: compact ? nil : plotHeight)
                .frame(maxHeight: compact ? .infinity : nil)
        }
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.m) {
            if !(data?.dateFields.isEmpty ?? true) {
                Button { showsDateFilter = true } label: {
                    Label(dateFilter.map { $0.field + ": " + dateRangeLabel($0) } ?? L10n.text("Date Range"),
                          systemImage: dateFilter == nil ? "calendar" : "calendar.badge.checkmark")
                        .lineLimit(1)
                }
                if dateFilter != nil {
                    Button { dateFilter = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear Date Filter")
                }
            }
            Spacer(minLength: 0)
            Button { showsPointList = true } label: { Label("Inspect", systemImage: "scope") }
                .disabled(data?.points.isEmpty ?? true)
            Menu {
                Button("Export PNG") { export(.png) }
                Button("Export PDF") { export(.pdf) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(data?.points.isEmpty ?? true)
            .accessibilityLabel("Export Chart")
        }
        .font(.captionStrong)
        .buttonStyle(.plain)
        .foregroundStyle(PortSQLPalette.accent)
        .frame(minHeight: Sizes.control)
    }

    /// One line under the chart: what was picked, its value, and its rows.
    private func selectionBar(_ point: VisualizationPlotPoint) -> some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 0) {
                Text(pointTitle(point))
                    .font(.captionText)
                    .foregroundStyle(PortSQLPalette.muted)
                    .lineLimit(1)
                Text(point.yValue, format: .number.precision(.significantDigits(1...12)))
                    .font(.rowTitle.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(PortSQLPalette.ink)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Spacing.s)
            Button {
                drilldown = ChartDrilldown(title: pointTitle(point), result: VisualizationService.matchingResult(data?.result ?? result, point: point))
            } label: {
                Text(L10n.format("View Rows (%d)", point.sourceRowIDs.count))
                    .font(.captionStrong)
                    .foregroundStyle(PortSQLPalette.accent)
                    .frame(minHeight: Sizes.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { selectedPointID = nil } label: {
                Image(systemName: "xmark")
                    .font(.captionStrong)
                    .foregroundStyle(PortSQLPalette.muted)
                    .frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Inspection")
        }
        .padding(.leading, Spacing.m)
        .background(PortSQLPalette.sunken, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    @ViewBuilder private func footer(_ data: ChartRenderData) -> some View {
        if data.plottedPointCount > data.points.count {
            Text(L10n.format("Showing %1$d of %2$d points", data.points.count, data.plottedPointCount))
                .font(.captionText).foregroundStyle(.secondary)
        }
        if result.isTruncated == true {
            Text("Chart uses the loaded result only. Export all data from the query for the complete result.")
                .font(.captionText).foregroundStyle(.orange)
        }
    }

    private func pointTitle(_ point: VisualizationPlotPoint) -> String {
        [point.xText, point.group ?? point.metric].compactMap { $0 }.joined(separator: " · ")
    }

    private func export(_ format: ChartExportFormat) {
        guard let data else { return }
        do {
            let url = try ChartExportService.write(preset: preset, result: data.result, points: data.points, xMode: data.xMode, dateFilter: dateFilter, format: format)
            shareItem = ChartShareItem(url: url)
        } catch { exportError = error.localizedDescription }
    }
}

private struct ChartPointList: View {
    let points: [VisualizationPlotPoint]
    let onSelect: (VisualizationPlotPoint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        PortbaseSheet(L10n.text("Inspect Chart")) {
            PortbaseSearchField(text: $search)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.s)
            List(points.filter { search.isEmpty || [$0.xText, $0.group ?? "", $0.metric ?? ""].contains(where: { $0.localizedStandardContains(search) }) }) { point in
                Button {
                    onSelect(point); dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(point.xText)
                            if let series = point.group ?? point.metric { Text(series).font(.captionText).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(point.yValue, format: .number.precision(.significantDigits(1...12))).monospacedDigit()
                    }
                    .frame(minHeight: Sizes.touchTarget)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } footer: {
            Button("Done") { dismiss() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private func dateRangeLabel(_ filter: VisualizationDateFilter) -> String {
    let lastDay = Calendar.current.date(byAdding: .second, value: -1, to: filter.end) ?? filter.end
    return filter.start.formatted(date: .abbreviated, time: .omitted) + " – " + lastDay.formatted(date: .abbreviated, time: .omitted)
}

private struct ChartDateFilterSheet: View {
    let result: QueryResultTable
    let fields: [VisualizationFieldDescriptor]
    let onApply: (VisualizationDateFilter?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var field: String
    @State private var start: Date
    @State private var end: Date

    init(result: QueryResultTable, fields: [VisualizationFieldDescriptor], current: VisualizationDateFilter?, onApply: @escaping (VisualizationDateFilter?) -> Void) {
        self.result = result; self.fields = fields; self.onApply = onApply
        let initialField = current?.field ?? fields.first?.name ?? ""
        let bounds = VisualizationService.dateBounds(for: result, field: initialField)
        _field = State(initialValue: initialField)
        _start = State(initialValue: current?.start ?? bounds?.lowerBound ?? .now)
        _end = State(initialValue: current.map { $0.end.addingTimeInterval(-1) } ?? bounds?.upperBound ?? .now)
    }

    var body: some View {
        PortbaseSheet(L10n.text("Date Range")) {
            Form {
                Picker("Date Field", selection: $field) {
                    ForEach(fields) { Text($0.name).tag($0.name) }
                }
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("Through", selection: $end, displayedComponents: .date)
            }
            .portbaseForm()
            .onChange(of: field) { _, value in
                if let bounds = VisualizationService.dateBounds(for: result, field: value) { start = bounds.lowerBound; end = bounds.upperBound }
            }
        } footer: {
            Button("Clear Date Filter") { onApply(nil); dismiss() }
                .buttonStyle(.portbaseSecondary)
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(.portbaseSecondary)
            Button("Apply") {
                let lower = Calendar.current.startOfDay(for: start)
                let upper = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end
                onApply(VisualizationDateFilter(field: field, start: lower, end: upper)); dismiss()
            }
            .buttonStyle(.portbasePrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(field.isEmpty || Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end))
        }
        .portbaseSheetNavigation()
        .presentationDetents([.medium, .large])
    }
}

private struct ChartDrilldown: Identifiable {
    let id = UUID()
    let title: String
    let result: QueryResultTable
}

private struct ChartDrilldownView: View {
    let drilldown: ChartDrilldown
    @Environment(\.dismiss) private var dismiss
    @State private var showsDocuments = false
    @State private var documentSelection: MongoDocumentSelection?
    @State private var rowSelection: ChartRowSelection?

    var body: some View {
        PortbaseSheet(L10n.text("Matching Rows")) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(drilldown.title).font(.cardTitle).textSelection(.enabled)
                    Text(drilldown.result.executionSummary).font(.captionText).foregroundStyle(.secondary)
                    if drilldown.result.documents != nil {
                        PortbaseTabs(selection: $showsDocuments, options: [
                            PortbaseChoice(value: false, title: L10n.text("Table")), PortbaseChoice(value: true, title: L10n.text("Documents")),
                        ])
                    }
                    if showsDocuments, let documents = drilldown.result.documents {
                        MongoDocumentResults(documents: documents)
                    } else {
                        ResultGridView(result: drilldown.result, onOpenRow: { index in
                            if let documents = drilldown.result.documents, documents.indices.contains(index) {
                                documentSelection = MongoDocumentSelection(index: index, json: documents[index])
                            } else {
                                rowSelection = ChartRowSelection(index: index, result: drilldown.result)
                            }
                        })
                    }
                }
                .padding()
            }
            .sheet(item: $documentSelection) { MongoDocumentInspector(selection: $0) }
            .sheet(item: $rowSelection) { ChartRowInspector(selection: $0) }
        } footer: {
            Button("Done") { dismiss() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ChartRowSelection: Identifiable {
    let id = UUID()
    let index: Int
    let result: QueryResultTable
}

private struct ChartRowInspector: View {
    let selection: ChartRowSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PortbaseSheet(L10n.text("View Row")) {
            List(Array(selection.result.columns.enumerated()), id: \.offset) { index, column in
                let cells = selection.result.rows[selection.index].cells
                let cell = cells.indices.contains(index) ? cells[index] : .null
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(column.name).font(.rowDetail).foregroundStyle(.secondary)
                    Text(cell.isNull ? "NULL" : (cell.displayValue.isEmpty ? "\"\"" : cell.displayValue))
                        .font(.codeText).textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ResultGridAccessibility.rowLabel(columns: [column], cells: [cell]))
            }
        } footer: {
            Button("Done") { dismiss() }
                .buttonStyle(.portbasePrimary)
                .keyboardShortcut(.defaultAction)
        }
    }
}

enum ChartExportFormat: String { case png, pdf }

enum ChartExportError: LocalizedError {
    case renderingFailed
    var errorDescription: String? { L10n.text("The chart could not be rendered. Try exporting again.") }
}

@MainActor enum ChartExportService {
    static func write(preset: SavedVisualizationPreset, result: QueryResultTable, points: [VisualizationPlotPoint], xMode: VisualizationFieldMode, dateFilter: VisualizationDateFilter?, format: ChartExportFormat) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortSQLCharts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("chart-" + UUID().uuidString + "." + format.rawValue)
        let view = VStack(alignment: .leading, spacing: Spacing.l) {
            Text(preset.tileTitle).font(.pageTitle)
            VisualizationChartPlot(preset: preset, points: points, xMode: xMode, compact: false)
            if let dateFilter { Text(dateFilter.field + ": " + dateRangeLabel(dateFilter)).font(.captionText) }
            Text(L10n.format("Loaded rows: %d", result.rows.count)).font(.captionText).foregroundStyle(.secondary)
            if result.isTruncated == true { Text("Truncated query result").font(.captionText).foregroundStyle(.secondary) }
        }
        .padding(Spacing.xxxl)
        .frame(width: 1_000, alignment: .leading)
        .background(.white)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        switch format {
        case .png:
#if canImport(UIKit)
            guard let data = renderer.uiImage?.pngData() else { throw ChartExportError.renderingFailed }
#else
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { throw ChartExportError.renderingFailed }
#endif
            try data.write(to: url, options: .atomic)
        case .pdf:
            var completed = false
            renderer.render(rasterizationScale: 2) { size, render in
                var page = CGRect(origin: .zero, size: size)
                guard let context = CGContext(url as CFURL, mediaBox: &page, nil) else { return }
                context.beginPDFPage(nil)
                render(context)
                context.endPDFPage()
                context.closePDF()
                completed = true
            }
            guard completed else { throw ChartExportError.renderingFailed }
        }
        return url
    }
}

private struct ChartShareItem: Identifiable { let id = UUID(); let url: URL }

#if canImport(UIKit)
private struct ChartShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#else
private struct ChartShareSheet: View {
    let url: URL
    var body: some View { ScriptActivitySheet(url: url) }
}
#endif

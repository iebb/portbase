import Charts
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct VisualizationChartPreview: View {
    let preset: SavedVisualizationPreset
    let result: QueryResultTable
    var compact: Bool
    @State private var dateFilter: VisualizationDateFilter?
    @State private var showsDateFilter = false
    @State private var showsPointList = false
    @State private var selectedPointID: String?
    @State private var drilldown: ChartDrilldown?
    @State private var shareItem: ChartShareItem?
    @State private var exportError: String?
    @State private var content = ChartContentState()

    private var selectedPoint: VisualizationPlotPoint? { content.points.first { $0.id == selectedPointID } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                if !content.dateFields.isEmpty {
                    Button { showsDateFilter = true } label: {
                        Label("Date Range", systemImage: dateFilter == nil ? "calendar" : "calendar.badge.checkmark")
                    }
                    .frame(minHeight: Sizes.touchTarget)
                }
                Button { showsPointList = true } label: {
                    Label("Inspect", systemImage: "scope").frame(minHeight: Sizes.touchTarget)
                }
                .disabled(content.points.isEmpty)
                Spacer(minLength: 0)
                Menu {
                    Button("Export PNG") { export(.png) }
                    Button("Export PDF") { export(.pdf) }
                } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                }
                .disabled(content.points.isEmpty)
                .accessibilityLabel("Export Chart")
            }
            .font(.rowDetail)
            .buttonStyle(.borderless)

            if let dateFilter {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(dateFilter.field + ": " + dateRangeLabel(dateFilter))
                        .font(.captionText).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { self.dateFilter = nil } label: {
                        Image(systemName: "xmark").frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                    }
                    .accessibilityLabel("Clear Date Filter")
                }
            }

            if content.points.isEmpty {
                ContentUnavailableView("No plottable rows", systemImage: "chart.bar.doc.horizontal")
                    .frame(height: compact ? 210 : 300)
            } else {
                VisualizationChartPlot(preset: preset, points: content.points, xMode: content.xMode, compact: compact,
                    selectedPointID: selectedPointID, onSelect: { selectedPointID = $0.id })
            }

            if let point = selectedPoint {
                selectedPointDetails(point)
            }
            Text(L10n.format("Loaded rows: %d / %d", content.result.rows.count, result.rows.count))
                .font(.captionText).foregroundStyle(.secondary)
            if result.isTruncated == true {
                Text("Chart uses the loaded result only. Export all data from the query for the complete result.")
                    .font(.captionText).foregroundStyle(.orange)
            }
        }
        .onChange(of: result, initial: true) { _, _ in rebuild() }
        .onChange(of: preset) { _, _ in rebuild() }
        .onChange(of: dateFilter) { _, _ in rebuild() }
        .sheet(isPresented: $showsDateFilter) {
            ChartDateFilterSheet(result: result, fields: content.dateFields, current: dateFilter) { dateFilter = $0 }
        }
        .sheet(isPresented: $showsPointList) {
            ChartPointList(points: content.points) { selectedPointID = $0.id }
        }
        .sheet(item: $drilldown) { ChartDrilldownView(drilldown: $0) }
        .sheet(item: $shareItem) { ChartShareSheet(url: $0.url) }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func selectedPointDetails(_ point: VisualizationPlotPoint) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .top, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(pointTitle(point)).font(.rowTitle).textSelection(.enabled)
                    Text(point.yValue, format: .number.precision(.significantDigits(1...12)))
                        .font(.codeText).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button { selectedPointID = nil } label: {
                    Image(systemName: "xmark").frame(width: Sizes.touchTarget, height: Sizes.touchTarget)
                }
                .accessibilityLabel("Close Inspection")
            }
            Button {
                drilldown = ChartDrilldown(title: pointTitle(point), result: VisualizationService.matchingResult(content.result, point: point))
            } label: {
                Label(L10n.format("View Rows (%d)", point.sourceRowIDs.count), systemImage: "tablecells")
                    .frame(minHeight: Sizes.touchTarget)
            }
        }
        .padding(Spacing.m)
        .background(PortSQLPalette.surface, in: RoundedRectangle(cornerRadius: Radius.xs))
    }

    private func pointTitle(_ point: VisualizationPlotPoint) -> String {
        [point.xText, point.group ?? point.metric].compactMap { $0 }.joined(separator: " · ")
    }

    private func rebuild() {
        let filtered = VisualizationService.filteredResult(result, dateFilter: dateFilter)
        let fields = VisualizationService.fieldDescriptors(for: result)
        content = ChartContentState(result: filtered, points: VisualizationService.chartPoints(for: filtered, preset: preset, fields: fields),
            xMode: VisualizationService.resolvedXMode(for: preset, fields: fields), dateFields: fields.filter(\.supportsDate))
        if !content.points.contains(where: { $0.id == selectedPointID }) { selectedPointID = nil }
    }

    private func export(_ format: ChartExportFormat) {
        do {
            let url = try ChartExportService.write(preset: preset, result: content.result, points: content.points, xMode: content.xMode, dateFilter: dateFilter, format: format)
            shareItem = ChartShareItem(url: url)
        } catch { exportError = error.localizedDescription }
    }
}

private struct ChartContentState {
    var result = QueryResultTable.empty
    var points: [VisualizationPlotPoint] = []
    var xMode = VisualizationFieldMode.category
    var dateFields: [VisualizationFieldDescriptor] = []
}

private struct ChartPointList: View {
    let points: [VisualizationPlotPoint]
    let onSelect: (VisualizationPlotPoint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        NavigationStack {
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
            .searchable(text: $search)
            .navigationTitle("Inspect Chart")
            .portbaseTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
        NavigationStack {
            Form {
                Picker("Date Field", selection: $field) {
                    ForEach(fields) { Text($0.name).tag($0.name) }
                }
                DatePicker("From", selection: $start, displayedComponents: .date)
                DatePicker("Through", selection: $end, displayedComponents: .date)
                Button("Clear Date Filter") { onApply(nil); dismiss() }
            }
            .navigationTitle("Date Range")
            .portbaseTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let lower = Calendar.current.startOfDay(for: start)
                        let upper = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end)) ?? end
                        onApply(VisualizationDateFilter(field: field, start: lower, end: upper)); dismiss()
                    }
                    .disabled(field.isEmpty || Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end))
                }
            }
            .onChange(of: field) { _, value in
                if let bounds = VisualizationService.dateBounds(for: result, field: value) { start = bounds.lowerBound; end = bounds.upperBound }
            }
        }
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(drilldown.title).font(.cardTitle).textSelection(.enabled)
                    Text(drilldown.result.executionSummary).font(.captionText).foregroundStyle(.secondary)
                    if drilldown.result.documents != nil {
                        Picker("Results", selection: $showsDocuments) {
                            Text("Table").tag(false)
                            Text("Documents").tag(true)
                        }
                        .pickerStyle(.segmented)
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
            .navigationTitle("Matching Rows")
            .portbaseTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $documentSelection) { MongoDocumentInspector(selection: $0) }
            .sheet(item: $rowSelection) { ChartRowInspector(selection: $0) }
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
        NavigationStack {
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
            .navigationTitle("View Row")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
            Text(preset.chartTitle.isEmpty ? preset.title : preset.chartTitle).font(.pageTitle)
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

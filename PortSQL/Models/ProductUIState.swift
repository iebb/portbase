import CoreGraphics
import Foundation

enum SavedChartPreviewState: Equatable {
    case loading
    case content
    case missingQuery
    case missingConnection
    case idle
    case failed(String)

    static func resolve(
        hasResolvedInitialState: Bool,
        isRunning: Bool,
        hasPreview: Bool,
        error: String?,
        hasSourceQuery: Bool,
        hasConnection: Bool
    ) -> SavedChartPreviewState {
        if let error, !error.isEmpty {
            return .failed(error)
        }
        if hasPreview {
            return .content
        }
        if isRunning || !hasResolvedInitialState {
            return .loading
        }
        if !hasSourceQuery {
            return .missingQuery
        }
        if !hasConnection {
            return .missingConnection
        }
        return .idle
    }
}

enum ResultGridLayout {
    static func expandedWidths(naturalWidths: [CGFloat], availableWidth: CGFloat) -> [CGFloat] {
        guard !naturalWidths.isEmpty else { return [] }

        let availableContentWidth = max(0, availableWidth - 16)
        let naturalTotal = naturalWidths.reduce(0, +)
        guard availableContentWidth > naturalTotal else { return naturalWidths }

        let extraPerColumn = (availableContentWidth - naturalTotal) / CGFloat(naturalWidths.count)
        return naturalWidths.map { $0 + extraPerColumn }
    }

    static func needsHorizontalScrolling(widths: [CGFloat], availableWidth: CGFloat) -> Bool {
        widths.reduce(0, +) > max(0, availableWidth - 16) + 1
    }
}

enum ResultGridAccessibility {
    static func rowLabel(columns: [QueryColumn], cells: [QueryCell]) -> String {
        columns.enumerated().map { index, column in
            let value: String
            if cells.indices.contains(index) {
                let cell = cells[index]
                value = cell.isNull ? L10n.text("NULL") : (cell.displayValue.isEmpty ? L10n.text("empty string") : cell.displayValue)
            } else {
                value = L10n.text("NULL")
            }
            return "\(column.name): \(value)"
        }
        .joined(separator: ", ")
    }

    static func headerValue(
        column: QueryColumn,
        isPrimaryKey: Bool,
        sortDirection: String?
    ) -> String {
        var details = [column.type]
        if isPrimaryKey {
            details.append("primary key")
        }
        if let sortDirection {
            details.append(sortDirection == "DESC" ? "sorted descending" : "sorted ascending")
        }
        return details.joined(separator: ", ")
    }
}

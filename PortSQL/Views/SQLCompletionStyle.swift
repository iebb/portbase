import SwiftUI

/// How each kind of completion is named and colored in the Mac list and the iPhone and iPad keyboard bar.
extension SQLCompletionItem.Kind {
    var title: String {
        switch self {
        case .keyword: L10n.text("Keyword")
        case .table: L10n.text("Table")
        case .view: L10n.text("View")
        case .cte: L10n.text("Common table expression")
        case .column: L10n.text("Column")
        case .alias: L10n.text("Alias")
        case .function: L10n.text("Function")
        case .join: L10n.text("Join")
        case .snippet: L10n.text("Snippet")
        case .schema: L10n.text("Schema")
        case .value: L10n.text("Value")
        case .operation: L10n.text("Operator")
        }
    }

    var tint: Color {
        switch self {
        case .table, .view, .cte, .schema: Color(red: 0.22, green: 0.52, blue: 0.93)
        case .column, .alias: Color(red: 0.55, green: 0.36, blue: 0.86)
        case .function: Color(red: 0.93, green: 0.55, blue: 0.13)
        case .join, .snippet: PortSQLPalette.accent
        case .keyword, .operation, .value: Color(red: 0.45, green: 0.5, blue: 0.58)
        }
    }
}

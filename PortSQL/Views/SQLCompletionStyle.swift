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

/// Typing an opening bracket or quote adds its closer, as code editors do; typing the closer steps over
/// it, and deleting an empty pair removes both. Shared by the Mac and iOS editors.
enum EditorAutoPairs {
    static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "'": "'", "\"": "\"", "`": "`"]
    private static let closers: Set<Character> = [")", "]", "}", "'", "\"", "`"]

    enum Action: Equatable {
        /// Type the character as usual.
        case insert
        /// Insert the opener and closer with the caret between them.
        case pair(String)
        /// Move past the closer that's already there.
        case stepOver
        /// Surround the selection with the pair, keeping it selected.
        case wrap(String, String)
    }

    /// What typing `character` should do at the selection in `text` (UTF-16 offsets).
    static func action(typing character: Character, in text: String, selection: NSRange) -> Action {
        let source = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return .insert }
        let next = selection.location < source.length ? glyph(at: selection.location, in: source) : nil
        let previous = selection.location > 0 ? glyph(at: selection.location - 1, in: source) : nil
        if selection.length == 0, closers.contains(character), next == character { return .stepOver }
        guard let closer = pairs[character] else { return .insert }
        if selection.length > 0 { return .wrap(String(character), String(closer)) }
        // Inside a string or comment, type plainly.
        if SQLEditingService.isProtected(text, offset: selection.location, engine: .postgresql) { return .insert }
        let nextAllowsPair = next.map { $0.isWhitespace || ")]},;".contains($0) } ?? true
        let isQuote = character == closer
        // A quote right after a word is an apostrophe or closes something, like don't or name'.
        let previousAllowsQuote = previous.map { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == character) } ?? true
        return nextAllowsPair && (!isQuote || previousAllowsQuote) ? .pair(String(character) + String(closer)) : .insert
    }

    /// Whether Backspace at the caret should delete an empty pair, like the parentheses in "(|)".
    static func deletesPair(in text: String, at location: Int) -> Bool {
        let source = text as NSString
        guard location > 0, location < source.length,
              let opener = glyph(at: location - 1, in: source), let closer = glyph(at: location, in: source) else { return false }
        return pairs[opener] == closer
    }

    private static func glyph(at location: Int, in source: NSString) -> Character? {
        let range = source.rangeOfComposedCharacterSequence(at: location)
        return source.substring(with: range).first
    }
}

/// A function signature with the parameter at the caret in bold, like DATE_TRUNC('day', **timestamp**).
struct SQLSignatureText: View {
    let signature: SQLSignatureHint

    var body: some View {
        var text = Text(verbatim: signature.name + "(").foregroundColor(PortSQLPalette.muted)
        for (index, parameter) in signature.parameters.enumerated() {
            if index > 0 { text = text + Text(verbatim: ", ").foregroundColor(PortSQLPalette.muted) }
            text = text + (index == signature.argument
                ? Text(verbatim: parameter).bold().foregroundColor(PortSQLPalette.accent)
                : Text(verbatim: parameter).foregroundColor(PortSQLPalette.muted))
        }
        return text + Text(verbatim: ")").foregroundColor(PortSQLPalette.muted)
    }
}

import Foundation

/// Line commands found in commercial SQL editors: duplicate, move up or down, and toggle case. Each
/// returns a change to one range of the text, so the editor applies it as one undoable edit without
/// replacing the whole buffer.
enum SQLLineEditing {
    struct RangeEdit: Equatable {
        /// The range of the original text to replace (UTF-16).
        let range: NSRange
        let replacement: String
        /// The selection afterward, in the edited text.
        let selection: NSRange
    }

    /// Duplicates the selected lines below themselves and selects the copy, as ⌘D does in Xcode.
    static func duplicateLines(_ text: String, selection: NSRange) -> RangeEdit? {
        guard let block = lineBlock(text, selection: selection) else { return nil }
        let source = text as NSString
        let lines = source.substring(with: block)
        let (body, newline) = splitNewline(lines)
        // The last line has no newline of its own, so the copy brings one.
        let separator = newline.isEmpty ? lineEnding(of: text) : newline
        let insertion = newline.isEmpty ? separator + body : body + newline
        let shift = newline.isEmpty ? (separator as NSString).length + (body as NSString).length : (lines as NSString).length
        return RangeEdit(range: NSRange(location: NSMaxRange(block), length: 0), replacement: insertion,
                         selection: NSRange(location: selection.location + shift, length: selection.length))
    }

    /// Swaps the selected lines with the line above or below, keeping the selection on them.
    static func moveLines(_ text: String, selection: NSRange, up: Bool) -> RangeEdit? {
        guard let block = lineBlock(text, selection: selection) else { return nil }
        let source = text as NSString
        if up {
            guard block.location > 0 else { return nil }
            let neighbor = source.lineRange(for: NSRange(location: block.location - 1, length: 0))
            let (neighborBody, neighborNewline) = splitNewline(source.substring(with: neighbor))
            let (blockBody, blockNewline) = splitNewline(source.substring(with: block))
            let replacement = blockBody + neighborNewline + neighborBody + blockNewline
            return RangeEdit(range: NSRange(location: neighbor.location, length: NSMaxRange(block) - neighbor.location), replacement: replacement,
                             selection: NSRange(location: selection.location - neighbor.length, length: selection.length))
        }
        guard NSMaxRange(block) < source.length else { return nil }
        let neighbor = source.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        let (neighborBody, neighborNewline) = splitNewline(source.substring(with: neighbor))
        let (blockBody, blockNewline) = splitNewline(source.substring(with: block))
        let replacement = neighborBody + blockNewline + blockBody + neighborNewline
        let shift = (neighborBody as NSString).length + (blockNewline as NSString).length
        return RangeEdit(range: NSRange(location: block.location, length: NSMaxRange(neighbor) - block.location), replacement: replacement,
                         selection: NSRange(location: block.location + shift + (selection.location - block.location), length: selection.length))
    }

    /// Uppercases the selection, or lowercases it when it's already all uppercase, as ⇧⌘U does in DataGrip.
    /// With nothing selected it changes the word at the caret.
    static func toggleCase(_ text: String, selection: NSRange) -> RangeEdit? {
        let source = text as NSString
        guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return nil }
        var range = selection
        if range.length == 0 {
            var start = range.location, end = range.location
            func isWord(_ index: Int) -> Bool {
                guard let scalar = UnicodeScalar(source.character(at: index)) else { return false }
                return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
            }
            while start > 0, isWord(start - 1) { start -= 1 }
            while end < source.length, isWord(end) { end += 1 }
            range = NSRange(location: start, length: end - start)
        }
        guard range.length > 0 else { return nil }
        let original = source.substring(with: range)
        let replacement = original == original.uppercased() && original != original.lowercased() ? original.lowercased() : original.uppercased()
        guard replacement != original, (replacement as NSString).length == range.length else { return nil }
        return RangeEdit(range: range, replacement: replacement, selection: selection.length == 0 ? selection : range)
    }

    /// The whole lines the selection touches; a selection ending at a line's start doesn't take that line.
    private static func lineBlock(_ text: String, selection: NSRange) -> NSRange? {
        let source = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0, NSMaxRange(selection) <= source.length else { return nil }
        var selected = selection
        if selected.length > 0, [10, 13].contains(Int(source.character(at: NSMaxRange(selected) - 1))) { selected.length -= 1 }
        return source.lineRange(for: selected)
    }

    private static func splitNewline(_ line: String) -> (String, String) {
        // "\r\n" is one Character in Swift, so dropping the last one removes either ending whole.
        guard let last = line.last, last.isNewline else { return (line, "") }
        return (String(line.dropLast()), String(last))
    }

    private static func lineEnding(of text: String) -> String { text.contains("\r\n") ? "\r\n" : "\n" }
}

import Foundation

/// Editor offsets use UTF-16, matching UITextView and NSRange.
enum SQLEditingService {
    struct Edit {
        let text: String
        let selection: NSRange
    }

    static func lineStarts(in text: String) -> [Int] {
        let source = text as NSString
        var starts = [0]
        var offset = 0
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(range)
            if offset < source.length { starts.append(offset) }
            else if source.length > 0, [10, 13, 0x2028, 0x2029].contains(Int(source.character(at: source.length - 1))) {
                starts.append(offset)
            }
        }
        return starts
    }

    static func toggleLineComments(_ text: String, selection: NSRange) -> Edit? {
        let source = text as NSString
        guard selection.location >= 0, selection.location <= source.length,
              selection.length >= 0, selection.length <= source.length - selection.location else { return nil }
        var selected = selection
        if selected.length > 0, NSMaxRange(selected) > 0,
           [10, 13].contains(Int(source.character(at: NSMaxRange(selected) - 1))) { selected.length -= 1 }
        let range = source.lineRange(for: selected)
        let original = source.substring(with: range)
        // Preserve newline shape (including CRLF) and indentation exactly.
        let starts = lineStarts(in: original)
        let originalSource = original as NSString
        let lines = starts.enumerated().compactMap { index, start -> String? in
            guard start < originalSource.length || originalSource.length == 0 else { return nil }
            let end = index + 1 < starts.count ? starts[index + 1] : originalSource.length
            return originalSource.substring(with: NSRange(location: start, length: end - start))
        }
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let removing = !nonempty.isEmpty && nonempty.allSatisfy { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("-- ") }
        let replacement = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return line }
            let indentation = line.prefix(while: { $0 == " " || $0 == "\t" })
            let rest = line.dropFirst(indentation.count)
            return String(indentation) + (removing ? String(rest.dropFirst(3)) : "-- " + rest)
        }.joined()
        return Edit(text: source.replacingCharacters(in: range, with: replacement),
                    selection: NSRange(location: range.location, length: replacement.utf16.count))
    }

    static func selection(in text: String, offset: Int, length: Int) -> Range<String.Index>? {
        guard offset >= 0, length > 0, offset <= text.utf16.count,
              length <= text.utf16.count - offset else { return nil }
        return Range(NSRange(location: offset, length: length), in: text)
    }

    static func characterOffset(in text: String, utf16Offset: Int) -> Int {
        let offset = max(0, min(utf16Offset, text.utf16.count))
        let index = String.Index(utf16Offset: offset, in: text)
        return text.distance(from: text.startIndex, to: index)
    }

    static func format(_ text: String, engine: DatabaseEngine) -> String {
        guard engine.isSQL else { return text }
        let spans = protectedRanges(in: text, engine: engine)
        // The server's NO_BACKSLASH_ESCAPES setting is unknown. Leave ambiguous input intact.
        if engine.isMySQLFamily, spans != protectedRanges(in: text, engine: engine, backslashEscapes: false) {
            return text
        }
        let keywords = #"\b(SELECT|INSERT\s+INTO|UPDATE|DELETE\s+FROM|CREATE\s+TABLE|ALTER\s+TABLE|DROP\s+TABLE|EXPLAIN|DESCRIBE|SHOW\s+TABLES|GROUP\s+BY|ORDER\s+BY|LEFT\s+JOIN|RIGHT\s+JOIN|INNER\s+JOIN|FROM|WHERE|HAVING|LIMIT|VALUES|SET|JOIN|ON|AND|OR|NOT|IN|LIKE|BETWEEN|EXISTS)\b"#
        let expression = try! NSRegularExpression(pattern: keywords, options: .caseInsensitive)
        let clauses = try! NSRegularExpression(pattern: #"[ \t]+(FROM|WHERE|GROUP BY|ORDER BY|HAVING|LIMIT|VALUES|SET|LEFT JOIN|RIGHT JOIN|INNER JOIN|JOIN|ON)\b[ \t]+"#)
        func code(_ source: Substring) -> String {
            var value = String(source)
            for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let range = Range(match.range, in: value) else { continue }
                value.replaceSubrange(range, with: value[range].uppercased())
            }
            return clauses.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "\n$1 ")
        }
        var result = ""
        var cursor = text.startIndex
        for span in spans {
            result += code(text[cursor..<span.lowerBound])
            result += text[span]
            cursor = span.upperBound
        }
        result += code(text[cursor...])
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isProtected(_ text: String, offset: Int, engine: DatabaseEngine) -> Bool {
        let index = String.Index(utf16Offset: max(0, min(offset, text.utf16.count)), in: text)
        return protectedRanges(in: text, engine: engine).contains { $0.lowerBound < index && index < $0.upperBound }
    }

    static func protectedRanges(in text: String, engine: DatabaseEngine, backslashEscapes: Bool = true) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let start = index
            let character = text[index]
            let next = text.index(after: index)
            let tail = text[index...]
            if tail.hasPrefix("--"), !engine.isMySQLFamily || tail.dropFirst(2).first?.isWhitespace == true {
                index = text[next...].firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? text.endIndex
                if index < text.endIndex { index = text.index(after: index) }
            } else if engine.isMySQLFamily, character == "#" {
                index = text[next...].firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? text.endIndex
                if index < text.endIndex { index = text.index(after: index) }
            } else if tail.hasPrefix("/*") {
                index = text.index(index, offsetBy: 2)
                var depth = 1
                while index < text.endIndex, depth > 0 {
                    if text[index...].hasPrefix("/*"), engine == .postgresql {
                        depth += 1; index = text.index(index, offsetBy: 2)
                    } else if text[index...].hasPrefix("*/") {
                        depth -= 1; index = text.index(index, offsetBy: 2)
                    } else { index = text.index(after: index) }
                }
            } else if engine == .postgresql, character == "$",
                      let delimiter = tail.range(of: #"^\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$"#, options: .regularExpression) {
                index = text.range(of: String(text[delimiter]), range: delimiter.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
            } else if engine == .sqlite, character == "[" {
                index = text[next...].firstIndex(of: "]").map { text.index(after: $0) } ?? text.endIndex
            } else if character == "'" || character == "\"" || character == "`" {
                let previous = index > text.startIndex ? text[text.index(before: index)] : nil
                let escaped = ((engine.isMySQLFamily || engine == .clickhouse) && backslashEscapes && character != "`")
                    || (engine == .postgresql && character == "'" && (previous == "e" || previous == "E"))
                index = next
                while index < text.endIndex {
                    let after = text.index(after: index)
                    if escaped, text[index] == "\\" {
                        index = after < text.endIndex ? text.index(after: after) : after
                    } else if text[index] == character {
                        if after < text.endIndex, text[after] == character { index = text.index(after: after) }
                        else { index = after; break }
                    } else { index = after }
                }
            } else { index = next; continue }
            ranges.append(start..<index)
        }
        return ranges
    }
}

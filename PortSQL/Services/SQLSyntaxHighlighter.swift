import Foundation

enum SQLTokenKind {
    case keyword
    case stringLiteral
    case numberLiteral
    case comment
    case identifier
    case symbol
}

struct SQLToken: Hashable {
    let range: NSRange
    let kind: SQLTokenKind
}

enum SQLSyntaxHighlighter {
    private static let keywords: Set<String> = [
        "ADD", "ALL", "ALTER", "ANALYZE", "AND", "AS", "ASC", "AUTO_INCREMENT", "BEGIN", "BETWEEN",
        "BY", "CASE", "CAST", "COMMIT", "CONSTRAINT", "COUNT", "CREATE", "CURRENT_DATE", "CURRENT_TIME",
        "CURRENT_TIMESTAMP", "DATABASE", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DROP",
        "ELSE", "END", "EXISTS", "EXPLAIN", "FALSE", "FOREIGN", "FROM", "FULL", "GROUP",
        "HAVING", "ILIKE", "IN", "INDEX", "INNER", "INSERT", "INTO", "IS", "JOIN", "KEY",
        "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER",
        "PRIMARY", "REFERENCES", "RETURNING", "RIGHT", "ROLLBACK", "SCHEMA", "SELECT", "SET", "SHOW",
        "TABLE", "TABLES", "THEN", "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UPDATE", "USE", "VALUES",
        "VIEW", "WHEN", "WHERE"
    ]

    private static let longestKeyword = keywords.map(\.count).max() ?? 0

    /// What a character is to the tokenizer. A mark joins the character before it, as an accent does.
    private enum CharacterClass { case letter, number, space, mark, other }

    private static let asciiClasses: [CharacterClass] = (0..<128).map { (code: Int) -> CharacterClass in
        switch UInt8(code) {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"): .letter
        case UInt8(ascii: "0")...UInt8(ascii: "9"): .number
        case 0x09...0x0D, 0x20: .space
        default: .other
        }
    }

    /// Scans UTF-16, the units text views count in, so a token's range needs no conversion and a long
    /// script isn't first split into characters.
    static func tokens(in query: String) -> [SQLToken] {
        let units = Array(query.utf16)
        let count = units.count
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(count / 5)
        var index = 0

        /// The class of the character at a position and the units it takes.
        func classify(_ position: Int) -> (kind: CharacterClass, length: Int) {
            let unit = units[position]
            if unit < 0x80 { return (asciiClasses[Int(unit)], 1) }
            var scalar = Unicode.Scalar(unit), length = 1
            if UTF16.isLeadSurrogate(unit), position + 1 < count, UTF16.isTrailSurrogate(units[position + 1]) {
                scalar = Unicode.Scalar(0x10000 + (UInt32(unit) - 0xD800) << 10 + (UInt32(units[position + 1]) - 0xDC00))
                length = 2
            }
            guard let scalar else { return (.other, length) }
            let properties = scalar.properties
            if properties.numericType != nil { return (.number, length) }
            if properties.isAlphabetic { return (.letter, length) }
            if properties.isWhitespace { return (.space, length) }
            switch properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return (.mark, length)
            // A zero-width joiner holds an emoji sequence together.
            default: return (scalar.value == 0x200D ? .mark : .other, length)
            }
        }
        func add(_ kind: SQLTokenKind, from start: Int) {
            tokens.append(SQLToken(range: NSRange(location: start, length: index - start), kind: kind))
        }
        func unit(_ character: Unicode.Scalar) -> UInt16 { UInt16(character.value) }
        let dash = unit("-"), slash = unit("/"), star = unit("*"), backslash = unit("\\")
        let quote = unit("'"), doubleQuote = unit("\""), backtick = unit("`")
        let underscore = unit("_"), dollar = unit("$"), point = unit("."), newline = unit("\n"), carriageReturn = unit("\r")

        while index < count {
            let start = index
            let first = units[index]

            if first == dash, index + 1 < count, units[index + 1] == dash {
                index += 2
                // A line ends at either character, so a script with Windows line endings colors the same.
                while index < count, units[index] != newline, units[index] != carriageReturn { index += 1 }
                add(.comment, from: start)
                continue
            }

            if first == slash, index + 1 < count, units[index + 1] == star {
                index += 2
                while index + 1 < count, !(units[index] == star && units[index + 1] == slash) { index += 1 }
                // A comment left open runs to the end.
                index = index + 1 < count ? index + 2 : count
                add(.comment, from: start)
                continue
            }

            if first == quote || first == doubleQuote || first == backtick {
                index += 1
                while index < count {
                    if units[index] == backslash { index += min(2, count - index); continue }
                    if units[index] == first {
                        index += 1
                        if first == quote, index < count, units[index] == quote { index += 1; continue }
                        break
                    }
                    index += 1
                }
                add(.stringLiteral, from: start)
                continue
            }

            let (kind, length) = classify(index)
            index += length
            if kind == .number {
                while index < count {
                    let next = classify(index)
                    guard next.kind == .number || next.kind == .mark || units[index] == point else { break }
                    index += next.length
                }
                add(.numberLiteral, from: start)
            } else if kind == .letter || first == underscore {
                var isASCII = first < 0x80
                while index < count {
                    let next = classify(index)
                    guard next.kind == .letter || next.kind == .number || next.kind == .mark
                            || units[index] == underscore || units[index] == dollar else { break }
                    if units[index] >= 0x80 { isASCII = false }
                    index += next.length
                }
                var isKeyword = false
                if isASCII, index - start <= longestKeyword {
                    let uppercased = units[start..<index].map { UInt8($0) &- 97 < 26 ? UInt8($0) &- 32 : UInt8($0) }
                    isKeyword = keywords.contains(String(decoding: uppercased, as: UTF8.self))
                }
                add(isKeyword ? .keyword : .identifier, from: start)
            } else if kind != .space {
                while index < count, case let next = classify(index), next.kind == .mark { index += next.length }
                add(.symbol, from: start)
            }
        }

        return tokens
    }

    /// The part of an edited text whose colors may differ: before it the tokens are the same, and after
    /// it they're the same shifted by the edit's change in length. An editor recolors just this part,
    /// so a keystroke in a long script doesn't lay the whole script out again.
    static func changedRange(from old: [SQLToken], to new: [SQLToken], oldLength: Int, newLength: Int) -> NSRange {
        let delta = newLength - oldLength
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix {
            let before = old[old.count - 1 - suffix], after = new[new.count - 1 - suffix]
            guard before.kind == after.kind, before.range.length == after.range.length,
                  before.range.location + delta == after.range.location else { break }
            suffix += 1
        }
        let start = prefix > 0 ? NSMaxRange(new[prefix - 1].range) : 0
        let end = suffix > 0 ? new[new.count - suffix].range.location : newLength
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Where a range's characters are after an edit that left `edited` in place of text `delta` units
    /// shorter. A range before the edit stays and one after it moves. One the edit touches grows to take
    /// in the new text, which is drawn like its neighbors until it's styled.
    static func range(_ range: NSRange, afterEditing edited: NSRange, changeInLength delta: Int) -> NSRange {
        let replacedEnd = NSMaxRange(edited) - delta
        if NSMaxRange(range) < edited.location { return range }
        if range.location > replacedEnd { return NSRange(location: range.location + delta, length: range.length) }
        let start = min(range.location, edited.location)
        return NSRange(location: start, length: max(NSMaxRange(range) + delta, NSMaxRange(edited)) - start)
    }
}

enum JSONSyntaxHighlighter {
    static func tokens(in text: String) -> [SQLToken] {
        let pattern = #""(?:[^"\\]|\\.)*"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|\b(?:true|false|null)\b|[{}\[\]:,]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            let value = string.substring(with: match.range)
            let kind: SQLTokenKind = value.hasPrefix("\"") ? .stringLiteral
                : ["true", "false", "null"].contains(value) ? .keyword
                : value.first?.isNumber == true || value.hasPrefix("-") ? .numberLiteral : .symbol
            return SQLToken(range: match.range, kind: kind)
        }
    }
}

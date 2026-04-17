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

    static func tokens(in query: String) -> [SQLToken] {
        let characters = Array(query)
        var tokens: [SQLToken] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "-" && index + 1 < characters.count && characters[index + 1] == "-" {
                let start = index
                index += 2
                while index < characters.count && characters[index] != "\n" {
                    index += 1
                }
                tokens.append(SQLToken(range: NSRange(location: start, length: index - start), kind: .comment))
                continue
            }

            if character == "/" && index + 1 < characters.count && characters[index + 1] == "*" {
                let start = index
                index += 2
                while index + 1 < characters.count {
                    if characters[index] == "*" && characters[index + 1] == "/" {
                        index += 2
                        break
                    }
                    index += 1
                }
                tokens.append(SQLToken(range: NSRange(location: start, length: index - start), kind: .comment))
                continue
            }

            if character == "'" || character == "\"" || character == "`" {
                let delimiter = character
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" {
                        index += min(2, characters.count - index)
                        continue
                    }
                    if characters[index] == delimiter {
                        index += 1
                        if delimiter == "'" && index < characters.count && characters[index] == "'" {
                            index += 1
                            continue
                        }
                        break
                    }
                    index += 1
                }
                tokens.append(SQLToken(range: NSRange(location: start, length: index - start), kind: .stringLiteral))
                continue
            }

            if character.isNumber {
                let start = index
                index += 1
                while index < characters.count && (characters[index].isNumber || characters[index] == ".") {
                    index += 1
                }
                tokens.append(SQLToken(range: NSRange(location: start, length: index - start), kind: .numberLiteral))
                continue
            }

            if character.isLetter || character == "_" {
                let start = index
                index += 1
                while index < characters.count && (characters[index].isLetter || characters[index].isNumber || characters[index] == "_" || characters[index] == "$") {
                    index += 1
                }
                let token = String(characters[start..<index]).uppercased()
                let kind: SQLTokenKind = keywords.contains(token) ? .keyword : .identifier
                tokens.append(SQLToken(range: NSRange(location: start, length: index - start), kind: kind))
                continue
            }

            if !character.isWhitespace {
                tokens.append(SQLToken(range: NSRange(location: index, length: 1), kind: .symbol))
            }
            index += 1
        }

        return tokens
    }
}

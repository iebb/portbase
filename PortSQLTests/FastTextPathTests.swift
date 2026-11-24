import XCTest
@testable import PortSQL

/// Copying, exporting and checking a script read their text as bytes where they used an encoder or a
/// regular expression for each value. Each is checked here against what it replaced.
final class FastTextPathTests: XCTestCase {
    /// The same values every run.
    private struct Sequence: RandomNumberGenerator {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state ^ (state >> 29)
        }
    }

    private func random(_ characters: [Character], upTo length: Int, using generator: inout Sequence) -> String {
        String((0..<Int.random(in: 0...length, using: &generator)).map { _ in characters.randomElement(using: &generator)! })
    }

    func testNumbersAreJudgedAsTheExpressionJudgedThem() {
        func earlier(_ value: String) -> Bool {
            value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
        }
        var texts = ["", "0", "-0", "00", "01", "10", "-", "-1", "--1", "+1", "1.", ".5", "1.5", "1.50", "1e5", "1E5", "1e+5", "1e-5", "1e", "1e+", "1.e5", "1.5e", "0.0e0",
                     "0e0", "-0.0", "1 ", " 1", "1\n", "1\r", "1\r\n", "1\n\n", "1\n\r", "\n1", "1\u{0B}", "1\u{0C}", "1\u{85}", "1\u{2028}", "1\u{2029}", "1\u{2028}\n",
                     "1\t", "1\u{A0}", "١", "１", "1e5\n", "1.5\r\n", "NaN", "nan", "Infinity", "0x10", "1_000", "1,000", "9007199254740993", "1e999", "-1.0E-10", "1\0"]
        var generator = Sequence()
        let characters = Array("0011223456789..--++eE \n\r\u{2028}x")
        for _ in 0..<20_000 { texts.append(random(characters, upTo: 7, using: &generator)) }
        for text in texts {
            // Whether the expression's `$` also matched before a final line break depended on the system's
            // version. A number followed by one is not a number.
            let endsInBreak = text.unicodeScalars.last.map { CharacterSet.newlines.contains($0) } ?? false
            let expected = endsInBreak ? false : earlier(text)
            XCTAssertEqual(JSONText.isNumber(text), expected, text.debugDescription)
            XCTAssertEqual(DataTransferCodec.isJSONNumber(text), expected, text.debugDescription)
        }
    }

    func testStringsAreWrittenAsTheEncodersWroteThem() throws {
        var texts = ["", "plain", "a b", "it's", "say \"hi\"", "C:\\temp", "a/b", "https://example.com/a?b=c", "line\nbreak", "tab\there", "\r\n", "\0", "\u{1F}", "\u{7F}",
                     "日本語", "naïve café", "👩🏽‍💻", "e\u{301}", "\u{2028}", "\u{2029}", "\u{FEFF}", "</script>", "{\"a\": [1, 2]}", "null", " ", "\u{85}"]
        var generator = Sequence()
        let characters = Array("abc 123\"\\/\n\t\r\u{1}\u{7F}é日🦊{}[]:,")
        for _ in 0..<3_000 { texts.append(random(characters, upTo: 10, using: &generator)) }
        for text in texts {
            XCTAssertEqual(DataTransferCodec.jsonString(text), String(decoding: try JSONEncoder().encode(text), as: UTF8.self), text.debugDescription)
            // A copy's JSON and the typed cells spell some escapes their own way; what they decode to is the text.
            let copied = ResultCopyFormatter.jsonString(text)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(copied.utf8)), text, text.debugDescription)
            var typed: [UInt8] = []
            JSONText.append(text, to: &typed)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(typed)), text, text.debugDescription)
        }
        XCTAssertEqual(ResultCopyFormatter.jsonString("a/b \"c\"\n\u{1}"), #""a/b \"c\"\n\u0001""#)
    }

    func testTypedCellsDecodeToWhatWasCopied() throws {
        var generator = Sequence()
        let characters = Array("ab 1\"\\/\n\t\r\u{1}é日🦊,")
        var rows = [
            QueryRow(cells: [.null, .text(""), .text("NULL"), .integer("42"), .decimal("-1.50"), .boolean(true), .boolean(false), .dateTime("2026-01-05 10:20:30+00:00"),
                             .json("{\"a\": [1, \"x\"]}"), .binary(Data()), .binary(Data((0...255).map(UInt8.init))),
                             .extendedJSON(canonical: "{\"$numberLong\":\"7\"}", display: "7")]),
            QueryRow(cells: []),
        ]
        for _ in 0..<300 {
            rows.append(QueryRow(cells: (0..<12).map { index in
                let text = random(characters, upTo: 9, using: &generator)
                switch index % 6 {
                case 0: return .text(text)
                case 1: return .json(text)
                case 2: return .dateTime(text)
                case 3: return .extendedJSON(canonical: text, display: String(text.reversed()))
                case 4: return .binary(Data(text.utf8))
                default: return index == 5 ? .null : .decimal(text)
                }
            }))
        }
        let columns = (0..<12).map { QueryColumn(name: $0 == 3 ? "odd \"name\"\n" : "column_\($0)", type: "text",
                                                 origin: $0 == 1 ? QueryColumnOrigin(schema: "public", table: "t", column: "c", postgresTableOID: 7, postgresAttributeNumber: 2) : nil) }
        for payload in [ResultGridClipboard.Payload(columns: columns, rows: rows), ResultGridClipboard.Payload(columns: [], rows: []),
                        ResultGridClipboard.Payload(columns: Array(columns.prefix(1)), rows: [QueryRow(cells: [.text("only")])])] {
            let data = try XCTUnwrap(ResultGridClipboard.typedData(payload))
            let decoded = try JSONDecoder().decode(ResultGridClipboard.Payload.self, from: data)
            XCTAssertEqual(decoded.rows.map(\.cells), payload.rows.map(\.cells))
            XCTAssertEqual(decoded.columns.map(\.name), payload.columns.map(\.name))
            XCTAssertEqual(decoded.columns.map(\.type), payload.columns.map(\.type))
            XCTAssertEqual(decoded.columns.map(\.origin), payload.columns.map(\.origin))
            // And nothing the encoder writes is left out.
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? NSDictionary
            XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary, encoded)
        }
    }

    func testCopiedTextQuotesWhatNeedsIt() {
        let payload = ResultGridClipboard.Payload(
            columns: [QueryColumn(name: "a,b", type: "text"), QueryColumn(name: "plain", type: "text")],
            rows: [QueryRow(cells: [.text("one\r\ntwo"), .text("it's")]), QueryRow(cells: [.text(" lead"), .text("trail ")]),
                   QueryRow(cells: [.text("re\rturn"), .text("say \"hi\"")]), QueryRow(cells: [.text("back\\slash"), .text("pipe|d")]),
                   QueryRow(cells: [.text(""), .null])])
        XCTAssertEqual(ResultCopyFormatter.text(payload, format: .csv),
                       "\"a,b\",plain\n\"one\r\ntwo\",it's\n\" lead\",\"trail \"\n\"re\rturn\",\"say \"\"hi\"\"\"\nback\\slash,pipe|d\n\"\",",
                       "A field holding a Windows line break is quoted like any other line break")
        XCTAssertEqual(ResultGridClipboard.parse(ResultGridClipboard.text(payload, headers: false)),
                       [["one\ntwo", "it's"], [" lead", "trail "], ["re\rturn", "say \"hi\""], ["back\\slash", "pipe|d"], ["", nil]])
        XCTAssertEqual(ResultCopyFormatter.text(payload, format: .markdown).components(separatedBy: "\n").dropFirst(2).map { $0 },
                       ["| one<br>two | it's |", "|  lead | trail  |", "| re\rturn | say \"hi\" |", "| back\\slash | pipe\\|d |", "|  | *NULL* |"])
        XCTAssertEqual(ResultCopyFormatter.literal(.text("it's"), engine: .postgresql), "'it''s'")
        XCTAssertEqual(ResultCopyFormatter.literal(.text("back\\slash"), engine: .postgresql), "'back\\slash'")
        XCTAssertEqual(ResultCopyFormatter.literal(.text("back\\slash's"), engine: .mysql), "'back\\\\slash''s'")
        XCTAssertEqual(ResultCopyFormatter.literal(.text("plain"), engine: .clickhouse), "'plain'")
        XCTAssertEqual(ResultCopyFormatter.literal(.integer("12"), engine: .mysql), "12")
        XCTAssertEqual(ResultCopyFormatter.literal(.integer("1 OR 1"), engine: .mysql), "'1 OR 1'")
    }

    func testKeywordsAreFoundAsTheExpressionFoundThem() {
        func earlier(_ word: String, in text: String) -> Bool {
            text.range(of: #"(^|[^A-Z0-9_])\#(word)($|[^A-Z0-9_])"#, options: .regularExpression) != nil
        }
        let words = ["INSERT", "UPDATE", "DELETE", "MERGE", "DROP", "TRUNCATE", "ALTER", "CREATE", "RENAME", "REPLACE", "UPSERT"]
        var texts = ["", "DROP", "DROP TABLE T", "SELECT DROP", "SELECT DROPS", "SELECT XDROP", "SELECT _DROP", "SELECT DROP_", "SELECT DROP1", "SELECT 1DROP",
                     "SELECT(DROP)", "DROP;DROP", "XDROP DROP", "DROPDROP", "DROPDROP DROP", "drop", "SELECT éDROPé", "SELECT DROP\n", "\nDROP", "SELECT DROP\u{2028}",
                     "DRO", "SELECT 'A' FROM T WHERE REPLACED = 1", "CREATED_AT", "LAST_UPDATE", "UPDATE", "UPDATE T SET A = 1", "INSERTED INSERT", "日本DELETE語"]
        var generator = Sequence()
        let pieces = words + ["SELECT", " ", " ", "_", "1", "X", "(", ")", ";", "\n", "é", "DRO", "ATE", "RE"]
        for _ in 0..<6_000 {
            texts.append((0..<Int.random(in: 1...6, using: &generator)).map { _ in pieces.randomElement(using: &generator)! }.joined())
        }
        for text in texts {
            for word in words {
                XCTAssertEqual(SQLSafetyService.containsWord(word, in: text), earlier(word, in: text), "\(word) in \(text.debugDescription)")
            }
        }
        XCTAssertFalse(SQLSafetyService.isReadOnlySQL("SELECT 1; DROP TABLE t", engine: .postgresql))
        XCTAssertTrue(SQLSafetyService.isReadOnlySQL("SELECT created_at, last_update FROM dropped WHERE replaced = 1", engine: .postgresql))
        XCTAssertFalse(SQLSafetyService.isReadOnlySQL("WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x", engine: .postgresql))
    }

    func testAnExportLargerThanItsBufferIsWrittenWhole() throws {
        let long = String(repeating: "wide value, with a \"quote\" ", count: 40)
        for format in [QueryResultExportFormat.json, .csv] {
            let writer = try DataExportWriter(format: format, progress: { _ in })
            defer { writer.discard() }
            writer.setColumns([QueryColumn(name: "id", type: "integer"), QueryColumn(name: "a/b", type: "text"), QueryColumn(name: "id", type: "integer")])
            for index in 0..<400 { try writer.append(QueryRow(cells: [.integer(String(index)), .text(long + String(index)), index % 7 == 0 ? .null : .decimal("1.5")])) }
            let result = try writer.finish()
            XCTAssertEqual(result.rowCount, 400)
            let data = try Data(contentsOf: XCTUnwrap(result.fileURL))
            XCTAssertGreaterThan(data.count, 400_000, "Several times the buffer")
            if format == .json {
                let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                XCTAssertEqual(rows.count, 400)
                XCTAssertEqual(rows[399]["id"] as? Int, 399)
                XCTAssertEqual(rows[399]["a/b"] as? String, long + "399")
                XCTAssertTrue(rows[399]["id_2"] is NSNull)
                XCTAssertEqual(rows[398]["id_2"] as? Double, 1.5)
                XCTAssertEqual(Set(rows[0].keys).count, 3)
            } else {
                let source = try DataTransferCodec.inspect(url: XCTUnwrap(result.fileURL), format: .csv, hasHeader: true, nullToken: "NULL")
                XCTAssertEqual(source.columnNames.first, "id")
                XCTAssertTrue(String(decoding: data.suffix(40), as: UTF8.self).hasSuffix("399\",NULL\r\n"))
                XCTAssertEqual(String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n").count, 402)
            }
        }
    }
}

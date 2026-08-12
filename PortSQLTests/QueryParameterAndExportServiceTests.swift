import XCTest
@testable import PortSQL

final class QueryParameterAndExportServiceTests: XCTestCase {
    func testParametersIgnorePostgresCastsAndPreviewExactStrings() {
        let sql = "SELECT :name::text AS name, :enabled AS enabled, :limit_value AS limit_value"

        XCTAssertEqual(QueryParameterService.parameters(in: sql), ["enabled", "limit_value", "name"])

        let rendered = QueryParameterService.render(
            sql: sql,
            values: [
                "name": "O'Hara",
                "enabled": "true",
                "limit_value": "25"
            ]
        )

        XCTAssertEqual(rendered, "SELECT 'O''Hara'::text AS name, 'true' AS enabled, '25' AS limit_value")
    }

    func testRenderPreservesBlankParameterAsEmptyString() {
        let rendered = QueryParameterService.render(
            sql: "SELECT * FROM users WHERE deleted_at IS :deletedAt",
            values: ["deletedAt": "  "]
        )

        XCTAssertEqual(rendered, "SELECT * FROM users WHERE deleted_at IS '  '")
    }

    func testRenderShowsExplicitNull() {
        let rendered = QueryParameterService.render(
            sql: "SELECT :blank, :missing",
            values: ["blank": "", "missing": "ignored"],
            nullParameters: ["missing"]
        )

        XCTAssertEqual(rendered, "SELECT '', NULL")
    }

    func testBoundQueryUsesTypedPlaceholdersAndIgnoresParametersInCommentsAndLiterals() throws {
        let sql = "SELECT ':literal', :name -- :comment\nWHERE id = :id AND active = :active"
        XCTAssertEqual(QueryParameterService.parameters(in: sql), ["active", "id", "name"])

        let bound = try QueryParameterService.boundQuery(
            sql: sql,
            values: ["name": "O'Hara", "id": "42", "active": "true"],
            engine: .postgresql
        )

        XCTAssertEqual(
            bound.sql,
            "SELECT ':literal', $1 -- :comment\nWHERE id = $2 AND active = $3"
        )
        XCTAssertEqual(bound.values, [.string("O'Hara"), .string("42"), .string("true")])
    }

    func testPostgresLexerPreservesJSONOperatorsAndIgnoresDollarQuotedBodies() throws {
        let sql = "SELECT payload #>> '{path}', $$:not_a_parameter$$, :actual"

        XCTAssertEqual(QueryParameterService.parameters(in: sql, engine: .postgresql), ["actual"])
        XCTAssertEqual(
            try QueryParameterService.boundQuery(sql: sql, values: ["actual": "00123"], engine: .postgresql),
            BoundQuery(sql: "SELECT payload #>> '{path}', $$:not_a_parameter$$, $1", values: [.string("00123")])
        )
    }

    func testMixedNativeAndNamedPlaceholdersFailClosed() {
        let sql = "SELECT $1, :name"
        XCTAssertThrowsError(
            try QueryParameterService.boundQuery(sql: sql, values: ["name": "Tokyo"], engine: .postgresql)
        ) { error in
            XCTAssertEqual(error as? QueryParameterError, .mixedPlaceholderStyles)
        }
    }

    func testNativePlaceholderDetectionIgnoresLexicalBodies() throws {
        let postgres = "SELECT '$1', $$ $2 $$, :name -- $3\n/* $4 */"
        let mysql = "SELECT '?', :name # ?\n/* ? */"

        XCTAssertEqual(
            try QueryParameterService.boundQuery(sql: postgres, values: ["name": "Tokyo"], engine: .postgresql),
            BoundQuery(sql: "SELECT '$1', $$ $2 $$, $1 -- $3\n/* $4 */", values: [.string("Tokyo")])
        )
        XCTAssertEqual(
            try QueryParameterService.boundQuery(sql: mysql, values: ["name": "Tokyo"], engine: .mysql),
            BoundQuery(sql: "SELECT '?', ? # ?\n/* ? */", values: [.string("Tokyo")])
        )
    }

    func testExplicitNullDoesNotBindOrTreatLiteralNullAsNull() throws {
        let bound = try QueryParameterService.boundQuery(
            sql: "SELECT :literal_null, :explicit_null, :blank",
            values: ["literal_null": "NULL", "explicit_null": "ignored", "blank": ""],
            nullParameters: ["explicit_null"],
            engine: .postgresql
        )

        XCTAssertEqual(bound.sql, "SELECT $1, NULL, $2")
        XCTAssertEqual(bound.values, [.string("NULL"), .string("")])
        XCTAssertEqual(
            QueryParameterService.render(
                sql: "SELECT :literal_null, :explicit_null, :blank",
                values: ["literal_null": "NULL", "explicit_null": "ignored", "blank": ""],
                nullParameters: ["explicit_null"]
            ),
            "SELECT 'NULL', NULL, ''"
        )
    }

    func testCSVExportEscapesCellsAndAlignsRowsToColumns() throws {
        let result = QueryResultTable(
            columns: [
                QueryColumn(name: "name", type: "text"),
                QueryColumn(name: "note", type: "text")
            ],
            rows: [
                QueryRow(values: ["O\"Hara", "line\nbreak"]),
                QueryRow(values: ["missing-note"])
            ],
            executionSummary: "2 rows",
            generatedMutation: nil,
            profiles: [],
            sourceTableReference: nil,
            sourceQuery: nil
        )

        let url = try XCTUnwrap(QueryResultExportService.write(result, format: .csv))
        let csv = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(csv, "\"name\",\"note\"\n\"O\"\"Hara\",\"line\nbreak\"\n\"missing-note\",NULL")
    }

    func testCSVExportDistinguishesNullFromEmptyText() throws {
        let result = QueryResultTable(
            columns: [
                QueryColumn(name: "empty", type: "text"),
                QueryColumn(name: "missing", type: "text")
            ],
            rows: [QueryRow(cells: [.text(""), .null])],
            executionSummary: "1 row",
            generatedMutation: nil,
            profiles: [],
            sourceTableReference: nil
        )

        let url = try XCTUnwrap(QueryResultExportService.write(result, format: .csv))
        let csv = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(csv, "\"empty\",\"missing\"\n\"\",NULL")
    }

    func testJSONExportUsesColumnNamesAndPrettyPrintedRows() throws {
        let result = QueryResultTable(
            columns: [
                QueryColumn(name: "id", type: "int"),
                QueryColumn(name: "name", type: "text")
            ],
            rows: [
                QueryRow(values: ["1", "Tokyo"])
            ],
            executionSummary: "1 row",
            generatedMutation: nil,
            profiles: [],
            sourceTableReference: nil,
            sourceQuery: nil
        )

        let url = try XCTUnwrap(QueryResultExportService.write(result, format: .json))
        let data = try Data(contentsOf: url)
        let objects = try JSONSerialization.jsonObject(with: data) as? [[String: String]]

        XCTAssertEqual(objects, [["id": "1", "name": "Tokyo"]])
    }

    func testJSONExportPreservesNullTypesAndDisambiguatesDuplicateColumns() throws {
        let result = QueryResultTable(
            columns: [
                QueryColumn(name: "id", type: "int"),
                QueryColumn(name: "id", type: "int"),
                QueryColumn(name: "empty", type: "text"),
                QueryColumn(name: "missing", type: "text")
            ],
            rows: [
                QueryRow(cells: [.integer("1"), .integer("2"), .text(""), .null])
            ],
            executionSummary: "1 row",
            generatedMutation: nil,
            profiles: [],
            sourceTableReference: nil
        )

        let url = try XCTUnwrap(QueryResultExportService.write(result, format: .json))
        let data = try Data(contentsOf: url)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        XCTAssertEqual(objects.first?["id"] as? Int, 1)
        XCTAssertEqual(objects.first?["id_2"] as? Int, 2)
        XCTAssertEqual(objects.first?["empty"] as? String, "")
        XCTAssertTrue(objects.first?["missing"] is NSNull)
    }
}

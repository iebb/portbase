import XCTest
@testable import PortSQL

final class DataEditorValidationServiceTests: XCTestCase {
    func testInsertAllowsAutoIncrementIntegerPrimaryKeyToBeBlank() {
        let fields = [
            field(name: "id", type: "int", isNullable: false, isPrimaryKey: true, value: ""),
            field(name: "name", type: "varchar", isNullable: false, value: "Tokyo")
        ]

        let errors = DataEditorValidationService.validate(
            fields: fields,
            mode: .insert,
            engine: .mysql
        )

        XCTAssertNil(errors[fields[0].id])
        XCTAssertTrue(errors.isEmpty)
    }

    func testInsertRejectsInvalidIntegerValues() {
        let fields = [
            field(name: "customerNumber", type: "int", isNullable: false, isPrimaryKey: true, value: "abc")
        ]

        let errors = DataEditorValidationService.validate(
            fields: fields,
            mode: .insert,
            engine: .mysql
        )

        XCTAssertEqual(errors[fields[0].id], "Enter an integer")
    }

    func testUpdateRejectsInvalidDecimalValues() {
        let fields = [
            field(name: "amount", type: "decimal(10,2)", isNullable: false, value: "oops")
        ]

        let errors = DataEditorValidationService.validate(
            fields: fields,
            mode: .update,
            engine: .mysql
        )

        XCTAssertEqual(errors[fields[0].id], "Enter a number")
    }

    func testValidateRejectsInvalidDateTimeAndJSONValues() {
        let dateField = field(name: "createdAt", type: "datetime", isNullable: false, value: "2026-04-17")
        let jsonField = field(name: "payload", type: "json", isNullable: false, value: "{bad json}")

        let errors = DataEditorValidationService.validate(
            fields: [dateField, jsonField],
            mode: .insert,
            engine: .mysql
        )

        XCTAssertEqual(errors[dateField.id], "Use YYYY-MM-DD HH:MM:SS")
        XCTAssertEqual(errors[jsonField.id], "Enter valid JSON")
    }

    func testSQLLiteralEscapesStringsAndNormalizesPostgresBooleans() {
        let textField = field(name: "name", type: "varchar", isNullable: false, value: "O'Hara")
        let boolField = field(name: "enabled", type: "boolean", isNullable: false, value: "true")

        XCTAssertEqual(
            DataEditorValidationService.sqlLiteral(for: textField, engine: .mysql),
            "'O''Hara'"
        )
        XCTAssertEqual(
            DataEditorValidationService.sqlLiteral(for: boolField, engine: .postgresql),
            "TRUE"
        )
    }

    private func field(
        name: String,
        type: String,
        isNullable: Bool,
        isPrimaryKey: Bool = false,
        value: String
    ) -> DataEditorField {
        DataEditorField(
            column: SchemaColumnDescriptor(
                name: name,
                type: type,
                isNullable: isNullable,
                isPrimaryKey: isPrimaryKey,
                isUnique: false
            ),
            value: value,
            originalValue: nil,
            isEditable: true
        )
    }
}

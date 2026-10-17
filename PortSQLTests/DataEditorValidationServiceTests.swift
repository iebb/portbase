import XCTest
@testable import PortSQL

#if canImport(MySQLNIO)
import MySQLNIO
#endif

#if canImport(PostgresNIO)
import NIOCore
import PostgresNIO
#endif

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

    func testBoundValuePreservesRawTextAndUsesTypedBooleans() {
        let textField = field(name: "name", type: "varchar", isNullable: false, value: "  O'Hara\\path  ")
        let boolField = field(name: "enabled", type: "boolean", isNullable: false, value: "true")

        XCTAssertEqual(
            DataEditorValidationService.boundValue(for: textField),
            .string("  O'Hara\\path  ")
        )
        XCTAssertEqual(
            DataEditorValidationService.boundValue(for: boolField),
            .boolean(true)
        )
    }

    func testBoundValueDistinguishesEmptyStringFromExplicitNull() {
        let empty = field(name: "note", type: "text", isNullable: true, value: "")
        var null = empty
        null.isNull = true

        XCTAssertEqual(DataEditorValidationService.boundValue(for: empty), .string(""))
        XCTAssertEqual(DataEditorValidationService.boundValue(for: null), .null)
    }

    func testNotNullTextAcceptsAndBindsEmptyString() {
        let empty = field(name: "code", type: "varchar(20)", isNullable: false, value: "")

        let errors = DataEditorValidationService.validate(
            fields: [empty],
            mode: .update,
            engine: .postgresql
        )

        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(DataEditorValidationService.boundValue(for: empty), .string(""))
    }

    #if canImport(MySQLNIO)
    func testMySQLTemporalFormattingMatchesEditorInputFormats() {
        let value = MySQLTime(
            year: 2026,
            month: 8,
            day: 12,
            hour: 9,
            minute: 7,
            second: 5,
            microsecond: 123_000
        )

        XCTAssertEqual(DatabaseService.formatMySQLDate(value), "2026-08-12")
        XCTAssertEqual(DatabaseService.formatMySQLTime(value), "09:07:05.123")
        XCTAssertEqual(DatabaseService.formatMySQLDateTime(value), "2026-08-12 09:07:05.123")
    }

    func testMySQLBinaryTimePreservesSignDaysAndModernTemporalTypes() throws {
        var buffer = ByteBufferAllocator().buffer(capacity: 8)
        buffer.writeInteger(UInt8(1))
        buffer.writeInteger(UInt32(2), endianness: .little)
        buffer.writeInteger(UInt8(3))
        buffer.writeInteger(UInt8(4))
        buffer.writeInteger(UInt8(5))
        let data = MySQLData(type: .time2, format: .binary, buffer: buffer)
        let time = try XCTUnwrap(data.time)

        XCTAssertTrue(time.isNegative)
        XCTAssertEqual(time.hour, 51)
        XCTAssertEqual(DatabaseService.formatMySQLTime(time), "-51:04:05")
    }

    func testMySQLBinaryYearDecodesAsInteger() {
        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.writeInteger(UInt16(2026), endianness: .little)
        let data = MySQLData(type: .year, format: .binary, buffer: buffer, isUnsigned: true)

        XCTAssertEqual(data.uint16, 2026)
    }
    #endif

    #if canImport(PostgresNIO)
    func testPostgresBinaryTimeAndTimeZoneFormatting() {
        let microseconds: Int64 = 32_825_123_000
        var timeBuffer = ByteBufferAllocator().buffer(capacity: 8)
        timeBuffer.writeInteger(microseconds)
        let time = PostgresData(type: .time, formatCode: .binary, value: timeBuffer)

        var timeZoneBuffer = ByteBufferAllocator().buffer(capacity: 12)
        timeZoneBuffer.writeInteger(microseconds)
        timeZoneBuffer.writeInteger(Int32(-9 * 3_600))
        let timeZone = PostgresData(type: .timetz, formatCode: .binary, value: timeZoneBuffer)

        XCTAssertEqual(DatabaseService.postgresTimeText(time), "09:07:05.123")
        XCTAssertEqual(DatabaseService.postgresTimeText(timeZone), "09:07:05.123+09:00")
    }

    func testPostgresTimestampFormattingPreservesAllMicroseconds() {
        var timestampBuffer = ByteBufferAllocator().buffer(capacity: 8)
        timestampBuffer.writeInteger(Int64(123_456))
        let timestamp = PostgresData(type: .timestamp, formatCode: .binary, value: timestampBuffer)

        var zonedBuffer = ByteBufferAllocator().buffer(capacity: 8)
        zonedBuffer.writeInteger(Int64(123_456))
        let zoned = PostgresData(type: .timestamptz, formatCode: .binary, value: zonedBuffer)

        XCTAssertEqual(DatabaseService.postgresTimestampText(timestamp), "2000-01-01 00:00:00.123456")
        XCTAssertEqual(DatabaseService.postgresTimestampText(zoned), "2000-01-01 00:00:00.123456+00:00")
    }
    #endif

    func testIPAddressDetectionCoversIPv4IPv6AndDNS() {
        XCTAssertTrue(DatabaseService.isIPAddress("192.0.2.10"))
        XCTAssertTrue(DatabaseService.isIPAddress("2001:db8::1"))
        XCTAssertFalse(DatabaseService.isIPAddress("database.example.com"))
    }

    func testFractionalZonedTemporalValuesAndNonIntegerTypeNamesValidate() {
        let values = [
            field(name: "at", type: "timestamptz", isNullable: false, value: "2026-08-12 09:07:05.123456+09:00"),
            field(name: "clock", type: "timetz", isNullable: false, value: "09:07:05.123+09:00"),
            field(name: "duration", type: "interval", isNullable: false, value: "1 day"),
            field(name: "location", type: "point", isNullable: false, value: "(1,2)")
        ]

        XCTAssertTrue(DataEditorValidationService.validate(fields: values, mode: .update, engine: .postgresql).isEmpty)
        XCTAssertEqual(DataEditorValidationService.boundValue(for: values[2]), .string("1 day"))
        XCTAssertEqual(DataEditorValidationService.boundValue(for: values[3]), .string("(1,2)"))
    }

    func testBinaryCellsAreRecognizedForFailClosedEditing() {
        XCTAssertTrue(QueryCell.binary(Data([0xde, 0xad])).isBinary)
        XCTAssertFalse(QueryCell.text("0xdead").isBinary)
        XCTAssertTrue(WorkspaceViewModel.isUnsupportedBinaryColumn(
            SchemaColumnDescriptor(
                name: "payload",
                type: "VARBINARY(255)",
                isNullable: true,
                isPrimaryKey: false,
                isUnique: false
            )
        ))
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

final class CellValueEditorTests: XCTestCase {
    private func column(_ type: String) -> SchemaColumnDescriptor {
        SchemaColumnDescriptor(name: "value", type: type, isNullable: true, isPrimaryKey: false, isUnique: false)
    }

    func testValueKindPicksAnEditorForEachType() {
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("boolean")), .boolean)
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("bigint")), .integer)
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("decimal(12,4)")), .decimal)
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("date")), .date)
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("datetime(6)")), .dateTime(hasTimeZone: false))
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("timestamp with time zone")), .dateTime(hasTimeZone: true))
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("time")), .time(hasTimeZone: false))
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("uuid")), .uuid)
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("jsonb")), .json)
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("bytea")), .binary)
        XCTAssertEqual(DataEditorValidationService.valueKind(for: column("varchar(255)")), .text)
    }

    func testTemporalValueRoundTripsItsOriginalShape() throws {
        for (text, kind) in [
            ("2024-02-29", DataEditorValueKind.date),
            ("2024-02-29T23:59:58.123456+05:30", .dateTime(hasTimeZone: true)),
            ("2024-02-29 01:02:03+00", .dateTime(hasTimeZone: true)),
            ("2024-02-29 01:02:03", .dateTime(hasTimeZone: false)),
            ("07:08:09.5", .time(hasTimeZone: false)),
        ] {
            XCTAssertEqual(try XCTUnwrap(TemporalEditValue(text, kind: kind)).text, text)
        }
    }

    func testPickerChangesOnlyShownPartsAndKeepsSecondsFractionAndZone() throws {
        var value = try XCTUnwrap(TemporalEditValue("2024-01-15T10:20:30.000123+09:00", kind: .dateTime(hasTimeZone: true)))
        let picked = try XCTUnwrap(TemporalEditValue.calendar.date(from: DateComponents(year: 2025, month: 6, day: 1, hour: 4, minute: 5, second: 0)))
        value.apply(picked)
        XCTAssertEqual(value.text, "2025-06-01T04:05:30.000123+09:00")
    }

    func testDurationsAndImpossibleDatesStayTextOnly() {
        XCTAssertNil(TemporalEditValue("838:59:59", kind: .time(hasTimeZone: false)))
        XCTAssertNil(TemporalEditValue("-01:00:00", kind: .time(hasTimeZone: false)))
        XCTAssertNil(TemporalEditValue("2023-02-29", kind: .date))
        XCTAssertNil(TemporalEditValue("not a date", kind: .date))
    }

    func testNowUsesLocalWallClockAndOffsetForZonedColumns() throws {
        var value = try XCTUnwrap(TemporalEditValue("2000-01-01 00:00:00.5+00", kind: .dateTime(hasTimeZone: true)))
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: -(3 * 3600 + 30 * 60)))
        value.setNow(Date(timeIntervalSince1970: 0), timeZone: zone)
        XCTAssertEqual(value.text, "1969-12-31 20:30:00-03:30")
    }
}

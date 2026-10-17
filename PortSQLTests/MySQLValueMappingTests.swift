import MySQLNIO
import NIOCore
import XCTest
@testable import PortSQL

/// MySQL values and column types as Portbase shows them.
final class MySQLValueMappingTests: XCTestCase {
    private func buffer(_ text: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return buffer
    }

    func testJSONColumnsShowTheirTextInBothProtocols() {
        // JSON is sent with the binary character set; it must not fall through to raw bytes (shown as 0x… hex).
        for format in [MySQLData.Format.binary, .text] {
            let data = MySQLData(type: .json, format: format, buffer: buffer(#"["GR"]"#))
            XCTAssertEqual(DatabaseService.cell(mysql: data, columnType: .json, flags: [], characterSet: .binary), .json(#"["GR"]"#), "\(format)")
        }
        let blob = MySQLData(type: .blob, format: .binary, buffer: buffer("raw"))
        XCTAssertEqual(DatabaseService.cell(mysql: blob, columnType: .blob, flags: [], characterSet: .binary), .binary(Data("raw".utf8)),
                       "Real binary columns stay bytes")
        XCTAssertEqual(DatabaseService.cell(mysql: MySQLData(type: .json, format: .binary, buffer: nil), columnType: .json, flags: [], characterSet: .binary), .null)
    }

    func testDecimalsKeepTheirScale() {
        for format in [MySQLData.Format.binary, .text] {
            for text in ["0.0000", "12.5000", "-0.0100", "1234567890.123456789"] {
                let data = MySQLData(type: .newdecimal, format: format, buffer: buffer(text))
                XCTAssertEqual(DatabaseService.cell(mysql: data, columnType: .newdecimal, flags: [], characterSet: .binary), .decimal(text), "\(format) \(text)")
            }
        }
    }

    func testColumnTypesReadAsDDLNames() {
        let utf8: MySQLProtocol.CharacterSet = .utf8mb4
        XCTAssertEqual(DatabaseService.mysqlTypeName(columnType: .varString, flags: [], characterSet: utf8), "varchar")
        XCTAssertEqual(DatabaseService.mysqlTypeName(columnType: .varString, flags: [], characterSet: .binary), "varbinary")
        XCTAssertEqual(DatabaseService.mysqlTypeName(columnType: .long, flags: .COLUMN_UNSIGNED, characterSet: .binary), "int unsigned")
        XCTAssertEqual(DatabaseService.mysqlTypeName(columnType: .longlong, flags: [], characterSet: .binary), "bigint")
        XCTAssertEqual(DatabaseService.mysqlTypeName(columnType: .json, flags: [], characterSet: .binary), "json")
        XCTAssertEqual(DatabaseService.mysqlTypeName(columnType: .blob, flags: [], characterSet: utf8), "text")
        XCTAssertEqual(DatabaseService.mysqlTypeName(columnType: .datetime2, flags: [], characterSet: .binary), "datetime")
        XCTAssertEqual(DatabaseService.mysqlTypeName(columnType: .string, flags: MySQLProtocol.ColumnFlags(rawValue: 0x0100), characterSet: utf8), "enum")
    }
}

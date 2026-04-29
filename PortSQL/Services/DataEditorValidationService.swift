import Foundation
import SwiftUI
import UIKit

enum DataEditorValidationService {
    static func validate(
        fields: [DataEditorField],
        mode: DataEditorMode,
        engine: DatabaseEngine
    ) -> [UUID: String] {
        var errors: [UUID: String] = [:]

        for field in fields {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = field.column.type.lowercased()
            let canOmitOnInsert = mode == .insert && field.column.isPrimaryKey && isIntegerType(type)

            if value.isEmpty {
                if !field.column.isNullable && !(mode == .insert && canOmitOnInsert) {
                    errors[field.id] = "Required"
                }
                continue
            }

            if isIntegerType(type), Int(value) == nil {
                errors[field.id] = "Enter an integer"
            } else if isDecimalType(type), Decimal(string: value) == nil {
                errors[field.id] = "Enter a number"
            } else if isBooleanType(type), normalizedBooleanLiteral(for: value, engine: engine) == nil {
                errors[field.id] = "Use true/false or 1/0"
            } else if isDateType(type), !isValidDate(value) {
                errors[field.id] = "Use YYYY-MM-DD"
            } else if isDateTimeType(type), !isValidDateTime(value) {
                errors[field.id] = "Use YYYY-MM-DD HH:MM:SS"
            } else if isTimeType(type), !isValidTime(value) {
                errors[field.id] = "Use HH:MM:SS"
            } else if isUUIDType(type), UUID(uuidString: value) == nil {
                errors[field.id] = "Enter a valid UUID"
            } else if isJSONType(type), !isValidJSON(value) {
                errors[field.id] = "Enter valid JSON"
            }
        }

        return errors
    }

    static func sqlLiteral(for field: DataEditorField, engine: DatabaseEngine) -> String? {
        let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = field.column.type.lowercased()
        if value.isEmpty {
            return nil
        }
        if isIntegerType(type) || isDecimalType(type) {
            return value
        }
        if isBooleanType(type), let boolean = normalizedBooleanLiteral(for: value, engine: engine) {
            return boolean
        }
        return "'\(value.sqlEscaped)'"
    }

    static func keyboardType(for column: SchemaColumnDescriptor) -> UIKeyboardType {
        let type = column.type.lowercased()
        if isIntegerType(type) {
            return .numberPad
        }
        if isDecimalType(type) {
            return .decimalPad
        }
        if isDateType(type) || isDateTimeType(type) || isTimeType(type) {
            return .numbersAndPunctuation
        }
        return .default
    }

    static func placeholder(for column: SchemaColumnDescriptor) -> String {
        let type = column.type.lowercased()
        if isDateType(type) {
            return "YYYY-MM-DD"
        }
        if isDateTimeType(type) {
            return "YYYY-MM-DD HH:MM:SS"
        }
        if isTimeType(type) {
            return "HH:MM:SS"
        }
        if isBooleanType(type) {
            return "true / false"
        }
        if isJSONType(type) {
            return "{\"key\":\"value\"}"
        }
        return column.name
    }

    static func isJSONColumn(_ column: SchemaColumnDescriptor) -> Bool {
        isJSONType(column.type.lowercased())
    }

    static func formattedJSON(_ value: String, prettyPrinted: Bool = true) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let options: JSONSerialization.WritingOptions = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let formattedData = try? JSONSerialization.data(withJSONObject: object, options: options),
              let formatted = String(data: formattedData, encoding: .utf8) else {
            return nil
        }
        return formatted
    }

    private static func normalizedBooleanLiteral(for value: String, engine: DatabaseEngine) -> String? {
        switch value.lowercased() {
        case "1", "true", "yes":
            return engine == .postgresql ? "TRUE" : "1"
        case "0", "false", "no":
            return engine == .postgresql ? "FALSE" : "0"
        default:
            return nil
        }
    }

    private static func isValidDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value) != nil
    }

    private static func isValidDateTime(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value) != nil
    }

    private static func isValidTime(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.date(from: value) != nil
    }

    private static func isValidJSON(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isIntegerType(_ type: String) -> Bool {
        ["int", "integer", "bigint", "smallint", "mediumint", "tinyint", "serial", "bigserial"].contains { type.contains($0) }
    }

    private static func isDecimalType(_ type: String) -> Bool {
        ["decimal", "numeric", "float", "double", "real"].contains { type.contains($0) }
    }

    private static func isBooleanType(_ type: String) -> Bool {
        type.contains("bool") || type == "bit"
    }

    private static func isDateType(_ type: String) -> Bool {
        type == "date"
    }

    private static func isDateTimeType(_ type: String) -> Bool {
        type.contains("timestamp") || type.contains("datetime")
    }

    private static func isTimeType(_ type: String) -> Bool {
        type == "time"
    }

    private static func isUUIDType(_ type: String) -> Bool {
        type.contains("uuid")
    }

    private static func isJSONType(_ type: String) -> Bool {
        type.contains("json")
    }
}

private extension String {
    var sqlEscaped: String {
        replacingOccurrences(of: "'", with: "''")
    }
}

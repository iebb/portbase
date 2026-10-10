import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

            if field.isNull {
                if !field.column.isNullable {
                    errors[field.id] = L10n.text("Required")
                }
                continue
            }

            if value.isEmpty {
                if !(mode == .insert && canOmitOnInsert), isNonTextType(type) {
                    errors[field.id] = L10n.text("Required")
                }
                continue
            }

            if isIntegerType(type), Int64(value) == nil {
                errors[field.id] = L10n.text("Enter an integer")
            } else if isDecimalType(type), Decimal(string: value) == nil {
                errors[field.id] = L10n.text("Enter a number")
            } else if isBooleanType(type), normalizedBooleanLiteral(for: value, engine: engine) == nil {
                errors[field.id] = L10n.text("Use true/false or 1/0")
            } else if isDateType(type), !isValidDate(value) {
                errors[field.id] = L10n.text("Use YYYY-MM-DD")
            } else if isDateTimeType(type), !isValidDateTime(value, allowsTimeZone: hasTimeZone(type)) {
                errors[field.id] = L10n.text("Use YYYY-MM-DD HH:MM:SS")
            } else if isTimeType(type), !isValidTime(value, allowsTimeZone: hasTimeZone(type)) {
                errors[field.id] = L10n.text("Use HH:MM:SS")
            } else if isUUIDType(type), UUID(uuidString: value) == nil {
                errors[field.id] = L10n.text("Enter a valid UUID")
            } else if isJSONType(type), !isValidJSON(value) {
                errors[field.id] = L10n.text("Enter valid JSON")
            }
        }

        return errors
    }

    static func boundValue(for field: DataEditorField) -> QueryBoundValue? {
        if field.isNull { return .null }
        let rawValue = field.value
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = field.column.type.lowercased()
        if value.isEmpty {
            return isNonTextType(type) ? nil : .string(rawValue)
        }
        if isIntegerType(type), let integer = Int64(value) {
            return .integer(integer)
        }
        if isDecimalType(type), Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) != nil {
            return .decimal(value)
        }
        if isBooleanType(type) {
            switch value.lowercased() {
            case "1", "true", "yes": return .boolean(true)
            case "0", "false", "no": return .boolean(false)
            default: return nil
            }
        }
        return .string(rawValue)
    }

    static func keyboardType(for column: SchemaColumnDescriptor) -> PortbaseKeyboardType {
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

    private static func isNonTextType(_ type: String) -> Bool {
        isIntegerType(type) || isDecimalType(type) || isBooleanType(type)
            || isDateType(type) || isDateTimeType(type) || isTimeType(type)
            || isUUIDType(type) || isJSONType(type)
    }

    private static func isValidDateTime(_ value: String, allowsTimeZone: Bool) -> Bool {
        let suffix = allowsTimeZone ? #"(?:Z|[+-]\d{2}(?::?\d{2})?)?"# : ""
        return matches(value, pattern: #"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?"# + suffix + "$" )
    }

    private static func isValidTime(_ value: String, allowsTimeZone: Bool) -> Bool {
        let suffix = allowsTimeZone ? #"(?:Z|[+-]\d{2}(?::?\d{2})?)?"# : ""
        return matches(value, pattern: #"^-?\d{2,3}:\d{2}:\d{2}(?:\.\d{1,6})?"# + suffix + "$" )
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isValidJSON(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isIntegerType(_ type: String) -> Bool {
        let base = canonicalBaseType(type)
        return ["int", "int2", "int4", "int8", "integer", "bigint", "smallint", "mediumint", "tinyint", "serial", "smallserial", "bigserial"].contains(base)
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
        let base = canonicalBaseType(type)
        return base == "time" || base == "timetz"
    }

    private static func hasTimeZone(_ type: String) -> Bool {
        type.contains("with time zone") || type.contains("timestamptz") || type.contains("timetz")
    }

    private static func canonicalBaseType(_ type: String) -> String {
        let lowered = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("timestamp") { return lowered }
        if lowered.hasPrefix("time with") || lowered.hasPrefix("time without") { return "time" }
        return lowered.split(whereSeparator: { $0 == "(" || $0.isWhitespace }).first.map(String.init) ?? lowered
    }

    private static func isUUIDType(_ type: String) -> Bool {
        type.contains("uuid")
    }

    private static func isJSONType(_ type: String) -> Bool {
        type.contains("json")
    }
}

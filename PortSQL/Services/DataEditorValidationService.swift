import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum DataEditorValueKind: Equatable {
    case text, integer, decimal, boolean, date, uuid, json, binary
    case dateTime(hasTimeZone: Bool)
    case time(hasTimeZone: Bool)
}

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
            return L10n.text("JSON")
        }
        return column.name
    }

    /// The editor a column's values need, from its declared type.
    static func valueKind(for column: SchemaColumnDescriptor) -> DataEditorValueKind {
        let type = column.type.lowercased()
        if isBooleanType(type) { return .boolean }
        if isIntegerType(type) { return .integer }
        if isDecimalType(type) { return .decimal }
        if isDateType(type) { return .date }
        if isDateTimeType(type) { return .dateTime(hasTimeZone: hasTimeZone(type)) }
        if isTimeType(type) { return .time(hasTimeZone: hasTimeZone(type)) }
        if isUUIDType(type) { return .uuid }
        if isJSONType(type) { return .json }
        if ["blob", "binary", "bytea", "varbinary"].contains(where: type.contains) { return .binary }
        return .text
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

/// A date, date-time, or time value split so a picker can change its wall-clock parts while the
/// text keeps its original shape: the date/time separator, fractional seconds, and zone suffix.
struct TemporalEditValue: Equatable {
    var year = 2000, month = 1, day = 1
    var hour = 0, minute = 0, second = 0
    var separator = " "
    var fraction = ""
    var zone = ""
    let hasDate: Bool
    let hasTime: Bool

    /// Pickers work in UTC so the edited wall clock never shifts with the device time zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    init?(_ text: String, kind: DataEditorValueKind) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let zonePattern = #"(Z|[+-]\d{2}(?::?\d{2})?)?"#
        let pattern: String
        switch kind {
        case .date:
            (hasDate, hasTime) = (true, false)
            pattern = #"^(\d{4})-(\d{2})-(\d{2})$"#
        case .dateTime:
            (hasDate, hasTime) = (true, true)
            pattern = #"^(\d{4})-(\d{2})-(\d{2})([ T])(\d{2}):(\d{2}):(\d{2})(\.\d{1,6})?"# + zonePattern + "$"
        case .time:
            (hasDate, hasTime) = (false, true)
            pattern = #"^(\d{2}):(\d{2}):(\d{2})(\.\d{1,6})?"# + zonePattern + "$"
        default:
            return nil
        }
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        func group(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: value) else { return "" }
            return String(value[range])
        }
        var next = 1
        if hasDate {
            year = Int(group(1)) ?? 0; month = Int(group(2)) ?? 0; day = Int(group(3)) ?? 0
            next = 4
            if hasTime { separator = group(4); next = 5 }
        }
        if hasTime {
            hour = Int(group(next)) ?? 0; minute = Int(group(next + 1)) ?? 0; second = Int(group(next + 2)) ?? 0
            fraction = group(next + 3); zone = group(next + 4)
        }
        // Durations such as MySQL's 838:59:59 and impossible dates stay text-only.
        guard hour < 24, minute < 60, second < 60, date != nil else { return nil }
    }

    /// The wall-clock value as a UTC date, for a picker.
    var date: Date? {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = Self.calendar.date(from: components) else { return nil }
        let check = Self.calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day ? date : nil
    }

    /// Takes the picker's date and minute parts. Seconds, fractions, and the zone are kept because
    /// pickers don't show them.
    mutating func apply(_ date: Date) {
        let parts = Self.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if hasDate { year = parts.year ?? year; month = parts.month ?? month; day = parts.day ?? day }
        if hasTime { hour = parts.hour ?? hour; minute = parts.minute ?? minute }
    }

    /// The current local time, with the local offset when the column stores a zone.
    mutating func setNow(_ now: Date = Date(), timeZone: TimeZone = .current) {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        year = parts.year ?? year; month = parts.month ?? month; day = parts.day ?? day
        hour = parts.hour ?? hour; minute = parts.minute ?? minute; second = parts.second ?? second
        fraction = ""
        if !zone.isEmpty {
            let offset = timeZone.secondsFromGMT(for: now)
            let sign = offset < 0 ? "-" : "+"
            zone = String(format: "%@%02d:%02d", sign, abs(offset) / 3600, abs(offset) % 3600 / 60)
        }
    }

    var text: String {
        let datePart = String(format: "%04d-%02d-%02d", year, month, day)
        let timePart = String(format: "%02d:%02d:%02d", hour, minute, second) + fraction + zone
        switch (hasDate, hasTime) {
        case (true, true): return datePart + separator + timePart
        case (true, false): return datePart
        default: return timePart
        }
    }
}

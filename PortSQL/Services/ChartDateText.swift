import Foundation

/// Reads the dates and times databases print, without a date formatter.
///
/// A formatter that fails takes tens of microseconds, and telling whether a column holds dates used to try
/// nine of them on every sampled value. This reads the common shapes directly:
///
///     2026-01-05                      2026/01/05          01/05/2026
///     2026-01-05 10:20:30             2026-01-05T10:20:30
///     2026-01-05 10:20:30.123456      a fraction, kept to the millisecond
///     2026-01-05 10:20:30+00:00       Z, +09, +0900 or +09:00
///
/// A time without a zone is read as UTC. Anything else is left to the formatters.
enum ChartDateText {
    static func date(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { parse($0) }
    }

    /// Whether a formatter could read the text at all: every format they know starts with a number and a
    /// separator. Text that isn't ASCII is always left for them to judge.
    static func mayBeDate(_ text: String) -> Bool {
        var sawDigit = false
        for byte in text.utf8 {
            if byte >= 0x80 { return true }
            if byte >= 0x30, byte <= 0x39 { sawDigit = true; continue }
            let isLetter = (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A
            return sawDigit && !isLetter
        }
        return false
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        let count = bytes.count
        guard count >= 10 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                guard index < count, bytes[index] >= 0x30, bytes[index] <= 0x39 else { return nil }
                value = value * 10 + Int(bytes[index] - 0x30)
            }
            return value
        }
        let dash = UInt8(ascii: "-"), slash = UInt8(ascii: "/"), colon = UInt8(ascii: ":")

        let year: Int, month: Int, day: Int
        var allowsT = false
        if bytes[4] == dash, bytes[7] == dash, let y = number(0, 4), let m = number(5, 2), let d = number(8, 2) {
            (year, month, day) = (y, m, d)
            allowsT = true
        } else if bytes[4] == slash, bytes[7] == slash, let y = number(0, 4), let m = number(5, 2), let d = number(8, 2) {
            (year, month, day) = (y, m, d)
        } else if bytes[2] == slash, bytes[5] == slash, let m = number(0, 2), let d = number(3, 2), let y = number(6, 4) {
            (year, month, day) = (y, m, d)
        } else {
            return nil
        }
        // Earlier years fall under the Julian calendar for the formatters; they keep those.
        guard year >= 1600, month >= 1, month <= 12, day >= 1, day <= days(in: month, of: year) else { return nil }

        var seconds = daysFromEpoch(year: year, month: month, day: day) * 86_400
        var milliseconds = 0
        if count > 10 {
            guard count >= 19, bytes[10] == UInt8(ascii: " ") || (allowsT && bytes[10] == UInt8(ascii: "T")),
                  bytes[13] == colon, bytes[16] == colon,
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
                  hour <= 23, minute <= 59, second <= 59 else { return nil }
            seconds += hour * 3_600 + minute * 60 + second
            var index = 19
            if index < count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                let start = index
                var scale = 100
                while index < count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                    milliseconds += Int(bytes[index] - 0x30) * scale
                    scale /= 10
                    index += 1
                }
                guard index > start, index - start <= 9 else { return nil }
            }
            if index < count {
                let sign = bytes[index]
                if sign == UInt8(ascii: "Z") || sign == UInt8(ascii: "z") {
                    index += 1
                } else if sign == UInt8(ascii: "+") || sign == dash {
                    guard let hours = number(index + 1, 2), hours <= 14 else { return nil }
                    index += 3
                    var minutes = 0
                    if index < count {
                        if bytes[index] == colon { index += 1 }
                        guard let value = number(index, 2), value <= 59 else { return nil }
                        minutes = value
                        index += 2
                    }
                    let offset = hours * 3_600 + minutes * 60
                    seconds -= sign == dash ? -offset : offset
                }
                guard index == count else { return nil }
            }
        }
        return Date(timeIntervalSince1970: Double(seconds * 1_000 + milliseconds) / 1_000)
    }

    private static func days(in month: Int, of year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days from 1970-01-01 in the Gregorian calendar.
    private static func daysFromEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

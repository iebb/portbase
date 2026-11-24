import Foundation

/// JSON text checked and written by hand, for the cells of a large copy or export: an encoder or a regular
/// expression made for every value was most of the time those took.
enum JSONText {
    /// Whether text is a JSON number and nothing more: `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
    static func isNumber(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            let count = bytes.count
            var index = 0
            func digits() -> Bool {
                let start = index
                while index < count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
                return index > start
            }
            if index < count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < count else { return false }
            if bytes[index] == UInt8(ascii: "0") { index += 1 } else if !digits() { return false }
            if index < count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() else { return false }
            }
            if index < count, bytes[index] | 0x20 == UInt8(ascii: "e") {
                index += 1
                if index < count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() else { return false }
            }
            return index == count
        }
    }

    /// Whether the text can stand between quotes as it is: no quote, backslash or control character, nor
    /// any of the other bytes named.
    static func isPlain(_ text: String, without others: (UInt8, UInt8) = (0x22, 0x22)) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            for byte in bytes where byte < 0x20 || byte == 0x22 || byte == 0x5C || byte == others.0 || byte == others.1 { return false }
            return true
        }
    }

    /// Adds the text as a JSON string, quotes included.
    static func append(_ text: String, to json: inout [UInt8]) {
        let hex = Array("0123456789abcdef".utf8)
        json.append(0x22)
        for byte in text.utf8 {
            switch byte {
            case 0x22: json.append(0x5C); json.append(0x22)
            case 0x5C: json.append(0x5C); json.append(0x5C)
            case 0x0A: json.append(0x5C); json.append(UInt8(ascii: "n"))
            case 0x0D: json.append(0x5C); json.append(UInt8(ascii: "r"))
            case 0x09: json.append(0x5C); json.append(UInt8(ascii: "t"))
            case 0..<0x20:
                json.append(contentsOf: [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"), hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]])
            default: json.append(byte)
            }
        }
        json.append(0x22)
    }
}

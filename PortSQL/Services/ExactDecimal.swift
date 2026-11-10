import Foundation

/// A decimal number of any size and precision, for totals of database values that must neither round
/// nor overflow. PostgreSQL `numeric` carries up to 131,072 digits and a float can reach 1e308, where
/// Foundation's `Decimal` keeps 38 digits and stops near 1e127.
struct ExactDecimal: Comparable, Hashable, Sendable {
    /// The largest power of ten accepted in scientific notation; anything beyond is not treated as a number.
    static let maximumExponent = 4_096
    private static let base: UInt64 = 1_000_000_000

    private(set) var isNegative = false
    /// Base-10⁹ limbs, least significant first, with no zero limbs at the top; empty is zero.
    private var limbs: [UInt32] = []
    /// Digits after the decimal point.
    private(set) var scale = 0

    static let zero = ExactDecimal()

    private init() {}

    private init(negative: Bool, limbs: [UInt32], scale: Int) {
        self.limbs = limbs
        self.scale = scale
        trim()
        isNegative = negative && !self.limbs.isEmpty
    }

    init(_ value: Int) {
        self.init(negative: value < 0, limbs: Self.limbs(of: value.magnitude), scale: 0)
    }

    /// Parses SQL-style numbers: an optional sign, digits with an optional point, and an optional exponent.
    init?(_ text: String) {
        var characters = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if let sign = characters.first, sign == "-" || sign == "+" { negative = sign == "-"; characters.removeFirst() }
        var digits: [UInt8] = []
        var fractionDigits = 0
        var seenPoint = false
        var exponent = 0
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            if let value = character.wholeNumberValue, character.isASCII {
                digits.append(UInt8(value))
                if seenPoint { fractionDigits += 1 }
            } else if character == ".", !seenPoint {
                seenPoint = true
            } else if character == "e" || character == "E" {
                guard let value = Int(characters[characters.index(after: index)...]), abs(value) <= Self.maximumExponent else { return nil }
                exponent = value
                break
            } else {
                return nil
            }
            index = characters.index(after: index)
        }
        guard !digits.isEmpty else { return nil }
        let shift = exponent - fractionDigits
        if shift >= 0 {
            digits += [UInt8](repeating: 0, count: shift)
            self.init(negative: negative, limbs: Self.limbs(fromDigits: digits), scale: 0)
        } else {
            self.init(negative: negative, limbs: Self.limbs(fromDigits: digits), scale: -shift)
        }
    }

    var isZero: Bool { limbs.isEmpty }

    // MARK: Arithmetic

    static func + (lhs: ExactDecimal, rhs: ExactDecimal) -> ExactDecimal {
        let scale = max(lhs.scale, rhs.scale)
        let left = lhs.rescaled(to: scale), right = rhs.rescaled(to: scale)
        if left.isNegative == right.isNegative {
            return ExactDecimal(negative: left.isNegative, limbs: add(left.limbs, right.limbs), scale: scale)
        }
        switch compare(left.limbs, right.limbs) {
        case 0: return ExactDecimal(negative: false, limbs: [], scale: scale)
        case 1: return ExactDecimal(negative: left.isNegative, limbs: subtract(left.limbs, right.limbs), scale: scale)
        default: return ExactDecimal(negative: right.isNegative, limbs: subtract(right.limbs, left.limbs), scale: scale)
        }
    }

    static func < (lhs: ExactDecimal, rhs: ExactDecimal) -> Bool {
        if lhs.isNegative != rhs.isNegative { return lhs.isNegative }
        let scale = max(lhs.scale, rhs.scale)
        let order = compare(lhs.rescaled(to: scale).limbs, rhs.rescaled(to: scale).limbs)
        return lhs.isNegative ? order > 0 : order < 0
    }

    static func == (lhs: ExactDecimal, rhs: ExactDecimal) -> Bool {
        let scale = max(lhs.scale, rhs.scale)
        return lhs.isNegative == rhs.isNegative && lhs.rescaled(to: scale).limbs == rhs.rescaled(to: scale).limbs
    }

    /// Equal values hash alike whatever their scale, so 1.50 and 1.5 do.
    func hash(into hasher: inout Hasher) {
        guard !isZero else { hasher.combine(0); return }
        var normalized = self
        while normalized.scale > 0, let last = normalized.limbs.first, last % 10 == 0 {
            normalized = normalized.rounded(toScale: normalized.scale - 1)
        }
        hasher.combine(normalized.isNegative)
        hasher.combine(normalized.limbs)
        hasher.combine(normalized.scale)
    }

    /// The quotient by a count, rounded half away from zero to the given digits after the point.
    func divided(by divisor: Int, fractionDigits: Int) -> ExactDecimal {
        precondition(divisor > 0)
        let widened = rescaled(to: fractionDigits + 1)
        let (quotient, _) = Self.divide(widened.limbs, by: UInt64(divisor))
        return ExactDecimal(negative: isNegative, limbs: quotient, scale: fractionDigits + 1).rounded(toScale: fractionDigits)
    }

    /// Rounded half away from zero to a number of digits after the point; fewer digits are padded.
    func rounded(toScale target: Int) -> ExactDecimal {
        guard target < scale else { return rescaled(to: target) }
        var digits = Self.digits(of: limbs)
        let dropped = scale - target
        if digits.count < dropped + 1 { digits = [UInt8](repeating: 0, count: dropped + 1 - digits.count) + digits }
        let roundsUp = digits[digits.count - dropped] >= 5
        var kept = Array(digits.dropLast(dropped))
        if roundsUp {
            var index = kept.count - 1
            while index >= 0 {
                if kept[index] == 9 { kept[index] = 0; index -= 1 } else { kept[index] += 1; break }
            }
            if index < 0 { kept.insert(1, at: 0) }
        }
        return ExactDecimal(negative: isNegative, limbs: Self.limbs(fromDigits: kept), scale: target)
    }

    // MARK: Text

    /// The number as SQL and spreadsheets read it: no grouping, a point before any fraction.
    var plainDescription: String {
        let (integer, fraction) = parts
        return (isNegative ? "-" : "") + integer + (fraction.isEmpty ? "" : "." + fraction)
    }

    /// The number for reading, grouped by thousands with the locale's separators.
    func formatted(fractionDigits: Int, locale: Locale = .current) -> String {
        let value = rounded(toScale: fractionDigits)
        var (integer, fraction) = value.parts
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let separator = locale.groupingSeparator ?? ","
        var grouped = ""
        for (offset, character) in integer.enumerated() {
            if offset > 0, (integer.count - offset) % 3 == 0 { grouped += separator }
            grouped.append(character)
        }
        let point = locale.decimalSeparator ?? "."
        return (value.isNegative ? "-" : "") + grouped + (fraction.isEmpty ? "" : point + fraction)
    }

    private var parts: (integer: String, fraction: String) {
        var text = Self.digits(of: limbs).map { String($0) }.joined()
        if text.count <= scale { text = String(repeating: "0", count: scale - text.count + 1) + text }
        let split = text.index(text.endIndex, offsetBy: -scale)
        return (String(text[..<split]), String(text[split...]))
    }

    // MARK: Limbs

    private func rescaled(to target: Int) -> ExactDecimal {
        guard target > scale else { return self }
        var result = self
        var remaining = target - scale
        while remaining >= 9 { result.limbs = Self.multiply(result.limbs, by: Self.base); remaining -= 9 }
        if remaining > 0 {
            var factor: UInt64 = 1
            for _ in 0..<remaining { factor *= 10 }
            result.limbs = Self.multiply(result.limbs, by: factor)
        }
        result.scale = target
        result.trim()
        return result
    }

    private mutating func trim() {
        while limbs.last == 0 { limbs.removeLast() }
        if limbs.isEmpty { isNegative = false }
    }

    private static func limbs(of value: UInt) -> [UInt32] {
        var value = UInt64(value)
        var result: [UInt32] = []
        while value > 0 { result.append(UInt32(value % base)); value /= base }
        return result
    }

    private static func limbs(fromDigits digits: [UInt8]) -> [UInt32] {
        var result: [UInt32] = []
        var end = digits.count
        while end > 0 {
            let start = max(0, end - 9)
            var limb: UInt32 = 0
            for digit in digits[start..<end] { limb = limb * 10 + UInt32(digit) }
            result.append(limb)
            end = start
        }
        while result.last == 0 { result.removeLast() }
        return result
    }

    private static func digits(of limbs: [UInt32]) -> [UInt8] {
        guard let top = limbs.last else { return [0] }
        var text = String(top)
        for limb in limbs.dropLast().reversed() {
            let part = String(limb)
            text += String(repeating: "0", count: 9 - part.count) + part
        }
        return text.compactMap { $0.wholeNumberValue.map(UInt8.init) }
    }

    private static func compare(_ lhs: [UInt32], _ rhs: [UInt32]) -> Int {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
        for index in stride(from: lhs.count - 1, through: 0, by: -1) where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index] ? -1 : 1
        }
        return 0
    }

    private static func add(_ lhs: [UInt32], _ rhs: [UInt32]) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(max(lhs.count, rhs.count) + 1)
        var carry: UInt64 = 0
        for index in 0..<max(lhs.count, rhs.count) {
            let sum = UInt64(index < lhs.count ? lhs[index] : 0) + UInt64(index < rhs.count ? rhs[index] : 0) + carry
            result.append(UInt32(sum % base))
            carry = sum / base
        }
        if carry > 0 { result.append(UInt32(carry)) }
        return result
    }

    /// The difference of magnitudes, where `lhs` is at least `rhs`.
    private static func subtract(_ lhs: [UInt32], _ rhs: [UInt32]) -> [UInt32] {
        var result: [UInt32] = []
        var borrow: Int64 = 0
        for index in 0..<lhs.count {
            var difference = Int64(lhs[index]) - Int64(index < rhs.count ? rhs[index] : 0) - borrow
            borrow = difference < 0 ? 1 : 0
            if difference < 0 { difference += Int64(base) }
            result.append(UInt32(difference))
        }
        while result.last == 0 { result.removeLast() }
        return result
    }

    private static func multiply(_ limbs: [UInt32], by factor: UInt64) -> [UInt32] {
        guard !limbs.isEmpty else { return [] }
        var result: [UInt32] = []
        var carry: UInt64 = 0
        for limb in limbs {
            let product = UInt64(limb) * factor + carry
            result.append(UInt32(product % base))
            carry = product / base
        }
        while carry > 0 { result.append(UInt32(carry % base)); carry /= base }
        return result
    }

    private static func divide(_ limbs: [UInt32], by divisor: UInt64) -> ([UInt32], UInt64) {
        var result = [UInt32](repeating: 0, count: limbs.count)
        var remainder: UInt64 = 0
        for index in stride(from: limbs.count - 1, through: 0, by: -1) {
            let current = remainder * base + UInt64(limbs[index])
            result[index] = UInt32(current / divisor)
            remainder = current % divisor
        }
        while result.last == 0 { result.removeLast() }
        return (result, remainder)
    }
}

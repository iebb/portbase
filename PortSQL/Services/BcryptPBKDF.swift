import CommonCrypto
import Crypto
import Foundation

/// OpenSSH's key derivation for passphrase-protected private keys: OpenBSD's `bcrypt_pbkdf`, a PBKDF2
/// variant built on the bcrypt hash (an expensive Blowfish key schedule), with SHA-512 as its PRF.
enum BcryptPBKDF {
    static let hashSize = 32

    enum Failure: Error { case invalidParameters }

    static func derive(passphrase: Data, salt: Data, rounds: Int, length: Int) throws -> Data {
        guard rounds >= 1, !passphrase.isEmpty, !salt.isEmpty, (1...hashSize * hashSize).contains(length), salt.count <= 1 << 20 else {
            throw Failure.invalidParameters
        }
        let stride = (length + hashSize - 1) / hashSize
        var amount = (length + stride - 1) / stride
        let sha2pass = Array(SHA512.hash(data: passphrase))
        var key = [UInt8](repeating: 0, count: length)
        var remaining = length
        var count: UInt32 = 1
        while remaining > 0 {
            var countSalt = salt
            countSalt.append(contentsOf: [UInt8(count >> 24), UInt8((count >> 16) & 0xff), UInt8((count >> 8) & 0xff), UInt8(count & 0xff)])
            var sha2salt = Array(SHA512.hash(data: countSalt))
            var hashed = hash(sha2pass: sha2pass, sha2salt: sha2salt)
            var output = hashed
            for _ in 1..<rounds {
                sha2salt = Array(SHA512.hash(data: hashed))
                hashed = hash(sha2pass: sha2pass, sha2salt: sha2salt)
                for index in output.indices { output[index] ^= hashed[index] }
            }
            // Output bytes are spread across the key, so every key byte depends on every round.
            amount = min(amount, remaining)
            var written = 0
            while written < amount {
                let destination = written * stride + Int(count - 1)
                if destination >= length { break }
                key[destination] = output[written]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return Data(key)
    }

    /// The bcrypt hash of a SHA-512 passphrase and salt: 64 rounds of the expensive key schedule, then
    /// "OxychromaticBlowfishSwatDynamite" enciphered 64 times, written as little-endian words.
    static func hash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        var state = BlowfishState()
        state.expand(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expand(key: sha2salt)
            state.expand(key: sha2pass)
        }
        let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)
        var position = 0
        var words = (0..<8).map { _ in BlowfishState.word(magic, &position) }
        for _ in 0..<64 {
            for block in Swift.stride(from: 0, to: 8, by: 2) {
                (words[block], words[block + 1]) = state.encipher(words[block], words[block + 1])
            }
        }
        var output = [UInt8](repeating: 0, count: hashSize)
        for (index, word) in words.enumerated() {
            output[4 * index] = UInt8(word & 0xff)
            output[4 * index + 1] = UInt8((word >> 8) & 0xff)
            output[4 * index + 2] = UInt8((word >> 16) & 0xff)
            output[4 * index + 3] = UInt8(word >> 24)
        }
        return output
    }
}

/// Blowfish's state as OpenBSD's blf.c keeps it, with the two key schedules bcrypt uses.
struct BlowfishState {
    private var p: [UInt32] = BlowfishConstants.p
    /// The four S-boxes, one after another.
    private var s: [UInt32] = BlowfishConstants.s0 + BlowfishConstants.s1 + BlowfishConstants.s2 + BlowfishConstants.s3

    /// The next big-endian word of `data`, wrapping around at its end.
    static func word(_ data: [UInt8], _ position: inout Int) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            if position >= data.count { position = 0 }
            value = (value << 8) | UInt32(data[position])
            position += 1
        }
        return value
    }

    func encipher(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
        p.withUnsafeBufferPointer { p in
            s.withUnsafeBufferPointer { s in
                @inline(__always) func f(_ x: UInt32) -> UInt32 {
                    ((s[Int(x >> 24)] &+ s[256 + Int((x >> 16) & 0xff)]) ^ s[512 + Int((x >> 8) & 0xff)]) &+ s[768 + Int(x & 0xff)]
                }
                var l = left ^ p[0], r = right
                var round = 1
                while round <= 16 {
                    r ^= f(l) ^ p[round]
                    l ^= f(r) ^ p[round + 1]
                    round += 2
                }
                return (r ^ p[17], l)
            }
        }
    }

    /// The salted key schedule (`Blowfish_expandstate`).
    mutating func expand(data: [UInt8], key: [UInt8]) {
        var position = 0
        for index in 0..<18 { p[index] ^= Self.word(key, &position) }
        position = 0
        var left: UInt32 = 0, right: UInt32 = 0
        for index in stride(from: 0, to: 18, by: 2) {
            left ^= Self.word(data, &position); right ^= Self.word(data, &position)
            (left, right) = encipher(left, right)
            p[index] = left; p[index + 1] = right
        }
        for index in stride(from: 0, to: 1024, by: 2) {
            left ^= Self.word(data, &position); right ^= Self.word(data, &position)
            (left, right) = encipher(left, right)
            s[index] = left; s[index + 1] = right
        }
    }

    /// The unsalted key schedule (`Blowfish_expand0state`).
    mutating func expand(key: [UInt8]) {
        var position = 0
        for index in 0..<18 { p[index] ^= Self.word(key, &position) }
        var left: UInt32 = 0, right: UInt32 = 0
        for index in stride(from: 0, to: 18, by: 2) {
            (left, right) = encipher(left, right)
            p[index] = left; p[index + 1] = right
        }
        for index in stride(from: 0, to: 1024, by: 2) {
            (left, right) = encipher(left, right)
            s[index] = left; s[index + 1] = right
        }
    }
}

/// AES in counter mode for OpenSSH's aesNNN-ctr private keys; CryptoKit offers only GCM.
enum SSHKeyCipher {
    static func aesCTR(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == kCCBlockSizeAES128 else { throw SSHTunnelError.invalidPrivateKey }
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { key in
            iv.withUnsafeBytes { iv in
                CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        iv.baseAddress, key.baseAddress, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw SSHTunnelError.invalidPrivateKey }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == data.count else { throw SSHTunnelError.invalidPrivateKey }
        return output
    }
}

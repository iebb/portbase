import NIOCore
import XCTest
@testable import MySQLNIO

/// `caching_sha2_password` scrambles must hash exactly the 20-byte nonce. MySQL 8 sends 21 bytes of
/// auth-plugin data (the nonce plus a trailing NUL); hashing all 21 passes only until the user is in the
/// server's authentication cache, after which every sign-in is denied.
final class CachingSha2ScrambleTests: XCTestCase {
    private let nonce: [UInt8] = Array(1...20)

    func testScrambleHashesTheTwentyByteNonceWithoutTheTrailingNUL() {
        // Reference: XOR(SHA256(p), SHA256(SHA256(SHA256(p)) || nonce)), computed independently with Python's hashlib.
        let expected = "40ba237ecc79a2ab91ef751db43260b223445246ce4074ec921efabdec7a3be4"
        let handshakeData = ByteBuffer(bytes: nonce + [0])
        let scramble = MySQLConnectionHandler.cachingSha2Scramble(password: "s3cret-pass", authPluginData: handshakeData)
        XCTAssertEqual(scramble.response.readableBytesView.map { String(format: "%02x", $0) }.joined(), expected)
        XCTAssertEqual(scramble.nonce, nonce, "The nonce kept for full authentication excludes the NUL as well")

        let withoutNUL = MySQLConnectionHandler.cachingSha2Scramble(password: "s3cret-pass", authPluginData: ByteBuffer(bytes: nonce))
        XCTAssertEqual(withoutNUL.response, scramble.response, "Servers that omit the NUL get the same scramble")
    }

    func testEmptyPasswordSendsAnEmptyResponse() {
        let handshakeData = ByteBuffer(bytes: nonce + [0])
        XCTAssertEqual(MySQLConnectionHandler.cachingSha2Scramble(password: "", authPluginData: handshakeData).response.readableBytes, 0)
        XCTAssertEqual(MySQLConnectionHandler.cachingSha2Scramble(password: nil, authPluginData: handshakeData).response.readableBytes, 0)
    }
}

import NIOSSH
import XCTest
@testable import PortSQL

/// Passphrase-protected OpenSSH keys, as `ssh-keygen -Z <cipher> -a 4` writes them. These are throwaway
/// keys made for this test; the public key beside each is what `ssh-keygen -y` reports for it.
final class SSHEncryptedKeyTests: XCTestCase {
    private struct Fixture {
        let cipher: String
        let passphrase: String
        let publicKey: String
        let privateKey: String
    }

    private let fixtures = [
        Fixture(cipher: "aes256-ctr", passphrase: "fixture passphrase 1", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFrZb2/qoyxHpKsYlhO6QfKtfxrqPiXJSnw3yEQo5Sj",
                privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBt9qOG5x
        6SaFcAq9KUtrfYAAAABAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIGFrZb2/qoyxHpKs
        YlhO6QfKtfxrqPiXJSnw3yEQo5SjAAAAkJphRX85PiYizXZ8WsaKEx7v7kKqo5dGCLSg2a
        uZum0I4JqlBrnt21NRzvfkXdsUtCqRQQHyRp+K1pOikWPTig0LbNiWgi3qEhh/yJ/Fz1Pk
        Z1VKqoEAKGK9d73YsDm3GW8TF+2dtS/7weUfMQmvH+zDzZpk+u1DzN5hipkJJZyZRKFcVP
        gAz7G8eXIwFyz9PA==
        -----END OPENSSH PRIVATE KEY-----
        """),
        Fixture(cipher: "aes128-ctr", passphrase: "fixture passphrase 2", publicKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBP2LLY75dtNC2IBkxrZC0fWKc2lXnxeizRUKPLwFZtLJGZQEvJkgbUkVSd9CC3SSXhFsj8ZESqcXD+TEfWRL9I=",
                privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczEyOC1jdHIAAAAGYmNyeXB0AAAAGAAAABDedME3Qb
        ltptPznmuU8JG1AAAABAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
        dHAyNTYAAABBBBP2LLY75dtNC2IBkxrZC0fWKc2lXnxeizRUKPLwFZtLJGZQEvJkgbUkVS
        d9CC3SSXhFsj8ZESqcXD+TEfWRL9IAAACgBmy7tkwTxd5g0EfWofmBnX5VhrxioMjP/qjx
        PtVkswmQ54ilhdn7+45CvHaCRR8Ta+yGx+SizczZbvJVW33jhlEIAVShfJqqnpq1BsghTb
        qA3sACrz29pH1ZuWvBBU3FUDRjC+vI7W0jOBJR4sAfU396WEMHZ9AY7HtfACEg5m4o57ub
        dBf+hz3MNGusLwOLRl45rMw2FRJ6JbiDOGQwvg==
        -----END OPENSSH PRIVATE KEY-----
        """),
        Fixture(cipher: "aes192-ctr", passphrase: "fixture passphrase 3", publicKey: "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBH4U4DqDiMcRhtDqBvCEiSDFP4CNlfSaA47I9dB4WgjpDsg1Dfmiq/krn6SQNqrG3M1ULHRhVwPwRJIpa5shzUwooTwhG+uggIFpWjI6y+xCAvQSYrNlxa0fX2rPEiZoQA==",
                privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczE5Mi1jdHIAAAAGYmNyeXB0AAAAGAAAABBmjStqzN
        u6/1EwwYjVmdHhAAAABAAAAAEAAACIAAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlz
        dHAzODQAAABhBH4U4DqDiMcRhtDqBvCEiSDFP4CNlfSaA47I9dB4WgjpDsg1Dfmiq/krn6
        SQNqrG3M1ULHRhVwPwRJIpa5shzUwooTwhG+uggIFpWjI6y+xCAvQSYrNlxa0fX2rPEiZo
        QAAAANCXPibb4h5r9Ab9ZfjeqhoPoIwKW19qWgQ6mIHqfk6fGoD19BL1qr0tI1N0AV8m9a
        XN0knRYoQcMHdXrmrqVo5xxTYYbDHGOojuHFnPC5JRu19PVoAxJGjv0sHaD7vzTtNjm6MX
        YGw4FBnzPs4nBhgdQ1N1wi1ZzKr25stV7YPrnGz+A2TLRBYoEFcw3WXWPyril7Li8r6iKj
        d8gFYdAaPVe9uzOFPBst8/1CV4TuJSGhBD7wueDHi3e4rv8nt7YLMzQW+qL2O+c2ZJj7uJ
        GGI7
        -----END OPENSSH PRIVATE KEY-----
        """),
        Fixture(cipher: "aes256-gcm@openssh.com", passphrase: "fixture passphrase 4", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOSXZORbgZNU/Gp+5+3oc0wHpAWP2OSjglGkad1GVo9V",
                privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAAFmFlczI1Ni1nY21Ab3BlbnNzaC5jb20AAAAGYmNyeXB0AA
        AAGAAAABDUsF7ppqrkuI8skOnA9ZK9AAAABAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAA
        IOSXZORbgZNU/Gp+5+3oc0wHpAWP2OSjglGkad1GVo9VAAAAkLev3vEuVAG5GVbp+wgqu7
        T00dtPSExrZcaqhMsdMduFWlukrqvoqbIrYAUMzqe19AT8DZkiFVioL5dNPoKcptWIW0P2
        UJPut1Im9B+Y9lSySRzCrtqozuz1hv9ok0I5zwB5Sic6QVBp7P+XvKjkLr4GKfzSt6HvuY
        c+5SWgWugF8fLftxRXNzG0O+zqbKOJcKye7vXP5MQvLekqhPqz1sU=
        -----END OPENSSH PRIVATE KEY-----
        """),
        Fixture(cipher: "aes128-gcm@openssh.com", passphrase: "fixture passphrase 5", publicKey: "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAADLTM7lLWkThiKBk3qINbTYeTp6a0uBn9CtIllIFdEALfW3DZ1xEVlrR4wiT4wzhOFohLu5f+e9kZKc2fjJH74LwHrx1zWCzVHvQ8E5Y06LNf4tm0xThFPGG9m08yHUyqWAMEFVeneX5vd4QSo2jrZ/Qr4sSte5RURFLNZv2Z+oe+Bpw==",
                privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAAFmFlczEyOC1nY21Ab3BlbnNzaC5jb20AAAAGYmNyeXB0AA
        AAGAAAABDRinj7ahlZ8f9OKllEl9lHAAAABAAAAAEAAACsAAAAE2VjZHNhLXNoYTItbmlz
        dHA1MjEAAAAIbmlzdHA1MjEAAACFBAADLTM7lLWkThiKBk3qINbTYeTp6a0uBn9CtIllIF
        dEALfW3DZ1xEVlrR4wiT4wzhOFohLu5f+e9kZKc2fjJH74LwHrx1zWCzVHvQ8E5Y06LNf4
        tm0xThFPGG9m08yHUyqWAMEFVeneX5vd4QSo2jrZ/Qr4sSte5RURFLNZv2Z+oe+BpwAAAQ
        BvFIq1pJDXYu9zjMYC5VxFh3MLQyqhJTZzIlT+8eZiiN5WqJvsuF07rop5s+Vjk1plHkRq
        H4Hq7QmgSLCThexbDvlQ3jyq3NyMrmAzhtOQIQpmCWnaUXPph3RH5Zmy7CJXvltyYh7esm
        xHefmGRzVehM6/c9Pu9Rz7tylgdyeFyHq7TsMRVuvvuIlHIPtZCzEKS9zchvm9WP31xSUG
        lfBrdwYDZ/Cp5mwoGvtzl2I6FBZ+2XxT8M1crIuXRCknRx1dcQsFsiHZjtmhV1t1kpbyb1
        gFiwLMrfopTMzcb8cPejoQdrjVpRT5OXbL1UGsyc+PTX3GXXa0+IQBuHIafFxmayz3hMgQ
        f+vj6kWUpbHjnQ==
        -----END OPENSSH PRIVATE KEY-----
        """),
        Fixture(cipher: "chacha20-poly1305@openssh.com", passphrase: "fixture passphrase 6", publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFNUuAfc3GOnt2h4czLkcGlKpuf9n3bl791rP75y1oEe",
                privateKey: """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAAHWNoYWNoYTIwLXBvbHkxMzA1QG9wZW5zc2guY29tAAAABm
        JjcnlwdAAAABgAAAAQQZaDo6IJ9L0WThKKAb3VCgAAAAQAAAABAAAAMwAAAAtzc2gtZWQy
        NTUxOQAAACBTVLgH3Nxjp7doeHMy5HBpSqbn/Z925e/daz++ctaBHgAAAIgOR3qaPJJqtz
        D9/lQFI0yYBXOtzSm7TE3Psph0xSycjawBL2o1Nn6FtSrL5Wdmvt3MEYLg1CDzMpX7CWW5
        iSkguy8986BFn7clSzXtuTkdDPMwnK1NwnudlsByxYQjvwywFJJUx2W+fRB8ML5vuP32/9
        iKIJfZnH8KjbLZqyaiVoT9Dqu3UxaIvzQ01nAoAZtB3xITk42QZA==
        -----END OPENSSH PRIVATE KEY-----
        """),
    ]

    func testEveryAESCipherDecryptsToTheKeysOwnPublicKey() throws {
        for fixture in fixtures where fixture.cipher.hasPrefix("aes") {
            XCTAssertTrue(SSHTunnelPrivateKeyParser.isEncrypted(fixture.privateKey), fixture.cipher)
            let key = try XCTUnwrap(SSHTunnelPrivateKeyParser.parse(fixture.privateKey, passphrase: fixture.passphrase), fixture.cipher)
            XCTAssertEqual(key.publicKey, try NIOSSHPublicKey(openSSHPublicKey: fixture.publicKey), fixture.cipher)
        }
    }

    func testWrongMissingAndUnsupportedPassphrasesFailClearly() throws {
        for fixture in fixtures where fixture.cipher.hasPrefix("aes") {
            XCTAssertThrowsError(try SSHTunnelPrivateKeyParser.parse(fixture.privateKey, passphrase: "not the passphrase"), fixture.cipher) { error in
                guard case SSHTunnelError.privateKeyPassphraseIncorrect = error else { return XCTFail("\(fixture.cipher): \(error)") }
            }
            XCTAssertThrowsError(try SSHTunnelPrivateKeyParser.parse(fixture.privateKey)) { error in
                guard case SSHTunnelError.privateKeyPassphraseRequired = error else { return XCTFail("\(error)") }
            }
        }
        let chacha = try XCTUnwrap(fixtures.first { $0.cipher.hasPrefix("chacha20") })
        XCTAssertThrowsError(try SSHTunnelPrivateKeyParser.parse(chacha.privateKey, passphrase: chacha.passphrase)) { error in
            guard case SSHTunnelError.privateKeyCipherUnsupported(let cipher) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(cipher, "chacha20-poly1305@openssh.com")
            XCTAssertTrue(error.localizedDescription.contains("ssh-keygen -p"))
        }
    }

    func testBcryptPBKDFRejectsDegenerateParameters() {
        XCTAssertThrowsError(try BcryptPBKDF.derive(passphrase: Data(), salt: Data([1]), rounds: 16, length: 48))
        XCTAssertThrowsError(try BcryptPBKDF.derive(passphrase: Data("x".utf8), salt: Data([1]), rounds: 0, length: 48))
        XCTAssertNoThrow(try BcryptPBKDF.derive(passphrase: Data("x".utf8), salt: Data([1]), rounds: 1, length: 48))
    }
}

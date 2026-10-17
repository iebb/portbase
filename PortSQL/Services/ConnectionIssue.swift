import Foundation

/// A readable explanation of a raw driver or transport error.
struct ConnectionIssue: Equatable {
    enum Kind: Equatable {
        case certificateUntrusted, certificateHostname, certificateExpired, tlsUnavailable, tlsHandshake
        case authentication, unreachable, timeout, other
    }

    let kind: Kind
    /// The original message, shown verbatim as details.
    let details: String

    var title: String {
        switch kind {
        case .certificateUntrusted: L10n.text("Server certificate isn’t trusted")
        case .certificateHostname: L10n.text("Certificate doesn’t match the host")
        case .certificateExpired: L10n.text("Server certificate has expired")
        case .tlsUnavailable: L10n.text("Server doesn’t offer TLS")
        case .tlsHandshake: L10n.text("Secure connection failed")
        case .authentication: L10n.text("Sign-in failed")
        case .unreachable: L10n.text("Server unreachable")
        case .timeout: L10n.text("Connection timed out")
        case .other: L10n.text("Connection failed")
        }
    }

    var guidance: String {
        switch kind {
        case .certificateUntrusted:
            L10n.text("The certificate is signed by an authority this device doesn’t trust, as with managed databases that use their own CA. Review the server’s certificate to trust its authority for this connection.")
        case .certificateHostname:
            L10n.text("The certificate was issued for a different name. Connect with the hostname listed in the certificate instead of an IP address or alias.")
        case .certificateExpired:
            L10n.text("Renew the server certificate, or check that this device’s date and time are correct.")
        case .tlsUnavailable:
            L10n.text("Enable TLS on the server. For a legacy server on a trusted network, you can choose Plaintext Only under Transport Security.")
        case .tlsHandshake:
            L10n.text("Portbase and the server couldn’t agree on a secure connection. Check the port and the server’s TLS settings.")
        case .authentication:
            L10n.text("Check the username, password, and authentication database.")
        case .unreachable:
            L10n.text("Check the host, port, VPN, firewall, and SSH tunnel settings.")
        case .timeout:
            L10n.text("The server didn’t respond in time. Check the network and try again.")
        case .other:
            L10n.text("Review the details below and the connection settings.")
        }
    }

    var isSecurityIssue: Bool {
        [.certificateUntrusted, .certificateHostname, .certificateExpired, .tlsUnavailable, .tlsHandshake].contains(kind)
    }

    static func classify(_ message: String) -> ConnectionIssue {
        let text = message.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }
        // Bare "tls" or "ssl" must be whole words, so identifiers such as ssl_mode in SQL errors don't match.
        let mentionsTLS = text.range(of: #"(^|[^a-z_])(tls|ssl)([^a-z_]|$)"#, options: .regularExpression) != nil

        let kind: Kind
        if has("hostname", "failedtovalidatehostname", "does not match", "doesn’t match", "doesn't match", "hostname_mismatch", "ip address mismatch", "-9843") {
            kind = .certificateHostname
        } else if has("certificate_expired", "certificate has expired", "certificate expired", "-9814") {
            kind = .certificateExpired
        } else if has("certificate_verify_failed", "unabletovalidatecertificate", "self signed", "self-signed", "unknown ca", "unknown_ca",
                      "untrusted", "not trusted", "certificate is invalid", "certificate for this server is invalid",
                      "unable to get local issuer", "-9807", "-9813", "certificate verify failed") {
            kind = .certificateUntrusted
        } else if has("sslunsupported", "does not support tls", "doesn’t support tls", "does not support ssl", "ssl is not enabled",
                      "server does not support ssl", "tls is not supported", "ssl off") {
            kind = .tlsUnavailable
        } else if mentionsTLS || has("handshake", "wrong_version_number", "boringssl", "niossl", "secure connection", "-1200", "-9806") {
            kind = .tlsHandshake
        } else if has("authentication failed", "password authentication", "invalid password", "wrong password", "access denied",
                      "28p01", "error 1045", "auth failed", "unauthorized", "http 401", "noauth", "wrongpass", "scram", "sasl") {
            kind = .authentication
        } else if has("timed out", "timeout", "-1001") {
            kind = .timeout
        } else if has("connection refused", "econnrefused", "could not connect", "couldn’t connect", "couldn't connect", "no route", "host not found",
                      "nodename nor servname", "getaddrinfo", "network is unreachable", "could not be found", "connection reset", "-1004", "-1003",
                      "nioconnectionerror", "socketaddresserror", "dnsaerror", "dns lookup", "connectionfailed", "connection failed") {
            kind = .unreachable
        } else {
            kind = .other
        }
        return ConnectionIssue(kind: kind, details: message)
    }

    /// Whether a message describes a connection problem rather than a SQL or data error.
    static func isConnectionProblem(_ message: String) -> Bool {
        classify(message).kind != .other
    }
}

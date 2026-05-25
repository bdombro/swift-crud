// EmailSender.swift: email abstraction for login codes — protocol, stdout fallback, and SMTP factory wiring.

import Foundation
import NIO

// MARK: - SMTP errors

/// Errors raised by the SMTP client implementation.
enum SMTPError: Error, CustomStringConvertible {
    /// `AUTH LOGIN` is refused when the connection is not protected by TLS.
    case authRequiresTLS
    /// TCP connect or an SMTP reply took longer than `SMTP_TIMEOUT_SECONDS`.
    case timeout
    /// Server returned a non-success SMTP status (body is the raw multiline reply).
    case serverRejected(String)
    /// `SMTP_HOST` is not usable for TLS SNI (e.g. MX names starting with `_`); set `SMTP_TLS_SERVERNAME`.
    case invalidTLSHostname(String)

    var description: String {
        switch self {
        case .authRequiresTLS:
            return "SMTP auth requires TLS (set SMTP_TLS_MODE to starttls or tls)"
        case .timeout:
            return "SMTP operation timed out"
        case .serverRejected(let reply):
            return "SMTP server rejected command: \(reply.prefix(200))"
        case .invalidTLSHostname(let host):
            return "SMTP TLS hostname \(host) is invalid; set SMTP_TLS_SERVERNAME (e.g. mail.example.com)"
        }
    }
}

// MARK: - From header formatting

/// RFC 5322 `From` value: optional display name plus angle-bracketed email.
func formatSMTPFromHeader(displayName: String?, email: String) -> String {
    let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedName.isEmpty else { return email }
    let escaped = trimmedName
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\" <\(email)>"
}

// MARK: - Protocol

/// Abstraction for delivering one-time 8-digit login codes to users.
protocol EmailSender: Sendable {
    /// Deliver an 8-digit zero-padded code to the user's email address.
    func send(code: String, to email: String) async throws
}

// MARK: - Print fallback

/// Prints the 8-digit code to stdout — the default when no SMTP is configured.
struct PrintEmailSender: EmailSender {
    func send(code: String, to email: String) async throws {
        print("Email send simulated: to= \(email), code= \(code)")
    }
}

// MARK: - Factory

extension EmailSender where Self == PrintEmailSender {
    static var printFallback: PrintEmailSender { PrintEmailSender() }
}

extension EmailSender where Self == SMTPEmailSender {
    static func smtp(config: SMTPConnectionConfig, group: EventLoopGroup, ownsGroup: Bool, from: String,
                     fromName: String? = nil) -> SMTPEmailSender {
        SMTPEmailSender(config: config, group: group, ownsGroup: ownsGroup, from: from, fromName: fromName)
    }
}

/// Picks the right sender based on environment config.
func makeEmailSender(from env: Environment) -> EmailSender {
    guard let host = env.smtpHost,
          let username = env.smtpUsername,
          let password = env.smtpPassword,
          let from = env.smtpFrom
    else {
        return .printFallback
    }
    let config = SMTPConnectionConfig(
        host: host,
        port: env.smtpPort,
        username: username,
        password: password,
        tlsMode: env.smtpTLSMode,
        tlsInsecure: env.smtpTlsInsecure,
        timeoutSeconds: env.smtpTimeoutSeconds,
        tlsServerName: env.smtpTLSServerName)
    let group = smtpEventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let ownsGroup = smtpEventLoopGroup == nil
    return .smtp(config: config, group: group, ownsGroup: ownsGroup, from: from, fromName: env.smtpFromName)
}

// EmailSender.swift: email abstraction for login codes — protocol, stdout fallback, factory from Environment.

import Foundation

// MARK: - SMTP errors

/// Errors raised by the SMTP client implementation.
enum SMTPError: Error {
    /// `AUTH LOGIN` is refused when the connection is not protected by TLS.
    case authRequiresTLS
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
    static func smtp(host: String, port: UInt16, username: String, password: String, from: String,
                     tlsMode: SMTPTLSMode = .starttls, tlsInsecure: Bool = false) -> SMTPEmailSender {
        SMTPEmailSender(host: host, port: port, username: username, password: password,
                        from: from, tlsMode: tlsMode, tlsInsecure: tlsInsecure)
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
    return .smtp(host: host, port: env.smtpPort, username: username, password: password, from: from,
                 tlsMode: env.smtpTLSMode, tlsInsecure: env.smtpTlsInsecure)
}

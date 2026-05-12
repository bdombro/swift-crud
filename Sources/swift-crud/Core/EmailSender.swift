// EmailSender.swift: email abstraction for delivering one-time login codes — provides PrintEmailSender (stdout fallback) and SMTPEmailSender (raw TCP via Network framework), plus a factory function.

import Foundation
import Network

// MARK: - Protocol

/// Abstraction for delivering one-time login codes to users.
protocol EmailSender: Sendable {
    /// Deliver the given code to the user's email address.
    func send(code: String, to email: String) async throws
}

// MARK: - Print fallback (current behaviour)

/// Prints the code to stdout — the default when no SMTP is configured.
struct PrintEmailSender: EmailSender {
    func send(code: String, to email: String) async throws {
        print("Email send simulated: to=\(email), code=\(code)")
    }
}

// MARK: - SMTP sender

/// Sends the code via SMTP using raw TCP (Network framework).
/// Requires `SMTP_HOST`, `SMTP_USERNAME`, `SMTP_PASSWORD`, and `SMTP_FROM` env vars.
struct SMTPEmailSender: EmailSender {
    let host: String
    let port: UInt16
    let username: String
    let password: String
    let from: String

    func send(code: String, to email: String) async throws {
        let message = buildMessage(code: code, to: email)
        try await sendRaw(message, to: email)
    }

    // MARK: - SMTP conversation

    private func sendRaw(_ message: String, to recipient: String) async throws {
        let connection = try await connect()
        try await connection.send("EHLO swift-crud\r\n")
        _ = try await connection.readUpToDelimiter()

        try await connection.send("AUTH LOGIN\r\n")
        _ = try await connection.readUpToDelimiter()

        try await connection.send("\(Data(username.utf8).base64EncodedString())\r\n")
        _ = try await connection.readUpToDelimiter()

        try await connection.send("\(Data(password.utf8).base64EncodedString())\r\n")
        _ = try await connection.readUpToDelimiter()

        try await connection.send("MAIL FROM:<\(from)>\r\n")
        _ = try await connection.readUpToDelimiter()

        try await connection.send("RCPT TO:<\(recipient)>\r\n")
        _ = try await connection.readUpToDelimiter()

        try await connection.send("DATA\r\n")
        _ = try await connection.readUpToDelimiter()

        try await connection.send("\(message)\r\n.\r\n")
        _ = try await connection.readUpToDelimiter()

        try await connection.send("QUIT\r\n")
    }

    private func buildMessage(code: String, to recipient: String) -> String {
        return """
        From: \(from)
        To: \(recipient)
        Subject: Your login code

        Your login code is: \(code)

        This code expires in 10 minutes.
        """
    }

    private func connect() async throws -> SMTPConnection {
        let connection = SMTPConnection()
        try await connection.connect(host: host, port: port)
        // Read the server greeting
        _ = try await connection.readUpToDelimiter()
        return connection
    }
}

// MARK: - Factory

extension EmailSender where Self == PrintEmailSender {
    static var printFallback: PrintEmailSender { PrintEmailSender() }
}

extension EmailSender where Self == SMTPEmailSender {
    static func smtp(host: String, port: UInt16, username: String, password: String, from: String) -> SMTPEmailSender {
        SMTPEmailSender(host: host, port: port, username: username, password: password, from: from)
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
    return .smtp(host: host, port: env.smtpPort, username: username, password: password, from: from)
}

// MARK: - Low-level TCP connection wrapper

private final class SMTPConnection: @unchecked Sendable {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "smtp")

    func connect(host: String, port: UInt16) async throws {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 587,
            using: .tcp
        )
        connection = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    func send(_ string: String) async throws {
        guard let conn = connection else { throw SMTPError.notConnected }
        let data = Data(string.utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func readUpToDelimiter() async throws -> String {
        guard let conn = connection else { throw SMTPError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    cont.resume(returning: String(decoding: data, as: UTF8.self))
                } else if isComplete {
                    cont.resume(returning: "")
                } else {
                    cont.resume(returning: "")
                }
            }
        }
    }

    deinit {
        connection?.cancel()
    }
}

private enum SMTPError: Error {
    case notConnected
}

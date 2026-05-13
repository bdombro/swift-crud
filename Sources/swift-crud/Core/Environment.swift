// Environment.swift: configuration management — loads settings from process environment and .env file with sensible defaults for port, database path, auth secret, and SMTP settings.

import Foundation

/// TLS mode for SMTP connections.
enum SMTPTLSMode: String {
    /// No encryption — plaintext SMTP (dev only).
    case none
    /// STARTTLS on the existing connection (port 587, the standard).
    case starttls
    /// Implicit TLS from the moment the TCP socket opens (port 465).
    case tls
}

// MARK: - .env file loading

/// Load key=value pairs from a .env file, returning them as a dictionary.
/// Does not override values already present in `overrides`.
private func loadDotEnv(path: String = ".env", overrides: [String: String]) -> [String: String] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path),
        let content = try? String(contentsOfFile: path, encoding: .utf8)
    else { return overrides }

    var result = overrides
    for line in content.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Skip comments and blank lines
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
        // Split on first =
        guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(
            in: .whitespaces)
        // Only set if not already in overrides (process env takes priority)
        if result[key] == nil {
            result[key] = value
        }
    }
    return result
}

// MARK: - Environment

/// Central config sourced from environment variables with sensible defaults.
struct Environment {
    // MARK: Server
    /// Port the HTTP server binds to.  Default `8000`.
    let port: UInt16

    /// Filesystem path for the SQLite database.  Default `db.sqlite` (CWD).
    let dbPath: String

    /// When true, Blackbird logs every query to stdout.
    let dbDebug: Bool

    // MARK: Logging
    /// File path for request logs.  If set, logs go here instead of stdout.
    let logFile: String?

    // MARK: Auth
    /// Secret key for HMAC-signing the `user_id` cookie.
    let authSecret: String

    // MARK: Email / SMTP
    /// SMTP server hostname.  If nil, email sending falls back to print-to-stdout.
    let smtpHost: String?

    /// SMTP server port.  Ignored when `smtpHost` is nil.  Default `587`.
    let smtpPort: UInt16

    /// SMTP username (typically the full email address).
    let smtpUsername: String?

    /// SMTP password / app password.
    let smtpPassword: String?

    /// The "From" address used in outgoing emails.
    let smtpFrom: String?

    /// TLS mode for SMTP connections.  Default `.starttls`.
    let smtpTLSMode: SMTPTLSMode

    /// When true, skip TLS certificate validation (dev only).  Default `false`.
    let smtpTlsInsecure: Bool

    // MARK: Init from real environment

    init() {
        // Process environment takes priority over .env file
        let processEnv = ProcessInfo.processInfo.environment
        let mergedEnv = loadDotEnv(overrides: processEnv)

        func get(_ key: String, default: String = "") -> String {
            mergedEnv[key] ?? ""
        }

        port = mergedEnv["PORT"].flatMap(UInt16.init) ?? 8000
        dbPath = mergedEnv["DB_PATH"] ?? "db.sqlite"
        dbDebug = mergedEnv["DB_DEBUG"].map { $0 == "true" || $0 == "1" } ?? false

        logFile = mergedEnv["LOG_FILE"].flatMap { $0.isEmpty ? nil : $0 }

        authSecret = mergedEnv["AUTH_SECRET"] ?? "change-me"

        smtpHost = mergedEnv["SMTP_HOST"].flatMap { $0.isEmpty ? nil : $0 }
        smtpPort = mergedEnv["SMTP_PORT"].flatMap(UInt16.init) ?? 587
        smtpUsername = mergedEnv["SMTP_USERNAME"].flatMap { $0.isEmpty ? nil : $0 }
        smtpPassword = mergedEnv["SMTP_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }
        smtpFrom = mergedEnv["SMTP_FROM"].flatMap { $0.isEmpty ? nil : $0 }
        smtpTLSMode = mergedEnv["SMTP_TLS_MODE"].flatMap(SMTPTLSMode.init) ?? .starttls
        smtpTlsInsecure = mergedEnv["SMTP_TLS_INSECURE"].map { $0 == "true" || $0 == "1" } ?? false
    }

    // MARK: Init for testing (allows overriding specific values)

    init(
        port: UInt16 = 8000,
        dbPath: String = "db.sqlite",
        dbDebug: Bool = false,
        authSecret: String = "change-me",
        smtpHost: String? = nil,
        smtpPort: UInt16 = 587,
        smtpUsername: String? = nil,
        smtpPassword: String? = nil,
        smtpFrom: String? = nil,
        smtpTLSMode: SMTPTLSMode = .starttls,
        smtpTlsInsecure: Bool = false,
        logFile: String? = nil
    ) {
        self.port = port
        self.dbPath = dbPath
        self.dbDebug = dbDebug
        self.authSecret = authSecret
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.smtpPassword = smtpPassword
        self.smtpFrom = smtpFrom
        self.smtpTLSMode = smtpTLSMode
        self.smtpTlsInsecure = smtpTlsInsecure
        self.logFile = logFile
    }
}

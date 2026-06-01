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

/// Strips optional surrounding quotes from a `.env` value (exposed for unit tests).
internal func stripDotEnvQuotes(_ value: String) -> String {
    var v = value
    if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
        v = String(v.dropFirst().dropLast())
    } else if v.count >= 2, v.hasPrefix("'"), v.hasSuffix("'") {
        v = String(v.dropFirst().dropLast())
    }
    return v
}

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
        var value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(
            in: .whitespaces)
        value = stripDotEnvQuotes(value)
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
    /// Default HTTP listen port when `PORT` is unset.
    static let defaultPort: UInt16 = 8222

    // MARK: Server
    /// Port the HTTP server binds to.  Default `8222`.
    let port: UInt16

    /// Filesystem path for the SQLite database.  Default `db.sqlite` (CWD).
    let dbPath: String

    /// When true, Blackbird logs every query to stdout.
    let dbDebug: Bool

    // MARK: Auth
    /// Secret key for HMAC-signing the `user_id` cookie.
    let authSecret: String

    /// Parent domain for the session cookie (`COOKIE_DOMAIN`). Omit for host-only cookies (local dev).
    let cookieDomain: String?

    /// When false, omit `Secure` on session cookies (`COOKIE_SECURE=false`) for local HTTP testing.
    let cookieSecure: Bool

    /// Browser origins allowed for credentialed CORS (`CORS_ALLOWED_ORIGINS`, comma-separated).
    let corsAllowedOrigins: [String]

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

    /// Optional display name for the `From` header (`SMTP_FROM_NAME`).
    let smtpFromName: String?

    /// TLS mode for SMTP connections.  Default `.starttls`.
    let smtpTLSMode: SMTPTLSMode

    /// When true, skip TLS certificate validation (dev only).  Default `false`.
    let smtpTlsInsecure: Bool

    /// Seconds to wait for SMTP connect and each server reply.  Default `30`.
    let smtpTimeoutSeconds: Int

    /// TLS SNI / certificate hostname when `SMTP_HOST` is not a valid DNS name (e.g. `_dc-mx.*` MX records).
    let smtpTLSServerName: String?

    // MARK: OpenObserve
    /// OpenObserve JSON ingestion endpoint URL. If nil, direct ingestion is skipped.
    let openobserveURL: String?

    /// OpenObserve ingestion username.
    let openobserveUser: String?

    /// OpenObserve ingestion password.
    let openobservePass: String?

    /// When true, access and info logs are written to standard output and error (default: true).
    let consoleLogsEnabled: Bool

    // MARK: Init from real environment

    /// Loads configuration from process environment, then `.env` (process vars win on conflict).
    init() {
        // Process environment takes priority over .env file
        let processEnv = ProcessInfo.processInfo.environment
        let mergedEnv = loadDotEnv(overrides: processEnv)

        func get(_ key: String, default: String = "") -> String {
            mergedEnv[key] ?? ""
        }

        port = mergedEnv["PORT"].flatMap(UInt16.init) ?? Self.defaultPort
        dbPath = mergedEnv["DB_PATH"] ?? "db.sqlite"
        dbDebug = mergedEnv["DB_DEBUG"].map { $0 == "true" || $0 == "1" } ?? false

        authSecret = mergedEnv["AUTH_SECRET"] ?? "change-me"

        cookieDomain = mergedEnv["COOKIE_DOMAIN"].flatMap { $0.isEmpty ? nil : $0 }
        cookieSecure = mergedEnv["COOKIE_SECURE"].map { $0 != "false" && $0 != "0" } ?? true
        corsAllowedOrigins =
            mergedEnv["CORS_ALLOWED_ORIGINS"]
            .map {
                $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } ?? []

        smtpHost = mergedEnv["SMTP_HOST"].flatMap { $0.isEmpty ? nil : $0 }
        smtpPort = mergedEnv["SMTP_PORT"].flatMap(UInt16.init) ?? 587
        smtpUsername = mergedEnv["SMTP_USERNAME"].flatMap { $0.isEmpty ? nil : $0 }
        smtpPassword = mergedEnv["SMTP_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }
        smtpFrom = mergedEnv["SMTP_FROM"].flatMap { $0.isEmpty ? nil : $0 }
        smtpFromName = mergedEnv["SMTP_FROM_NAME"].flatMap { $0.isEmpty ? nil : $0 }
        smtpTLSMode = mergedEnv["SMTP_TLS_MODE"].flatMap(SMTPTLSMode.init) ?? .starttls
        smtpTlsInsecure = mergedEnv["SMTP_TLS_INSECURE"].map { $0 == "true" || $0 == "1" } ?? false
        smtpTimeoutSeconds = mergedEnv["SMTP_TIMEOUT_SECONDS"].flatMap(Int.init) ?? defaultSMTPTimeoutSeconds
        smtpTLSServerName = mergedEnv["SMTP_TLS_SERVERNAME"].flatMap { $0.isEmpty ? nil : $0 }

        openobserveURL = mergedEnv["OPENOBSERVE_URL"].flatMap { $0.isEmpty ? nil : $0 }
        openobserveUser = mergedEnv["OPENOBSERVE_USER"].flatMap { $0.isEmpty ? nil : $0 }
        openobservePass = mergedEnv["OPENOBSERVE_PASS"].flatMap { $0.isEmpty ? nil : $0 }

        consoleLogsEnabled = mergedEnv["CONSOLE_LOGS_ENABLED"].map { $0 != "false" && $0 != "0" } ?? true
    }

    // MARK: Init for testing (allows overriding specific values)

    /// Documented defaults without reading process environment or `.env` (unit tests).
    static func testingDefaults() -> Environment {
        Environment(
            port: Self.defaultPort,
            dbPath: "db.sqlite",
            dbDebug: false,
            authSecret: "change-me",
            cookieDomain: nil,
            cookieSecure: true,
            corsAllowedOrigins: [],
            smtpHost: nil,
            smtpPort: 587,
            smtpUsername: nil,
            smtpPassword: nil,
            smtpFrom: nil,
            smtpFromName: nil,
            smtpTLSMode: .starttls,
            smtpTlsInsecure: false,
            smtpTimeoutSeconds: defaultSMTPTimeoutSeconds,
            smtpTLSServerName: nil,
            openobserveURL: nil,
            openobserveUser: nil,
            openobservePass: nil,
            consoleLogsEnabled: true
        )
    }

    /// Builds config from explicit values; used by unit tests instead of `ProcessInfo` / `.env`.
    init(
        port: UInt16 = Environment.defaultPort,
        dbPath: String = "db.sqlite",
        dbDebug: Bool = false,
        authSecret: String = "change-me",
        cookieDomain: String? = nil,
        cookieSecure: Bool = true,
        corsAllowedOrigins: [String] = [],
        smtpHost: String? = nil,
        smtpPort: UInt16 = 587,
        smtpUsername: String? = nil,
        smtpPassword: String? = nil,
        smtpFrom: String? = nil,
        smtpFromName: String? = nil,
        smtpTLSMode: SMTPTLSMode = .starttls,
        smtpTlsInsecure: Bool = false,
        smtpTimeoutSeconds: Int = defaultSMTPTimeoutSeconds,
        smtpTLSServerName: String? = nil,
        openobserveURL: String? = nil,
        openobserveUser: String? = nil,
        openobservePass: String? = nil,
        consoleLogsEnabled: Bool = true
    ) {
        self.port = port
        self.dbPath = dbPath
        self.dbDebug = dbDebug
        self.authSecret = authSecret
        self.cookieDomain = cookieDomain
        self.cookieSecure = cookieSecure
        self.corsAllowedOrigins = corsAllowedOrigins
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.smtpPassword = smtpPassword
        self.smtpFrom = smtpFrom
        self.smtpFromName = smtpFromName
        self.smtpTLSMode = smtpTLSMode
        self.smtpTlsInsecure = smtpTlsInsecure
        self.smtpTimeoutSeconds = smtpTimeoutSeconds
        self.smtpTLSServerName = smtpTLSServerName
        self.openobserveURL = openobserveURL
        self.openobserveUser = openobserveUser
        self.openobservePass = openobservePass
        self.consoleLogsEnabled = consoleLogsEnabled
    }
}

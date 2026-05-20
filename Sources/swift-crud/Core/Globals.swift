// Globals.swift: module-level singletons wired at startup (database, auth secret, email).

import Blackbird
import Foundation

/// Module-level auth secret for HMAC-signing the `user_id` cookie.
nonisolated(unsafe) var activeAuthSecret: String = "change-me"

/// Parent domain for the `user_id` cookie (`COOKIE_DOMAIN`), e.g. `btec.cc` for cross-subdomain sharing.
nonisolated(unsafe) var cookieDomain: String?

/// When true, session cookies include `Secure` (`COOKIE_SECURE`; default true).
nonisolated(unsafe) var cookieSecure: Bool = true

/// Allowed `Origin` values for CORS (`CORS_ALLOWED_ORIGINS`, comma-separated).
nonisolated(unsafe) var corsAllowedOrigins: [String] = []

/// Module-level database reference set once at startup.
nonisolated(unsafe) var db: Blackbird.Database!

/// Module-level email sender set once at startup.
nonisolated(unsafe) var emailSender: EmailSender = PrintEmailSender()

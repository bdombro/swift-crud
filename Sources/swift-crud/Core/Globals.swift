// Globals.swift: module-level singletons wired at startup (database, auth secret, email).

import Blackbird
import Foundation

/// Module-level auth secret for HMAC-signing the `user_id` cookie.
nonisolated(unsafe) var activeAuthSecret: String = "change-me"

/// Module-level database reference set once at startup.
nonisolated(unsafe) var db: Blackbird.Database!

/// Module-level email sender set once at startup.
nonisolated(unsafe) var emailSender: EmailSender = PrintEmailSender()

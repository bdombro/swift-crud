// Validators.swift: shared validation helpers used across route handlers.

import Foundation

/// Validates a post ID string: non-empty and within reasonable length.
func isValidID(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 255
}

/// Validates an optional UUID string: nil is valid (will be auto-generated), otherwise must be a proper UUID.
func isValidUUID(_ s: String?) -> Bool {
    guard let s else { return true }
    return UUID(uuidString: s) != nil
}

/// Normalizes login / send-code email: trim, lowercase, single `@`, no plus-addressing in the local part.
func normalizeEmail(_ raw: String) -> String? {
    let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard email.count >= 5, email.count <= 254 else { return nil }
    let parts = email.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    guard !parts[0].contains("+") else { return nil }
    return email
}

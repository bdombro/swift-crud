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

// MockEmailSender: records sent codes for test assertions.
// Conforms to the EmailSender protocol; swap in via the module-level `emailSender` global.

import Foundation
@testable import swift_crud

/// Records every `send(code:to:)` call so tests can verify what code was issued.
actor MockEmailSender: EmailSender {

    private(set) var sent: [(code: String, to: String)] = []

    func send(code: String, to email: String) async throws {
        sent.append((code: code, to: email))
    }

    /// Most recent code sent to a given address.
    func lastCode(for email: String) -> String? {
        sent.last { $0.to == email }?.code
    }

    /// Clear recorded sends between tests.
    func reset() {
        sent = []
    }
}

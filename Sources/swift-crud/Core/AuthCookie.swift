// AuthCookie.swift: HMAC-SHA256 helpers for signing and verifying the `user_id` session cookie.

import CryptoKit
import Foundation

// Constant-time comparison of two Data values to prevent timing side-channel attacks.
private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var result: UInt8 = 0
    for i in 0..<lhs.count {
        result |= lhs[i] ^ rhs[i]
    }
    return result == 0
}

/// Namespace for HMAC-signed `user_id` cookie helpers.
enum AuthCookie {
    /// Sign a user ID for use as the cookie value.
    static func sign(userId: Int, with secret: String) -> String {
        let data = Data("\(userId)".utf8)
        let key = SymmetricKey(data: Data(secret.utf8))
        let hmac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        let sig = Data(hmac).base64EncodedString()
        return "\(userId).\(sig)"
    }

    /// Verify and extract the user ID from a signed cookie value.
    /// Returns `nil` if the signature is missing, malformed, or invalid.
    static func verify(_ cookieValue: String, secret: String) -> Int? {
        let parts = cookieValue.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
            let userId = Int(parts[0])
        else { return nil }

        let data = Data("\(parts[0])".utf8)
        let key = SymmetricKey(data: Data(secret.utf8))
        let expected = HMAC<SHA256>.authenticationCode(for: data, using: key)

        guard let sigData = Data(base64Encoded: String(parts[1])),
            sigData.count == SHA256.byteCount
        else { return nil }
        guard constantTimeEqual(Data(expected), sigData) else { return nil }

        return userId
    }

    /// Set the `user_id` cookie on a response (signed value).
    static func setCookie(userId: Int, secret: String) -> String {
        sign(userId: userId, with: secret)
    }
}

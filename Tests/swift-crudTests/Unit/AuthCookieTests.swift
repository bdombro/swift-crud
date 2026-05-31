// AuthCookieTests: pure unit tests for HMAC cookie signing and verification.
// No I/O — runs in parallel with the rest of the suite.

import Foundation
import Testing
@testable import swift_crud

@Suite("AuthCookie")
struct AuthCookieTests {

    // MARK: Round-trip

    @Test("sign then verify returns original userId", arguments: zip(["e2e12345-6789-abcd-ef01-23456789abcd", "another-uuid-string", "custom-id"], ["s3cr3t", "another-key", "x"]))
    func roundTrip(userId: String, secret: String) {
        let signed = AuthCookie.sign(userId: userId, with: secret)
        #expect(AuthCookie.verify(signed, secret: secret) == userId)
    }

    // MARK: Failure cases

    @Test("wrong secret returns nil")
    func wrongSecret() {
        let signed = AuthCookie.sign(userId: "user-1", with: "correct-secret")
        #expect(AuthCookie.verify(signed, secret: "wrong-secret") == nil)
    }

    @Test("cookie with no dot separator returns nil")
    func noSeparator() {
        #expect(AuthCookie.verify("12345", secret: "secret") == nil)
    }

    @Test("tampered userId returns nil")
    func tamperedUserId() {
        let signed = AuthCookie.sign(userId: "user-1", with: "secret")
        let sig = signed.split(separator: ".", maxSplits: 1).last.map(String.init) ?? ""
        #expect(AuthCookie.verify("user-2.\(sig)", secret: "secret") == nil)
    }

    @Test("tampered signature returns nil")
    func tamperedSignature() {
        let signed = AuthCookie.sign(userId: "user-1", with: "secret")
        let userId = signed.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        // Valid base64 but wrong bytes (all-zero, 32 bytes → 44 base64 chars with padding)
        let badSig = Data(repeating: 0, count: 32).base64EncodedString()
        #expect(AuthCookie.verify("\(userId).\(badSig)", secret: "secret") == nil)
    }

    @Test("non-base64 signature returns nil")
    func nonBase64Signature() {
        #expect(AuthCookie.verify("user-1.not!!base64@@", secret: "secret") == nil)
    }

    @Test("signature of wrong byte length returns nil")
    func wrongSignatureLength() {
        // 16 bytes is shorter than SHA256's 32 bytes
        let shortSig = Data(repeating: 0xAB, count: 16).base64EncodedString()
        #expect(AuthCookie.verify("user-1.\(shortSig)", secret: "secret") == nil)
    }

    @Test("empty cookie string returns nil")
    func emptyCookie() {
        #expect(AuthCookie.verify("", secret: "secret") == nil)
    }
}

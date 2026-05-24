import Foundation
import Testing
@testable import swift_crud

@Suite("SMTP response framing")
struct SMTPParsingTests {
    @Test("single-line 220 greeting is complete")
    func greetingComplete() {
        let greeting = "220 mail.example.com ESMTP\r\n"
        #expect(isSMTPResponseComplete(greeting))
        #expect(smtpFinalStatusCode(greeting) == 220)
    }

    @Test("multiline EHLO reply is complete")
    func ehloComplete() {
        let ehlo = "250-mail.example.com\r\n250-STARTTLS\r\n250 CHUNKING\r\n"
        #expect(isSMTPResponseComplete(ehlo))
        #expect(smtpFinalStatusCode(ehlo) == 250)
    }

    @Test("continuation-only buffer is not complete")
    func partialEhlo() {
        let partial = "250-mail.example.com\r\n250-STARTTLS\r\n"
        #expect(!isSMTPResponseComplete(partial))
    }

    @Test("requireSMTPCode accepts allowed codes")
    func requireCode() throws {
        try requireSMTPCode(in: "250 ok\r\n", allowed: [250])
        #expect(throws: SMTPError.self) {
            try requireSMTPCode(in: "535 auth failed\r\n", allowed: [235])
        }
    }

    @Test("formatSMTPFromHeader with display name")
    func fromHeaderWithName() {
        #expect(formatSMTPFromHeader(displayName: "BTEC", email: "noreply@example.com")
            == "\"BTEC\" <noreply@example.com>")
    }

    @Test("formatSMTPFromHeader without display name")
    func fromHeaderEmailOnly() {
        #expect(formatSMTPFromHeader(displayName: nil, email: "noreply@example.com") == "noreply@example.com")
        #expect(formatSMTPFromHeader(displayName: "  ", email: "noreply@example.com") == "noreply@example.com")
    }

    @Test("formatSMTPFromHeader escapes quotes and backslashes")
    func fromHeaderEscaping() {
        #expect(formatSMTPFromHeader(displayName: "A \"B\" C", email: "a@b.co")
            == "\"A \\\"B\\\" C\" <a@b.co>")
    }
}

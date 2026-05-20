// SessionCookieTests: Set-Cookie attribute assembly for session auth.

import Testing
@testable import swift_crud

@Suite("SessionCookie", .serialized)
struct SessionCookieTests {

    @Test("default header includes Secure and omits Domain")
    func defaultHeader() {
        cookieDomain = nil
        cookieSecure = true
        let header = SessionCookie.setHeader(signedValue: "1.abc", expires: "Wed, 01 Jan 2099 00:00:00 GMT")
        #expect(header.contains("user_id=1.abc"))
        #expect(header.contains("HttpOnly"))
        #expect(header.contains("Secure"))
        #expect(header.contains("SameSite=Lax"))
        #expect(!header.contains("Domain="))
    }

    @Test("COOKIE_DOMAIN adds Domain attribute")
    func withDomain() {
        cookieDomain = "btec.cc"
        cookieSecure = true
        let header = SessionCookie.setHeader(signedValue: "2.sig", expires: "Wed, 01 Jan 2099 00:00:00 GMT")
        #expect(header.contains("Domain=btec.cc"))
    }

    @Test("cookieSecure false omits Secure")
    func withoutSecure() {
        cookieDomain = nil
        cookieSecure = false
        let header = SessionCookie.setHeader(signedValue: "3.sig", expires: "Wed, 01 Jan 2099 00:00:00 GMT")
        #expect(!header.contains("Secure"))
    }

    @Test("clear header uses epoch expiry")
    func clearHeader() {
        cookieDomain = "example.com"
        cookieSecure = false
        let header = SessionCookie.clearHeader()
        #expect(header.hasPrefix("user_id=;"))
        #expect(header.contains("Expires=Thu, 01 Jan 1970"))
        #expect(header.contains("Domain=example.com"))
    }
}

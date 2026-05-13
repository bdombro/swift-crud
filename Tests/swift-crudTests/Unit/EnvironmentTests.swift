// EnvironmentTests: verifies the test-overload Environment initializer defaults and overrides.
// Skips the ProcessInfo init — that path depends on the process environment and is flaky.

import Testing
@testable import swift_crud

@Suite("Environment")
struct EnvironmentTests {

    // MARK: Defaults

    @Test("default port is 8000")
    func defaultPort() {
        #expect(Environment().port == 8000)
    }

    @Test("default dbPath is db.sqlite")
    func defaultDbPath() {
        #expect(Environment().dbPath == "db.sqlite")
    }

    @Test("default dbDebug is false")
    func defaultDbDebug() {
        #expect(Environment().dbDebug == false)
    }

    @Test("default smtpHost is nil")
    func defaultSmtpHost() {
        #expect(Environment().smtpHost == nil)
    }

    @Test("default smtpPort is 587")
    func defaultSmtpPort() {
        #expect(Environment().smtpPort == 587)
    }

    @Test("default smtpUsername is nil")
    func defaultSmtpUsername() {
        #expect(Environment().smtpUsername == nil)
    }

    // MARK: Overrides

    @Test("custom port round-trips")
    func customPort() {
        #expect(Environment(port: 9000).port == 9000)
    }

    @Test("custom dbPath round-trips")
    func customDbPath() {
        #expect(Environment(dbPath: "/tmp/test.db").dbPath == "/tmp/test.db")
    }

    @Test("custom authSecret round-trips")
    func customAuthSecret() {
        #expect(Environment(authSecret: "my-secret").authSecret == "my-secret")
    }

    @Test("custom smtpHost round-trips")
    func customSmtpHost() {
        #expect(Environment(smtpHost: "smtp.example.com").smtpHost == "smtp.example.com")
    }

    @Test("default smtpTLSMode is starttls")
    func defaultSmtpTLSMode() {
        #expect(Environment().smtpTLSMode == .starttls)
    }

    @Test("custom smtpTLSMode round-trips")
    func customSmtpTLSMode() {
        #expect(Environment(smtpTLSMode: .tls).smtpTLSMode == .tls)
        #expect(Environment(smtpTLSMode: .none).smtpTLSMode == .none)
    }

    @Test("default smtpTlsInsecure is false")
    func defaultSmtpTlsInsecure() {
        #expect(Environment().smtpTlsInsecure == false)
    }

    @Test("custom smtpTlsInsecure round-trips")
    func customSmtpTlsInsecure() {
        #expect(Environment(smtpTlsInsecure: true).smtpTlsInsecure == true)
    }

    @Test("dbDebug true round-trips")
    func dbDebugTrue() {
        #expect(Environment(dbDebug: true).dbDebug == true)
    }
}

// EnvironmentTests: verifies the test-overload Environment initializer defaults and overrides.
// Skips the ProcessInfo init — that path depends on the process environment and is flaky.

import Testing
@testable import swift_crud

@Suite("Environment")
struct EnvironmentTests {

    // MARK: Defaults

    @Test("default port is 8222")
    func defaultPort() {
        #expect(Environment.testingDefaults().port == 8222)
    }

    @Test("default dbPath is db.sqlite")
    func defaultDbPath() {
        #expect(Environment.testingDefaults().dbPath == "db.sqlite")
    }

    @Test("default dbDebug is false")
    func defaultDbDebug() {
        #expect(Environment.testingDefaults().dbDebug == false)
    }

    @Test("default smtpHost is nil")
    func defaultSmtpHost() {
        #expect(Environment.testingDefaults().smtpHost == nil)
    }

    @Test("default smtpPort is 587")
    func defaultSmtpPort() {
        #expect(Environment.testingDefaults().smtpPort == 587)
    }

    @Test("default smtpUsername is nil")
    func defaultSmtpUsername() {
        #expect(Environment.testingDefaults().smtpUsername == nil)
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

    @Test("default cookieDomain is nil")
    func defaultCookieDomain() {
        #expect(Environment.testingDefaults().cookieDomain == nil)
    }

    @Test("default cookieSecure is true")
    func defaultCookieSecure() {
        #expect(Environment.testingDefaults().cookieSecure == true)
    }

    @Test("default corsAllowedOrigins is empty")
    func defaultCorsOrigins() {
        #expect(Environment.testingDefaults().corsAllowedOrigins.isEmpty)
    }

    @Test("custom cookie and CORS settings round-trip")
    func customCookieAndCors() {
        let env = Environment(
            cookieDomain: "btec.cc",
            cookieSecure: false,
            corsAllowedOrigins: ["https://app.btec.cc", "https://staging.btec.cc"])
        #expect(env.cookieDomain == "btec.cc")
        #expect(env.cookieSecure == false)
        #expect(env.corsAllowedOrigins == ["https://app.btec.cc", "https://staging.btec.cc"])
    }

    @Test("custom smtpHost round-trips")
    func customSmtpHost() {
        #expect(Environment(smtpHost: "smtp.example.com").smtpHost == "smtp.example.com")
    }

    @Test("default smtpTLSMode is starttls")
    func defaultSmtpTLSMode() {
        #expect(Environment.testingDefaults().smtpTLSMode == .starttls)
    }

    @Test("custom smtpTLSMode round-trips")
    func customSmtpTLSMode() {
        #expect(Environment(smtpTLSMode: .tls).smtpTLSMode == .tls)
        #expect(Environment(smtpTLSMode: .none).smtpTLSMode == .none)
    }

    @Test("default smtpTlsInsecure is false")
    func defaultSmtpTlsInsecure() {
        #expect(Environment.testingDefaults().smtpTlsInsecure == false)
    }

    @Test("custom smtpTlsInsecure round-trips")
    func customSmtpTlsInsecure() {
        #expect(Environment(smtpTlsInsecure: true).smtpTlsInsecure == true)
    }

    @Test("dbDebug true round-trips")
    func dbDebugTrue() {
        #expect(Environment(dbDebug: true).dbDebug == true)
    }

    // MARK: .env value parsing

    @Test("stripDotEnvQuotes removes balanced double quotes")
    func stripDoubleQuotes() {
        #expect(stripDotEnvQuotes("\"hello\"") == "hello")
    }

    @Test("stripDotEnvQuotes removes balanced single quotes")
    func stripSingleQuotes() {
        #expect(stripDotEnvQuotes("'world'") == "world")
    }

    @Test("stripDotEnvQuotes leaves unquoted values unchanged")
    func stripUnquoted() {
        #expect(stripDotEnvQuotes("plain") == "plain")
    }
}

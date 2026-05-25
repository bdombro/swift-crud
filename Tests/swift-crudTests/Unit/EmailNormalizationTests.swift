import Testing

@testable import swift_crud

@Suite("Email normalization")
struct EmailNormalizationTests {

    @Test("trim and lowercase")
    func trimLowercase() {
        #expect(normalizeEmail("  User@Example.COM  ") == "user@example.com")
    }

    @Test("rejects plus addressing")
    func rejectsPlus() {
        #expect(normalizeEmail("user+tag@example.com") == nil)
    }

    @Test("rejects too short and malformed")
    func rejectsInvalid() {
        #expect(normalizeEmail("a@b") == nil)
        #expect(normalizeEmail("a@@b.com") == nil)
        #expect(normalizeEmail("") == nil)
    }

    @Test("accepts typical address")
    func acceptsTypical() {
        #expect(normalizeEmail("bdombro@gmail.com") == "bdombro@gmail.com")
    }
}

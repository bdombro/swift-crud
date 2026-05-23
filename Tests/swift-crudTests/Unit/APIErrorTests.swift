// APIErrorTests: stable error codes in JSON error bodies.

import Foundation
import Testing
@testable import swift_crud

@Suite("APIError")
struct APIErrorTests {

    @Test("apiError encodes message and code")
    func encodesBody() throws {
        let response = HTTPResponse.apiError(.unauthorized, .invalidEmail)
        let body = try JSONDecoder().decode(APIErrorBody.self, from: response.body)
        #expect(body.message == "invalid email")
        #expect(body.code == 104)
    }

    @Test("custom message overrides default")
    func customMessage() throws {
        let response = HTTPResponse.apiError(.badRequest, .invalidPostId, message: "custom")
        let body = try JSONDecoder().decode(APIErrorBody.self, from: response.body)
        #expect(body.message == "custom")
        #expect(body.code == 203)
    }
}

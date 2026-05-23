// APIError.swift: stable three-digit error codes and JSON error response bodies.

import Foundation
import NIOHTTP1

/// JSON body for API error responses.
struct APIErrorBody: Codable {
    let message: String
    let code: Int
}

/// Application error codes (three digits). Each case maps to one distinct client-facing error.
enum APIErrorCode: Int {
    // MARK: Session (1xx)
    case unauthorized = 101
    case invalidCodeEncoding = 102
    case invalidEmailOrPassword = 103
    case invalidEmail = 104
    case sendCodeIPRateLimited = 105
    case sendCodeEmailRateLimited = 106
    case sendCodeCooldown = 107

    // MARK: Posts (2xx)
    case postContentTooLong = 201
    case postVariantTooLong = 202
    case invalidPostId = 203
    case postNotFound = 204
    case invalidAfterCursor = 205
    case missingPostIdParameter = 206
    case postNotFoundOrUnauthorized = 207
    case invalidBulkPostId = 208

    // MARK: Health (3xx)
    case databaseUnavailable = 301

    // MARK: Server (9xx)
    case routeNotFound = 901
    case requestBodyTooLarge = 902
    case internalServerError = 903

    /// Default English message when the handler does not override the text.
    var defaultMessage: String {
        switch self {
        case .unauthorized: return "unauthorized"
        case .invalidCodeEncoding: return "invalid login code format"
        case .invalidEmailOrPassword: return "invalid email or password"
        case .invalidEmail: return "invalid email"
        case .sendCodeIPRateLimited:
            return "Too many code requests from this network. Try again later."
        case .sendCodeEmailRateLimited: return "Too many code requests. Try again later."
        case .sendCodeCooldown: return "Wait 2 minutes after requesting a code to try again."
        case .postContentTooLong: return "content too long"
        case .postVariantTooLong: return "variant too long"
        case .invalidPostId: return "invalid post id"
        case .postNotFound: return "Post not found"
        case .invalidAfterCursor: return "invalid after cursor"
        case .missingPostIdParameter: return "missing id parameter"
        case .postNotFoundOrUnauthorized: return "Post not found or unauthorized"
        case .invalidBulkPostId: return "invalid id format"
        case .databaseUnavailable: return "database unavailable"
        case .routeNotFound: return "Not Found"
        case .requestBodyTooLarge: return "Request body too large"
        case .internalServerError: return "internal server error"
        }
    }
}

extension HTTPResponse {
    /// JSON error response with `message` and a stable three-digit `code`.
    static func apiError(
        _ status: HTTPResponseStatus,
        _ code: APIErrorCode,
        message: String? = nil
    ) -> HTTPResponse {
        json(status, APIErrorBody(message: message ?? code.defaultMessage, code: code.rawValue))
    }
}

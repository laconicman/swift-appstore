import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import AppStoreKit

/// Runs a request through one middleware straight into a ``MockTransport``.
func run(
    _ middleware: some ClientMiddleware,
    _ request: HTTPRequest,
    body: HTTPBody? = nil,
    through transport: MockTransport,
    operationID: String = "test_operation"
) async throws -> (HTTPResponse, HTTPBody?) {
    let baseURL = URL(string: "https://api.appstoreconnect.apple.com")!
    return try await middleware.intercept(request, body: body, baseURL: baseURL, operationID: operationID) {
        try await transport.send($0, body: $1, baseURL: $2, operationID: operationID)
    }
}

/// Records requested sleeps instead of waiting.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [TimeInterval] = []

    var delays: [TimeInterval] { lock.withLock { _delays } }

    var sleep: RetryMiddleware.Sleep {
        { [self] delay in lock.withLock { _delays.append(delay) } }
    }
}

extension HTTPRequest {
    static func get(_ path: String) -> HTTPRequest {
        HTTPRequest(method: .get, scheme: "https", authority: "api.appstoreconnect.apple.com", path: path)
    }

    static func post(_ path: String) -> HTTPRequest {
        HTTPRequest(method: .post, scheme: "https", authority: "api.appstoreconnect.apple.com", path: path)
    }
}

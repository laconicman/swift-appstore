import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Adds `Authorization: Bearer <jwt>` to every request and, on a `401 Unauthorized`, refreshes
/// the token once and replays the request. A second 401 is returned to the caller as-is — it
/// means the key is revoked or lacks the role, not that the token aged out.
///
/// The replay is skipped when the request body can only be iterated once
/// (`HTTPBody.IterationBehavior.single`), because the transport has already consumed it.
public struct AuthenticationMiddleware: ClientMiddleware {
    private let tokens: BearerTokenCache

    public init(tokens: BearerTokenCache) {
        self.tokens = tokens
    }

    public init(key: APIKey) {
        self.init(tokens: BearerTokenCache(signer: JWTSigner(key: key)))
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(try await tokens.token())"
        let (response, responseBody) = try await next(request, body, baseURL)

        guard response.status == .unauthorized, body.isReplayable else {
            return (response, responseBody)
        }
        await tokens.invalidate()
        request.headerFields[.authorization] = "Bearer \(try await tokens.token())"
        return try await next(request, body, baseURL)
    }
}

extension HTTPBody? {
    /// Whether the body can be sent a second time. `nil` (no body) always can.
    var isReplayable: Bool {
        switch self?.iterationBehavior {
        case .none, .multiple: true
        case .single: false
        }
    }
}

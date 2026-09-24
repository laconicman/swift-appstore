import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Thrown when a mutating request (POST / PATCH / DELETE) failed *without a response* — a timeout,
/// a dropped connection, a cancelled task — so App Store Connect may or may not have applied it.
///
/// AppStoreKit never retries such a request on its own: a duplicate `POST` creates a second
/// localization, screenshot set or review submission item, and Apple has no idempotency key
/// to make that safe. Instead the caller gets this error with ``inspectionGuidance`` telling
/// it what to read before deciding. (Modeled on zelentsov-dev/asc-mcp's
/// `ASCNonIdempotentWriteRecovery`, which classifies the same failure as "outcome unknown"
/// and points at the resource to inspect.)
public struct MutationOutcomeUnknownError: Error, CustomStringConvertible, Sendable {
    public let operationID: String
    public let method: HTTPRequest.Method
    public let path: String
    public let underlying: any Error

    public init(operationID: String, method: HTTPRequest.Method, path: String, underlying: any Error) {
        self.operationID = operationID
        self.method = method
        self.path = path
        self.underlying = underlying
    }

    /// What to check before retrying by hand.
    public var inspectionGuidance: String {
        switch method {
        case .post:
            "The create may have succeeded. GET the collection (`\(path)`) and look for a resource whose attributes match what you sent; only re-send the POST if it is absent. A blind retry can create a duplicate."
        case .patch:
            "The update may have been applied in full or in part. GET `\(path)` and compare each attribute with the intended value; re-send the PATCH only for the fields that differ."
        case .delete:
            "The delete may have been applied. GET `\(path)`: a 404 means it went through and nothing more is needed; a 200 means it is safe to send the DELETE again."
        default:
            "GET `\(path)` and compare its state with what the request intended before re-sending."
        }
    }

    public var description: String {
        "\(method.rawValue) \(Redactor.redact(path)) (\(operationID)) failed before a response arrived — outcome unknown: \(Redactor.redact("\(underlying)")). \(inspectionGuidance)"
    }
}

/// Outermost middleware: converts a transport-level failure of a non-idempotent request into
/// ``MutationOutcomeUnknownError``. Idempotent requests and responses of any status pass through
/// untouched — a `4xx`/`5xx` *response* is a known outcome and stays a normal client error.
/// So do failures that provably happened before anything was sent (an unreadable `.p8`) and
/// cancellation, which the caller initiated and expects to see as `CancellationError`.
public struct NonIdempotentWriteGuard: ClientMiddleware {
    public init() {}

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard !RetryPolicy.isIdempotent(request.method) else {
            return try await next(request, body, baseURL)
        }
        do {
            return try await next(request, body, baseURL)
        } catch let error as MutationOutcomeUnknownError {
            throw error
        } catch let error as JWTSignerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MutationOutcomeUnknownError(
                operationID: operationID,
                method: request.method,
                path: request.path ?? "",
                underlying: error
            )
        }
    }
}

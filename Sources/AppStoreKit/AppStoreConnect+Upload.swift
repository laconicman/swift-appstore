import Foundation
import HTTPTypes
import OpenAPIRuntime
import AppStoreOpenAPI

extension AppStoreConnect {
    /// One `uploadOperations` entry executed: a chunked byte PUT to Apple's upload host.
    ///
    /// The request deliberately bypasses `middlewares` — the op's `requestHeaders` are the
    /// whole authorization, and the ES256 bearer must not be sent to the upload host — but
    /// keeps `RetryMiddleware` semantics: the byte PUT rides a flaky transport, so each
    /// attempt goes out on a fresh connection under the same policy the JSON calls use.
    /// PUT is idempotent in `RetryPolicy.isIdempotent`, so retryable statuses and
    /// transport failures retry inside the middleware; a Data-backed body is replayable.
    ///
    /// - Parameters:
    ///   - operation: The op as it arrived on the reservation (`url`, `offset`, `length`,
    ///     `requestHeaders`). `method` defaults to PUT when absent.
    ///   - bytes: The chunk to send — `data[offset..<offset+length]` sliced by the caller.
    ///   - operationID: Label used for logging/redaction, not a generated operation id.
    public func putUploadOperation(
        _ operation: Components.Schemas.UploadOperation,
        bytes: Data,
        operationID: String
    ) async throws {
        guard let urlString = operation.url, let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else {
            // No URL in the message — signed upload urls carry credentials in the query.
            throw UploadOperationError.invalid(operationID, "unusable upload url")
        }
        guard components.scheme == "https" else {
            // Uploads carry signed headers and media bytes — plaintext is never acceptable.
            throw UploadOperationError.invalid(operationID, "upload url is not https")
        }
        let method: HTTPRequest.Method
        if let raw = operation.method, !raw.isEmpty {
            guard let parsed = HTTPRequest.Method(raw) else {
                throw UploadOperationError.invalid(operationID, "unsupported upload method \(raw)")
            }
            method = parsed
        } else {
            method = .put
        }
        let authority = components.port.map { "\(host):\($0)" } ?? host
        var request = HTTPRequest(
            method: method,
            scheme: components.scheme,
            authority: authority,
            path: components.percentEncodedPath + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
        )
        for header in operation.requestHeaders ?? [] {
            guard let name = header.name.flatMap({ HTTPField.Name($0) }) else {
                throw UploadOperationError.invalid(operationID, "unusable upload header \(Redactor.redact(header.name ?? "nil"))")
            }
            // The op's requestHeaders are the whole authorization — an `Authorization`
            // header on the upload host is never legitimate; refuse rather than forward.
            guard name != .authorization else {
                throw UploadOperationError.invalid(operationID, "op carries an Authorization header")
            }
            request.headerFields[name] = header.value
        }
        // Apple's upload host answers 411 without an explicit length: the transport
        // streams an HTTPBody as chunked unless the request itself declares it. The
        // Python recipe never saw this because urllib sets Content-Length from the body.
        request.headerFields[.contentLength] = String(bytes.count)
        guard let baseURL = URL(string: "https://\(authority)") else {
            throw UploadOperationError.invalid(operationID, "unusable upload url")
        }
        let retry = RetryMiddleware(policy: retryPolicy, sleep: sleep)
        let guard_ = NonIdempotentWriteGuard()
        let body = HTTPBody(bytes)
        // Keep the write-guard-outermost ordering even off the normal chain: a non-PUT op
        // whose outcome is unknown surfaces as `MutationOutcomeUnknownError`, not a raw
        // transport error, so the caller reconciles instead of blind-retrying.
        let (response, _) = try await guard_.intercept(
            request,
            body: body,
            baseURL: baseURL,
            operationID: operationID,
            next: { req, reqBody, reqBaseURL in
                try await retry.intercept(
                    req,
                    body: reqBody,
                    baseURL: reqBaseURL,
                    operationID: operationID,
                    next: { req, reqBody, reqBaseURL in
                        try await self.transport.send(req, body: reqBody, baseURL: reqBaseURL, operationID: operationID)
                    }
                )
            }
        )
        guard (200..<300).contains(response.status.code) else {
            throw UploadOperationError.rejected(operationID, "upload answered \(response.status.code)")
        }
    }
}

/// Failures from the upload-operation path — distinct from `WorkflowError` because
/// the caller reconciles a stranded reservation rather than translating a message.
public enum UploadOperationError: Error, Equatable {
    /// The op itself was malformed (url, method, or a header that can't be sent).
    case invalid(String, String)
    /// The upload host answered non-2xx after retries.
    case rejected(String, String)
}

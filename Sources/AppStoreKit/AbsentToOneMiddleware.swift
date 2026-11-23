import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Apple answers `200` with `{"data": null, "links": …}` when a to-one relationship is
/// unset — observed live on `appStoreVersions_appStoreReviewDetail_getToOneRelated` (a
/// version with no review detail) and `appStoreVersions_build_getToOneRelated` (a
/// never-staged version), field trial 2026-10-01, issue #31. The spec declares `data`
/// required and non-nullable, so the generated decoder throws `DecodingError` before the
/// typed `Output` exists — the failure surfaces as a crash instead of the `.notFound`
/// case every caller already maps to "absent".
///
/// This middleware rewrites that one response shape — a `200` to a `*_getToOneRelated`
/// operation whose JSON body has `data: null` — into the `404` +
/// `ErrorResponse` the operation's own contract already declares, so callers see
/// `.notFound`. Every release-tier `*_getToOneRelated` operation declares a JSON
/// `ErrorResponse` for 404 (verified against `openapi.json`, 2026-11-23), and
/// `_getToOneRelationship` operations are untouched: linkage responses legitimately
/// carry `data: null`/`[]` and already decode.
///
/// Ordering: it sits between ``NonIdempotentWriteGuard`` and ``RetryMiddleware`` — outside
/// retry, so the synthesized 404 is never re-evaluated for another attempt, and inside
/// the guard's view of "final" responses only. ``RateLimitMiddleware`` and
/// ``AuthenticationMiddleware`` are inside it, so they still see the real `200` and its
/// headers.
public struct AbsentToOneMiddleware: ClientMiddleware, Sendable {
    /// `*_getToOneRelated` responses are single resources; a body past this size is not
    /// inspected and passes through untouched.
    static let maximumInspectedBytes = 4 * 1024 * 1024

    /// Creates the middleware.
    public init() {}

    /// Passes every request through; on the response side, rewrites Apple's
    /// absent-to-one `200 {"data": null}` into the declared `404` and otherwise
    /// returns the pair untouched — including bodies too large or too unknown
    /// to inspect safely.
    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard request.method == .get,
              operationID.hasSuffix("_getToOneRelated"),
              response.status.code == 200,
              let responseBody
        else { return (response, responseBody) }
        // Only a declared length that fits the cap is inspected: collecting past
        // it throws `TooManyBytesError`, and a consumed stream cannot be handed
        // back — unknown-length bodies pass through untouched.
        guard case .known(let length) = responseBody.length,
              length <= Int64(Self.maximumInspectedBytes)
        else { return (response, responseBody) }
        let data = try await Data(collecting: responseBody, upTo: Self.maximumInspectedBytes)
        guard Self.isAbsentToOne(data) else {
            // The body was consumed for inspection — hand the deserializer the same bytes.
            return (response, HTTPBody(data))
        }
        var notFound = response
        notFound.status = .notFound
        notFound.headerFields[.contentType] = "application/json"
        notFound.headerFields[.contentLength] = String(Self.notFoundBody.utf8.count)
        return (notFound, HTTPBody(Self.notFoundBody))
    }

    /// `true` when the body is a JSON document whose `data` member is `null` — the
    /// observed Apple shape. A document with no `data` key at all is malformed rather
    /// than "absent": it passes through and fails loudly in the decoder, because a
    /// silent `.notFound` would read downstream as a fact.
    static func isAbsentToOne(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard let value = object["data"] else { return false }
        return value is NSNull
    }

    /// A minimal `ErrorResponse` — the schema every `*_getToOneRelated` 404 declares.
    /// The detail names the normalization so a surfaced error explains itself.
    static let notFoundBody = #"{"errors":[{"status":"404","code":"NOT_FOUND","title":"Not Found","detail":"The to-one relationship is unset — App Store Connect returned `data: null` on a 200; normalized to 404."}]}"#
}

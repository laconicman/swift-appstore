import Foundation
import HTTPTypes
import OpenAPIRuntime

/// One observation of App Store Connect's `X-Rate-Limit` header, which every response carries as
/// `user-hour-lim:3500;user-hour-rem:500;` — a rolling per-hour budget per API key.
/// <https://developer.apple.com/documentation/appstoreconnectapi/identifying-rate-limits>
public struct RateLimitInfo: Sendable, Hashable {
    /// Requests allowed per rolling hour (`user-hour-lim`).
    public let hourlyLimit: Int?
    /// Requests left in the current rolling hour (`user-hour-rem`).
    public let hourlyRemaining: Int?
    /// The operation whose response this was read from.
    public let operationID: String
    public let observedAt: Date

    public init(hourlyLimit: Int?, hourlyRemaining: Int?, operationID: String, observedAt: Date) {
        self.hourlyLimit = hourlyLimit
        self.hourlyRemaining = hourlyRemaining
        self.operationID = operationID
        self.observedAt = observedAt
    }

    /// Parses the header value; returns `nil` when neither field is present.
    public init?(headerValue: String, operationID: String, observedAt: Date = Date()) {
        var limit: Int?
        var remaining: Int?
        for field in headerValue.split(separator: ";") {
            let parts = field.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            switch parts[0] {
            case "user-hour-lim": limit = value
            case "user-hour-rem": remaining = value
            default: continue
            }
        }
        guard limit != nil || remaining != nil else { return nil }
        self.init(hourlyLimit: limit, hourlyRemaining: remaining, operationID: operationID, observedAt: observedAt)
    }
}

extension HTTPField.Name {
    static let xRateLimit = HTTPField.Name("X-Rate-Limit")!
}

/// Remembers the most recent ``RateLimitInfo`` seen on any response, so a caller can throttle
/// or surface "N requests left this hour" without parsing headers itself.
public final class RateLimitMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var _latest: RateLimitInfo?

    public init() {}

    /// The last observation, or `nil` before the first response arrives.
    public var latest: RateLimitInfo? {
        lock.withLock { _latest }
    }

    func record(_ info: RateLimitInfo) {
        lock.withLock { _latest = info }
    }
}

/// Feeds every response's `X-Rate-Limit` header into a ``RateLimitMonitor``. Purely
/// observational: it never delays or fails a request — that is ``RetryMiddleware``'s job.
public struct RateLimitMiddleware: ClientMiddleware, Sendable {
    public let monitor: RateLimitMonitor

    public init(monitor: RateLimitMonitor) {
        self.monitor = monitor
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        if let header = response.headerFields[.xRateLimit],
           let info = RateLimitInfo(headerValue: header, operationID: operationID) {
            monitor.record(info)
        }
        return (response, responseBody)
    }
}

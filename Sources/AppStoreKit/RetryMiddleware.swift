import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Which failures are retried, how often, and how long to wait in between.
///
/// The method split is the heart of it: **idempotent** requests (GET/HEAD/OPTIONS/PUT) are
/// retried on 408, 429 and any 5xx, and on transport errors; **non-idempotent** ones
/// (POST/PATCH/DELETE) only on 429, where Apple provably rejected the request before acting
/// on it. Anything else for a mutation is handed to ``NonIdempotentWriteGuard``.
/// (Policy mirrors zelentsov-dev/asc-mcp's `HTTPClient`: operation-aware retry, exponential
/// backoff with jitter capped at 30 s, `Retry-After` honored when present.)
public struct RetryPolicy: Sendable {
    /// Total attempts including the first; `1` disables retrying.
    public var maximumAttempts: Int
    /// Delay before the first retry; doubles on each subsequent one.
    public var baseDelay: TimeInterval
    /// Upper bound for any single wait, including one requested via `Retry-After`.
    public var maximumDelay: TimeInterval
    /// Full jitter: each wait is drawn uniformly from `0...computedDelay`.
    public var jitter: Bool
    public var retryableStatuses: Set<Int>

    public init(
        maximumAttempts: Int = 4,
        baseDelay: TimeInterval = 0.5,
        maximumDelay: TimeInterval = 30,
        jitter: Bool = true,
        retryableStatuses: Set<Int> = Set([408, 429] + Array(500...599))
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.jitter = jitter
        self.retryableStatuses = retryableStatuses
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maximumAttempts: 1)

    /// `true` for methods whose repeat has the same effect as a single send.
    public static func isIdempotent(_ method: HTTPRequest.Method) -> Bool {
        switch method {
        case .get, .head, .options, .put, .trace: true
        default: false
        }
    }

    public func shouldRetry(_ response: HTTPResponse, method: HTTPRequest.Method) -> Bool {
        let code = response.status.code
        if Self.isIdempotent(method) { return retryableStatuses.contains(code) }
        return code == 429
    }

    /// Wait before `attempt` (1-based; the first retry is attempt 1), preferring `Retry-After`.
    public func delay(beforeRetry attempt: Int, response: HTTPResponse?, now: Date = Date()) -> TimeInterval {
        if let header = response?.headerFields[.retryAfter],
           let requested = Self.parseRetryAfter(header, now: now) {
            return min(max(0, requested), maximumDelay)
        }
        let exponential = min(baseDelay * pow(2, Double(attempt - 1)), maximumDelay)
        return jitter ? Double.random(in: 0...exponential) : exponential
    }

    /// `Retry-After` is either delta-seconds or an HTTP-date (RFC 9110 §10.2.3).
    static func parseRetryAfter(_ value: String, now: Date) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return date.timeIntervalSince(now)
    }
}

/// Retries per ``RetryPolicy``. Placed *outside* ``AuthenticationMiddleware`` so every attempt
/// gets a still-valid bearer token; ``RateLimitMiddleware`` sits inside so each attempt's
/// `X-Rate-Limit` header is recorded.
///
/// A request whose body is single-shot (`HTTPBody.IterationBehavior.single`) is never retried,
/// because the bytes are gone after the first send.
public struct RetryMiddleware: ClientMiddleware, Sendable {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    public let policy: RetryPolicy
    private let sleep: Sleep

    /// `sleep` is injectable so tests run without real waits.
    public init(
        policy: RetryPolicy = .default,
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.policy = policy
        self.sleep = sleep
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let idempotent = RetryPolicy.isIdempotent(request.method)
        let attempts = body.isReplayable ? policy.maximumAttempts : 1
        var attempt = 0
        while true {
            attempt += 1
            let isLast = attempt >= attempts
            let rejected: HTTPResponse?
            do {
                let (response, responseBody) = try await next(request, body, baseURL)
                guard !isLast, policy.shouldRetry(response, method: request.method) else {
                    return (response, responseBody)
                }
                rejected = response
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // No response at all. Safe to try again only when a duplicate would be harmless.
                guard idempotent, !isLast else { throw error }
                rejected = nil
            }
            try await sleep(policy.delay(beforeRetry: attempt, response: rejected))
        }
    }
}

import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import OSLogLoggingMiddleware
import AppStoreOpenAPI

/// The entry point: a generated `Client` wired with authentication, retry, rate-limit tracking and
/// the non-idempotent-write guard, plus the pagination helper.
///
/// ```swift
/// let asc = try AppStoreConnect(key: APIKey(keyID: "ABC123DEFG", issuerID: "…", privateKeyPath: keyURL))
/// let apps = try await asc.client.appsGetCollection(query: .init(limit: 50)).ok.body.json
/// for try await page in asc.pages(startingWith: apps, links: \.links) { … }
/// print(asc.rateLimits.latest?.hourlyRemaining ?? -1)
/// ```
///
/// Middleware order (outermost first) and why:
/// 1. ``NonIdempotentWriteGuard`` — sees the *final* failure of a mutation, after retries gave up.
/// 2. ``RetryMiddleware`` — replays the whole inner chain, so each attempt re-enters auth.
/// 3. ``AuthenticationMiddleware`` — a fresh-enough token on every attempt; refreshes once on 401.
/// 4. ``RateLimitMiddleware`` — records `X-Rate-Limit` from every attempt's response.
/// 5. `OSLogLoggingMiddleware` — Apple platforms only; bodies are never logged by default.
public struct AppStoreConnect: Sendable {
    /// The generated client. Every operation in the active generator tier is a method on it.
    public let client: Client
    /// Last-seen `X-Rate-Limit` values.
    public let rateLimits: RateLimitMonitor
    public let serverURL: URL

    let transport: any ClientTransport
    let middlewares: [any ClientMiddleware]
    let dateTranscoder: any DateTranscoder

    /// - Parameters:
    ///   - key: The API key; only the `.p8` *path* is stored.
    ///   - serverURL: Defaults to the spec's `https://api.appstoreconnect.apple.com/`.
    ///   - retryPolicy: ``RetryPolicy/default`` unless you need different limits.
    ///   - bodyLoggingPolicy: Passed to `OSLogLoggingMiddleware` on Apple platforms; ignored elsewhere.
    ///   - transport: Swap in a mock `ClientTransport` for tests.
    public init(
        key: APIKey,
        serverURL: URL? = nil,
        retryPolicy: RetryPolicy = .default,
        bodyLoggingPolicy: BodyLoggingPolicy = .never,
        transport: any ClientTransport = URLSessionTransport()
    ) throws {
        try self.init(
            tokens: BearerTokenCache(signer: JWTSigner(key: key)),
            serverURL: serverURL,
            retryPolicy: retryPolicy,
            bodyLoggingPolicy: bodyLoggingPolicy,
            transport: transport
        )
    }

    /// Lower-level initializer for callers that manage the token cache (or its clock) themselves.
    public init(
        tokens: BearerTokenCache,
        serverURL: URL? = nil,
        retryPolicy: RetryPolicy = .default,
        bodyLoggingPolicy: BodyLoggingPolicy = .never,
        transport: any ClientTransport = URLSessionTransport(),
        sleep: @escaping RetryMiddleware.Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) throws {
        let serverURL = try serverURL ?? Servers.Server1.url()
        let rateLimits = RateLimitMonitor()
        var middlewares: [any ClientMiddleware] = [
            NonIdempotentWriteGuard(),
            RetryMiddleware(policy: retryPolicy, sleep: sleep),
            AuthenticationMiddleware(tokens: tokens),
            RateLimitMiddleware(monitor: rateLimits),
        ]
        #if canImport(Darwin)
        middlewares.append(OSLogLoggingMiddleware(bodyLoggingConfiguration: bodyLoggingPolicy))
        #endif
        let dateTranscoder = AppStoreConnectDateTranscoder()

        self.client = Client(
            serverURL: serverURL,
            configuration: Configuration(dateTranscoder: dateTranscoder),
            transport: transport,
            middlewares: middlewares
        )
        self.rateLimits = rateLimits
        self.serverURL = serverURL
        self.transport = transport
        self.middlewares = middlewares
        self.dateTranscoder = dateTranscoder
    }
}

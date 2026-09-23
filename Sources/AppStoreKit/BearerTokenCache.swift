import Foundation

/// Hands out a cached bearer token and re-mints it shortly before expiry.
///
/// Apple's guidance is to reuse one token for many requests rather than sign per request.
/// The 90-second `leeway` means a token is treated as expired that long before its real
/// `exp`, so a request that is in flight when the boundary passes is not rejected with 401.
/// (Design constants — 20-minute lifetime, ~90 s leeway, one refresh on 401 — follow the
/// evaluated prior art in zelentsov-dev/asc-mcp's `JWTService` / `HTTPClient`.)
public actor BearerTokenCache {
    public static let defaultLeeway: TimeInterval = 90

    private let signer: JWTSigner
    private let leeway: TimeInterval
    private let clock: @Sendable () -> Date
    private var cached: JWTSigner.Token?

    public init(
        signer: JWTSigner,
        leeway: TimeInterval = BearerTokenCache.defaultLeeway,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.signer = signer
        self.leeway = leeway
        self.clock = clock
    }

    /// The current token, minting a new one when none is cached or the cached one is within
    /// `leeway` of expiring.
    public func token() throws -> String {
        let now = clock()
        if let cached, cached.expiresAt.timeIntervalSince(now) > leeway {
            return cached.value
        }
        let fresh = try signer.mint(now: now)
        cached = fresh
        return fresh.value
    }

    /// Drops the cached token so the next ``token()`` call mints a fresh one — used after a 401.
    public func invalidate() {
        cached = nil
    }
}

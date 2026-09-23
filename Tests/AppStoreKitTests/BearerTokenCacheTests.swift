import Foundation
import Testing
@testable import AppStoreKit

@Suite("BearerTokenCache")
struct BearerTokenCacheTests {
    /// A settable clock shared with the cache.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: Date
        init(_ now: Date) { _now = now }
        var now: Date {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
        func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    @Test("reuses a token until it is within the leeway of expiring, then re-mints")
    func reusesUntilLeeway() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = BearerTokenCache(signer: JWTSigner(key: key.apiKey), leeway: 90, clock: { clock.now })

        let first = try await cache.token()
        clock.advance(by: 20 * 60 - 91)
        let stillValid = try await cache.token()
        #expect(stillValid == first)

        clock.advance(by: 2)
        let refreshed = try await cache.token()
        #expect(refreshed != first)
        #expect(try DecodedJWT(refreshed).claims["iat"] as? Int == 1_700_000_000 + 20 * 60 - 89)
    }

    @Test("invalidate() forces a fresh token on the next call")
    func invalidate() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
        let cache = BearerTokenCache(signer: JWTSigner(key: key.apiKey), clock: { clock.now })

        let first = try await cache.token()
        await cache.invalidate()
        clock.advance(by: 1)
        let second = try await cache.token()

        #expect(second != first)
    }
}

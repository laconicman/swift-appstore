import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import AppStoreKit

@Suite("AuthenticationMiddleware")
struct AuthenticationMiddlewareTests {
    @Test("attaches a bearer JWT signed by the configured key")
    func attachesBearer() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport()

        _ = try await run(AuthenticationMiddleware(key: key.apiKey), .get("/v1/apps"), through: transport)

        let authorization = try #require(await transport.requests.first?.headerFields[.authorization])
        #expect(authorization.hasPrefix("Bearer "))
        let jwt = try DecodedJWT(String(authorization.dropFirst("Bearer ".count)))
        #expect(try jwt.isValidSignature(for: key.publicKey))
    }

    @Test("on 401 refreshes the token once and replays; a second 401 is returned")
    func refreshesOnceOn401() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.unauthorized), .json(.unauthorized)])
        let cache = BearerTokenCache(signer: JWTSigner(key: key.apiKey))

        let (response, _) = try await run(AuthenticationMiddleware(tokens: cache), .get("/v1/apps"), through: transport)

        #expect(response.status == .unauthorized)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].headerFields[.authorization] != nil)
        #expect(requests[1].headerFields[.authorization] != nil)
    }

    @Test("on 401 the replay succeeds and the caller sees the 200")
    func replaySucceeds() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.unauthorized), .json(.ok, #"{"ok":true}"#)])

        let (response, _) = try await run(AuthenticationMiddleware(key: key.apiKey), .get("/v1/apps"), through: transport)

        #expect(response.status == .ok)
        #expect(await transport.requests.count == 2)
    }

    @Test("a single-shot body is not replayed after 401")
    func singleShotBodyNotReplayed() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.unauthorized), .json(.ok)])
        let streamed = HTTPBody(
            AsyncStream<ArraySlice<UInt8>> { $0.yield(ArraySlice("{}".utf8)); $0.finish() },
            length: .unknown,
            iterationBehavior: .single
        )

        let (response, _) = try await run(
            AuthenticationMiddleware(key: key.apiKey), .post("/v1/appInfoLocalizations"), body: streamed, through: transport
        )

        #expect(response.status == .unauthorized)
        #expect(await transport.requests.count == 1)
    }
}

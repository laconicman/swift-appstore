import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import AppStoreOpenAPI
@testable import AppStoreKit

/// The façade end to end: a real generated operation through the full middleware chain into a
/// mock transport. Nothing here talks to App Store Connect.
@Suite("AppStoreConnect over a mock transport")
struct AppStoreConnectTests {
    static let appsPage1 = #"""
    {"data":[{"type":"apps","id":"1","attributes":{"name":"One","bundleId":"com.example.one"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps?limit=1",
              "next":"https://api.appstoreconnect.apple.com/v1/apps?cursor=AQ&limit=1"},
     "meta":{"paging":{"total":2,"limit":1}}}
    """#
    static let appsPage2 = #"""
    {"data":[{"type":"apps","id":"2","attributes":{"name":"Two","bundleId":"com.example.two"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps?cursor=AQ&limit=1"},
     "meta":{"paging":{"total":2,"limit":1}}}
    """#

    @Test("apps list: correct request shape, bearer token, decoded response, rate limit recorded")
    func listApps() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.ok, Self.appsPage1, headers: [.xRateLimit: "user-hour-lim:3500;user-hour-rem:3400;"])])
        let asc = try AppStoreConnect(key: key.apiKey, transport: transport)

        let page = try await asc.client.appsGetCollection(query: .init(limit: 1)).ok.body.json

        #expect(page.data.map(\.id) == ["1"])
        #expect(page.data.first?.attributes?.bundleId == "com.example.one")
        #expect(page.links.next?.contains("cursor=AQ") == true)
        #expect(asc.rateLimits.latest?.hourlyRemaining == 3400)
        #expect(asc.rateLimits.latest?.operationID == "apps_getCollection")

        let exchange = try #require(await transport.exchanges.first)
        #expect(exchange.request.method == .get)
        #expect(exchange.request.path == "/v1/apps?limit=1")
        #expect(exchange.baseURL == asc.serverURL)
        #expect(exchange.baseURL.host == "api.appstoreconnect.apple.com")
        #expect(exchange.operationID == "apps_getCollection")
        let authorization = try #require(exchange.request.headerFields[.authorization])
        #expect(try DecodedJWT(String(authorization.dropFirst("Bearer ".count))).isValidSignature(for: key.publicKey))
    }

    @Test("pages(startingWith:links:) follows links.next through the same middleware chain")
    func followsNextLinks() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.ok, Self.appsPage1), .json(.ok, Self.appsPage2)])
        let asc = try AppStoreConnect(key: key.apiKey, transport: transport)

        let first = try await asc.client.appsGetCollection(query: .init(limit: 1)).ok.body.json
        var ids: [String] = []
        for try await page in asc.pages(startingWith: first, links: \.links) {
            ids += page.data.map(\.id)
        }

        #expect(ids == ["1", "2"])
        let exchanges = await transport.exchanges
        #expect(exchanges.count == 2)
        #expect(exchanges[1].request.path == "/v1/apps?cursor=AQ&limit=1")
        #expect(exchanges[1].request.headerFields[.authorization] != nil, "page fetches are authenticated")
        #expect(exchanges[1].operationID == AppStoreConnect.pageOperationID)
    }

    @Test("items(startingWith:links:data:) flattens pages")
    func flattensItems() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.ok, Self.appsPage1), .json(.ok, Self.appsPage2)])
        let asc = try AppStoreConnect(key: key.apiKey, transport: transport)

        let first = try await asc.client.appsGetCollection(query: .init(limit: 1)).ok.body.json
        var names: [String] = []
        for try await app in asc.items(startingWith: first, links: \.links, data: \.data) {
            names.append(app.attributes?.name ?? "")
        }

        #expect(names == ["One", "Two"])
    }

    @Test("a page fetch that is retried gets the 200 after a 503")
    func pageFetchIsRetried() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.ok, Self.appsPage1), .json(.serviceUnavailable), .json(.ok, Self.appsPage2)])
        let asc = try AppStoreConnect(
            tokens: BearerTokenCache(signer: JWTSigner(key: key.apiKey)),
            transport: transport,
            sleep: SleepRecorder().sleep
        )

        let first = try await asc.client.appsGetCollection(query: .init(limit: 1)).ok.body.json
        var count = 0
        for try await _ in asc.pages(startingWith: first, links: \.links) { count += 1 }

        #expect(count == 2)
        #expect(await transport.exchanges.count == 3)
    }

    @Test("a non-2xx page fetch is a PaginationError")
    func pageFetchError() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.forbidden)])
        let asc = try AppStoreConnect(key: key.apiKey, transport: transport)

        await #expect(throws: PaginationError.self) {
            try await asc.page(at: "https://api.appstoreconnect.apple.com/v1/apps?cursor=AQ", as: Components.Schemas.AppsResponse.self)
        }
    }

    @Test("dates in Apple's offset format decode")
    func decodesDates() throws {
        let transcoder = AppStoreConnectDateTranscoder()

        #expect(try transcoder.decode("2024-06-25T08:00:00-07:00") == Date(timeIntervalSince1970: 1_719_327_600))
        #expect(try transcoder.decode("2024-06-25T15:00:00.000+00:00") == Date(timeIntervalSince1970: 1_719_327_600))
        #expect(try transcoder.decode("2024-06-25T15:00:00Z") == Date(timeIntervalSince1970: 1_719_327_600))
        #expect(throws: (any Error).self) { try transcoder.decode("yesterday") }
    }
}

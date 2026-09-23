import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import AppStoreKit

@Suite("Rate limits")
struct RateLimitTests {
    @Test("parses Apple's X-Rate-Limit header")
    func parsesHeader() {
        let info = RateLimitInfo(headerValue: "user-hour-lim:3500;user-hour-rem:500;", operationID: "apps_getCollection")

        #expect(info?.hourlyLimit == 3500)
        #expect(info?.hourlyRemaining == 500)
        #expect(info?.operationID == "apps_getCollection")
        #expect(RateLimitInfo(headerValue: "garbage", operationID: "x") == nil)
        #expect(RateLimitInfo(headerValue: "user-hour-rem: 12", operationID: "x")?.hourlyRemaining == 12)
    }

    @Test("middleware records the last-seen values on the monitor without altering the response")
    func recordsLatest() async throws {
        let monitor = RateLimitMonitor()
        let transport = MockTransport([
            .json(.ok, headers: [.xRateLimit: "user-hour-lim:3500;user-hour-rem:3499;"]),
            .json(.ok, headers: [.xRateLimit: "user-hour-lim:3500;user-hour-rem:3498;"]),
            .json(.ok),
        ])
        let middleware = RateLimitMiddleware(monitor: monitor)

        #expect(monitor.latest == nil)
        _ = try await run(middleware, .get("/v1/apps"), through: transport, operationID: "apps_getCollection")
        #expect(monitor.latest?.hourlyRemaining == 3499)
        let (response, _) = try await run(middleware, .get("/v1/apps/1"), through: transport, operationID: "apps_getInstance")
        #expect(response.status == .ok)
        #expect(monitor.latest?.hourlyRemaining == 3498)
        #expect(monitor.latest?.operationID == "apps_getInstance")

        _ = try await run(middleware, .get("/v1/apps"), through: transport)
        #expect(monitor.latest?.hourlyRemaining == 3498, "a response without the header keeps the previous observation")
    }
}

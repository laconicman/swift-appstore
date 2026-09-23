import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import AppStoreKit

@Suite("RetryMiddleware")
struct RetryMiddlewareTests {
    private static let policy = RetryPolicy(maximumAttempts: 4, baseDelay: 1, maximumDelay: 30, jitter: false)

    @Test("GET retries 408/429/5xx and transport failures, with doubling backoff")
    func idempotentRetries() async throws {
        let sleeps = SleepRecorder()
        let transport = MockTransport([.json(.serviceUnavailable), .networkFailure, .json(.requestTimeout), .json(.ok)])

        let (response, _) = try await run(
            RetryMiddleware(policy: Self.policy, sleep: sleeps.sleep), .get("/v1/apps"), through: transport
        )

        #expect(response.status == .ok)
        #expect(await transport.requests.count == 4)
        #expect(sleeps.delays == [1, 2, 4])
    }

    @Test("gives up after maximumAttempts and returns the last response")
    func exhausts() async throws {
        let transport = MockTransport(Array(repeating: .json(.internalServerError), count: 4))

        let (response, _) = try await run(
            RetryMiddleware(policy: Self.policy, sleep: SleepRecorder().sleep), .get("/v1/apps"), through: transport
        )

        #expect(response.status == .internalServerError)
        #expect(await transport.requests.count == 4)
    }

    @Test("POST retries only on 429")
    func nonIdempotentOnly429() async throws {
        let transport = MockTransport([.json(.tooManyRequests), .json(.internalServerError), .json(.ok)])

        let (response, _) = try await run(
            RetryMiddleware(policy: Self.policy, sleep: SleepRecorder().sleep),
            .post("/v1/appInfoLocalizations"), body: HTTPBody("{}"), through: transport
        )

        #expect(response.status == .internalServerError)
        #expect(await transport.requests.count == 2)
    }

    @Test("POST is never retried after a transport failure — that is the guard's job")
    func nonIdempotentNoRetryOnFailure() async throws {
        let transport = MockTransport([.networkFailure, .json(.ok)])

        await #expect(throws: MockTransport.SimulatedNetworkFailure.self) {
            try await run(
                RetryMiddleware(policy: Self.policy, sleep: SleepRecorder().sleep),
                .post("/v1/appInfoLocalizations"), body: HTTPBody("{}"), through: transport
            )
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("Retry-After in seconds overrides the backoff, capped at maximumDelay")
    func honorsRetryAfter() async throws {
        let sleeps = SleepRecorder()
        let transport = MockTransport([
            .json(.tooManyRequests, headers: [.retryAfter: "7"]),
            .json(.tooManyRequests, headers: [.retryAfter: "600"]),
            .json(.ok),
        ])

        _ = try await run(RetryMiddleware(policy: Self.policy, sleep: sleeps.sleep), .get("/v1/apps"), through: transport)

        #expect(sleeps.delays == [7, 30])
    }

    @Test("Retry-After as an HTTP-date is converted to a relative wait")
    func retryAfterDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = "Tue, 14 Nov 2023 22:14:30 GMT" // now is 22:13:20 GMT

        let delay = RetryPolicy.parseRetryAfter(later, now: now)

        #expect(delay == 70)
    }

    @Test("a single-shot request body disables retrying entirely")
    func singleShotBodyNoRetry() async throws {
        let transport = MockTransport([.json(.tooManyRequests), .json(.ok)])
        let streamed = HTTPBody(
            AsyncStream<ArraySlice<UInt8>> { $0.yield(ArraySlice("{}".utf8)); $0.finish() },
            length: .unknown,
            iterationBehavior: .single
        )

        let (response, _) = try await run(
            RetryMiddleware(policy: Self.policy, sleep: SleepRecorder().sleep),
            .get("/v1/apps"), body: streamed, through: transport
        )

        #expect(response.status == .tooManyRequests)
        #expect(await transport.requests.count == 1)
    }

    @Test("policy classifies methods")
    func methodClassification() {
        #expect(RetryPolicy.isIdempotent(.get))
        #expect(RetryPolicy.isIdempotent(.put))
        #expect(!RetryPolicy.isIdempotent(.post))
        #expect(!RetryPolicy.isIdempotent(.patch))
        #expect(!RetryPolicy.isIdempotent(.delete))
    }
}

import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import AppStoreKit

@Suite("NonIdempotentWriteGuard")
struct NonIdempotentWriteGuardTests {
    @Test("a POST that fails without a response surfaces MutationOutcomeUnknownError with guidance")
    func postOutcomeUnknown() async throws {
        let transport = MockTransport([.networkFailure])

        let error = await #expect(throws: MutationOutcomeUnknownError.self) {
            try await run(
                NonIdempotentWriteGuard(), .post("/v1/appInfoLocalizations"), body: HTTPBody("{}"),
                through: transport, operationID: "appInfoLocalizations_createInstance"
            )
        }

        #expect(error?.method == .post)
        #expect(error?.path == "/v1/appInfoLocalizations")
        #expect(error?.operationID == "appInfoLocalizations_createInstance")
        #expect(error?.underlying is MockTransport.SimulatedNetworkFailure)
        #expect(error?.inspectionGuidance.contains("duplicate") == true)
        #expect(await transport.requests.count == 1, "never re-sent")
    }

    @Test("PATCH and DELETE get method-specific guidance")
    func guidancePerMethod() {
        let patch = MutationOutcomeUnknownError(
            operationID: "x", method: .patch, path: "/v1/appInfoLocalizations/1", underlying: MockTransport.SimulatedNetworkFailure()
        )
        let delete = MutationOutcomeUnknownError(
            operationID: "x", method: .delete, path: "/v1/appInfoLocalizations/1", underlying: MockTransport.SimulatedNetworkFailure()
        )

        #expect(patch.inspectionGuidance.contains("compare each attribute"))
        #expect(delete.inspectionGuidance.contains("404"))
        #expect(patch.description.contains("outcome unknown"))
    }

    @Test("error text never carries bearer material — transport errors get redacted")
    func bearerRedaction() {
        struct TransportEcho: Error, CustomStringConvertible {
            var description: String { "send failed, request headers: Bearer eyJhbGciOi.fake.jwt" }
        }
        let error = MutationOutcomeUnknownError(
            operationID: "x", method: .post, path: "/v1/x", underlying: TransportEcho()
        )
        #expect(!error.description.contains("eyJhbGciOi"))
        #expect(error.description.contains("Bearer <redacted>"))
        #expect(Redactor.redact("Authorization: Bearer abc.def.ghi") == "Authorization: Bearer <redacted>")
    }

    @Test("an error *response* is a known outcome and passes through unchanged")
    func errorResponsePassesThrough() async throws {
        let transport = MockTransport([.json(.conflict)])

        let (response, _) = try await run(
            NonIdempotentWriteGuard(), .post("/v1/appInfoLocalizations"), body: HTTPBody("{}"), through: transport
        )

        #expect(response.status == .conflict)
    }

    @Test("GET failures are not wrapped")
    func getNotWrapped() async throws {
        let transport = MockTransport([.networkFailure])

        await #expect(throws: MockTransport.SimulatedNetworkFailure.self) {
            try await run(NonIdempotentWriteGuard(), .get("/v1/apps"), through: transport)
        }
    }

    @Test("a signing failure happens before anything is sent and is not wrapped")
    func signingFailureNotWrapped() async throws {
        let missing = APIKey(keyID: "NOPE", issuerID: nil, privateKeyPath: URL(fileURLWithPath: "/nonexistent.p8"))
        let transport = MockTransport()
        let chain = NonIdempotentWriteGuard()
        let auth = AuthenticationMiddleware(key: missing)
        let baseURL = URL(string: "https://api.appstoreconnect.apple.com")!

        await #expect(throws: JWTSignerError.self) {
            try await chain.intercept(.post("/v1/apps"), body: HTTPBody("{}"), baseURL: baseURL, operationID: "x") { request, body, url in
                try await auth.intercept(request, body: body, baseURL: url, operationID: "x") {
                    try await transport.send($0, body: $1, baseURL: $2, operationID: "x")
                }
            }
        }
        #expect(await transport.requests.isEmpty)
    }
}

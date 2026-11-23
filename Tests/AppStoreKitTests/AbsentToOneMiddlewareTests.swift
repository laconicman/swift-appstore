import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import AppStoreKit

/// Apple's `200 {"data": null}` on unset to-one relateds becomes the `404` the generated
/// outputs already model — and nothing else is touched.
@Suite("AbsentToOneMiddleware")
struct AbsentToOneMiddlewareTests {
    private func exchange(
        operationID: String = "appStoreVersions_build_getToOneRelated",
        status: HTTPResponse.Status = .ok,
        body: String?,
        method: HTTPRequest.Method = .get
    ) async throws -> (HTTPResponse, String?) {
        let request = HTTPRequest(method: method, scheme: "https",
                                  authority: "api.appstoreconnect.apple.com",
                                  path: "/v1/appStoreVersions/v1/build")
        let transport = MockTransport([.json(status, body ?? "{}")])
        let (response, responseBody) = try await run(
            AbsentToOneMiddleware(), request, through: transport, operationID: operationID
        )
        var data: Data?
        if let responseBody {
            data = try await Data(collecting: responseBody, upTo: 1 << 20)
        }
        return (response, data.map { String(decoding: $0, as: UTF8.self) })
    }

    @Test("data:null on a to-one related GET becomes a 404 ErrorResponse")
    func nullDataBecomesNotFound() async throws {
        let (response, body) = try await exchange(body: #"{"data":null,"links":{}}"#)
        #expect(response.status.code == 404)
        #expect(response.headerFields[.contentType] == "application/json")
        let json = try #require(body)
        #expect(json.contains("\"code\":\"NOT_FOUND\""))
        #expect(json.contains("\"status\":\"404\""))
    }

    @Test("a missing data key is malformed, not absent — passes through to fail loudly")
    func absentDataKeyPassesThrough() async throws {
        let payload = #"{"links":{}}"#
        let (response, body) = try await exchange(body: payload)
        #expect(response.status.code == 200)
        #expect(body == payload)
    }

    @Test("the synthesized 404 keeps the real response's headers — rate limits included")
    func headersPreserved() async throws {
        let request = HTTPRequest(method: .get, scheme: "https",
                                  authority: "api.appstoreconnect.apple.com",
                                  path: "/v1/appStoreVersions/v1/build")
        let transport = MockTransport([
            .json(.ok, #"{"data":null,"links":{}}"#,
                  headers: [.xRateLimit: "user-hour-lim:3500;user-hour-rem:100;"])
        ])
        let (response, _) = try await run(
            AbsentToOneMiddleware(), request, through: transport,
            operationID: "appStoreVersions_build_getToOneRelated"
        )
        #expect(response.status.code == 404)
        #expect(response.headerFields[.xRateLimit] == "user-hour-lim:3500;user-hour-rem:100;")
    }

    @Test("a populated data passes through byte-identical")
    func populatedDataPassesThrough() async throws {
        let payload = #"{"data":{"type":"builds","id":"b1"},"links":{}}"#
        let (response, body) = try await exchange(body: payload)
        #expect(response.status.code == 200)
        #expect(body == payload)
    }

    @Test("to-one *Relationship* ops are untouched — linkage null is legitimate")
    func relationshipOpsPassThrough() async throws {
        let (response, body) = try await exchange(
            operationID: "appStoreVersions_build_getToOneRelationship",
            body: #"{"data":null,"links":{}}"#
        )
        #expect(response.status.code == 200)
        #expect(body == #"{"data":null,"links":{}}"#)
    }

    @Test("non-matching operations pass through even with data:null")
    func otherOperationsPassThrough() async throws {
        let (response, body) = try await exchange(
            operationID: "apps_getInstance",
            body: #"{"data":null,"links":{}}"#
        )
        #expect(response.status.code == 200)
        #expect(body == #"{"data":null,"links":{}}"#)
    }

    @Test("non-GET methods pass through")
    func nonGetPassesThrough() async throws {
        let (response, body) = try await exchange(
            body: #"{"data":null,"links":{}}"#, method: .post
        )
        #expect(response.status.code == 200)
        #expect(body == #"{"data":null,"links":{}}"#)
    }

    @Test("non-200 statuses pass through")
    func errorsPassThrough() async throws {
        let (response, _) = try await exchange(status: .notFound, body: #"{"errors":[]}"#)
        #expect(response.status.code == 404)
    }

    @Test("an unknown-length body is never inspected — it could not be handed back")
    func unknownLengthPassesThrough() async throws {
        let request = HTTPRequest(method: .get, scheme: "https",
                                  authority: "api.appstoreconnect.apple.com",
                                  path: "/v1/appStoreVersions/v1/build")
        let payload = #"{"data":null,"links":{}}"#
        let (response, responseBody) = try await AbsentToOneMiddleware().intercept(
            request, body: nil,
            baseURL: URL(string: "https://api.appstoreconnect.apple.com")!,
            operationID: "appStoreVersions_build_getToOneRelated"
        ) { _, _, _ in
            (HTTPResponse(status: .ok), HTTPBody(payload, length: .unknown))
        }
        #expect(response.status.code == 200)
        let data = try await Data(collecting: #require(responseBody), upTo: 1 << 20)
        #expect(String(decoding: data, as: UTF8.self) == payload)
    }

    @Test("a declared length over the cap skips inspection")
    func oversizedDeclaredLengthPassesThrough() async throws {
        let request = HTTPRequest(method: .get, scheme: "https",
                                  authority: "api.appstoreconnect.apple.com",
                                  path: "/v1/appStoreVersions/v1/build")
        let payload = #"{"data":null,"links":{}}"#
        let (response, responseBody) = try await AbsentToOneMiddleware().intercept(
            request, body: nil,
            baseURL: URL(string: "https://api.appstoreconnect.apple.com")!,
            operationID: "appStoreVersions_build_getToOneRelated"
        ) { _, _, _ in
            (HTTPResponse(status: .ok),
             HTTPBody(payload, length: .known(Int64(AbsentToOneMiddleware.maximumInspectedBytes) + 1)))
        }
        #expect(response.status.code == 200)
        // Collect with headroom over the *declared* length — `Data(collecting:)`
        // rejects up front when the declared size exceeds the cap.
        let data = try await Data(collecting: #require(responseBody),
                                  upTo: AbsentToOneMiddleware.maximumInspectedBytes + 1)
        #expect(String(decoding: data, as: UTF8.self) == payload)
    }

    @Test("through the full chain, the generated op yields .notFound")
    func generatedOperationSeesNotFound() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.ok, #"{"data":null,"links":{}}"#)])
        let asc = try AppStoreConnect(key: key.apiKey, transport: transport)

        let output = try await asc.client.appStoreVersionsBuildGetToOneRelated(
            .init(path: .init(id: "v1"))
        )
        guard case .notFound = output else {
            Issue.record("expected .notFound, got \(output)")
            return
        }
    }

    @Test("through the full chain, a real resource still decodes")
    func generatedOperationStillDecodes() async throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let transport = MockTransport([.json(.ok, #"{"data":{"type":"builds","id":"b1"},"links":{"self":"https://api.appstoreconnect.apple.com/v1/x"}}"#)])
        let asc = try AppStoreConnect(key: key.apiKey, transport: transport)

        let output = try await asc.client.appStoreVersionsBuildGetToOneRelated(
            .init(path: .init(id: "v1"))
        )
        guard case .ok(let ok) = output else {
            Issue.record("expected .ok, got \(output)")
            return
        }
        #expect(try ok.body.json.data.id == "b1")
    }
}

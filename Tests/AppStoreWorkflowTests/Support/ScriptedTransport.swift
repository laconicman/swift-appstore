import Foundation
import HTTPTypes
import OpenAPIRuntime
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import AppStoreKit

/// A scripted `ClientTransport`: replays canned responses in order and records every request.
/// Same pattern as `AppStoreKitTests`'s `MockTransport` — test targets can't share sources, so
/// the workflow suite carries its own copy.
actor ScriptedTransport: ClientTransport {
    enum Step {
        case respond(HTTPResponse, body: String?)
        case fail(any Error)
    }

    struct Exchange {
        let request: HTTPRequest
        let body: Data?
        let operationID: String
    }

    struct ScriptExhausted: Error {}

    private var script: [Step]
    private(set) var exchanges: [Exchange] = []

    init(_ script: [Step]) {
        self.script = script
    }

    var requests: [HTTPRequest] { exchanges.map(\.request) }
    var operationIDs: [String] { exchanges.map(\.operationID) }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var bodyData: Data?
        if let body { bodyData = try await Data(collecting: body, upTo: 1 << 20) }
        exchanges.append(Exchange(request: request, body: bodyData, operationID: operationID))
        guard !script.isEmpty else { throw ScriptExhausted() }
        switch script.removeFirst() {
        case .respond(let response, let body):
            return (response, body.map { HTTPBody($0) })
        case .fail(let error):
            throw error
        }
    }
}

extension ScriptedTransport.Step {
    static func json(_ status: HTTPResponse.Status, _ body: String = "{}") -> Self {
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return .respond(response, body: body)
    }
}

/// A throwaway P-256 key at a temp path — exercises `APIKey`'s only interface (a file path)
/// without a real App Store Connect credential.
struct ThrowawayKey {
    let apiKey: APIKey
    private let directory: URL

    init() throws {
        let privateKey = P256.Signing.PrivateKey()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoreWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("AuthKey_TESTKEY123.p8")
        try privateKey.pemRepresentation.write(to: path, atomically: true, encoding: .utf8)
        apiKey = APIKey(keyID: "TESTKEY123", issuerID: "57246542-96fe-1a63-e053-0824d011072a", privateKeyPath: path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// `AppStoreConnect` wired to a scripted transport — the full middleware chain runs (JWT,
/// retry, pagination, write guard); only the network is faked. The throwaway `.p8` stays on
/// disk for the client's lifetime (the middleware signs on every request); the OS reaps /tmp.
func scriptedConnect(_ script: [ScriptedTransport.Step]) throws -> (AppStoreConnect, ScriptedTransport) {
    let key = try ThrowawayKey()
    let transport = ScriptedTransport(script)
    let asc = try AppStoreConnect(key: key.apiKey, transport: transport)
    return (asc, transport)
}

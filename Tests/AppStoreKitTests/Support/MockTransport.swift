import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A scripted `ClientTransport`: replays a queue of canned responses (or thrown errors) and
/// records every request it saw. Lets the middleware chain be asserted without a network —
/// the test suite never contacts App Store Connect.
actor MockTransport: ClientTransport {
    enum Step {
        case respond(HTTPResponse, body: String?)
        case fail(any Error)
    }

    struct Exchange {
        let request: HTTPRequest
        let body: Data?
        let baseURL: URL
        let operationID: String
    }

    struct ScriptExhausted: Error {}
    struct SimulatedNetworkFailure: Error, Equatable {}

    private var script: [Step]
    private(set) var exchanges: [Exchange] = []

    init(_ script: [Step]) {
        self.script = script
    }

    init(status: HTTPResponse.Status = .ok, json: String = "{}") {
        self.init([.json(status, json)])
    }

    var requests: [HTTPRequest] { exchanges.map(\.request) }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var bodyData: Data?
        if let body { bodyData = try await Data(collecting: body, upTo: 1 << 20) }
        exchanges.append(Exchange(request: request, body: bodyData, baseURL: baseURL, operationID: operationID))
        guard !script.isEmpty else { throw ScriptExhausted() }
        switch script.removeFirst() {
        case .respond(let response, let body):
            return (response, body.map { HTTPBody($0) })
        case .fail(let error):
            throw error
        }
    }
}

extension MockTransport.Step {
    static func json(
        _ status: HTTPResponse.Status,
        _ body: String = "{}",
        headers: [HTTPField.Name: String] = [:]
    ) -> Self {
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        for (name, value) in headers { response.headerFields[name] = value }
        return .respond(response, body: body)
    }

    static let networkFailure = Self.fail(MockTransport.SimulatedNetworkFailure())
}

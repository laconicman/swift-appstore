import Foundation
import HTTPTypes
import OpenAPIRuntime
import AppStoreOpenAPI

/// Following `links.next`.
///
/// App Store Connect paginates every collection with a `PagedDocumentLinks` object whose `next`
/// is a complete URL (cursor included). Sixty generated response types carry such a `links`
/// property; rather than conform each to a protocol by hand, the helper takes a key path.
extension AppStoreConnect {
    /// Yields `first`, then every following page until `links.next` is absent.
    ///
    /// ```swift
    /// let first = try await asc.client.appsGetCollection(query: .init(limit: 200)).ok.body.json
    /// for try await page in asc.pages(startingWith: first, links: \.links) {
    ///     apps += page.data
    /// }
    /// ```
    public func pages<Page: Decodable & Sendable>(
        startingWith first: Page,
        links: @escaping @Sendable (Page) -> Components.Schemas.PagedDocumentLinks
    ) -> AsyncThrowingStream<Page, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var page = first
                continuation.yield(page)
                do {
                    while let next = links(page).next, !next.isEmpty {
                        try Task.checkCancellation()
                        page = try await self.page(at: next, as: Page.self)
                        continuation.yield(page)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Flattens ``pages(startingWith:links:)`` to the elements of each page's `data`.
    public func items<Page: Decodable & Sendable, Item: Sendable>(
        startingWith first: Page,
        links: @escaping @Sendable (Page) -> Components.Schemas.PagedDocumentLinks,
        data: @escaping @Sendable (Page) -> [Item]
    ) -> AsyncThrowingStream<Item, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await page in pages(startingWith: first, links: links) {
                        for item in data(page) { continuation.yield(item) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fetches one page from a `links.next` (or `links.first`) URL through the same middleware
    /// chain and date handling as generated operations.
    ///
    /// The generated client cannot do this itself: its operations take typed query parameters,
    /// while Apple's `next` link carries an opaque `cursor` that no operation declares.
    ///
    /// The link is only followed when it names the configured server — the middleware chain
    /// attaches the bearer token to whatever host it is given, so an off-host URL would leak
    /// the JWT. Apple's links always point back at the same API host.
    public func page<Page: Decodable & Sendable>(at link: String, as _: Page.Type) async throws -> Page {
        guard let url = URL(string: link),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host
        else { throw PaginationError.invalidLink(link) }
        guard scheme == serverURL.scheme,
              host.caseInsensitiveCompare(serverURL.host ?? "") == .orderedSame,
              (components.port ?? (scheme == "https" ? 443 : 80)) == (serverURL.port ?? (serverURL.scheme == "https" ? 443 : 80))
        else { throw PaginationError.untrustedHost(link) }

        var request = HTTPRequest(method: .get, scheme: scheme, authority: host, path: components.percentEncodedPath)
        if let query = components.percentEncodedQuery { request.path! += "?" + query }
        request.headerFields[.accept] = "application/json"
        guard let baseURL = URL(string: "\(scheme)://\(host)\(components.port.map { ":\($0)" } ?? "")") else {
            throw PaginationError.invalidLink(link)
        }

        let (response, body) = try await send(request, baseURL: baseURL, operationID: Self.pageOperationID)
        guard response.status.kind == .successful else {
            throw PaginationError.unexpectedStatus(response.status, link: link)
        }
        guard let body else { throw PaginationError.emptyBody(link: link) }
        let data = try await Data(collecting: body, upTo: Self.maximumPageBytes)
        return try decoder.decode(Page.self, from: data)
    }

    /// The `operationID` middlewares see for a page fetch (a generated operation's id is its
    /// spec `operationId`, e.g. `apps_getCollection`).
    public static let pageOperationID = "pagination_followNextLink"
    static let maximumPageBytes = 64 * 1024 * 1024

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        let transcoder = dateTranscoder
        decoder.dateDecodingStrategy = .custom { decoder in
            try transcoder.decode(try decoder.singleValueContainer().decode(String.self))
        }
        return decoder
    }

    /// Runs `request` through ``middlewares`` (outermost first) and then ``transport``.
    func send(_ request: HTTPRequest, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let transport = transport
        var next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?) = {
            try await transport.send($0, body: $1, baseURL: $2, operationID: operationID)
        }
        for middleware in middlewares.reversed() {
            let inner = next
            next = {
                try await middleware.intercept($0, body: $1, baseURL: $2, operationID: operationID, next: inner)
            }
        }
        return try await next(request, nil, baseURL)
    }
}

public enum PaginationError: Error, CustomStringConvertible, Sendable {
    case invalidLink(String)
    case untrustedHost(String)
    case unexpectedStatus(HTTPResponse.Status, link: String)
    case emptyBody(link: String)

    public var description: String {
        switch self {
        case .invalidLink(let link): "`links.next` is not an absolute URL: \(link)"
        case .untrustedHost(let link): "`links.next` names a host other than the configured server, refusing to send credentials there: \(link)"
        case .unexpectedStatus(let status, let link): "GET \(link) returned \(status)"
        case .emptyBody(let link): "GET \(link) returned no body"
        }
    }
}

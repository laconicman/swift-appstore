# ``AppStoreKit``

A type-safe, async/await App Store Connect API client, generated from Apple's official OpenAPI
specification with swift-openapi-generator, behind a façade that handles authentication, retry,
rate limits, pagination and uncertain writes.

## Overview

`AppStoreKit` wraps the generated client (the `AppStoreOpenAPI` module) in ``AppStoreConnect``:
a one-call factory that stacks four middlewares over the generated `Client` and exposes what
they learn. Every endpoint in the active generator tier is a typed method; every documented
response status is a `switch` case.

```swift
import AppStoreKit
import AppStoreOpenAPI

let key = APIKey(keyID: "ABC123DEFG", issuerID: "5724…072a", privateKeyPath: keyURL)
let asc = try AppStoreConnect(key: key)

let apps = try await asc.client.appsGetCollection(query: .init(limit: 200)).ok.body.json
for try await app in asc.items(startingWith: apps, links: \.links, data: \.data) {
    print(app.attributes?.bundleId ?? "")
}
```

The client is scoped (via the generator's `filter:`) to the **App Store publishing surface**:
app infos and versions with their localizations, screenshots and previews, review details and
submissions, builds, TestFlight groups and testers, age-rating and accessibility declarations,
categories and availability — 202 operations. The `full` template covers all 1,270.

Nothing in this package talks to Apple during `swift build` or `swift test`. The private key
is only ever referenced by its **file path**.

## Topics

### Architecture & Decisions
- <doc:Design>
- <doc:Roadmap>
- <doc:TechDebt>

### Entry point
- ``AppStoreConnect``
- ``APIKey``

### Authentication
- ``JWTSigner``
- ``BearerTokenCache``
- ``AuthenticationMiddleware``
- ``JWTSignerError``

### Retry & rate limits
- ``RetryPolicy``
- ``RetryMiddleware``
- ``RateLimitInfo``
- ``RateLimitMonitor``
- ``RateLimitMiddleware``

### Writes with an unknown outcome
- ``NonIdempotentWriteGuard``
- ``MutationOutcomeUnknownError``

### Pagination & decoding
- ``PaginationError``
- ``AppStoreConnectDateTranscoder``

# AppStoreKit

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE.txt)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/laconicman/swift-appstore)

A type-safe, async/await **App Store Connect API client** for Swift, generated from Apple's
official [OpenAPI specification](https://developer.apple.com/documentation/appstoreconnectapi)
with Apple's [swift-openapi-generator](https://github.com/apple/swift-openapi-generator), plus a
façade that handles the parts the spec does not describe: ES256 JWT auth, retry and rate-limit
etiquette, pagination, and safe handling of writes whose outcome is unknown.

> Not affiliated with Apple Inc. "App Store", "App Store Connect" and "TestFlight" are
> trademarks of Apple Inc.; this is an independent client.

Builds and tests on **Linux** as well as Apple platforms (swift-crypto stands in for
CryptoKit), so CI never needs a Mac — or a real API key.

## API coverage

The **entire** App Store Connect API v4.5 (1,270 operations) is available — coverage is a
build-time choice. The package ships the **`release`** tier by default; switch by copying a
template over `Sources/AppStoreOpenAPI/openapi-generator-config.yaml` and rebuilding:

| Tier | Operations | Config file | Verified to build |
|---|---|---|---|
| **`release`** (default) | 202 | `openapi-generator-config.yaml` | yes — Swift 6.2 (Linux) and 6.3 (macOS) |
| `full` (whole API) | 1,270 | `openapi-generator-config.full.yaml` | not yet (needs ≳16 GB RAM; see `Upstream/README.md`) |

The `release` tier is the App Store *publishing* surface: apps, app infos + localizations,
App Store versions + localizations, screenshot sets/screenshots, app preview sets/previews,
review details + attachments, review submissions + items, builds (read), TestFlight beta
localizations/groups/testers, age-rating declarations, accessibility declarations, categories,
and availability/territories. Exact counts and both sha256 pins live in
`Sources/AppStoreOpenAPI/spec-manifest.json`.

## Install

```swift
.package(url: "https://github.com/laconicman/swift-appstore.git", from: "0.1.0")
// target dependency:
.product(name: "AppStoreKit", package: "swift-appstore")
```

Requires Swift 6.2 (`swift-tools-version: 6.2` — the manifest spells its concurrency policy
with `.defaultIsolation(nil)`; see Design → Concurrency); iOS 16 / macOS 13 / tvOS 16 /
watchOS 9, or Linux. The package is nonisolated by default and every public type is
`Sendable`, so an app compiled with MainActor default isolation consumes it unchanged.

## Authentication — key *path* only

Create an [API key](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
in App Store Connect and download the `.p8` once. AppStoreKit takes the key's **file path**,
never its contents: the key is read at signing time, its bytes never appear in a log, an error
message or a type you could accidentally print, and `.p8` is git-ignored.

```swift
let key = APIKey(
    keyID: "ABC123DEFG",
    issuerID: "57246542-96fe-1a63-e053-0824d011072a",   // nil for an individual key
    privateKeyPath: URL(fileURLWithPath: "/Users/me/.appstoreconnect/AuthKey_ABC123DEFG.p8")
)
// or from ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH:
let key = APIKey(environment: ProcessInfo.processInfo.environment)
```

Tokens are ES256, 20 minutes (Apple's maximum), cached and reused until ~90 s before expiry,
and minted once more and replayed if Apple answers 401.

## Usage

```swift
import AppStoreKit
import AppStoreOpenAPI

let asc = try AppStoreConnect(key: key)

// Any generated operation, with exhaustive documented statuses:
let apps = try await asc.client.appsGetCollection(query: .init(limit: 50))
switch apps {
case .ok(let ok):               print(try ok.body.json.data.map(\.id))
case .badRequest(let bad):      print(try bad.body.json.errors ?? [])
case .undocumented(let s, _):   print("status \(s)")
default:                        break
}

// Follow `links.next` across every page:
let first = try await asc.client.appsGetCollection(query: .init(limit: 200)).ok.body.json
for try await app in asc.items(startingWith: first, links: \.links, data: \.data) {
    print(app.attributes?.bundleId ?? "")
}

// What Apple last told us about the hourly budget:
if let quota = asc.rateLimits.latest { print("\(quota.hourlyRemaining ?? 0) requests left") }
```

### What the façade does on the wire

| Situation | Behaviour |
|---|---|
| 401 | re-mint the JWT once, replay once; a second 401 is returned |
| 408 / 429 / 5xx on `GET`, `PUT` | retry with exponential backoff + jitter (default 4 attempts, first included), honouring `Retry-After` |
| 429 on `POST`, `PATCH`, `DELETE` | retry (Apple guarantees nothing was executed) |
| 408 / 5xx on `POST`, `PATCH`, `DELETE` | **returned as-is** — a response is a known outcome, and re-sending a create may duplicate it |
| transport failure mid-`POST`/`PATCH`/`DELETE` | `MutationOutcomeUnknownError` with per-method guidance on how to inspect before repairing |
| `X-Rate-Limit` header | parsed into `RateLimitInfo`, latest exposed on `asc.rateLimits` |

All of it is middleware over the generated client, so anything the façade does not cover is
one `asc.client.<operation>` call away.

## The `asc` workflow tool

`asc` is the pull → diff → apply spine for App Store metadata, over a fastlane-layout
`metadata/` tree (one file per field per locale, plus `review_information/`):

```sh
asc pull                  # live ASC state → metadata files + .asc-baseline.json
asc diff                  # three-way diff: local vs live vs last-pull baseline (read-only)
asc apply                 # prints the write plan; writes only with --yes
asc validate              # offline checks: field limits, locale codes, required fields
asc preflight --app X.app --floor 15.0   # archive checks; --archive for .xcarchive
asc questionnaire --source <app dir>     # evidence-cited App Review answer sheets (local-only)
asc submit [--version 1.3.0] [--build 9] # stages a review submission — preview without --yes
```

`asc submit` plans the version upsert (reuse the editable version, rename it, or create
the `--version` string), picks the newest VALID unexpired App-Store-eligible build for
the target release (or `--build`), reuses or creates a `reviewSubmissions` draft, and
stages the items — then stops. It refuses while a submission is in-flight on that
platform, skips items already on the draft, and never sends `submitted` or a release
request: the owner reviews the staged draft and submits in App Store Connect.

The preview is a snapshot, so `--yes` re-reads live before the first write. The gates
that must hold *abort* with a re-plan message — a submission that went in-flight, a
version renamed or no longer stageable, a build that left the eligible set. Draft
state is *reconciled* instead: a draft that appeared is reused rather than
duplicated, and its items are re-read so only missing ones are posted.

Per-app values live in `asc.json` (see `asc.example.json`): bundle id or app id, platform,
the metadata directory, expected locales, and the `asc preflight` deployment floor.
Credentials resolve from `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH` or the config's
`keyId` / `issuerId` / `keyPath` — the `.p8` is referenced by path only.

The baseline sidecar records resource ids, states, and a digest per exported field, so
`apply` can tell *local edit* from *remote drift*: a live value that changed since the last
pull is a conflict, not something to overwrite (re-pull, or `--force`). Empty files that
would clear a remote value are refused without `--allow-clear`; missing localization rows
and the review-detail row are only created with `--create-missing`. Fields that Apple
allows editing in a non-editable state (`promotionalText`, `copyright`, review details)
pass the state gate; everything else refuses while the version or appInfo is frozen.
`asc apply` stops at the first failed write and reports how far it got.

## Layout

| Path | What |
|---|---|
| `Sources/AppStoreOpenAPI/openapi.json` | Apple's spec, vendored and normalized by `asc-spec-tool` |
| `Sources/AppStoreOpenAPI/spec-manifest.json` | Pin: spec version, download date, upstream + vendored sha256, path/operation/schema counts, per-tier counts |
| `Sources/AppStoreOpenAPI/openapi-generator-config*.yaml` | Active `release` tier + preserved `full` template |
| `Sources/AppStoreKit/` | Façade: `AppStoreConnect`, `APIKey`, `JWTSigner`, middlewares, pagination |
| `Sources/asc-spec-tool/` | Maintainer tool: fetch → normalize → re-pin → drift report |
| `Sources/AppStoreWorkflow/` | pull/diff/apply/validate/preflight over a `metadata/` tree |
| `Sources/asc/` | The `asc` executable |
| `Sources/AppStoreKit/AppStoreKit.docc/` | DocC: Design, Roadmap, Tech Debt |
| `Upstream/` | Dated notes on what Apple's spec does that the generator cannot take as-is |
| `Tests/AppStoreKitTests/` | Swift Testing, mock transport, throwaway keys — offline |
| `Tests/AppStoreWorkflowTests/` | Same harness shape: scripted transport, synthetic archives |

The generated client (`Client`/`Operations`/`Components`/`Servers`) is **built from the
vendored spec at build time** — run `swift build`; nothing generated is committed.

## Regenerate from a newer spec

```bash
swift run asc-spec-tool                  # fetch Apple's zip, normalize, re-pin the manifest, print drift
swift run asc-spec-tool --check          # fetch and compare only; exit 1 if operations were added/removed/changed
swift run asc-spec-tool --no-fetch       # re-normalize the vendored spec in place (offline)
swift run asc-spec-tool --from spec.zip  # use an already-downloaded zip or openapi.oas.json
swift build                              # regenerate the client
```

The normalization is one transform — drop the five `enum: []` that make the generator emit an
uninhabited Swift enum — and it is idempotent, so a spec that no longer needs it passes through
unchanged. Details and reproduction in `Upstream/`.

## Documentation

`swift package generate-documentation --target AppStoreKit` (swift-docc-plugin), or
**Product ▸ Build Documentation** in Xcode. Start with the **Design** article.

## License

Apache 2.0 — see [`LICENSE.txt`](LICENSE.txt).

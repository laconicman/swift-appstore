# Design

Why AppStoreKit is generated, how it is structured, and the decisions behind it.

## Generate, don't adopt

Apple publishes the App Store Connect API as an OpenAPI 3.0.1 document (v4.5 at the time of
writing: 973 paths, 1,270 operations, 1,407 schemas, a single `https://api.appstoreconnect.apple.com/`
server and an `http` bearer scheme). It is regenerated with every API release, so a
hand-written client is stale on arrival. The existing Swift options were reviewed before
starting:

- **`rock-n-code/asconnect-service`** — also vendors the spec and runs swift-openapi-generator.
  It proves the approach compiles, but it ships no authentication, retry, pagination or spec
  pinning, so it is a starting point rather than a dependency.
- **`apparata/AppStoreKit`** — an older, hand-written client that happens to own the obvious
  module name. Not spec-driven; not tracked.
- **`zelentsov-dev/asc-mcp`** — not Swift, but the most carefully thought-through treatment of
  App Store Connect's *operational* behaviour: JWT lifetime and refresh, method-aware retry,
  and explicit recovery for writes whose outcome is unknown. Its `ASCNonIdempotentWriteRecovery`
  is the model for ``NonIdempotentWriteGuard``.

So: Apple's [swift-openapi-generator](https://github.com/apple/swift-openapi-generator) as a
**build plugin** — generated at build time, never committed, so the client cannot drift from
the vendored spec — with a thin façade for everything the spec does not describe.

## Module layout

Two library targets, deliberately split so the large generated module rebuilds only when the
spec or the tier changes:

- **`AppStoreOpenAPI`** — generated `Client` / `Operations` / `Components` / `Servers`. Holds
  `openapi.json`, `spec-manifest.json`, `openapi-generator-config.yaml` (the active tier), the
  preserved `openapi-generator-config.full.yaml` template, and a placeholder `Generated.swift`
  (see <doc:TechDebt>). `accessModifier: public`, `namingStrategy: idiomatic`.
- **`AppStoreKit`** — the façade: ``AppStoreConnect``, ``APIKey``, ``JWTSigner``,
  ``BearerTokenCache``, the four middlewares, pagination, and ``AppStoreConnectDateTranscoder``.

Plus one executable, `asc-spec-tool`, for the maintainer.

## Scope via `filter:`

The active tier, **`release`**, is the publishing surface (202 operations) and generates
~173k lines; on Swift 6.1.2 that is ~3 minutes cold on a small Linux box, isolated in its own
target. The **`full`** template (1,270 operations, no filter) is preserved beside it and
`exclude:`-d from the target so the plugin never sees it. Its build has **not** been verified —
the type-checker exhausted a 7 GB machine — so treat it as a template, not a tested
configuration (<doc:TechDebt>).

The `release` filter is **tag-led with two exceptions**. Apple's tags are resource-shaped
(`AppInfos`, `AppStoreVersions`, `BetaGroups`, …) and select cleanly — except `Apps` and
`Builds`, which tag every `/v1/apps/{id}/<relationship>` and `/v1/builds/{id}/<relationship>`
route (87 operations under `Apps` alone, reaching into in-app purchases, Game Center and Xcode
Cloud). Those two are pulled in by explicit `operationId` instead: the app-level reads plus
`apps_updateInstance`, and read-only build access (upload is Transporter/Xcode territory, not
the API).

## Spec pinning and normalization

`asc-spec-tool` (`swift run asc-spec-tool`) is the maintainer pipeline — fetch Apple's zip →
extract `openapi.oas.json` → normalize → write `openapi.json` + `spec-manifest.json` → print
the operation-level drift against what was vendored before. The manifest records the spec
version, download date, the **upstream** sha256 (of Apple's bytes) and the **vendored** sha256
(after normalization), the path/operation/schema counts, how many edits normalization made, and
the operation count of each tier.

One normalization exists today: five `fields[appKeywords]` query parameters declare `enum: []`,
which swift-openapi-generator turns into an empty Swift enum that does not compile. The tool
drops those five keys; the enclosing `{"type": "string"}` is untouched, so the parameter simply
becomes `[String]?`. It is idempotent — re-running over the vendored file is a no-op — and the
count is in the manifest so the change is auditable. `Upstream/` has the pasteable feedback
draft and the reproduction.

Excluding the five operations via `filter:` was the alternative; it was rejected because two
of them are on the publishing path (`appStoreVersions_appStoreVersionLocalizations_getToManyRelated`
among them) and because widening an uninhabited type to `String` cannot break a caller.

## Authentication

App Store Connect uses short-lived **ES256 JWTs** signed with a `.p8` private key. The façade's
stance is that the key is identified by its **path** — ``APIKey/privateKeyPath`` — and read at
signing time. There is no `init(privateKeyPEM:)`: the bytes never live in a Swift value that
could be logged, `print`ed in a test failure, or captured by a crash reporter, and
``JWTSignerError`` mentions the path only. `*.p8` is git-ignored as a second line.

``JWTSigner`` mints tokens with Apple's header (`alg: ES256`, `kid`, `typ: JWT`) and claims
(`iss` + `aud: appstoreconnect-v1` for a team key; `sub: user` instead of `iss` for an
individual key), capped at Apple's 20-minute maximum. It uses **CryptoKit** on Apple platforms
and [swift-crypto](https://github.com/apple/swift-crypto) elsewhere — same API, so one source
file — which is what makes Linux CI possible.

``BearerTokenCache`` reuses a token until it is within ~90 s of expiry (Apple asks that tokens
be reused, not minted per request). ``AuthenticationMiddleware`` attaches it and, on a 401,
invalidates the cache and replays the request **once**; a second 401 is returned to the caller
because at that point the key, not the clock, is the problem.

## Retry, rate limits, and writes that might have happened

Apple documents an hourly per-key budget (`X-Rate-Limit: user-hour-lim:3500;user-hour-rem:…`)
and answers 429 when it is exceeded. ``RateLimitMiddleware`` parses the header from every
response into ``RateLimitInfo`` and ``RateLimitMonitor`` keeps the latest, so a caller can slow
down *before* hitting 429 — the low-volume etiquette the project brief asks for.

``RetryMiddleware`` is method-aware, following asc-mcp's analysis:

| Method | Retried on |
|---|---|
| `GET`, `HEAD`, `OPTIONS`, `PUT`, `TRACE` | 408, 429, 5xx, and transport failures |
| `POST`, `PATCH`, `DELETE` | **429 only** |

The asymmetry is the point. A 429 means Apple executed nothing, so any method is safe to
re-send. A 5xx or a dropped connection on a `POST` means the create *may* have happened; re-sending
would duplicate an `appScreenshot` or `betaTester`. So the façade does not retry it — it lets the
error propagate to ``NonIdempotentWriteGuard``, the outermost middleware, which wraps a
*transport-level* failure of a mutation in ``MutationOutcomeUnknownError`` carrying the
operation, method, path, and ``MutationOutcomeUnknownError/inspectionGuidance``: re-read the
parent's relationship and look for a duplicate (POST), re-read the resource and compare each
attribute (PATCH), expect a 404 (DELETE). An HTTP *error response* is a known outcome and is
passed through untouched; only "no response at all" is unknown.

Backoff is exponential with full jitter, capped, and overridden by `Retry-After` (seconds or
HTTP-date). Requests whose body is a single-shot stream are never retried or replayed, because
the body is gone.

Middleware order, outermost first: guard → retry → auth → rate-limit → (Darwin) OSLog. Retry
sits *outside* auth so every attempt gets a fresh-enough token; the guard sits outside retry so
it sees only the *final* failure.

## Pagination

Apple's list responses carry `links.next` as an absolute URL that encodes the cursor and all
the original query parameters. ``AppStoreConnect/pages(startingWith:links:)`` follows it as an
`AsyncThrowingStream` of typed pages, and ``AppStoreConnect/items(startingWith:links:data:)``
flattens. The follow-up requests are plain `GET`s built from the link, sent **through the same
middleware chain** as generated operations (so they are authenticated, retried and rate-limit
tracked), and decoded with the same date transcoder. The generated `Client` cannot be used for
this because the cursor parameter is not in the spec.

## Dates

Apple emits ISO-8601 with an explicit offset, sometimes with fractional seconds
(`2024-06-25T08:00:00-07:00`, `…T15:00:00.000+00:00`). ``AppStoreConnectDateTranscoder``
accepts both forms; the runtime's stock transcoder accepts only one.

## Concurrency: nonisolated by default

`Package.swift` spells it on every target — `swiftSettings: [.defaultIsolation(nil)]`. Two
reasons, either of which would suffice:

1. **A client library must not impose an executor on its callers.** Every call into this
   package — a paged read, a JWT signature, a listing diff, a staging plan — is work that
   should run on the caller's context; hopping to the main actor and back would be
   contention bought for nothing. Apps that adopt the opposite dialect (MainActor default
   plus the SE-0461/SE-0470 upcoming features — the `YDelivery` precedent) consume this
   package unchanged, because every public async function takes and returns `Sendable`
   values only.
2. **Generated code cannot live under `-default-isolation MainActor`.** With SE-0470's
   inferred isolated conformances, the generated `Codable` conformances and the `Client`'s
   `APIProtocol` conformance would become MainActor-isolated and fail their `nonisolated`
   requirements — upstream `apple/swift-openapi-generator#796` and `#823`, whose sanctioned
   workaround is "turn that off in that module." `openapi.json` is vendored, never edited by
   hand, so the target setting is the only knob.

The safety model does not come from the flag. Every shared type is `Sendable` — explicitly,
so a future `var` cannot silently break it; mutable state sits behind an isolation boundary
of its own: ``BearerTokenCache`` is an actor, ``RateLimitMonitor`` is a final class guarded
by a lock (`@unchecked Sendable`, with the reasoning at the declaration). The middlewares,
``AppStoreConnect`` itself, and the whole workflow layer are value types over those two.
Pagination's generic `Page` is constrained `Decodable & Sendable` on all three entry points
so a result can cross into an actor-isolated caller.

Corollaries: `nonisolated` markers on value types are no-ops here — do not write them.
Adding `.defaultIsolation(MainActor.self)` to any target is the regression `REVIEW.md`
flags; if a UI-adjacent target ever joins this package, it takes the MainActor default and
the generated target stays `nil`. `swift-tools-version: 6.2` is what makes the setting
expressible, so the Linux CI image tracks a 6.2 toolchain (`swift:6.2-jammy`) and consumers
need Swift 6.2 or newer.

## Where the workflow layer plugs in

This package stops at the API. The publishing *workflow* — pull live App Store metadata into a
repo, diff it against the checked-in copy, apply the difference, preflight a submission — is a
separate layer, and the seam for it is deliberately narrow: ``AppStoreConnect`` (a configured
client plus ``RateLimitMonitor``), the pagination stream, and the typed
``MutationOutcomeUnknownError`` that a workflow can catch and turn into an "inspect before
re-applying" step. Nothing in `AppStoreKit` knows about repositories, diffs or files other than
the `.p8`.

# Tech Debt

Known compromises, workarounds and upstream-spec limitations carried by AppStoreKit. Each entry
names the cost and how to discharge it. Claims are marked **verified** (reproduced in this
repository) or **reasoned**.

## 1. Vendored spec is normalized, not byte-identical (upstream)

Five `fields[appKeywords]` query parameters declare `enum: []`; swift-openapi-generator emits
an empty Swift enum for each, which fails to compile (**verified**, 2026-09-23, Swift 6.1.2).
`asc-spec-tool` drops those five keys when vendoring.

- **Cost:** `openapi.json` differs from Apple's file. Both sha256 values and the edit count are
  in `spec-manifest.json`, so the difference is auditable but it is a difference.
- **Discharge:** Apple fixes the five parameters (`Upstream/` has the feedback draft). The
  transform is idempotent, so on a fixed spec it becomes a no-op and the two hashes converge.

## 2. `full` tier not verified

The template selects all 1,270 operations. A build was started on a 7 GB Linux box and stopped
when the type-checker for the generated `Types+Operations.swift` alone passed 4 GB
(**verified** that it ran out of memory; **not verified** that it would compile with more).

- **Cost:** unknown whether the remaining 1,068 operations surface further generator quirks.
- **Discharge:** build once on a ≥16 GB machine; record results in `Upstream/`.

## 3. Placeholder file in the generated target

`Sources/AppStoreOpenAPI/Generated.swift` is an otherwise-empty file. SwiftPM's product
emptiness check runs before the build plugin and rejects a target that has only the spec and
config, so one real source file is required. Same constraint GitLabKit carries.

- **Discharge:** none needed.

## 4. Linux `BodyLoggingPolicy` shim

`OSLogLoggingMiddleware`'s whole source is `#if canImport(Darwin)`, so on Linux the module
exists but exports nothing — including `BodyLoggingPolicy`, which is a parameter of
``AppStoreConnect``'s initializers. `BodyLoggingPolicy+Linux.swift` re-declares the two cases
under `#if !canImport(Darwin)` so the initializer signature is the same on every platform.

- **Cost:** a duplicated public type that must track upstream by hand; on Linux the parameter
  is accepted and ignored.
- **Discharge:** attach a swift-log middleware on non-Darwin (see <doc:Roadmap>) and make the
  policy a façade-owned type mapped onto whichever logger is present; or upstream a
  platform-neutral `BodyLoggingPolicy` to `OSLogLoggingMiddleware`.

## 5. `RateLimitMonitor` is a lock-guarded class

The latest ``RateLimitInfo`` is stored in a `final class` behind a lock and marked
`@unchecked Sendable`, so it can be read synchronously (`asc.rateLimits.latest`) from
non-async code. An `actor` would be the idiomatic Swift 6 choice but forces `await` on every
read.

- **Discharge:** revisit if callers turn out to be async anyway; a `Mutex`-based property
  (Synchronization module, macOS 15 / iOS 18) would remove the `@unchecked` once the
  deployment floor rises.

## 6. Pagination bypasses the generated `Client`

`links.next` carries a `cursor` query parameter that Apple's spec does not declare, so the
follow-up requests are built as raw `GET`s and decoded with the page's `Decodable` type. They
still run through the full middleware chain (**verified** by test: authenticated, retried).

- **Cost:** the page URL is trusted as given by Apple; a page type mismatch is a decoding
  error, not a compile error. Response bodies are capped at 64 MiB.
- **Discharge:** if Apple ever documents `cursor`, the generated operation can be used and the
  raw request removed.

## 7. Generated-module compile time and warnings

The `release` tier generates ~173k lines (`Types+Operations.swift` 93k, `Client.swift` 40k,
`Types+Components+Schemas.swift` 36k) — ~3 minutes cold on a small Linux box, isolated in
`AppStoreOpenAPI` so façade changes do not pay for it. Apple marks 193 schema members and 159
operations `deprecated`; a few are referenced by other generated declarations and warn on
every build (`Upstream/deprecated-relationships-warn-in-generated-code.md`).

- **Discharge:** tighten the filter, or pre-generate via the command plugin and commit the
  output if the trade-off flips.

## 8. Hand-assembled `release` filter

The tier is a list of ~25 tags plus 20 explicit `operationId`s (for `Apps` and `Builds`, whose
tags over-select). It was assembled by hand against the publishing surface (**reasoned**, not
derived mechanically) and will need maintenance as Apple adds resources or tags.

- **Discharge:** the drift report from `swift run asc-spec-tool --check` flags added/removed
  operations; review it on each spec bump.

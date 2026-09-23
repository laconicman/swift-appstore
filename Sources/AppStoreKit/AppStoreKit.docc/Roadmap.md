# Roadmap

Planned work, in rough priority order. This package is the API layer; the publishing workflow
that consumes it is built separately (see the last section of <doc:Design>).

## Verify the `full` tier

`openapi-generator-config.full.yaml` selects all 1,270 operations and has never been compiled
to completion (<doc:TechDebt> #2). Build it once on a machine with enough memory, record the
time and any generator failures in `Upstream/`, and either fix them by normalization or by
`filter:` exclusion — each exclusion dated and marked verified.

## Exercise the façade against the real API, once

Everything here is verified against a mock transport and Apple's documentation. A single
opt-in live test (gated behind an environment variable, never in CI) that lists apps with a real
key would confirm the JWT claims, the `X-Rate-Limit` header shape, and that Apple's dates decode
across the `release` tier's response types — the same role `liveDecodeReviewEntities` plays in
GitLabKit.

## File the `enum: []` feedback

`Upstream/empty-enum-in-app-keywords-fields.md` is ready to paste into Feedback Assistant.
Once Apple fixes it, `swift run asc-spec-tool` reports `emptyEnumsDropped: 0` and the
normalization can be retired.

## A workflow-facing operation catalogue

A publishing workflow wants to ask "which operations are writes, which are creates, which
paginate" without reading the spec. `asc-spec-tool` already walks every operation; emitting a
small generated table (`operationId → method, path, isPaginated`) into `AppStoreKit` would let
``NonIdempotentWriteGuard`` and the pagination helper be driven by data instead of by HTTP
method alone.

## Cross-platform logging

`OSLogLoggingMiddleware` is Darwin-only and is attached under `#if canImport(Darwin)`. For
server/Linux use, attach [`LoggingMiddleware`](https://github.com/laconicman/LoggingMiddleware)
(swift-log) under the complementary condition, and retire the Linux-only ``BodyLoggingPolicy``
shim (<doc:TechDebt> #4).

## Extract the middleware family

``AuthenticationMiddleware`` (JWT-minting bearer), ``RetryMiddleware`` and
``NonIdempotentWriteGuard`` are generic over any swift-openapi-runtime client. Once stable,
promote them to standalone packages alongside `OSLogLoggingMiddleware`.

## Publish documentation

Add `.spi.yml` and wire this catalog to the Swift Package Index once the repository is public.

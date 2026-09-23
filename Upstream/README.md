# Upstream notes

What Apple's App Store Connect OpenAPI document does that a Swift code generator has to work
around, with the evidence and the local mitigation for each. Apple's spec has no public issue
tracker — the channel is [Feedback Assistant](https://feedbackassistant.apple.com) — so each
note carries a **pasteable feedback draft** rather than a link to a filed issue.

Every claim is tagged **verified** (reproduced in this repository, with the command) or
**reasoned** (inferred from the document; not yet reproduced), and dated, because Apple
re-publishes the spec without a changelog.

| Note | Problem | Local mitigation today | Status |
|---|---|---|---|
| [empty-enum-in-app-keywords-fields](empty-enum-in-app-keywords-fields.md) | Five `fields[appKeywords]` query parameters declare `enum: []`, which swift-openapi-generator turns into an uncompilable empty Swift enum | `asc-spec-tool` drops the empty `enum` keys when vendoring (5 edits, recorded in `spec-manifest.json`) | verified 2026-09-23; feedback not yet filed |
| [deprecated-relationships-warn-in-generated-code](deprecated-relationships-warn-in-generated-code.md) | 193 `deprecated: true` schema members and 159 deprecated operations become `@available(*, deprecated)` in generated code; a few are referenced by other *generated* declarations and warn on every build | none — warnings only, generated code is not committed | verified 2026-09-23; informational, not a spec defect |

Both are **generator-facing** issues; the API itself behaves as documented. Neither required
excluding an operation from the `release` tier — the tier's 202 operations all generate and
compile (`swift build --target AppStoreOpenAPI`, Swift 6.1.2, Linux x86_64, 2026-09-23).

## Not verified in this repository

* **The `full` tier compiles.** `openapi-generator-config.full.yaml` selects all 1,270
  operations. A full-tier build was started on the 7 GB Linux box used for this scaffold and
  had to be stopped: the type-checker for the generated `Types+Operations.swift` alone passed
  4 GB. Expect the full tier to need a machine with ≥16 GB and to take well over the release
  tier's ~3 minutes. Whether *other* spec quirks surface in the 1,068 operations the release
  tier does not include is therefore **unknown** — treat the template as a starting point.

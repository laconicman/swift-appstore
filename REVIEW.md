# Review Guidelines

Steers Devin Review on this repo. Rules here are what a smart outsider would miss — the
invariants the design depends on, not generic Swift advice.

## Critical Areas

- `Sources/AppStoreKit/AppStoreConnect.swift`: `NonIdempotentWriteGuard` must stay the
  outermost middleware — flag any middleware inserted ahead of it.
- `Sources/AppStoreKit/`: a transport failure on POST/PATCH/DELETE must surface as
  `MutationOutcomeUnknownError`. Reject retries added around mutating calls — a re-sent
  POST can duplicate a localization or submission item.
- `Sources/AppStoreKit/AppStoreConnect+Pagination.swift`: `links.next` is a full URL Apple
  supplies; the follow check pins scheme + host + port to the configured server so the
  bearer token can't leak. Reject any change that widens it.
- `Sources/AppStoreWorkflow/ListingApplier.swift`: all `plan()` gates must run before the
  first network write. Flag a write path added outside `perform(_:)` or a gate moved after
  a send.
- `Sources/AppStoreWorkflow/ListingApplier.swift`: baseline digests must refresh from the
  PATCH *response* attributes, not the values sent — otherwise a post-apply diff reads clean
  on values Apple normalized differently.
- `Sources/AppStoreWorkflow/ListingField.swift`: a new field case must come with the correct
  `target`, `filePath`, `editableAnytime`, and limit per Apple's surface matrix.
- `Sources/AppStoreWorkflow/ListingField.swift`: `keywords` and `reviewNotes` are **byte**
  limits (`maxUTF8Bytes`), not character limits — flag a field that picks the wrong unit.
- `Sources/AppStoreWorkflow/ASCConfiguration.swift`: `asc.json` is closed-world — unknown
  keys fail loudly. A new config field must extend the allowed-key set and the typed field
  together; flag any decode path that silently tolerates extras.
- `Sources/asc-spec-tool/`: tier operation pins (`operationIDs`) and `reviewedAtSpec`
  watermarks are what make a spec bump reviewable. Reject a manifest write that drops them,
  and flag a spec PR whose "new since pin" digest is missing or unexplained.
- `Sources/asc/ASCMain.swift`: `main()` must `exit(1)` on failure, never `throw` — a thrown
  error at top level is a fatal trap. Flag any `throw` reachable from `main`.

## Conventions

- Require a doc comment on new public API in `Sources/AppStoreKit/`, `Sources/AppStoreWorkflow/`,
  and `Sources/asc/`, matching the existing files.
- Require `WorkflowError` (not raw generated-client errors) for failures that surface to the
  `asc` user in `Sources/AppStoreWorkflow/` and `Sources/asc/`.
- Flag any test under `Tests/` that would reach the network — the suite uses scripted
  transports and synthetic fixtures only.
- Reject hand edits to `Sources/AppStoreOpenAPI/openapi.json` — the correct change is an
  `asc-spec-tool` re-fetch plus manifest re-pin.

## Security

- Flag any code outside `Sources/AppStoreKit/JWTSigner.swift` that opens a `.p8` file, and
  any print/log/write path that could carry its contents — keys are referenced by path only.
- Flag any path that reads files named in the `sensitiveFileNames` list in
  `Sources/AppStoreWorkflow/ListingField.swift`, or sends a review-account password in a
  request body — review credentials are managed in App Store Connect, never in the tree.
- `review_information/` is secret-bearing: fastlane layouts put `demo_password.txt` in it
  as plaintext, and ASC has no API field for the password. Pull/diff must never read, emit,
  or delete files in `sensitiveFileNames`; `demo_user.txt` stays a managed field — the
  username is a real API attribute, the password is not.
- Bearer material must never reach an error string. Any new error path that interpolates an
  underlying transport error goes through `Redactor` first — flag a `\(error)` in a
  user-facing message that skips it.
- `asc pull`, `asc diff`, and `asc validate` are read-only — flag any non-GET operation
  reachable from them in `Sources/AppStoreWorkflow/ListingPuller.swift` or `Sources/asc/`.

## Not yet built — apply when the code lands

- **Screenshots:** PNG alpha must be stripped before upload — App Store rejects alpha. Flag
  any screenshot path that re-encodes without removing it.
- **Screenshot ordering:** track-slot sync is append-only. Inserting a local shot before an
  existing remote slot is a delete-and-rebuild of that track — flag a diff plan that
  presents it as an in-place insert.
- **Approval gates:** a confirmation prompt's timeout must be a real timer a modal run loop
  can't starve; a caller disconnect cancels the prompt; there is no "approve all" shortcut.
- **Readiness gates:** a submission-readiness check should cover update-version What's New,
  age-rating nil fields, privacy-policy URL, review contact fields, conditional
  demo-account fields, per-locale screenshot counts, an attached build, and privacy
  nutrition labels as a non-blocking deep link — not just field validation.

## Ignore

- `Sources/AppStoreOpenAPI/` — vendored spec, pinned manifest, and generator configs; review
  `asc-spec-tool` output instead.
- `Package.resolved`, `.build/` — skip generated files.
- `Upstream/` — skip dated notes except to check a note's date and claim are consistent.

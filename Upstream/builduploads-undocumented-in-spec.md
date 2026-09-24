# `buildUploads` is in the spec but undocumented

Surface-shape note for Apple's App Store Connect OpenAPI specification (v4.5, 2026-09-24).
**Status: spec shape verified; supported status unverified** — the paths and schemas exist
in the vendored document; whether ordinary API keys may complete a build upload is unknown
(no live probe yet — the field-trial session had no key).

## What the document says

v4.5 contains the full resource set: `/v1/buildUploads`, `/v1/buildUploads/{id}`,
`/v1/buildUploads/{id}/buildUploadFiles`, `/v1/buildUploadFiles`,
`/v1/buildUploadFiles/{id}`, and the `apps/{id}/buildUploads` relationship pair. But:

- The `BuildUpload` and `BuildUploadFile` schemas carry **no `description`** — no semantics,
  no lifecycle documentation.
- `developer.apple.com/documentation/appstoreconnectapi/builduploads` is a **404**
  (checked 2026-09-23).
- The AppStore project's surface matrix marks the surface "probe-only until a live
  `GET /v1/apps/{id}/buildUploads` answers whether ordinary keys see it".

So the document *exposes* the resources without *documenting* them — the generator will
emit types and operations with empty doc comments.

## Local impact

None today: the `release` tier deliberately excludes `buildUploads` (binary upload is
Transporter/Xcode territory). If a live probe ever shows the surface works for ordinary
keys, adding the `BuildUploads`/`BuildUploadFiles` tags to the tier is a config-only
change — at which point the missing descriptions mean generated doc comments are empty
and the operations' intended use must come from observation, not the spec.

## Feedback draft

> The v4.5 OpenAPI document ships `buildUploads`/`buildUploadFiles` paths and schemas with
> no `description` fields, and there is no corresponding documentation page (the
> `documentation/appstoreconnectapi/builduploads` URL 404s). Please document the intended
> lifecycle — create upload, add files, state machine — or state that the surface is
> reserved for internal/Xcode use.

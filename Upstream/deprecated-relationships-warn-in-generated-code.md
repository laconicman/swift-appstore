# Deprecated schema members produce build warnings in generated code

Informational note for Apple's App Store Connect OpenAPI specification (v4.5, 2026-09-23).
**Status: verified** — observed in every `swift build` of the `release` tier. Not a spec
defect; nothing to file.

## What the document says

The v4.5 document marks **159 operations** and **193 schema members** `deprecated: true`
(counted with a JSON walk over `paths` and `components/schemas`). swift-openapi-generator
faithfully emits `@available(*, deprecated)` for each of them.

## What shows up

Most deprecations are silent — they only warn when *your* code uses the member. A handful warn
on every build because another **generated** declaration references them, e.g. the memberwise
initializer of `AppEncryptionDeclaration.RelationshipsPayload` names its deprecated `builds`
member type:

```
…/GeneratedSources/Types+Components+Schemas.swift:6620:94: warning: 'BuildsPayload' is deprecated
```

`AppEncryptionDeclaration` is not in the `release` filter; it is pulled in transitively because
`AppStoreVersion` responses can `include` it.

## Local handling

None. The warnings are in build-plugin output, not in committed code, and there is no generator
option to suppress deprecation attributes. The generated files already carry
`// swiftlint:disable all` (see `additionalFileComments` in the generator config). If the noise
becomes a problem, the options are:

* a `#if` guard is not possible — the files are generated wholesale;
* stripping `deprecated: true` in `asc-spec-tool` normalization (**rejected** for now: it
  would hide real deprecation signal from façade callers);
* filtering the responsible schemas out of the tier, which is not possible for schemas reached
  through `include` polymorphism.

## Why it is recorded

The deprecated set is the most likely place for the *next* generator break: when Apple removes
a deprecated operation the drift report from `swift run asc-spec-tool --check` will list it
under **removed**, and any façade code or test fixture that named it stops compiling. Keep the
`release` tier's explicit `operations:` list free of deprecated operations (it is today — the
list was assembled from the current, non-deprecated App Store publishing surface; **reasoned**,
not mechanically checked).

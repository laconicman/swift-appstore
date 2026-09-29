## Summary

-

Closes #… — or "no tracked issue" if this is a follow-up that never had one.

## Checklist

- [ ] `swift test` green locally (CI repeats it on Linux and macOS)
- [ ] `openapi.json` / `spec-manifest.json` touched only through `swift run asc-spec-tool` — never by hand (the spec-pin job enforces it)
- [ ] New public API in `AppStoreKit` / `AppStoreWorkflow` / `asc` carries a doc comment
- [ ] Every user-facing transport error passes `Redactor`; the `.p8` is referenced by path, never read into a message or a file
- [ ] `README.md` / `REVIEW.md` / DocC (`Design`, `Roadmap`, `TechDebt`) updated if a recorded decision or invariant changed
- [ ] Source-breaking for consumers (or a toolchain-floor move) → `breaking` label, minor bump noted here
- [ ] Labelled for the release notes (`.github/release.yml`)
- [ ] No AI attribution in commits or this description
- [ ] Before merge: Devin Review round complete and `contrib in laconicman/swift-appstore --pr N` at `owed 0 / to re-read 0`; merge with `gh pr merge N --merge --auto`, never on red

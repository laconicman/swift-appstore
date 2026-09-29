# Security

## Scope

This package talks to App Store Connect on the owner's behalf, so its security surface is
the credential and the writes:

- **The API key is never stored here.** `APIKey` holds a key ID, an issuer ID, and the
  *path* to a `.p8`; the file is read only to sign a JWT (≤ 20 min) and its contents never
  reach a log, an error message, a metadata file, or the repository. Tests mint a
  throwaway P-256 key — no real key exists in CI, and no request leaves the runner
  (`.github/workflows/ci.yml`).
- **Bearer tokens are redacted** at every user-facing error surface (`Redactor`), including
  API error bodies and mutation-outcome-unknown reports.
- **Writes whose outcome is unknown are never retried.** A transport failure after a
  non-idempotent request surfaces as `MutationOutcomeUnknownError` from the outermost
  middleware (`NonIdempotentWriteGuard`); the retry middleware sits inside it.
- **`review_information/` is secret-bearing.** `asc pull` never writes the demo-account
  password; the password stays managed in App Store Connect.
- **Submission stays human.** `asc submit` stages a review-submission *draft* and stops;
  no code path sends `submitted: true` or creates a release request. A phased release is
  created only with `--phased-release` and always INACTIVE. The owner submits in
  App Store Connect.

## Reporting

Use GitHub's private vulnerability reporting on this repository (Security → Report a
vulnerability). Please do not open a public issue for anything involving a credential
path, a token, or a way to bypass the write guard.

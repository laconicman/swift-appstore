# Field-trial inputs — 2026-09-24

Distilled findings from the AppStore project's tool field trial
(`AppStore/docs/field-trial-local.md`, `field-trial-cloud.md`) that bear on this package.
Tags: **verified** = exercised or read in source during the trial; **reasoned** = inferred,
not run; **open** = needs a live ASC key. Not part of the package docs — an input note for
whoever is working the tree; fold into `Design`/`TechDebt`/`Roadmap` or delete once absorbed.

## Confirms decisions already taken here

- **Key-path-only credentials** — asc-mcp also accepts inline `key_content`/`ASC_PRIVATE_KEY`
  env; Blitz *copies* the `.p8` into `~/.blitz/asc-agent/` (0600/0700, hygienic but a second
  copy). This package's "path only, never contents" stance is the outlier in the right
  direction. (**verified**)
- **`NonIdempotentWriteGuard` + no mutation retries** — asc-mcp independently implements the
  same rule: reads retry 408/429/5xx, mutations retry **only** 429
  (`HTTPClient.swift` L316-320). (**verified**)
- **Baseline digests from the PATCH response** — the review invariant already covers it;
  trial evidence only agrees. (no action)

## Worth adopting

- **`asc-spec-tool`: per-item `reviewAtSpec` watermarks.** asc-mcp pins every manifest
  classification/waiver to a spec version; a spec bump expires them and its
  `openapi-contract-check` reports the expiries as structural errors (1,050 diagnostics on
  4.4.1→4.5, of which exactly **one** was a genuinely new untriaged operation). Adopt the
  watermark; also emit a "new since pin" digest line — the real signal drowned in expiry
  noise otherwise. (**verified** on asc-mcp v4.1.6; see field-trial-local §1)
- **Reject unknown config keys loudly.** asc-mcp silently ignores a typo'd `--workers` name —
  `--workers version` yields a 17-tool server with no error. Any filter/tier selection of
  ours should hard-fail on unknown names. (**verified**)
- **Redact bearer material in errors.** asc-mcp's `Redactor` scrubs the token even inside
  Apple's `401` message text (observed on a real 401). Check our error path does the same
  on `MutationOutcomeUnknownError` and transport failures. (**verified**)
- **fastlane-format interchange: `review_information/` is secret-bearing.** Apple's own
  `deliver download_metadata` writes the review demo password to
  `review_information/demo_password.txt` in **plaintext** (file-key names: `demo_user.txt`,
  `first_name.txt`, `notes.txt`, … — not attribute names). Any pull/interchange path must
  gitignore or redact that directory. (**verified** in fastlane 2.230.0 source)
- **Screenshot pipeline must own the no-alpha rule.** Both `simctl io screenshot` output
  (1320×2868 RGBA) and appshot's composited output (1290×2796) carry an alpha channel;
  Apple forbids alpha. Also: appshot's embedded spec DB is stale (treats 6.5" as required,
  lacks 1260×2736) — do not reuse it as a validator. (**verified**)
- **Track-slot diff rule, if we do screenshot sync:** ASC set order == upload order, there
  is no reorder op. Appended-only local files → minimal diff; inserting a local file before
  a remote one forces delete-all + re-upload (Blitz's `requiresFullTrackRebuild`).
  (**verified** in Blitz source)
- **Readiness-gate field list worth copying** for a future `preflight`: per-locale
  What's New on *update* versions, age-rating nil-field check across 7 attributes (the 409
  trap), privacy-policy URL, four review-contact fields, conditional demo-account fields,
  per-class screenshot counts, build attached; privacy nutrition labels = deep-link only,
  non-blocking. (**verified** in `ASCSubmissionReadinessManager.swift`)
- **Approval-gate requirements, if ever built** (all failure modes verified live on Blitz):
  timeout on a clock a modal can't starve (its `Timer` dies inside `runModal`'s run loop —
  5-minute auto-deny never fires); cancel the prompt when the caller disconnects (Blitz's
  orphaned alert wedges the whole MCP surface, reads included); no all-or-nothing
  "approve all" that silently pre-approves every category.

## Tier-scope questions for the owner of this repo

- `BetaFeedbackCrashSubmissions` + `BetaFeedbackScreenshotSubmissions` are real spec tags
  (feedback text **and** screenshots — the old "not in API" claim was wrong). Out of the
  `release` tier today; adding them is two tags + two `Apps` relationship ops. Is TestFlight
  feedback in scope for the release surface?
- `buildUploads` stays excluded — right call (undocumented + Transporter territory);
  see `Upstream/builduploads-undocumented-in-spec.md`.
- `InAppPurchases*`/`Subscriptions*` version resources may be needed *only to resolve* a
  Ready-to-Submit product's version id for the reviewSubmissionItems path — see
  `Upstream/reviewsubmissionitems-relationship-types.md`.

## Open probes (all need a live ASC key — read-only)

1. LearnWords baseline (`club.laconic.LearnWords`, 1.3.0/10, locales en/ru/es):
   `GET /v1/apps?filter[bundleId]=…` → `appStoreVersions` → `appStoreVersionLocalizations`
   → `appInfos` → `appInfoLocalizations` **for each** app info → `appStoreReviewDetail`.
   The puller's `selectAppInfo` already pairs-by-state correctly — the naive "first"
   shortcut was a doc bug, not a code bug.
2. `GET /v1/apps/{id}/buildUploads` — 403/404 vs empty list settles the undocumented
   surface's key-visibility. No POST.
3. First-version IAP attach via `reviewSubmissionItems` version relationships —
   `Upstream/reviewsubmissionitems-relationship-types.md` has the exact shape.
4. Live `deliver download_metadata` tree + diff against §1's reads (fastlane file-key
   layout vs API fields).
5. `fastlane-plugin-translate_gpt_release_notes` — needs an LLM key; local Ruby 3.2.2
   clears its ≥3.1 floor.

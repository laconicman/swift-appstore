# Submission staging — prior-art confirmation (fastlane, 2026-09-24)

**Status: secondary-source verified** — answers from DeepWiki deep-mode consults against
`fastlane/fastlane`, with file:line citations into `deliver/` and `spaceship/`. Records
what shaped `SubmissionStaging.swift` so a reviewer can check the reasoning, not the code.

## `submit_for_review` flow (deliver/lib/deliver/submit_for_review.rb)

1. `app.get_in_progress_review_submission` — errors if one exists. **Matches our
   in-flight gate** (`reviewSubmissions` states outside the draft set).
2. `app.get_ready_review_submission` / `create_review_submission` — reuse-or-create
   draft. **Matches `plan.draftID` reuse.**
3. `submission.add_app_store_version_to_review_items` — item POST. **Matches step 4.**
4. Polls `appStoreVersion.app_version_state` until `READY_FOR_REVIEW` (10 × 15s) — the
   version resource's state, not the submission's.
5. `submission.submit_for_review` — **we deliberately stop before 4–5.** The poll and the
   submit stay human.

The older `appStoreVersionSubmission` resource exists in spaceship but is not used by
this flow — `reviewSubmissions`/`reviewSubmissionItems` are the live surface. This is why
staging reads `reviewSubmissions` state and ignores `AppStoreVersionSubmission` (a bare
marker with no useful attributes).

## Phased release (deliver/lib/deliver/upload_metadata.rb L318–L336)

- `deliver` only ever creates `appStoreVersionPhasedReleases` with state `INACTIVE`, on the
  editable version, **before** submission (upload_metadata runs before submit_for_review).
- `ACTIVE`/`PAUSED`/`COMPLETE` transitions are Apple's — fastlane never calls them.
- If we ever ship a `--phased-release` flag: it belongs in `asc submit` as a pre-item
  create on the version, state `INACTIVE`. Whether LearnWords wants phased release at all
  is an owner question — noted in `docs/BRIEFING-2026-09-25.md` on the AppStore repo.

## Screenshot ordering (spaceship ConnectAPI vs legacy Tunes)

- `appScreenshotSets_appScreenshots_replaceToManyRelationship` is an *ordered* to-many
  PATCH — the real reorder op (what `reorder_screenshots` calls).
- fastlane's own upload sync is append + natural-filename sort; it does not reorder via the
  relationship except in the explicit reorder action.
- The ConnectAPI screenshot path uploads raw bytes — **no alpha stripping** (legacy Tunes
  code strips; unused by the current path). Any screenshot uploader we write must strip
  alpha itself.
- `app_screenshot_sets` = `(localization × display type)` buckets — the diff key for the
  future screenshot sync is track-slot, not filename.

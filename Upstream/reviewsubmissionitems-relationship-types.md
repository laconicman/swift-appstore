# `reviewSubmissionItems` accepts only *versioned* relationships

Surface-shape note for Apple's App Store Connect OpenAPI specification (v4.5, 2026-09-24).
**Status: spec shape verified; live behaviour reasoned** — enum contents reproduced locally;
runtime acceptance not yet probed against the real API (no key in the field-trial session).

## What the document says

`ReviewSubmissionItemCreateRequest.data.relationships` offers exactly these item types
(vendored `openapi.json`, read 2026-09-24):

`appCustomProductPageVersion`, `appEvent`, `appStoreVersion`,
`appStoreVersionExperiment`, `appStoreVersionExperimentV2`, `backgroundAssetVersion`,
`gameCenterAchievementVersion`, `gameCenterActivityVersion`,
`gameCenterChallengeVersion`, `gameCenterLeaderboardSetVersion`,
`gameCenterLeaderboardVersion`, **`inAppPurchaseVersion`**, `reviewSubmission`,
**`subscriptionGroupVersion`**, **`subscriptionVersion`**.

There is **no** `inAppPurchase` or `subscription` relationship type — only the versioned
entities.

## Why it matters

Blitz (a native ASC client) documents that flagging an *existing* Ready-to-Submit IAP or
subscription to ship with a **first** app version goes through the web-only iris API
(`POST /iris/v1/{subscription,inAppPurchase}Submissions` with
`submitWithNextAppStoreVersion: true`), and that the public
`POST /v1/subscriptionSubmissions` / `/v1/inAppPurchaseSubmissions` endpoints reject the
first-version case with `FIRST_SUBSCRIPTION_MUST_BE_SUBMITTED_ON_VERSION` (Blitz's bundled
`asc-iap-attach` agent skill; **not** reproduced against the live API).

That error only proves a first product must travel *with* an app version — which the
versioned relationship types can express: a Ready-to-Submit product has a version resource,
so one review-submission item can carry `inAppPurchaseVersion`/`subscriptionVersion`
alongside `appStoreVersion`. **Probably supported through the public API; needs a live
probe.** If confirmed, the last known "must go through the website" step of a first
submission disappears.

## Local impact

The `release` tier already includes the `ReviewSubmissions` and `ReviewSubmissionItems`
tags, so the probe needs no config change: create a review submission, then an item whose
relationship is the product *version* id, plus one for the app version. Whether
`inAppPurchaseVersions`/`subscriptionVersions` are also needed as first-class tier members
(for *finding* the version id of a Ready-to-Submit product) is the open question — today
neither tag is in the tier.

## Feedback draft

> `ReviewSubmissionItemCreateRequest` accepts `inAppPurchaseVersion` and
> `subscriptionVersion` relationships but not `inAppPurchase`/`subscription`. Please
> document whether attaching a Ready-to-Submit IAP/subscription to a *first* app version's
> review submission via the versioned relationship is supported — the web UI's
> "Add In-App Purchases or Subscriptions" modal implies it is, and the public
> `inAppPurchaseSubmissions`/`subscriptionSubmissions` endpoints reject it with
> `FIRST_SUBSCRIPTION_MUST_BE_SUBMITTED_ON_VERSION`.

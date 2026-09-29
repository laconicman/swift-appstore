import Foundation
@testable import AppStoreKit
@testable import AppStoreWorkflow

/// Shared `LiveListing`/`Baseline` fixtures for the diff and plan suites — the drift
/// provenance shape both `ListingDiffer` and `ListingApplier.plan` tests exercise.
/// Kept as free functions like `scriptedConnect`; `liveListing` is named so it can't be
/// confused with the `live(...)` member helpers inside the suites.
func liveListing(localized: [String: FieldValues]) -> LiveListing {
    LiveListing(
        app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: "en-US", sku: nil),
        version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
        appInfo: .init(id: "I1", appStoreState: "PREPARE_FOR_SUBMISSION"),
        reviewDetailID: nil,
        localizationIDs: localized.mapValues { _ in .init(version: "VL", appInfo: "AIL") },
        values: ListingSnapshot(localized: localized), demoAccountRequired: nil
    )
}

func driftedLive(field: ListingField) -> (LiveListing, Baseline) {
    let live = liveListing(localized: ["en-US": [field: "drifted"]])
    var baseline = live.makeBaseline()
    baseline.digests[Baseline.digestKey(field: field, locale: "en-US")] = Baseline.digest(of: "old")
    return (live, baseline)
}

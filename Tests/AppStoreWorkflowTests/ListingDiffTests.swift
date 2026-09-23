import Foundation
import Testing
@testable import AppStoreWorkflow

/// Three-way classification: local files vs live values vs the pull baseline.
/// Covers every `ChangeKind` plus the remote-only-locale report.
@Suite("ListingDiffer three-way classification")
struct ListingDiffTests {
    func live(
        localized: [String: FieldValues] = ["en-US": [.name: "Live Name", .description: "Live desc"]],
        shared: FieldValues = [.copyright: "2025 Laconic"],
        reviewDetailID: String? = "RD1"
    ) -> LiveListing {
        LiveListing(
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: "en-US", sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: "READY_FOR_SALE"),
            reviewDetailID: reviewDetailID,
            localizationIDs: localized.mapValues { _ in .init(version: "VL", appInfo: "AIL") },
            values: ListingSnapshot(localized: localized, shared: shared),
            demoAccountRequired: nil
        )
    }

    func local(_ localized: [String: FieldValues], shared: FieldValues = [:]) -> MetadataTree {
        MetadataTree(snapshot: ListingSnapshot(localized: localized, shared: shared))
    }

    func baseline(for snapshot: ListingSnapshot) -> Baseline {
        Baseline(
            exportedAt: Date(),
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: nil, sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: nil),
            reviewDetailID: "RD1",
            localizationIDs: [:],
            digests: Baseline.digests(for: snapshot)
        )
    }

    @Test("identical local and live → unchanged, empty diff")
    func unchanged() {
        let liveValues: FieldValues = [.name: "Same", .description: "Same desc"]
        let diff = ListingDiffer.diff(
            local: local(["en-US": liveValues]),
            live: live(localized: ["en-US": liveValues], shared: [:]),
            baseline: baseline(for: ListingSnapshot(localized: ["en-US": liveValues]))
        )
        #expect(diff.entries.allSatisfy { $0.kind == .unchanged })
        #expect(diff.isEmpty)
    }

    @Test("local edit with live still at baseline → change")
    func localChange() {
        let liveValues: FieldValues = [.name: "Old Name"]
        let diff = ListingDiffer.diff(
            local: local(["en-US": [.name: "New Name"]]),
            live: live(localized: ["en-US": liveValues], shared: [:]),
            baseline: baseline(for: ListingSnapshot(localized: ["en-US": liveValues]))
        )
        let entry = diff.entries.first { $0.field == .name }
        #expect(entry?.kind == .change)
        #expect(entry?.live == "Old Name")
        #expect(entry?.local == "New Name")
    }

    @Test("live drifted from baseline and local differs → conflict")
    func conflict() {
        let diff = ListingDiffer.diff(
            local: local(["en-US": [.name: "My Edit"]]),
            live: live(localized: ["en-US": [.name: "Someone Else's Edit"]], shared: [:]),
            baseline: baseline(for: ListingSnapshot(localized: ["en-US": [.name: "Pulled Name"]]))
        )
        let entry = diff.entries.first { $0.field == .name }
        #expect(entry?.kind == .conflict)
    }

    @Test("local == live but both drifted from baseline → converged, no write")
    func converged() {
        let diff = ListingDiffer.diff(
            local: local(["en-US": [.name: "New"]]),
            live: live(localized: ["en-US": [.name: "New"]], shared: [:]),
            baseline: baseline(for: ListingSnapshot(localized: ["en-US": [.name: "Old"]]))
        )
        let entry = diff.entries.first { $0.field == .name }
        #expect(entry?.kind == .converged)
        #expect(diff.isEmpty)
    }

    @Test("empty local file against a live value → blocked")
    func blocked() {
        let diff = ListingDiffer.diff(
            local: local(["en-US": [.description: ""]]),
            live: live(localized: ["en-US": [.description: "Live desc"]], shared: [:]),
            baseline: nil
        )
        let entry = diff.entries.first { $0.field == .description }
        #expect(entry?.kind == .blocked)
    }

    @Test("local locale absent from live → create entries")
    func createMissing() {
        let diff = ListingDiffer.diff(
            local: local(["de-DE": [.name: "Wörter", .description: "Beschreibung"]]),
            live: live(localized: ["en-US": [.name: "Live"]], shared: [:]),
            baseline: nil
        )
        let creates = diff.entries(ofKind: .create)
        #expect(creates.count == 2)
        #expect(creates.allSatisfy { $0.locale == "de-DE" })
        // en-US is remote-only now.
        #expect(diff.remoteOnlyLocales == ["en-US"])
    }

    @Test("shared review-detail fields create when no review detail exists remotely")
    func reviewDetailCreate() {
        let diff = ListingDiffer.diff(
            local: local([:], shared: [.contactEmail: "r@example.com"]),
            live: live(localized: [:], shared: [:], reviewDetailID: nil),
            baseline: nil
        )
        let entry = diff.entries.first { $0.field == .contactEmail }
        #expect(entry?.kind == .create)
    }

    @Test("no baseline → differences are plain changes, never conflicts")
    func noBaseline() {
        let diff = ListingDiffer.diff(
            local: local(["en-US": [.name: "Different"]]),
            live: live(localized: ["en-US": [.name: "Live Name"]], shared: [:]),
            baseline: nil
        )
        #expect(diff.entries.first { $0.field == .name }?.kind == .change)
        #expect(diff.entries(ofKind: .conflict).isEmpty)
    }

    @Test("fields with no local file are untouched — not diffs")
    func absentLocalFile() {
        let diff = ListingDiffer.diff(
            local: local(["en-US": [.name: "Same as live? no — only name present"]]),
            live: live(localized: ["en-US": [.name: "Same as live? no — only name present", .keywords: "a,b"]], shared: [:]),
            baseline: nil
        )
        // keywords has no local file → no entry at all (not a "clear").
        #expect(diff.entries.allSatisfy { $0.field == .name })
    }
}

import Foundation
import Testing
@testable import AppStoreKit
@testable import AppStoreWorkflow

/// `.asc-baseline.json` — the sidecar that makes the diff three-way: identity, digests,
/// and provenance carry-forward.
@Suite("Baseline identity and digests")
struct BaselineTests {

    // MARK: - baseline identity

    func baseline(appID: String = "APP1", bundleId: String = "com.example.app",
                  versionID: String = "V1", appInfoID: String = "I1") -> Baseline {
        Baseline(
            exportedAt: Date(), app: .init(id: appID, bundleId: bundleId, primaryLocale: nil, sku: nil),
            version: .init(id: versionID, versionString: "1.0", platform: "IOS", appStoreState: "X"),
            appInfo: .init(id: appInfoID, appStoreState: nil), reviewDetailID: nil,
            localizationIDs: [:], digests: [:]
        )
    }

    func liveListing(versionID: String = "V1", appInfoID: String = "I1") -> LiveListing {
        LiveListing(
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: "en-US", sku: nil),
            version: .init(id: versionID, versionString: "1.0", platform: "IOS", appStoreState: "X"),
            appInfo: .init(id: appInfoID, appStoreState: nil), reviewDetailID: nil,
            localizationIDs: [:], values: ListingSnapshot(), demoAccountRequired: nil
        )
    }

    @Test("a baseline from another app is a hard identity violation")
    func baselineAppMismatch() {
        let b = baseline(appID: "OTHER", bundleId: "com.other.app")
        #expect(b.identityViolation(against: liveListing()) != nil)
    }

    @Test("same-app baseline passes; version/appInfo drift surfaces as notes")
    func baselineIdentityNotes() {
        let b = baseline()
        #expect(b.identityViolation(against: liveListing()) == nil)
        let notes = b.identityNotes(against: liveListing(versionID: "V2", appInfoID: "I2"))
        #expect(notes.count == 2)
    }

    // MARK: - digest width

    @Test("baseline digests are the full SHA-256, not a truncation")
    func digestWidth() {
        #expect(Baseline.digest(of: "x").count == 64)
    }

    @Test("v1 baselines are an identity violation — re-seed by pulling")
    func oldSchemaFlagged() {
        var b = Baseline(
            exportedAt: Date(), app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: nil, sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "X"),
            appInfo: .init(id: "I1", appStoreState: nil), reviewDetailID: nil,
            localizationIDs: [:], digests: [:]
        )
        b.schemaVersion = 1
        let live = LiveListing(
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: "en-US", sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "X"),
            appInfo: .init(id: "I1", appStoreState: nil), reviewDetailID: nil,
            localizationIDs: [:], values: ListingSnapshot(), demoAccountRequired: nil
        )
        #expect(b.identityViolation(against: live)?.contains("v1") == true)
    }

    // MARK: - kept-stale provenance

    @Test("carryDigests preserves the old digest for files pull kept despite remote removal")
    func digestCarryForward() {
        var old = Baseline(
            exportedAt: Date(), app: .init(id: "A", bundleId: "b", primaryLocale: nil, sku: nil),
            version: .init(id: "V", versionString: "1.0", platform: "IOS", appStoreState: "X"),
            appInfo: .init(id: "I", appStoreState: nil), reviewDetailID: nil,
            localizationIDs: [:], digests: ["en-US/keywords.txt": "abc123"]
        )
        var fresh = Baseline(
            exportedAt: Date(), app: .init(id: "A", bundleId: "b", primaryLocale: nil, sku: nil),
            version: .init(id: "V2", versionString: "1.1", platform: "IOS", appStoreState: "X"),
            appInfo: .init(id: "I", appStoreState: nil), reviewDetailID: nil,
            localizationIDs: [:], digests: [:]
        )
        fresh.carryDigests(from: old, for: ["en-US/keywords.txt", "de-DE/name.txt"])
        #expect(fresh.digests["en-US/keywords.txt"] == "abc123")
        #expect(fresh.digests["de-DE/name.txt"] == nil)   // never pulled — nothing to carry
        old.digests["en-US/keywords.txt"] = "changed"     // carry is by value
        #expect(fresh.digests["en-US/keywords.txt"] == "abc123")
    }

    // MARK: - keys and the sidecar file

    @Test("digestKey is locale-prefixed for localized fields, bare for shared fields")
    func digestKeyShape() {
        #expect(Baseline.digestKey(field: .name, locale: "en-US") == "en-US/name.txt")
        #expect(Baseline.digestKey(field: .copyright, locale: nil) == "copyright.txt")
    }

    @Test("write stores the sidecar at the pinned file name")
    func sidecarFileName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaselineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try baseline().write(to: root)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(Baseline.fileName).path))
        #expect(Baseline.fileName == ".asc-baseline.json")
    }
}

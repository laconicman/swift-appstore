import Foundation
import Testing
@testable import AppStoreWorkflow

/// The fastlane-layout interchange: write → load round-trips, one trailing newline per file,
/// unknown files reported, credential files ignored.
@Suite("MetadataStore layout")
struct MetadataStoreTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MetadataStoreTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test("write → load round-trips values and paths")
    func roundTrip() throws {
        var snapshot = ListingSnapshot()
        snapshot.localized["en-US"] = [.name: "LearnWords", .description: "Learn words."]
        snapshot.localized["de-DE"] = [.name: "Wörter"]
        snapshot.shared[.copyright] = "2025 Laconic"
        snapshot.shared[.contactEmail] = "review@example.com"

        let written = try MetadataStore.write(snapshot, to: root)
        #expect(written.contains("en-US/name.txt"))
        #expect(written.contains("en-US/description.txt"))
        #expect(written.contains("de-DE/name.txt"))
        #expect(written.contains("copyright.txt"))
        #expect(written.contains("review_information/email_address.txt"))

        let tree = try MetadataStore.load(root: root)
        #expect(tree.snapshot.localized["en-US"]?[.name] == "LearnWords")
        #expect(tree.snapshot.localized["en-US"]?[.description] == "Learn words.")
        #expect(tree.snapshot.localized["de-DE"]?[.name] == "Wörter")
        #expect(tree.snapshot.shared[.copyright] == "2025 Laconic")
        #expect(tree.snapshot.shared[.contactEmail] == "review@example.com")
        #expect(tree.unknownFiles.isEmpty)
    }

    @Test("files end in exactly one newline")
    func trailingNewline() throws {
        var snapshot = ListingSnapshot()
        snapshot.localized["en-US"] = [.name: "App"]
        try MetadataStore.write(snapshot, to: root)

        let raw = try String(contentsOf: root.appendingPathComponent("en-US/name.txt"), encoding: .utf8)
        #expect(raw == "App\n")
        // And a value that already carries a newline inside is preserved, not collapsed.
        var multi = ListingSnapshot()
        multi.localized["en-US"] = [.description: "line one\nline two"]
        try MetadataStore.write(multi, to: root)
        let tree = try MetadataStore.load(root: root)
        #expect(tree.snapshot.localized["en-US"]?[.description] == "line one\nline two")
    }

    @Test("unknown .txt files are reported, never silently dropped")
    func unknownFiles() throws {
        let dir = root.appendingPathComponent("en-US")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "typo".write(to: dir.appendingPathComponent("desciption.txt"), atomically: true, encoding: .utf8)
        try "LearnWords".write(to: dir.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)

        let tree = try MetadataStore.load(root: root)
        #expect(tree.unknownFiles == ["en-US/desciption.txt"])
        #expect(tree.snapshot.localized["en-US"]?[.name] == "LearnWords")
        // The typo'd file is not mapped onto .description.
        #expect(tree.snapshot.localized["en-US"]?[.description] == nil)
    }

    @Test("demo_password.txt is ignored — never read into the snapshot")
    func sensitiveFiles() throws {
        let dir = root.appendingPathComponent("review_information")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hunter2".write(to: dir.appendingPathComponent("demo_password.txt"), atomically: true, encoding: .utf8)
        try "demo@example.com".write(to: dir.appendingPathComponent("demo_user.txt"), atomically: true, encoding: .utf8)

        let tree = try MetadataStore.load(root: root)
        #expect(tree.ignoredFiles == ["review_information/demo_password.txt"])
        #expect(tree.snapshot.shared[.demoAccountName] == "demo@example.com")
        // Nothing in the model can hold a password — assert no field captured it.
        #expect(!tree.snapshot.shared.values.contains("hunter2"))
    }

    @Test("a missing root loads as an empty tree (pre-pull state)")
    func missingRoot() throws {
        let absent = root.appendingPathComponent("does-not-exist")
        let tree = try MetadataStore.load(root: absent)
        #expect(tree.snapshot.localized.isEmpty)
        #expect(tree.snapshot.shared.isEmpty)
        #expect(tree.unknownFiles.isEmpty)
    }

    @Test("baseline sidecar round-trips and is not treated as metadata")
    func baselineSidecar() throws {
        var baseline = Baseline(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: "en-US", sku: "SKU"),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: "READY_FOR_SALE"),
            reviewDetailID: "RD1",
            localizationIDs: ["en-US": .init(version: "VL1", appInfo: "AIL1")],
            digests: ["en-US/name.txt": "deadbeef"]
        )
        try baseline.write(to: root)

        let loaded = try Baseline.load(root: root)
        #expect(loaded?.version.id == "V1")
        #expect(loaded?.localizationIDs["en-US"]?.version == "VL1")
        #expect(loaded?.digests["en-US/name.txt"] == "deadbeef")

        baseline.digests["en-US/name.txt"] = "cafef00d"
        try baseline.write(to: root)
        #expect(try Baseline.load(root: root)?.digests["en-US/name.txt"] == "cafef00d")
    }

    // MARK: - pull reconciles remote-deleted files

    @Test("a field removed remotely is deleted locally when the baseline proves it untouched")
    func reconcileRemovesStaleFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewRound1-\(UUID().uuidString)", isDirectory: true)
        // Prior pull exported keywords.txt for en-US.
        let snapshot = ListingSnapshot(localized: ["en-US": [.keywords: "a,b"]])
        try MetadataStore.write(snapshot, to: root)
        let baseline = Baseline(
            exportedAt: Date(), app: .init(id: "A", bundleId: "b", primaryLocale: nil, sku: nil),
            version: .init(id: "V", versionString: "1.0", platform: "IOS", appStoreState: "X"),
            appInfo: .init(id: "I", appStoreState: nil), reviewDetailID: nil,
            localizationIDs: [:], digests: Baseline.digests(for: snapshot)
        )
        try baseline.write(to: root)

        // Remote cleared keywords — the next pull's snapshot has no value for it.
        let live = ListingSnapshot(localized: ["en-US": [:]])
        try MetadataStore.write(live, to: root)
        let r = try MetadataStore.reconcile(live, baseline: baseline, at: root)

        #expect(r.removed == ["en-US/keywords.txt"])
        #expect(r.keptStale.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("en-US/keywords.txt").path))
    }

    @Test("a locally-edited stale file is kept and reported, never deleted")
    func reconcileKeepsEditedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewRound1-\(UUID().uuidString)", isDirectory: true)
        let snapshot = ListingSnapshot(localized: ["en-US": [.keywords: "a,b"]])
        try MetadataStore.write(snapshot, to: root)
        let baseline = Baseline(
            exportedAt: Date(), app: .init(id: "A", bundleId: "b", primaryLocale: nil, sku: nil),
            version: .init(id: "V", versionString: "1.0", platform: "IOS", appStoreState: "X"),
            appInfo: .init(id: "I", appStoreState: nil), reviewDetailID: nil,
            localizationIDs: [:], digests: Baseline.digests(for: snapshot)
        )
        // Owner edits the file after the pull.
        try "c,d,e".write(to: root.appendingPathComponent("en-US/keywords.txt"), atomically: true, encoding: .utf8)

        let live = ListingSnapshot(localized: ["en-US": [:]])
        let r = try MetadataStore.reconcile(live, baseline: baseline, at: root)

        #expect(r.removed.isEmpty)
        #expect(r.keptStale == ["en-US/keywords.txt"])
        #expect(try MetadataStore.readFile(root.appendingPathComponent("en-US/keywords.txt")) == "c,d,e")
    }

    @Test func rootLevelUnknownFileReported() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("en-US"), withIntermediateDirectories: true
        )
        try "note".write(to: root.appendingPathComponent("typo.txt"), atomically: true, encoding: .utf8)
        try "v".write(to: root.appendingPathComponent("en-US/whats_new.txt"), atomically: true, encoding: .utf8)
        let tree = try MetadataStore.load(root: root)
        #expect(tree.unknownFiles.contains("typo.txt"))
    }
}

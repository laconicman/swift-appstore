import Foundation
import HTTPTypes
import Testing
@testable import AppStoreKit
@testable import AppStoreWorkflow

/// Regression tests for the first Devin Review round on the workflow spine — one test per
/// finding so a reverted fix fails loudly instead of silently shipping again.
@Suite("review round 1 regressions")
struct ReviewRound1Tests {

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

    // MARK: - per-target localization rows

    @Test("a locale with a version row but no appInfo row creates only the appInfo fields")
    func partialRowCreate() throws {
        let live = LiveListing(
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: "en-US", sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: nil),
            reviewDetailID: nil,
            // de-DE has a version localization but no appInfo localization remotely.
            localizationIDs: ["de-DE": .init(version: "VL-DE", appInfo: nil)],
            values: ListingSnapshot(localized: ["de-DE": [.description: "Live desc"]]),
            demoAccountRequired: nil
        )
        let local = MetadataTree(snapshot: ListingSnapshot(localized: [
            "de-DE": [.description: "Live desc", .name: "Mein Name"],
        ]))
        let diff = ListingDiffer.diff(local: local, live: live, baseline: nil)

        let name = try #require(diff.entries.first { $0.field == .name })
        #expect(name.kind == .create)                    // appInfo row absent → create
        let desc = try #require(diff.entries.first { $0.field == .description })
        #expect(desc.kind == .unchanged)                 // version row present → normal classify
    }

    // MARK: - archive traversal reaches nested bundles

    @Test("an appex inside .app inside .xcarchive is found — the skipDescendants regression")
    func xcarchiveNestedExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewRound1-\(UUID().uuidString)", isDirectory: true)
        try makeBundle(root, "A.xcarchive/Products/Applications/App.app", minOS: "15.0")
        try makeBundle(root, "A.xcarchive/Products/Applications/App.app/PlugIns/Widget.appex", minOS: "14.0")

        let report = try Preflight.inspect(at: root.appendingPathComponent("A.xcarchive"), floor: "15.0")
        #expect(report.bundles.count == 2)
        #expect(report.findings.contains {
            if case .belowFloor(let b, let found, _) = $0 { return b.hasSuffix("Widget.appex") && found == "14.0" }
            return false
        })
    }

    @Test("framework version drift is not flagged — only app/extension equality")
    func frameworkDriftIgnored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewRound1-\(UUID().uuidString)", isDirectory: true)
        try makeBundle(root, "App.app", version: "1.2.2", build: "7")
        // A framework legitimately carries its own version — must not trip TD-24's check.
        try makeBundle(root, "App.app/Frameworks/Kingfisher.framework", version: "8.0.0", build: "1")
        let report = try Preflight.inspect(at: root.appendingPathComponent("App.app"), floor: "15.0")
        #expect(report.bundles.count == 2)
        #expect(!report.findings.contains {
            if case .versionMismatch = $0 { return true }
            return false
        })
        #expect(!report.findings.contains {
            if case .buildMismatch = $0 { return true }
            return false
        })
        // Floor + privacy still apply to every bundle.
        #expect(report.ok)
    }

    // MARK: - invalid platform fails closed

    @Test("an unknown platform throws before any request — no silent all-platform fetch")
    func invalidPlatform() async throws {
        let (asc, transport) = try scriptedConnect([])
        await #expect(throws: WorkflowError.self) {
            _ = try await ListingPuller(asc: asc).pull(appID: "APP1", bundleId: nil, platform: "WATCH_OS", version: .latest)
        }
        #expect(await transport.exchanges.isEmpty)
    }

    // MARK: - force/allow-clear can't bypass the gates

    func frozenLive() -> LiveListing {
        LiveListing(
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: "en-US", sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "READY_FOR_SALE"),
            appInfo: .init(id: "I1", appStoreState: "READY_FOR_SALE"),
            reviewDetailID: "RD1",
            localizationIDs: ["en-US": .init(version: "VL1", appInfo: "AIL1")],
            values: ListingSnapshot(), demoAccountRequired: nil
        )
    }

    @Test("a forced conflict on a frozen version still hits the editable-state gate")
    func forcedConflictRespectsEditability() async throws {
        let (asc, _) = try scriptedConnect([])
        let applier = ListingApplier(asc: asc)
        let entry = FieldDiff(field: .description, locale: "en-US", kind: .conflict, local: "new", live: "drifted")
        let diff = ListingDiff(entries: [entry], remoteOnlyLocales: [])
        await #expect(throws: WorkflowError.self) {
            _ = try await applier.plan(diff, live: frozenLive(), options: .init(force: true))
        }
    }

    @Test("a forced conflict with an over-limit value still fails validation")
    func forcedConflictValidated() async throws {
        let (asc, _) = try scriptedConnect([])
        let applier = ListingApplier(asc: asc)
        let tooLong = String(repeating: "x", count: 31)   // name limit is 30
        let entry = FieldDiff(field: .name, locale: "en-US", kind: .conflict, local: tooLong, live: "drifted")
        let diff = ListingDiff(entries: [entry], remoteOnlyLocales: [])
        // Editable state so it reaches validation; validation must still reject it.
        var live = frozenLive()
        live.version.appStoreState = "PREPARE_FOR_SUBMISSION"
        await #expect(throws: WorkflowError.self) {
            _ = try await applier.plan(diff, live: live, options: .init(force: true))
        }
    }

    @Test("an allowed clear on a frozen version still hits the editable-state gate")
    func allowedClearRespectsEditability() async throws {
        let (asc, _) = try scriptedConnect([])
        let applier = ListingApplier(asc: asc)
        let entry = FieldDiff(field: .description, locale: "en-US", kind: .blocked, local: "", live: "x")
        let diff = ListingDiff(entries: [entry], remoteOnlyLocales: [])
        await #expect(throws: WorkflowError.self) {
            _ = try await applier.plan(diff, live: frozenLive(), options: .init(allowClear: true))
        }
    }

    // MARK: - URL scheme restriction

    @Test("non-http(s) URL schemes are rejected for support/marketing URLs")
    func urlSchemeRestricted() throws {
        let tree = MetadataTree(snapshot: ListingSnapshot(localized: [
            "en-US": [.supportUrl: "ftp://example.com/help", .name: "Name",
                      .description: "desc", .keywords: "a", .whatsNew: "n",
                      .subtitle: "s", .promotionalText: "p"],
        ]))
        let issues = ListingValidator.validate(local: tree, expectedLocales: nil)
        #expect(issues.contains {
            $0.path == "en-US/support_url.txt" && $0.message.contains("http")
        })
    }

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

    // MARK: - appInfo selection ties to the version

    @Test("pull prefers the appInfo whose state matches the selected version's")
    func appInfoPairedToVersion() async throws {
        let appInfosJSON = #"""
        {"data":[
          {"type":"appInfos","id":"I_LIVE","attributes":{"appStoreState":"READY_FOR_SALE"}},
          {"type":"appInfos","id":"I_EDIT","attributes":{"appStoreState":"PREPARE_FOR_SUBMISSION"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/APP1/appInfos"}}
        """#
        let appInfoLocalizationsJSON = #"""
        {"data":[{"type":"appInfoLocalizations","id":"AIL2","attributes":{"locale":"en-US","name":"N"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/appInfos/I_EDIT/appInfoLocalizations"}}
        """#
        let (asc, _) = try scriptedConnect([
            .json(.ok, ListingPullerTests.appJSON),
            .json(.ok, appInfosJSON),
            .json(.ok, ListingPullerTests.versionsJSON),                 // V_EDIT is PREPARE_FOR_SUBMISSION
            .json(.ok, ListingPullerTests.versionLocalizationsJSON),
            .json(.ok, appInfoLocalizationsJSON),
            .json(.ok, ListingPullerTests.reviewDetailJSON),
        ])
        let live = try await ListingPuller(asc: asc).pull(
            appID: "APP1", bundleId: nil, platform: "IOS", version: .latest
        )
        // I_LIVE was listed first but is READY_FOR_SALE; the editable version's peer wins.
        #expect(live.appInfo.id == "I_EDIT")
    }

    // MARK: - helpers

    func makeBundle(_ root: URL, _ path: String, version: String = "1.2.2", build: String = "7",
                    minOS: String? = "15.0", privacy: Bool = true) throws {
        let dir = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.\(dir.lastPathComponent)",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        if let minOS { plist["MinimumOSVersion"] = minOS }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Info.plist"))
        if privacy {
            try "<plist><dict/></plist>".write(
                to: dir.appendingPathComponent("PrivacyInfo.xcprivacy"), atomically: true, encoding: .utf8)
        }
    }
}

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

/// Second review round on PR #2 — findings against the round-1 fixes.
@Suite("review round 2 regressions")
struct ReviewRound2Tests {

    // MARK: - normalized responses write back

    static let normalizedPatch = #"""
    {"data":{"type":"appStoreVersionLocalizations","id":"VL1","attributes":{
      "locale":"en-US","description":"new desc","keywords":null,"whatsNew":null,
      "promotionalText":null,"supportUrl":null,"marketingUrl":null}}, "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/VL1"}}
    """#

    @Test("a response value that differs from the sent value is reported for file write-back")
    func normalizedValueReported() async throws {
        let (asc, _) = try scriptedConnect([.json(.ok, Self.normalizedPatch)])
        var baseline = Baseline(
            exportedAt: Date(), app: .init(id: "APP1", bundleId: "b", primaryLocale: nil, sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: nil), reviewDetailID: nil,
            localizationIDs: ["en-US": .init(version: "VL1")], digests: [:]
        )
        let live = LiveListing(
            app: .init(id: "APP1", bundleId: "b", primaryLocale: "en-US", sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: nil), reviewDetailID: nil,
            localizationIDs: ["en-US": .init(version: "VL1")], values: ListingSnapshot(), demoAccountRequired: nil
        )
        // Sent "new desc " (trailing space); Apple stored "new desc".
        let result = await ListingApplier(asc: asc).apply(
            [.versionLocalizationUpdate(id: "VL1", locale: "en-US", values: [.description: "new desc "])],
            baseline: &baseline, live: live
        )
        #expect(result.ok)
        #expect(result.normalized.count == 1)
        #expect(result.normalized.first?.field == .description)
        #expect(result.normalized.first?.value == "new desc")
        // And the baseline records the stored value, so the next diff sees truth.
        #expect(baseline.digests["en-US/description.txt"] == Baseline.digest(of: "new desc"))
    }

    // MARK: - create payloads are gated atomically

    @Test("an app-info localization create without name.txt fails in plan, not mid-apply")
    func createNeedsNameAtPlan() async throws {
        let (asc, transport) = try scriptedConnect([])
        let applier = ListingApplier(asc: asc)
        // subtitle is appInfo-targeted; the locale's row doesn't exist → create.
        let entries = [
            FieldDiff(field: .subtitle, locale: "de-DE", kind: .create, local: "Untertitel", live: nil),
        ]
        let live = LiveListing(
            app: .init(id: "APP1", bundleId: "b", primaryLocale: "en-US", sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: "READY_FOR_SALE"), reviewDetailID: nil,
            localizationIDs: [:], values: ListingSnapshot(), demoAccountRequired: nil
        )
        await #expect(throws: WorkflowError.self) {
            _ = try await applier.plan(ListingDiff(entries: entries, remoteOnlyLocales: []),
                                       live: live, options: .init(createMissing: true))
        }
        #expect(await transport.exchanges.isEmpty)
    }

    // MARK: - category clears aren't expressible

    @Test("clearing a non-required category is refused — the payload can't say data:null")
    func categoryClearRefused() async throws {
        let (asc, _) = try scriptedConnect([])
        let applier = ListingApplier(asc: asc)
        let entries = [
            FieldDiff(field: .secondaryCategory, locale: nil, kind: .blocked, local: "", live: "GAMES"),
        ]
        let live = LiveListing(
            app: .init(id: "APP1", bundleId: "b", primaryLocale: "en-US", sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: "READY_FOR_SALE"), reviewDetailID: nil,
            localizationIDs: [:], values: ListingSnapshot(), demoAccountRequired: nil
        )
        await #expect(throws: WorkflowError.self) {
            _ = try await applier.plan(ListingDiff(entries: entries, remoteOnlyLocales: []),
                                       live: live, options: .init(allowClear: true))
        }
    }

    @Test("clearing a required field is refused even with --allow-clear")
    func requiredClearRefused() async throws {
        let (asc, _) = try scriptedConnect([])
        let applier = ListingApplier(asc: asc)
        let entries = [
            FieldDiff(field: .description, locale: "en-US", kind: .blocked, local: "", live: "x"),
        ]
        let live = LiveListing(
            app: .init(id: "APP1", bundleId: "b", primaryLocale: "en-US", sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: "READY_FOR_SALE"), reviewDetailID: nil,
            localizationIDs: ["en-US": .init(version: "VL1")], values: ListingSnapshot(), demoAccountRequired: nil
        )
        await #expect(throws: WorkflowError.self) {
            _ = try await applier.plan(ListingDiff(entries: entries, remoteOnlyLocales: []),
                                       live: live, options: .init(allowClear: true))
        }
    }

    // MARK: - malformed floor

    @Test("a non-numeric deployment floor is a config error, not a vacuous pass")
    func malformedFloor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR2-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "x", "MinimumOSVersion": "15.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Info.plist"))
        #expect(throws: WorkflowError.self) {
            _ = try Preflight.inspect(at: dir, floor: "fifteen")
        }
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
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: nil, sku: nil),
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

    // MARK: - metadata root containment

    @Test("a metadata root that escapes the working directory is refused")
    func rootEscape() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR2-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: WorkflowError.self) {
            _ = try ASCConfiguration.contained(base.appendingPathComponent("../outside"), under: base)
        }
        // An absolute --metadata path escapes too.
        #expect(throws: WorkflowError.self) {
            _ = try ASCConfiguration.contained(URL(fileURLWithPath: "/tmp"), under: base)
        }
        // And a ../ sequence in the config's metadataRoot resolves out of base.
        var config = ASCConfiguration()
        config.metadataRoot = "../outside"
        #expect(throws: WorkflowError.self) {
            _ = try config.metadataRootURL(relativeTo: base)
        }
        let inside = try ASCConfiguration.contained(base.appendingPathComponent("meta/x"), under: base)
        #expect(inside.path.hasPrefix(base.standardizedFileURL.path))
    }
}

// MARK: - Round 3: drift-vs-clear ordering, warning pass-through, root unknowns, missing versions

@Suite("Round 3 regression")
struct ReviewRound3Tests {
    func live(localized: [String: FieldValues]) -> LiveListing {
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
        let live = live(localized: ["en-US": [field: "drifted"]])
        var baseline = live.makeBaseline()
        baseline.digests[Baseline.digestKey(field: field, locale: "en-US")] = Baseline.digest(of: "old")
        return (live, baseline)
    }

    @Test func driftedEmptyIsConflictNotBlocked() {
        let (live, baseline) = driftedLive(field: .whatsNew)
        let local = MetadataTree(snapshot: ListingSnapshot(localized: ["en-US": [.whatsNew: ""]]))
        let diff = ListingDiffer.diff(local: local, live: live, baseline: baseline)
        // Empty local + drifted remote → conflict: --allow-clear alone must not authorize it.
        #expect(diff.entries.first?.kind == .conflict)
    }

    @Test func forcedEmptyConflictStillNeedsAllowClear() throws {
        let (live, baseline) = driftedLive(field: .whatsNew)
        let local = MetadataTree(snapshot: ListingSnapshot(localized: ["en-US": [.whatsNew: ""]]))
        let diff = ListingDiffer.diff(local: local, live: live, baseline: baseline)
        // --force answers the drift; writing "" is still a clear and needs --allow-clear too.
        let (asc, _) = try scriptedConnect([])
        #expect(throws: (any Error).self) {
            _ = try ListingApplier(asc: asc).plan(diff, live: live, options: .init(force: true))
        }
        let (writes, _) = try ListingApplier(asc: asc).plan(
            diff, live: live, options: .init(force: true, allowClear: true)
        )
        #expect(writes.count == 1)
    }

    @Test func advisoryWarningDoesNotBlockWrite() throws {
        let live = live(localized: ["en-US": [.keywords: "a"]])
        let baseline = live.makeBaseline()
        let local = MetadataTree(snapshot: ListingSnapshot(localized: ["en-US": [.keywords: "one; two; three"]]))
        let diff = ListingDiffer.diff(local: local, live: live, baseline: baseline)
        // ";" in keywords is a warning, not an error — it must not abort the write.
        let (asc, _) = try scriptedConnect([])
        let (writes, _) = try ListingApplier(asc: asc).plan(diff, live: live, options: .init())
        #expect(writes.count == 1)
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

    @Test func executableBundleMissingVersionFlagged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR3-\(UUID().uuidString)", isDirectory: true)
        // Both bundles lack the version key — previously each collapsed to "?" and the
        // equality check passed silently. Now each must get its own explicit finding.
        for path in ["App.app", "App.app/PlugIns/Widget.appex"] {
            let dir = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleIdentifier": "com.example.\(dir.lastPathComponent)",
                "CFBundleVersion": "7",
                "MinimumOSVersion": "15.0",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: dir.appendingPathComponent("Info.plist"))
            try "<plist><dict/></plist>".write(
                to: dir.appendingPathComponent("PrivacyInfo.xcprivacy"), atomically: true, encoding: .utf8
            )
        }
        let report = try Preflight.inspect(at: root.appendingPathComponent("App.app"), floor: "15.0")
        let missing = report.findings.filter { if case .missingVersion = $0 { true } else { false } }
        #expect(missing.count == 2)
    }
}

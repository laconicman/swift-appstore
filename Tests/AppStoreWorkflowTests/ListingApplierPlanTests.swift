import Foundation
import Testing
@testable import AppStoreKit
@testable import AppStoreWorkflow

/// `ListingApplier.plan` gates — all evaluated before the first write. The transport is never
/// called; the plan is pure.
@Suite("ListingApplier planning gates")
struct ListingApplierPlanTests {
    func makeApplier() throws -> ListingApplier {
        let (asc, _) = try scriptedConnect([])
        return ListingApplier(asc: asc)
    }

    func live(versionState: String = "PREPARE_FOR_SUBMISSION", appInfoState: String? = "READY_FOR_SALE") -> LiveListing {
        LiveListing(
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: "en-US", sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: versionState),
            appInfo: .init(id: "I1", appStoreState: appInfoState),
            reviewDetailID: "RD1",
            localizationIDs: ["en-US": .init(version: "VL1", appInfo: "AIL1")],
            values: ListingSnapshot(),
            demoAccountRequired: nil
        )
    }

    func diff(_ entries: [FieldDiff]) -> ListingDiff {
        ListingDiff(entries: entries, remoteOnlyLocales: [])
    }

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

    @Test("conflict refuses without --force")
    func conflictGate() throws {
        let applier = try makeApplier()
        // A version-localization field: the fixture's version is editable (its appInfo is not,
        // and a forced conflict must still respect that gate — name would throw here).
        let d = diff([FieldDiff(field: .description, locale: "en-US", kind: .conflict, local: "a", live: "b")])
        #expect(throws: WorkflowError.self) {
            _ = try applier.plan(d, live: live(), options: .init())
        }
        // With force the same entry becomes a grouped write.
        let (writes, _) = try applier.plan(d, live: live(), options: .init(force: true))
        #expect(writes.count == 1)
    }

    @Test("empty-file clear refuses without --allow-clear")
    func blockedGate() throws {
        let applier = try makeApplier()
        // whatsNew is not a required field — clearing it is a legal write once allowed.
        // (A required field like description stays refused even under --allow-clear.)
        let d = diff([FieldDiff(field: .whatsNew, locale: "en-US", kind: .blocked, local: "", live: "b")])
        #expect(throws: WorkflowError.self) {
            _ = try applier.plan(d, live: live(), options: .init())
        }
        let (writes, _) = try applier.plan(d, live: live(), options: .init(allowClear: true))
        #expect(writes.count == 1)
    }

    @Test("version-localization writes refuse while the version state isn't editable")
    func editableStateGate() throws {
        let applier = try makeApplier()
        let d = diff([FieldDiff(field: .description, locale: "en-US", kind: .change, local: "new", live: "old")])
        #expect(throws: WorkflowError.self) {
            _ = try applier.plan(d, live: live(versionState: "READY_FOR_SALE"), options: .init())
        }
    }

    @Test("editableAnytime fields bypass the state gate (promo text, copyright, review)")
    func anytimeFields() throws {
        let applier = try makeApplier()
        let d = diff([
            FieldDiff(field: .promotionalText, locale: "en-US", kind: .change, local: "promo", live: "old"),
            FieldDiff(field: .copyright, locale: nil, kind: .change, local: "2026", live: "2025"),
            FieldDiff(field: .contactEmail, locale: nil, kind: .change, local: "a@b.c", live: "x@y.z"),
        ])
        // Version is READY_FOR_SALE — not editable — but all three fields are anytime-editable.
        let (writes, _) = try applier.plan(d, live: live(versionState: "READY_FOR_SALE"), options: .init())
        #expect(writes.count == 3)
    }

    @Test("create entries are skipped unless --create-missing")
    func createGate() throws {
        let applier = try makeApplier()
        let d = diff([FieldDiff(field: .name, locale: "de-DE", kind: .create, local: "Name", live: nil)])
        let editable = live(appInfoState: "PREPARE_FOR_SUBMISSION")
        let (writes, result) = try applier.plan(d, live: editable, options: .init())
        #expect(writes.isEmpty)
        #expect(result.skipped.count == 1)

        let (writes2, _) = try applier.plan(d, live: editable, options: .init(createMissing: true))
        #expect(writes2.count == 1)
        guard case .appInfoLocalizationCreate(let appInfoID, let locale, _) = writes2[0] else {
            Issue.record("expected appInfoLocalizationCreate, got \(writes2[0])")
            return
        }
        #expect(appInfoID == "I1")
        #expect(locale == "de-DE")
    }

    @Test("two changed fields on one target+locale batch into a single PATCH")
    func batching() throws {
        let applier = try makeApplier()
        let d = diff([
            FieldDiff(field: .description, locale: "en-US", kind: .change, local: "d", live: "old"),
            FieldDiff(field: .keywords, locale: "en-US", kind: .change, local: "k", live: "old"),
            FieldDiff(field: .supportUrl, locale: "en-US", kind: .change, local: "https://s", live: "old"),
        ])
        let (writes, _) = try applier.plan(d, live: live(), options: .init())
        #expect(writes.count == 1)
        guard case .versionLocalizationUpdate(let id, let locale, let values) = writes[0] else {
            Issue.record("expected versionLocalizationUpdate, got \(writes[0])")
            return
        }
        #expect(id == "VL1")
        #expect(locale == "en-US")
        #expect(values.count == 3)
    }

    @Test("copyright change maps to a versionUpdate write")
    func versionWrite() throws {
        let applier = try makeApplier()
        let d = diff([FieldDiff(field: .copyright, locale: nil, kind: .change, local: "2026", live: "2025")])
        let (writes, _) = try applier.plan(d, live: live(), options: .init())
        guard case .versionUpdate(let id, let copyright) = writes.first else {
            Issue.record("expected versionUpdate")
            return
        }
        #expect(id == "V1")
        #expect(copyright == "2026")
    }

    @Test("review-detail change without a remote row is a create gated on --create-missing")
    func reviewDetailCreate() throws {
        let applier = try makeApplier()
        var listing = live()
        listing.reviewDetailID = nil
        let d = diff([FieldDiff(field: .reviewNotes, locale: nil, kind: .create, local: "notes", live: nil)])
        let (writes, _) = try applier.plan(d, live: listing, options: .init(createMissing: true))
        guard case .reviewDetailCreate(let versionID, _) = writes.first else {
            Issue.record("expected reviewDetailCreate")
            return
        }
        #expect(versionID == "V1")
    }

    // MARK: - force/allow-clear can't bypass the gates

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
        let live = liveListing(localized: ["en-US": [.keywords: "a"]])
        let baseline = live.makeBaseline()
        let local = MetadataTree(snapshot: ListingSnapshot(localized: ["en-US": [.keywords: "one; two; three"]]))
        let diff = ListingDiffer.diff(local: local, live: live, baseline: baseline)
        // ";" in keywords is a warning, not an error — it must not abort the write.
        let (asc, _) = try scriptedConnect([])
        let (writes, _) = try ListingApplier(asc: asc).plan(diff, live: live, options: .init())
        #expect(writes.count == 1)
    }
}

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

    @Test("conflict refuses without --force")
    func conflictGate() throws {
        let applier = try makeApplier()
        let d = diff([FieldDiff(field: .name, locale: "en-US", kind: .conflict, local: "a", live: "b")])
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
        let d = diff([FieldDiff(field: .description, locale: "en-US", kind: .blocked, local: "", live: "b")])
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
}

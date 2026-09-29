import Foundation
import Testing
@testable import AppStoreWorkflow

/// `asc submit` — the staging half of the submission pipeline. Everything runs over a
/// scripted transport: no network, and every POST/PATCH the plan emits is inspectable.
@Suite("SubmissionStager over a scripted transport")
struct SubmissionStagingTests {
    static let appJSON = #"""
    {"data":{"type":"apps","id":"APP1","attributes":{
      "bundleId":"com.example.app","name":"Example","primaryLocale":"en-US","sku":"SKU1"}},
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/APP1"}}
    """#

    static func versionsJSON(_ entries: String) -> String { """
    {"data":[\(entries)],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/APP1/appStoreVersions"}}
    """ }

    static let editableVersion = #"""
    {"type":"appStoreVersions","id":"V_EDIT","attributes":{
      "versionString":"1.2.2","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}
    """#
    static let liveVersion = #"""
    {"type":"appStoreVersions","id":"V_LIVE","attributes":{
      "versionString":"1.2.1","platform":"IOS","appStoreState":"READY_FOR_SALE"}}
    """#
    static let acceptedVersion = #"""
    {"type":"appStoreVersions","id":"V_ACC","attributes":{
      "versionString":"1.2.2","platform":"IOS","appStoreState":"ACCEPTED"}}
    """#

    static let buildsJSON = #"""
    {"data":[{"type":"builds","id":"B1","attributes":{
      "version":"9","processingState":"VALID","expired":false,"uploadedDate":"2026-09-20T10:00:00Z","minOsVersion":"15.0"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/builds"}}
    """#
    static let buildsHighMinOSJSON = #"""
    {"data":[{"type":"builds","id":"B1","attributes":{
      "version":"9","processingState":"VALID","expired":false,"uploadedDate":"2026-09-20T10:00:00Z","minOsVersion":"17.0"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/builds"}}
    """#
    static let buildsLowMinOSJSON = #"""
    {"data":[{"type":"builds","id":"B1","attributes":{
      "version":"9","processingState":"VALID","expired":false,"uploadedDate":"2026-09-20T10:00:00Z","minOsVersion":"14.0"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/builds"}}
    """#
    static let noBuildsJSON = #"""
    {"data":[], "links":{"self":"https://api.appstoreconnect.apple.com/v1/builds"}}
    """#

    static let noSubmissionsJSON = #"""
    {"data":[], "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions"}}
    """#
    static let inFlightSubmissionJSON = #"""
    {"data":[{"type":"reviewSubmissions","id":"RS1","attributes":{"platform":"IOS","state":"WAITING_FOR_REVIEW"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions"}}
    """#
    static let draftSubmissionJSON = #"""
    {"data":[{"type":"reviewSubmissions","id":"RS_DRAFT","attributes":{"platform":"IOS","state":"READY_FOR_REVIEW"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions"}}
    """#
    static let draftItemsJSON = #"""
    {"data":[{"type":"reviewSubmissionItems","id":"RSI1","attributes":{"state":"READY_FOR_REVIEW"},
      "relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V_EDIT"}}}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions/RS_DRAFT/items"}}
    """#
    static let draftItemsBothVersionsJSON = #"""
    {"data":[{"type":"reviewSubmissionItems","id":"RSI_OLD","attributes":{"state":"READY_FOR_REVIEW"},
       "relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V_OTHER"}}}},
      {"type":"reviewSubmissionItems","id":"RSI_NEW","attributes":{"state":"READY_FOR_REVIEW"},
       "relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V_EDIT"}}}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions/RS_DRAFT/items"}}
    """#
    static let draftItemsTwoStaleJSON = #"""
    {"data":[{"type":"reviewSubmissionItems","id":"RSI_A","attributes":{"state":"READY_FOR_REVIEW"},
       "relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V_A"}}}},
      {"type":"reviewSubmissionItems","id":"RSI_B","attributes":{"state":"READY_FOR_REVIEW"},
       "relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V_B"}}}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions/RS_DRAFT/items"}}
    """#
    static let draftItemsOtherVersionJSON = #"""
    {"data":[{"type":"reviewSubmissionItems","id":"RSI1","attributes":{"state":"READY_FOR_REVIEW"},
      "relationships":{"appStoreVersion":{"data":{"type":"appStoreVersions","id":"V_OTHER"}}}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions/RS_DRAFT/items"}}
    """#
    static let emptyItemsJSON = #"""
    {"data":[], "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions/RS_DRAFT/items"}}
    """#

    static let attachedBuildJSON = #"""
    {"data":{"type":"builds","id":"B1"},
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersions/V_EDIT/build"}}
    """#
    static let otherBuildJSON = #"""
    {"data":{"type":"builds","id":"B_OLD"},
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersions/V_EDIT/build"}}
    """#
    static let noBuildAttached = #"""
    {"errors":[{"status":"404","code":"NOT_FOUND","title":"Not Found","detail":"no build"}]}
    """#

    static let createdVersionJSON = #"""
    {"data":{"type":"appStoreVersions","id":"V_NEW","attributes":{
      "versionString":"1.3.0","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}},
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersions/V_NEW"}}
    """#
    static let createdSubmissionJSON = #"""
    {"data":{"type":"reviewSubmissions","id":"RS_NEW","attributes":{"platform":"IOS","state":"READY_FOR_REVIEW"}},
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissions/RS_NEW"}}
    """#
    static let createdItemJSON = #"""
    {"data":{"type":"reviewSubmissionItems","id":"RSI_NEW","attributes":{"state":"READY_FOR_REVIEW"}},
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/reviewSubmissionItems/RSI_NEW"}}
    """#

    // MARK: plan

    @Test("plan previews a full stage: existing version, attach build, new draft, one item")
    func planHappyPath() async throws {
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion + "," + Self.liveVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.otherBuildJSON),
        ])
        let plan = try await SubmissionStager(asc: asc).plan(
            appID: "APP1", bundleId: nil, platform: "IOS",
            request: .init(versionString: "1.2.2"))
        #expect(plan.versionAction == .useExisting(id: "V_EDIT", versionString: "1.2.2", state: "PREPARE_FOR_SUBMISSION"))
        #expect(plan.buildID == "B1")
        #expect(plan.buildAttachNeeded)
        #expect(plan.draftID == nil)
        #expect(plan.inFlightState == nil)
        #expect(plan.blockedReasons.isEmpty)
        #expect(plan.steps.contains { $0.contains("attach") })
        #expect(plan.steps.contains { $0.contains("create review submission draft") })
        #expect(plan.steps.contains { $0.contains("stage item: appStoreVersion") })
        #expect(plan.steps.last?.contains("never sent") == true)
    }

    @Test("a non-editable exact version match is a hard stop, not a plan")
    func planNonEditableExact() async throws {
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.liveVersion)),
            .json(.ok, Self.noSubmissionsJSON),
        ])
        await #expect(throws: WorkflowError.self) {
            _ = try await SubmissionStager(asc: asc).plan(
                appID: "APP1", bundleId: nil, platform: "IOS",
                request: .init(versionString: "1.2.1"))
        }
    }

    @Test("an in-flight submission surfaces as a blocked plan, never as staged steps")
    func planInFlight() async throws {
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.inFlightSubmissionJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.otherBuildJSON),
        ])
        let plan = try await SubmissionStager(asc: asc).plan(
            appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        #expect(plan.inFlightState == "WAITING_FOR_REVIEW")
        #expect(!plan.blockedReasons.isEmpty)
    }

    @Test("a build below the floor blocks; above it warns and still stages")
    func planBuildFloorMismatch() async throws {
        // Below the floor is the 90068 class (Preflight's direction) — a blocker.
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsLowMinOSJSON),
            .json(.ok, Self.otherBuildJSON),
        ])
        let below = try await SubmissionStager(asc: asc).plan(
            appID: "APP1", bundleId: nil, platform: "IOS",
            minimumOSVersion: "15.0", request: .init())
        #expect(below.buildBelowFloor != nil)
        #expect(below.blockedReasons.contains { $0.contains("90068") })
        #expect(below.floorDrift == nil && below.warnings.isEmpty)

        // Above the floor is stale config — a warning line, and --yes stages normally.
        let (asc2, transport2) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsHighMinOSJSON),
            .json(.ok, Self.otherBuildJSON),
            .json(.ok, Self.noSubmissionsJSON),           // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)), // version drift check
            .json(.ok, Self.buildsHighMinOSJSON),          // eligibility re-query
            .json(.ok, Self.otherBuildJSON),               // live attached-build read
            .respond(.init(status: .noContent), body: nil), // build attach PATCH
            .json(.created, Self.createdSubmissionJSON),
            .json(.created, Self.createdItemJSON),
        ])
        let stager2 = SubmissionStager(asc: asc2)
        let above = try await stager2.plan(
            appID: "APP1", bundleId: nil, platform: "IOS",
            minimumOSVersion: "15.0", request: .init())
        #expect(above.buildBelowFloor == nil)
        #expect(above.blockedReasons.isEmpty)
        #expect(above.floorDrift?.contains("stale") == true)
        #expect(above.warnings.count == 1)
        let result = await stager2.stage(above, request: .init())
        #expect(result.ok, "a warned plan still stages")
        let ops = await transport2.operationIDs
        #expect(ops.contains("reviewSubmissionItems_createInstance"))

        // An exact match neither blocks nor warns.
        let (asc3, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.otherBuildJSON),
        ])
        let exact = try await SubmissionStager(asc: asc3).plan(
            appID: "APP1", bundleId: nil, platform: "IOS",
            minimumOSVersion: "15.0", request: .init())
        #expect(exact.buildBelowFloor == nil && exact.floorDrift == nil)
        #expect(exact.blockedReasons.isEmpty && exact.warnings.isEmpty)
    }

    @Test("no editable version + no --version is a config error, not a guess")
    func planNoEditableNoVersion() async throws {
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.liveVersion)),
            .json(.ok, Self.noSubmissionsJSON),
        ])
        await #expect(throws: WorkflowError.self) {
            _ = try await SubmissionStager(asc: asc).plan(
                appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        }
    }

    // MARK: stage

    @Test("stage: PATCH build, create draft, post the version item — in that order")
    func stageHappyPath() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.otherBuildJSON),
            .json(.ok, Self.noSubmissionsJSON),           // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)), // version drift check
            .json(.ok, Self.buildsJSON),                   // eligibility re-query
            .json(.ok, Self.otherBuildJSON),               // live attached-build read
            .respond(.init(status: .noContent), body: nil),
            .json(.created, Self.createdSubmissionJSON),
            .json(.created, Self.createdItemJSON),
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        let result = await stager.stage(plan, request: .init())
        #expect(result.ok)
        #expect(result.draftID == "RS_NEW")
        let ops = await transport.operationIDs
        #expect(ops.contains("appStoreVersions_build_updateToOneRelationship"))
        #expect(ops.contains("reviewSubmissions_createInstance"))
        #expect(ops.contains("reviewSubmissionItems_createInstance"))
        #expect(!ops.contains("appStoreVersions_createInstance"))
        // The build query must be scoped to the target release + App Store audience.
        let buildsReq = await transport.exchanges.first { $0.operationID == "builds_getCollection" }
        let path = buildsReq?.request.path ?? ""
        #expect(path.contains("filter%5BbuildAudienceType%5D=APP_STORE_ELIGIBLE"))
        #expect(path.contains("filter%5BpreReleaseVersion.version%5D=1.2.2"))
        #expect(path.contains("filter%5BpreReleaseVersion.platform%5D=IOS"))
    }

    @Test("stage creates the version when none is editable, then attaches the build")
    func stageCreatesVersion() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.liveVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.noSubmissionsJSON),           // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.liveVersion)), // drift: still no editable
            .json(.ok, Self.buildsJSON),                   // eligibility re-query
            .json(.created, Self.createdVersionJSON),
            .json(.notFound, Self.noBuildAttached),        // fresh version carries none
            .respond(.init(status: .noContent), body: nil),
            .json(.created, Self.createdSubmissionJSON),
            .json(.created, Self.createdItemJSON),
        ])
        let stager = SubmissionStager(asc: asc)
        let request = SubmissionRequest(versionString: "1.3.0")
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: request)
        #expect(plan.versionAction == .create(versionString: "1.3.0"))
        #expect(plan.buildAttachNeeded, "a fresh version has no build — attach must run")
        let result = await stager.stage(plan, request: request)
        #expect(result.ok)
        let ops = await transport.operationIDs
        let createIdx = ops.firstIndex(of: "appStoreVersions_createInstance")
        let attachIdx = ops.firstIndex(of: "appStoreVersions_build_updateToOneRelationship")
        #expect(createIdx != nil && attachIdx != nil && createIdx! < attachIdx!)
    }

    @Test("an in-flight submission fails stage before any write")
    func stageRefusesInFlight() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.inFlightSubmissionJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.otherBuildJSON),
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        let readsBefore = await transport.exchanges.count
        let result = await stager.stage(plan, request: .init())
        #expect(!result.ok)
        #expect(result.failed?.contains("WAITING_FOR_REVIEW") == true)
        #expect(await transport.exchanges.count == readsBefore, "a blocked stage must issue no requests")
    }

    @Test("stage aborts without writes when a submission goes in-flight after the preview")
    func stageRechecksInFlight() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.noSubmissionsJSON),           // plan: nothing in flight
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.otherBuildJSON),
            .json(.ok, Self.inFlightSubmissionJSON),      // recheck: now WAITING_FOR_REVIEW
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        #expect(plan.blockedReasons.isEmpty)
        let readsBefore = await transport.exchanges.count
        let result = await stager.stage(plan, request: .init())
        #expect(!result.ok)
        #expect(result.failed?.contains("WAITING_FOR_REVIEW") == true)
        // Only the recheck GET ran — zero writes.
        let post = await transport.exchanges.dropFirst(readsBefore)
        #expect(post.count == 1)
        #expect(post.allSatisfy { $0.request.method == .get })
    }

    @Test("restaging a draft that already carries the version item skips the POST")
    func stageIdempotentItems() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.draftSubmissionJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.draftItemsJSON),
            .json(.ok, Self.attachedBuildJSON),
            .json(.ok, Self.draftSubmissionJSON),         // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)), // version drift check
            .json(.ok, Self.buildsJSON),                   // eligibility re-query
            .json(.ok, Self.draftItemsJSON),              // prefetched items
            .json(.ok, Self.attachedBuildJSON),            // already attached — skip PATCH
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        #expect(plan.draftID == "RS_DRAFT")
        #expect(plan.alreadyStaged.contains("appStoreVersion:V_EDIT"))
        let result = await stager.stage(plan, request: .init())
        #expect(result.ok)
        let ops = await transport.operationIDs
        #expect(!ops.contains("reviewSubmissionItems_createInstance"))
        #expect(!ops.contains("reviewSubmissions_createInstance"))
    }

    @Test("a draft staging a different version's item gets it replaced (POST + DELETE)")
    func stageVersionItemRepoint() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.draftSubmissionJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.draftItemsOtherVersionJSON),
            .json(.ok, Self.attachedBuildJSON),
            .json(.ok, Self.draftSubmissionJSON),         // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)), // version drift check
            .json(.ok, Self.buildsJSON),                   // eligibility re-query
            .json(.ok, Self.draftItemsOtherVersionJSON),  // prefetched items
            .json(.ok, Self.attachedBuildJSON),            // already attached — skip PATCH
            .json(.created, Self.createdItemJSON),         // POST ours FIRST
            .respond(.init(status: .noContent), body: nil), // then DELETE the stale item
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        #expect(plan.versionItemRepoint == "V_OTHER")
        #expect(plan.steps.contains { $0.contains("replace staged version item V_OTHER") })
        #expect(plan.blockedReasons.isEmpty, "a replaceable item is a step, not a block")
        let result = await stager.stage(plan, request: .init())
        #expect(result.ok)
        let ops = await transport.operationIDs
        let delIdx = ops.firstIndex(of: "reviewSubmissionItems_deleteInstance")
        let postIdx = ops.lastIndex(of: "reviewSubmissionItems_createInstance")
        #expect(delIdx != nil && postIdx != nil && postIdx! < delIdx!,
                "POST before DELETE — a rejected POST leaves the old item intact")
        #expect(result.staged.contains { $0.contains("removed stale version item") })
    }

    @Test("a draft created between preview and --yes is reused, not duplicated")
    func stageReusesConcurrentDraft() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.noSubmissionsJSON),            // plan: no draft
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.attachedBuildJSON),
            .json(.ok, Self.draftSubmissionJSON),          // recheck: Bob's draft appeared
            .json(.ok, Self.versionsJSON(Self.editableVersion)), // version drift check
            .json(.ok, Self.buildsJSON),                   // eligibility re-query
            .json(.ok, Self.emptyItemsJSON),               // its items
            .json(.ok, Self.attachedBuildJSON),            // already attached — skip PATCH
            .json(.created, Self.createdItemJSON),
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        #expect(plan.draftID == nil)
        let result = await stager.stage(plan, request: .init())
        #expect(result.ok)
        #expect(result.draftID == "RS_DRAFT", "the concurrent draft is reused")
        let ops = await transport.operationIDs
        #expect(!ops.contains("reviewSubmissions_createInstance"), "no second draft")
    }

    @Test("repeated product ids post one item each")
    func stageDedupesProductIDs() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.attachedBuildJSON),
            .json(.ok, Self.noSubmissionsJSON),            // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)), // version drift check
            .json(.ok, Self.buildsJSON),                   // eligibility re-query
            .json(.ok, Self.attachedBuildJSON),            // already attached — skip PATCH
            .json(.created, Self.createdSubmissionJSON),
            .json(.created, Self.createdItemJSON),           // appStoreVersion item
            .json(.created, Self.createdItemJSON),           // IAP1
            .json(.created, Self.createdItemJSON),           // IAP2
        ])
        let request = SubmissionRequest(iapVersionIDs: ["IAP1", "IAP1", "IAP2", "IAP2"])
        #expect(request.iapVersionIDs == ["IAP1", "IAP2"])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: request)
        let result = await stager.stage(plan, request: request)
        #expect(result.ok)
        let itemPosts = await transport.exchanges.filter { $0.operationID == "reviewSubmissionItems_createInstance" }
        #expect(itemPosts.count == 3, "version item + two distinct IAPs — duplicates deduped")
    }

    @Test("the floor check reads the platform's own minimum — lsMinimumSystemVersion on macOS")
    func planMacOSFloor() async throws {
        let macBuild = #"""
        {"data":[{"type":"builds","id":"B1","attributes":{
          "version":"3","processingState":"VALID","expired":false,"lsMinimumSystemVersion":"15.0"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/builds"}}
        """#
        // Declared minimum under the floor but computed above it — the higher must win.
        let macSplitBuild = #"""
        {"data":[{"type":"builds","id":"B1","attributes":{
          "version":"3","processingState":"VALID","expired":false,
          "lsMinimumSystemVersion":"14.0","computedMinMacOsVersion":"15.0"}}],
         "links":{"self":"https://api.appstoreconnect.apple.com/v1/builds"}}
        """#
        let macVersion = #"""
        {"type":"appStoreVersions","id":"V_MAC","attributes":{
          "versionString":"1.2.2","platform":"MAC_OS","appStoreState":"PREPARE_FOR_SUBMISSION"}}
        """#
        // A 16.0 floor keeps both cases *below* it — the 90068 direction, so they
        // remain blocks. The split build must report 15.0, not 14.0: the higher of
        // declared and computed is what the floor is compared against.
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(macVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, macBuild),
            .json(.ok, Self.attachedBuildJSON),
        ])
        let plan = try await SubmissionStager(asc: asc).plan(
            appID: "APP1", bundleId: nil, platform: "MAC_OS",
            minimumOSVersion: "16.0", request: .init())
        #expect(plan.buildBelowFloor != nil, "macOS build at 15.0 against a 16.0 floor must block")

        let (asc2, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(macVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, macSplitBuild),
            .json(.ok, Self.attachedBuildJSON),
        ])
        let plan2 = try await SubmissionStager(asc: asc2).plan(
            appID: "APP1", bundleId: nil, platform: "MAC_OS",
            minimumOSVersion: "16.0", request: .init())
        #expect(plan2.buildBelowFloor?.contains("15.0") == true,
                "computed 15.0 must be the compared minimum even when declared says 14.0")
    }

    @Test("a build that expired between preview and --yes aborts before the attach")
    func stageRefusesExpiredBuild() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.otherBuildJSON),
            .json(.ok, Self.noSubmissionsJSON),           // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)), // version drift check
            .json(.ok, Self.noBuildsJSON),                 // B1 dropped out of the eligible set
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        let readsBefore = await transport.exchanges.count
        let result = await stager.stage(plan, request: .init())
        #expect(!result.ok)
        #expect(result.failed?.contains("no longer in the VALID+unexpired+APP_STORE_ELIGIBLE set") == true)
        // Only the three gate re-reads ran — zero writes, no renamed/created version left behind.
        #expect(await transport.exchanges.dropFirst(readsBefore).allSatisfy { $0.request.method == .get })
    }

    @Test("an ACCEPTED version is not repurposed — a new version is created instead")
    func planAcceptedCreatesNew() async throws {
        // ACCEPTED is metadata-editable but committed to its release: asking for a new
        // version must create one, never rename the approved one.
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.acceptedVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsJSON),
        ])
        let plan = try await SubmissionStager(asc: asc).plan(
            appID: "APP1", bundleId: nil, platform: "IOS",
            request: .init(versionString: "1.3.0"))
        #expect(plan.versionAction == .create(versionString: "1.3.0"))
        // And with no --version, an approved-only listing is a config error, not a reuse.
        let (asc2, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.acceptedVersion)),
            .json(.ok, Self.noSubmissionsJSON),
        ])
        await #expect(throws: WorkflowError.self) {
            try await SubmissionStager(asc: asc2).plan(
                appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        }
    }

    @Test("a draft with two stale version items loses both, posting the target once")
    func stageDeletesEveryStaleItem() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.draftSubmissionJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.draftItemsTwoStaleJSON),
            .json(.ok, Self.attachedBuildJSON),
            .json(.ok, Self.draftSubmissionJSON),          // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.draftItemsTwoStaleJSON),       // prefetched items
            .json(.ok, Self.attachedBuildJSON),
            .json(.created, Self.createdItemJSON),          // POST target once
            .respond(.init(status: .noContent), body: nil), // DELETE RSI_A
            .respond(.init(status: .noContent), body: nil), // DELETE RSI_B
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        // The preview names both stale items — it must not understate what --yes removes.
        #expect(plan.steps.contains { $0.hasPrefix("replace staged version item V_A") })
        #expect(plan.steps.contains { $0 == "remove stale version item V_B" })
        let result = await stager.stage(plan, request: .init())
        #expect(result.ok)
        let ops = await transport.operationIDs
        #expect(ops.filter { $0 == "reviewSubmissionItems_deleteInstance" }.count == 2)
        #expect(ops.filter { $0 == "reviewSubmissionItems_createInstance" }.count == 1)
    }

    @Test("a draft holding both version items loses the stale one without a second POST")
    func stageBothItemsDeletesOnly() async throws {
        // A prior run POSTed the target item but died before the DELETE — restaging must
        // delete the stale item, not re-POST a duplicate.
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.draftSubmissionJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.draftItemsBothVersionsJSON),
            .json(.ok, Self.attachedBuildJSON),
            .json(.ok, Self.draftSubmissionJSON),          // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.draftItemsBothVersionsJSON),   // prefetched items
            .json(.ok, Self.attachedBuildJSON),
            .respond(.init(status: .noContent), body: nil), // DELETE RSI_OLD only
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        let result = await stager.stage(plan, request: .init())
        #expect(result.ok)
        #expect(result.staged.contains { $0.contains("removed stale version item") })
        let ops = await transport.operationIDs
        #expect(!ops.contains("reviewSubmissionItems_createInstance"),
                "target item is already staged — no second POST")
        #expect(ops.contains("reviewSubmissionItems_deleteInstance"))
    }

    @Test("a version renamed between preview and --yes aborts without writes")
    func stageAbortsOnVersionDrift() async throws {
        let renamed = #"""
        {"type":"appStoreVersions","id":"V_EDIT","attributes":{
          "versionString":"1.2.3","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}
        """#
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.attachedBuildJSON),
            .json(.ok, Self.noSubmissionsJSON),            // in-flight recheck
            .json(.ok, Self.versionsJSON(renamed)),        // 1.2.2 → 1.2.3 since preview
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: .init())
        let readsBefore = await transport.exchanges.count
        let result = await stager.stage(plan, request: .init())
        #expect(!result.ok)
        #expect(result.failed?.contains("renamed 1.2.2 → 1.2.3") == true)
        #expect(await transport.exchanges.dropFirst(readsBefore).allSatisfy { $0.request.method == .get })
    }

    @Test("a planned create aborts when an editable version appeared since the preview")
    func stageCreateAbortsOnNewEditable() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.liveVersion)),
            .json(.ok, Self.noSubmissionsJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.noSubmissionsJSON),            // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)), // someone created 1.2.2
        ])
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(
            appID: "APP1", bundleId: nil, platform: "IOS",
            request: .init(versionString: "1.3.0"))
        let readsBefore = await transport.exchanges.count
        let result = await stager.stage(plan, request: .init())
        #expect(!result.ok)
        #expect(result.failed?.contains("editable version") == true)
        #expect(await transport.exchanges.dropFirst(readsBefore).allSatisfy { $0.request.method == .get })
    }

    @Test("a versioned IAP id stages an inAppPurchaseVersion item, not the unversioned type")
    func stageIAPVersionItem() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.versionsJSON(Self.editableVersion)),
            .json(.ok, Self.draftSubmissionJSON),
            .json(.ok, Self.buildsJSON),
            .json(.ok, Self.draftItemsJSON),
            .json(.ok, Self.attachedBuildJSON),
            .json(.ok, Self.draftSubmissionJSON),         // in-flight recheck
            .json(.ok, Self.versionsJSON(Self.editableVersion)), // version drift check
            .json(.ok, Self.buildsJSON),                   // eligibility re-query
            .json(.ok, Self.draftItemsJSON),              // prefetched items
            .json(.ok, Self.attachedBuildJSON),            // already attached — skip PATCH
            .json(.created, Self.createdItemJSON),
        ])
        let stager = SubmissionStager(asc: asc)
        let request = SubmissionRequest(iapVersionIDs: ["IAPV1"])
        let plan = try await stager.plan(appID: "APP1", bundleId: nil, platform: "IOS", request: request)
        let result = await stager.stage(plan, request: request)
        #expect(result.ok)
        #expect(result.staged.contains { $0.contains("inAppPurchaseVersion IAPV1") })
        let writes = await transport.exchanges.filter { $0.operationID == "reviewSubmissionItems_createInstance" }
        let body = String(data: writes.last?.body ?? Data(), encoding: .utf8) ?? ""
        #expect(body.contains("\"inAppPurchaseVersions\""))
        #expect(!body.contains("\"inAppPurchase\""))
    }
}

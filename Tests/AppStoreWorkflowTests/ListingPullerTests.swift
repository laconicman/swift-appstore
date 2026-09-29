import Foundation
import HTTPTypes
import Testing
@testable import AppStoreKit
@testable import AppStoreWorkflow

/// `ListingPuller.pull` end to end over a scripted transport — the full read path resolves the
/// app, picks the editable version, collects both localization sets and the review detail, and
/// normalizes everything into a `LiveListing`. Nothing talks to Apple.
@Suite("ListingPuller over a scripted transport")
struct ListingPullerTests {
    static let appJSON = #"""
    {"data":{"type":"apps","id":"APP1","attributes":{
      "bundleId":"com.example.app","name":"Example","primaryLocale":"en-US","sku":"SKU1"}}, "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/APP1"}}
    """#

    static let appInfosJSON = #"""
    {"data":[{"type":"appInfos","id":"I1","attributes":{"appStoreState":"READY_FOR_SALE"},
      "relationships":{"primaryCategory":{"data":{"type":"appCategories","id":"EDUCATION"}}}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/APP1/appInfos"}}
    """#

    static let versionsJSON = #"""
    {"data":[
      {"type":"appStoreVersions","id":"V_LIVE","attributes":{
        "versionString":"1.2.1","platform":"IOS","appStoreState":"READY_FOR_SALE","copyright":"2024 Laconic"}},
      {"type":"appStoreVersions","id":"V_EDIT","attributes":{
        "versionString":"1.2.2","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION","copyright":"2025 Laconic"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/APP1/appStoreVersions"}}
    """#

    static let versionLocalizationsJSON = #"""
    {"data":[{"type":"appStoreVersionLocalizations","id":"VL1","attributes":{
      "locale":"en-US","description":"Live desc","keywords":"a,b","whatsNew":"fixes",
      "promotionalText":"promo","supportUrl":"https://example.com/help","marketingUrl":null}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersions/V_EDIT/appStoreVersionLocalizations"}}
    """#

    static let appInfoLocalizationsJSON = #"""
    {"data":[{"type":"appInfoLocalizations","id":"AIL1","attributes":{
      "locale":"en-US","name":"Live Name","subtitle":"Live Sub",
      "privacyPolicyUrl":"https://example.com/privacy","privacyChoicesUrl":null,"privacyPolicyText":null}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appInfos/I1/appInfoLocalizations"}}
    """#

    static let reviewDetailJSON = #"""
    {"data":{"type":"appStoreReviewDetails","id":"RD1","attributes":{
      "contactFirstName":"A","contactLastName":"B","contactEmail":"r@example.com",
      "contactPhone":"+1 555 0100","demoAccountName":null,"demoAccountRequired":false,
      "notes":"notes here"}}, "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersions/V_EDIT/appStoreReviewDetail"}}
    """#

    static let notFoundJSON = #"""
    {"errors":[{"status":"404","code":"NOT_FOUND","title":"Not Found","detail":"no review detail"}]}
    """#

    @Test("pull selects the editable version and normalizes every surface")
    func pullHappyPath() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.appInfosJSON),
            .json(.ok, Self.versionsJSON),
            .json(.ok, Self.versionLocalizationsJSON),
            .json(.ok, Self.appInfoLocalizationsJSON),
            .json(.ok, Self.reviewDetailJSON),
        ])
        let live = try await ListingPuller(asc: asc).pull(
            appID: "APP1", bundleId: nil, platform: "IOS", version: .latest
        )

        #expect(live.app.bundleId == "com.example.app")
        #expect(live.version.id == "V_EDIT")                    // editable beats READY_FOR_SALE
        #expect(live.version.versionString == "1.2.2")
        #expect(live.version.appStoreState == "PREPARE_FOR_SUBMISSION")
        #expect(live.versionIsEditable)
        #expect(live.appInfo.id == "I1")

        let enUS = live.values.localized["en-US"]
        #expect(enUS?[.name] == "Live Name")
        #expect(enUS?[.description] == "Live desc")
        #expect(enUS?[.whatsNew] == "fixes")
        #expect(enUS?[.supportUrl] == "https://example.com/help")

        #expect(live.values.shared[.copyright] == "2025 Laconic")
        #expect(live.values.shared[.primaryCategory] == "EDUCATION")
        #expect(live.values.shared[.contactEmail] == "r@example.com")
        #expect(live.values.shared[.reviewNotes] == "notes here")
        #expect(live.reviewDetailID == "RD1")
        #expect(live.localizationIDs["en-US"]?.version == "VL1")
        #expect(live.localizationIDs["en-US"]?.appInfo == "AIL1")

        // The read path hits the six endpoints in order — nothing else.
        let ops = await transport.operationIDs
        #expect(ops == [
            "apps_getInstance",
            "apps_appInfos_getToManyRelated",
            "apps_appStoreVersions_getToManyRelated",
            "appStoreVersions_appStoreVersionLocalizations_getToManyRelated",
            "appInfos_appInfoLocalizations_getToManyRelated",
            "appStoreVersions_appStoreReviewDetail_getToOneRelated",
        ])

        // Category linkage only arrives when the relationships are `include`d — the first
        // live pull wrote no primary_category.txt because this query was bare.
        let appInfosQuery = await transport.exchanges[1].request.path ?? ""
        for rel in ["primaryCategory", "secondaryCategory", "primarySubcategoryOne", "secondarySubcategoryTwo"] {
            #expect(appInfosQuery.contains(rel), "appInfos request must include \(rel)")
        }
    }

    @Test("a 404 review detail is absence, not an error")
    func pullWithoutReviewDetail() async throws {
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.appInfosJSON),
            .json(.ok, Self.versionsJSON),
            .json(.ok, Self.versionLocalizationsJSON),
            .json(.ok, Self.appInfoLocalizationsJSON),
            .json(.notFound, Self.notFoundJSON),
        ])
        let live = try await ListingPuller(asc: asc).pull(
            appID: "APP1", bundleId: nil, platform: "IOS", version: .latest
        )
        #expect(live.reviewDetailID == nil)
        #expect(live.values.shared[.contactEmail] == nil)
    }

    @Test("version selector `live` picks READY_FOR_SALE")
    func liveSelector() async throws {
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.appInfosJSON),
            .json(.ok, Self.versionsJSON),
            .json(.ok, Self.versionLocalizationsJSON),
            .json(.ok, Self.appInfoLocalizationsJSON),
            .json(.notFound, Self.notFoundJSON),
        ])
        let live = try await ListingPuller(asc: asc).pull(
            appID: "APP1", bundleId: nil, platform: "IOS", version: .live
        )
        #expect(live.version.id == "V_LIVE")
        #expect(!live.versionIsEditable)
    }

    @Test("an unknown app id surfaces the API error detail")
    func appNotFound() async throws {
        let (asc, _) = try scriptedConnect([.json(.notFound, Self.notFoundJSON)])
        await #expect(throws: WorkflowError.self) {
            _ = try await ListingPuller(asc: asc).pull(
                appID: "NOPE", bundleId: nil, platform: "IOS", version: .latest
            )
        }
    }

    @Test("baseline made from a pulled listing digests every exported value")
    func baselineFromLive() async throws {
        let (asc, _) = try scriptedConnect([
            .json(.ok, Self.appJSON),
            .json(.ok, Self.appInfosJSON),
            .json(.ok, Self.versionsJSON),
            .json(.ok, Self.versionLocalizationsJSON),
            .json(.ok, Self.appInfoLocalizationsJSON),
            .json(.ok, Self.reviewDetailJSON),
        ])
        let live = try await ListingPuller(asc: asc).pull(
            appID: "APP1", bundleId: nil, platform: "IOS", version: .latest
        )
        let baseline = live.makeBaseline()
        #expect(baseline.digests["en-US/name.txt"] == Baseline.digest(of: "Live Name"))
        #expect(baseline.digests["copyright.txt"] == Baseline.digest(of: "2025 Laconic"))
        #expect(baseline.digests["review_information/notes.txt"] == Baseline.digest(of: "notes here"))
        #expect(baseline.localizationIDs["en-US"]?.version == "VL1")
    }
}

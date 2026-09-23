import Foundation
import HTTPTypes
import Testing
@testable import AppStoreKit
@testable import AppStoreWorkflow

/// `ListingApplier.apply` execution over a scripted transport — request bodies carry the
/// planned values, and baseline digests refresh from the *response* (Apple may normalize).
@Suite("ListingApplier execution")
struct ListingApplierTests {
    static let patchedVersionLocalization = #"""
    {"data":{"type":"appStoreVersionLocalizations","id":"VL1","attributes":{
      "locale":"en-US","description":"new desc","keywords":"a,b","whatsNew":null,
      "promotionalText":null,"supportUrl":null,"marketingUrl":null}}, "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/VL1"}}
    """#

    static let createdAppInfoLocalization = #"""
    {"data":{"type":"appInfoLocalizations","id":"AIL_NEW","attributes":{
      "locale":"de-DE","name":"Wörter","subtitle":null,
      "privacyPolicyUrl":null,"privacyChoicesUrl":null,"privacyPolicyText":null}}, "links":{"self":"https://api.appstoreconnect.apple.com/v1/appInfoLocalizations/AIL_NEW"}}
    """#

    func makeBaseline() -> Baseline {
        Baseline(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: nil, sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: nil),
            reviewDetailID: nil,
            localizationIDs: ["en-US": .init(version: "VL1", appInfo: "AIL1")],
            digests: ["en-US/description.txt": Baseline.digest(of: "old desc")]
        )
    }

    func listing() -> LiveListing {
        LiveListing(
            app: .init(id: "APP1", bundleId: "com.example.app", primaryLocale: nil, sku: nil),
            version: .init(id: "V1", versionString: "1.0", platform: "IOS", appStoreState: "PREPARE_FOR_SUBMISSION"),
            appInfo: .init(id: "I1", appStoreState: nil),
            reviewDetailID: nil,
            localizationIDs: ["en-US": .init(version: "VL1", appInfo: "AIL1")],
            values: ListingSnapshot(),
            demoAccountRequired: nil
        )
    }

    @Test("a PATCH sends the changed attributes and refreshes the baseline digest")
    func updateRefreshesBaseline() async throws {
        let (asc, transport) = try scriptedConnect([.json(.ok, Self.patchedVersionLocalization)])
        var baseline = makeBaseline()
        let result = await ListingApplier(asc: asc).apply(
            [.versionLocalizationUpdate(id: "VL1", locale: "en-US", values: [.description: "new desc"])],
            baseline: &baseline, live: listing()
        )
        #expect(result.ok)
        #expect(result.applied.count == 1)

        // The digest moved to the *response* value — a second diff sees truth.
        #expect(baseline.digests["en-US/description.txt"] == Baseline.digest(of: "new desc"))

        // The wire body carried the attribute, the id, and the resource type.
        let exchange = await transport.exchanges.first
        let body = try #require(exchange?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = json["data"] as? [String: Any]
        #expect(data?["type"] as? String == "appStoreVersionLocalizations")
        #expect(data?["id"] as? String == "VL1")
        #expect((data?["attributes"] as? [String: Any])?["description"] as? String == "new desc")
    }

    @Test("a create POSTs with the relationship and records the new id in the baseline")
    func createRecordsID() async throws {
        let (asc, _) = try scriptedConnect([.json(.created, Self.createdAppInfoLocalization)])
        var baseline = makeBaseline()
        let result = await ListingApplier(asc: asc).apply(
            [.appInfoLocalizationCreate(appInfoID: "I1", locale: "de-DE", values: [.name: "Wörter"])],
            baseline: &baseline, live: listing()
        )
        #expect(result.ok)
        #expect(baseline.localizationIDs["de-DE"]?.appInfo == "AIL_NEW")
        #expect(baseline.digests["de-DE/name.txt"] == Baseline.digest(of: "Wörter"))
    }

    @Test("a failing write stops the run and names the write that failed")
    func failureAborts() async throws {
        let (asc, transport) = try scriptedConnect([
            .json(.ok, Self.patchedVersionLocalization),
            .json(.unprocessableContent, #"{"errors":[{"status":"422","code":"ENTITY_ERROR","detail":"too long"}]}"#),
            .json(.ok, Self.patchedVersionLocalization),
        ])
        var baseline = makeBaseline()
        let result = await ListingApplier(asc: asc).apply(
            [
                .versionLocalizationUpdate(id: "VL1", locale: "en-US", values: [.description: "new desc"]),
                .appInfoLocalizationUpdate(id: "AIL1", locale: "en-US", values: [.name: "n"]),
                .versionLocalizationUpdate(id: "VL1", locale: "en-US", values: [.keywords: "k"]),
            ],
            baseline: &baseline, live: listing()
        )
        #expect(!result.ok)
        #expect(result.applied.count == 1)
        #expect(result.failed?.contains("PATCH appInfoLocalizations") == true)
        // The third write never ran.
        #expect(await transport.exchanges.count == 2)
    }
}

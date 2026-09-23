import Foundation
import AppStoreKit
import AppStoreOpenAPI

/// Reads the live App Store Connect listing and normalizes it into a ``LiveListing``.
///
/// Read path (all GET, in order):
/// `apps` (resolve by id or bundleId) → `appInfos` (pick the editable one) → `appStoreVersions`
/// (pick per ``VersionSelector``) → `appInfoLocalizations` + `appStoreVersionLocalizations`
/// (paginated) → `appStoreReviewDetail` (may 404). Categories come from the appInfo's
/// relationship data; `copyright` from the version.
public struct ListingPuller: Sendable {
    public let asc: AppStoreConnect

    public init(asc: AppStoreConnect) {
        self.asc = asc
    }

    public func pull(appID: String?, bundleId: String?, platform: String, version selector: VersionSelector) async throws -> LiveListing {
        guard ["IOS", "MAC_OS", "TV_OS", "VISION_OS"].contains(platform) else {
            throw WorkflowError.misconfigured("platform must be IOS, MAC_OS, TV_OS, or VISION_OS — got \(platform)")
        }
        let app = try await resolveApp(appID: appID, bundleId: bundleId)
        let appInfos = try await appInfos(appID: app.id)
        let versions = try await versions(appID: app.id, platform: platform)
        let version = try selectVersion(versions, selector: selector)
        let appInfo = try selectAppInfo(appInfos, for: version)

        var localized: [String: FieldValues] = [:]
        var localizationIDs: [String: Baseline.LocalizationIDs] = [:]

        for loc in try await versionLocalizations(versionID: version.id) {
            guard let locale = loc.attributes?.locale else { continue }
            let a = loc.attributes
            var values = localized[locale] ?? [:]
            values[.description] = a?.description
            values[.keywords] = a?.keywords
            values[.whatsNew] = a?.whatsNew
            values[.promotionalText] = a?.promotionalText
            values[.marketingUrl] = a?.marketingUrl
            values[.supportUrl] = a?.supportUrl
            localized[locale] = values
            localizationIDs[locale, default: .init()].version = loc.id
        }
        for loc in try await appInfoLocalizations(appInfoID: appInfo.id) {
            guard let locale = loc.attributes?.locale else { continue }
            let a = loc.attributes
            var values = localized[locale] ?? [:]
            values[.name] = a?.name
            values[.subtitle] = a?.subtitle
            values[.privacyPolicyUrl] = a?.privacyPolicyUrl
            values[.privacyChoicesUrl] = a?.privacyChoicesUrl
            values[.privacyPolicyText] = a?.privacyPolicyText
            localized[locale] = values
            localizationIDs[locale, default: .init()].appInfo = loc.id
        }

        var shared: FieldValues = [:]
        shared[.copyright] = version.attributes?.copyright
        let rels = appInfo.relationships
        shared[.primaryCategory] = rels?.primaryCategory?.data?.id
        shared[.secondaryCategory] = rels?.secondaryCategory?.data?.id
        shared[.primarySubcategoryOne] = rels?.primarySubcategoryOne?.data?.id
        shared[.primarySubcategoryTwo] = rels?.primarySubcategoryTwo?.data?.id
        shared[.secondarySubcategoryOne] = rels?.secondarySubcategoryOne?.data?.id
        shared[.secondarySubcategoryTwo] = rels?.secondarySubcategoryTwo?.data?.id

        var reviewDetailID: String?
        var demoRequired: Bool?
        if let detail = try await reviewDetail(versionID: version.id) {
            reviewDetailID = detail.id
            let a = detail.attributes
            demoRequired = a?.demoAccountRequired
            shared[.contactFirstName] = a?.contactFirstName
            shared[.contactLastName] = a?.contactLastName
            shared[.contactPhone] = a?.contactPhone
            shared[.contactEmail] = a?.contactEmail
            shared[.demoAccountName] = a?.demoAccountName
            shared[.demoAccountRequired] = a?.demoAccountRequired.map { $0 ? "true" : "false" }
            shared[.reviewNotes] = a?.notes
        }

        return LiveListing(
            app: .init(
                id: app.id,
                bundleId: app.attributes?.bundleId ?? bundleId ?? "",
                primaryLocale: app.attributes?.primaryLocale,
                sku: app.attributes?.sku
            ),
            version: .init(
                id: version.id,
                versionString: version.attributes?.versionString ?? "",
                platform: version.attributes?.platform?.rawValue ?? platform,
                appStoreState: version.attributes?.appStoreState?.rawValue ?? ""
            ),
            appInfo: .init(
                id: appInfo.id,
                appStoreState: appInfo.attributes?.appStoreState?.rawValue ?? appInfo.attributes?.state?.rawValue
            ),
            reviewDetailID: reviewDetailID,
            localizationIDs: localizationIDs,
            values: ListingSnapshot(localized: localized, shared: shared),
            demoAccountRequired: demoRequired
        )
    }

    // MARK: - Reads

    private func resolveApp(appID: String?, bundleId: String?) async throws -> Components.Schemas.App {
        if let appID {
            let output = try await asc.client.appsGetInstance(.init(path: .init(id: appID)))
            guard case .ok(let ok) = output else { throw apiError("appsGetInstance", errorResponse(of: output)) }
            return try ok.body.json.data
        }
        guard let bundleId, !bundleId.isEmpty else {
            throw WorkflowError.misconfigured("config needs `appId` or `bundleId`")
        }
        let output = try await asc.client.appsGetCollection(
            query: .init(filter_lbrack_bundleId_rbrack_: [bundleId], limit: 2)
        )
        guard case .ok(let ok) = output else { throw apiError("appsGetCollection", errorResponse(of: output)) }
        let apps = try ok.body.json.data
        guard let app = apps.first else { throw WorkflowError.notFound("no app with bundleId \(bundleId)") }
        guard apps.count == 1 else { throw WorkflowError.ambiguous("\(apps.count) apps match bundleId \(bundleId)") }
        return app
    }

    private func appInfos(appID: String) async throws -> [Components.Schemas.AppInfo] {
        let output = try await asc.client.appsAppInfosGetToManyRelated(.init(path: .init(id: appID)))
        guard case .ok(let ok) = output else { throw apiError("appsAppInfosGetToManyRelated", errorResponse(of: output)) }
        return try ok.body.json.data
    }

    private func versions(appID: String, platform: String) async throws -> [Components.Schemas.AppStoreVersion] {
        typealias PlatformFilter = Operations.AppsAppStoreVersionsGetToManyRelated.Input.Query.FilterLbrackPlatformRbrackPayloadPayload
        let platformFilter: PlatformFilter? = switch platform {
        case "IOS": .ios
        case "MAC_OS": .macOs
        case "TV_OS": .tvOs
        case "VISION_OS": .visionOs
        default: nil
        }
        let output = try await asc.client.appsAppStoreVersionsGetToManyRelated(
            .init(
                path: .init(id: appID),
                query: .init(filter_lbrack_platform_rbrack_: platformFilter.map { [$0] }, limit: 200)
            )
        )
        guard case .ok(let ok) = output else { throw apiError("appsAppStoreVersionsGetToManyRelated", errorResponse(of: output)) }
        var all: [Components.Schemas.AppStoreVersion] = []
        for try await page in asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data
        }
        return all
    }

    private func versionLocalizations(versionID: String) async throws -> [Components.Schemas.AppStoreVersionLocalization] {
        let output = try await asc.client.appStoreVersionsAppStoreVersionLocalizationsGetToManyRelated(
            .init(path: .init(id: versionID), query: .init(limit: 200))
        )
        guard case .ok(let ok) = output else { throw apiError("versionLocalizations", errorResponse(of: output)) }
        var all: [Components.Schemas.AppStoreVersionLocalization] = []
        for try await page in asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data
        }
        return all
    }

    private func appInfoLocalizations(appInfoID: String) async throws -> [Components.Schemas.AppInfoLocalization] {
        let output = try await asc.client.appInfosAppInfoLocalizationsGetToManyRelated(
            .init(path: .init(id: appInfoID), query: .init(limit: 200))
        )
        guard case .ok(let ok) = output else { throw apiError("appInfoLocalizations", errorResponse(of: output)) }
        var all: [Components.Schemas.AppInfoLocalization] = []
        for try await page in asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data
        }
        return all
    }

    private func reviewDetail(versionID: String) async throws -> Components.Schemas.AppStoreReviewDetail? {
        let output = try await asc.client.appStoreVersionsAppStoreReviewDetailGetToOneRelated(.init(path: .init(id: versionID)))
        switch output {
        case .ok(let ok): return try ok.body.json.data
        case .notFound: return nil
        default: throw apiError("appStoreReviewDetail", errorResponse(of: output))
        }
    }

    // MARK: - Selection

    /// The appInfo paired with the selected version when one is identifiable — the in-progress
    /// appInfo shares the in-progress version's state — else the first editable (non-frozen) one,
    /// else the first. Deterministic ordering, not API return order.
    private func selectAppInfo(_ appInfos: [Components.Schemas.AppInfo], for version: Components.Schemas.AppStoreVersion) throws -> Components.Schemas.AppInfo {
        guard !appInfos.isEmpty else { throw WorkflowError.notFound("app has no appInfos") }
        func state(_ info: Components.Schemas.AppInfo) -> String? {
            info.attributes?.appStoreState?.rawValue ?? info.attributes?.state?.rawValue
        }
        let versionState = version.attributes?.appStoreState?.rawValue
        if let paired = appInfos.first(where: { state($0) == versionState }) { return paired }
        return appInfos.first(where: {
            guard let s = state($0) else { return true }
            return !LiveListing.frozenAppInfoStates.contains(s)
        }) ?? appInfos[0]
    }

    private func selectVersion(_ versions: [Components.Schemas.AppStoreVersion], selector: VersionSelector) throws -> Components.Schemas.AppStoreVersion {
        func state(_ v: Components.Schemas.AppStoreVersion) -> String { v.attributes?.appStoreState?.rawValue ?? "" }
        switch selector {
        case .exact(let wanted):
            guard let v = versions.first(where: { $0.attributes?.versionString == wanted }) else {
                throw WorkflowError.notFound("no version \(wanted); have \(versions.compactMap(\.attributes?.versionString).joined(separator: ", "))")
            }
            return v
        case .live:
            guard let v = versions.first(where: { state($0) == "READY_FOR_SALE" }) else {
                throw WorkflowError.notFound("no READY_FOR_SALE version")
            }
            return v
        case .latest:
            for state in LiveListing.versionPrecedence {
                if let v = versions.first(where: { $0.attributes?.appStoreState?.rawValue == state }) { return v }
            }
            guard let newest = versions.max(by: { ($0.attributes?.createdDate ?? .distantPast) < ($1.attributes?.createdDate ?? .distantPast) }) else {
                throw WorkflowError.notFound("app has no appStoreVersions for this platform")
            }
            return newest
        }
    }
}

/// Pulls `errors[].detail` out of any generated output that isn't `.ok`/`created`. The outputs
/// share no protocol, so this walks the payload shape instead: `<case>.body.json` →
/// `ErrorResponse`. Returns `nil` when no error body is present.
func errorResponse<Output>(of output: Output) -> String? {
    for child in Mirror(reflecting: output).children {
        let payload = Mirror(reflecting: child.value)
        guard let body = payload.children.first(where: { $0.label == "body" })?.value,
              let json = Mirror(reflecting: body).children.first(where: { $0.label == "json" })?.value,
              let response = json as? Components.Schemas.ErrorResponse,
              let errors = response.errors
        else { continue }
        return errors.map { $0.detail }.joined(separator: "; ")
    }
    return nil
}

func apiError(_ operation: String, _ detail: String?) -> WorkflowError {
    .api(operation: operation, detail: detail ?? "unexpected response")
}

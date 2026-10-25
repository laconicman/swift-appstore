import AppStoreKit
import AppStoreOpenAPI
import Foundation

/// Read side of `media` — resolves the push target with `pull`'s exact selector
/// semantics and lists sets/members for the planner, the pusher's reconciles and
/// `media status`.
public struct MediaReader: Sendable {
    /// The resolved `--version` target.
    public struct Target: Sendable {
        public var app: Components.Schemas.App
        public var version: Components.Schemas.AppStoreVersion
        public var localizations: [Components.Schemas.AppStoreVersionLocalization]

        /// `en-GB` → localization id, for a staged locale that exists remotely.
        public func localizationID(locale: String) -> String? {
            localizations.first { $0.attributes?.locale == locale }?.id
        }
    }

    private let puller: ListingPuller

    public init(asc: AppStoreConnect) {
        puller = ListingPuller(asc: asc)
    }

    /// Resolve app → versions → selector → localizations, exactly as `pull` does.
    /// `push` additionally requires `editable` below.
    public func target(appID: String?, bundleId: String?, platform: String, selector: VersionSelector) async throws -> Target {
        let app = try await puller.resolveApp(appID: appID, bundleId: bundleId)
        let versions = try await puller.versions(appID: app.id, platform: platform)
        let version = try puller.selectVersion(versions, selector: selector)
        let localizations = try await puller.versionLocalizations(versionID: version.id)
        return Target(app: app, version: version, localizations: localizations)
    }

    /// Push refuses states a screenshot/preview mutation can't survive — the
    /// `editableVersionStates` set `pull` uses minus `READY_FOR_REVIEW` (text-only,
    /// per the comment there) and `ACCEPTED`. `READY_FOR_SALE` and later states
    /// are refused outright.
    public func requireEditable(_ target: Target) throws {
        let state = target.version.attributes?.appStoreState?.rawValue ?? "?"
        let editable: Set<String> = [
            "PREPARE_FOR_SUBMISSION", "INVALID_BINARY", "WAITING_FOR_EXPORT_COMPLIANCE",
            "DEVELOPER_REJECTED", "METADATA_REJECTED", "REJECTED", "WAITING_FOR_REVIEW",
        ]
        guard editable.contains(state) else {
            throw WorkflowError.notEditable(["version \(target.version.attributes?.versionString ?? target.version.id) is \(state) — media upload needs an editable state"])
        }
    }

    /// Screenshot sets belonging to one localization (for the create-set 409
    /// reconcile and `media status`).
    public func screenshotSets(localizationID: String) async throws -> [Components.Schemas.AppScreenshotSet] {
        let output = try await puller.asc.client.appStoreVersionLocalizationsAppScreenshotSetsGetToManyRelated(
            .init(path: .init(id: localizationID), query: .init(limit: 200))
        )
        guard case .ok(let ok) = output else { throw apiError("appScreenshotSets", errorResponse(of: output)) }
        var all: [Components.Schemas.AppScreenshotSet] = []
        for try await page in puller.asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data
        }
        return all
    }

    public func previewSets(localizationID: String) async throws -> [Components.Schemas.AppPreviewSet] {
        let output = try await puller.asc.client.appStoreVersionLocalizationsAppPreviewSetsGetToManyRelated(
            .init(path: .init(id: localizationID), query: .init(limit: 200))
        )
        guard case .ok(let ok) = output else { throw apiError("appPreviewSets", errorResponse(of: output)) }
        var all: [Components.Schemas.AppPreviewSet] = []
        for try await page in puller.asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data
        }
        return all
    }

    /// Sets of the given kind for a localization — the planner's shape.
    public func sets(localizationID: String, kind: MediaKind) async throws -> [SetRow] {
        switch kind {
        case .screenshot:
            return try await screenshotSets(localizationID: localizationID).map {
                SetRow(id: $0.id, rawType: $0.attributes?.screenshotDisplayType?.rawValue ?? "")
            }
        case .preview:
            return try await previewSets(localizationID: localizationID).map {
                SetRow(id: $0.id, rawType: $0.attributes?.previewType?.rawValue ?? "")
            }
        }
    }

    /// A live set's id + type, kind-agnostic.
    public struct SetRow: Sendable, Equatable {
        public var id: String
        public var rawType: String
    }

    /// Members of a screenshot set, in Apple's stored order (= display order).
    public func screenshotRows(setID: String) async throws -> [AssetRow] {
        let output = try await puller.asc.client.appScreenshotSetsAppScreenshotsGetToManyRelated(
            .init(path: .init(id: setID), query: .init(limit: 200))
        )
        guard case .ok(let ok) = output else { throw apiError("appScreenshots", errorResponse(of: output)) }
        var all: [AssetRow] = []
        for try await page in puller.asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data.map(AssetRow.init(screenshot:))
        }
        return all
    }

    public func previewRows(setID: String) async throws -> [AssetRow] {
        let output = try await puller.asc.client.appPreviewSetsAppPreviewsGetToManyRelated(
            .init(path: .init(id: setID), query: .init(limit: 200))
        )
        guard case .ok(let ok) = output else { throw apiError("appPreviews", errorResponse(of: output)) }
        var all: [AssetRow] = []
        for try await page in puller.asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data.map(AssetRow.init(preview:))
        }
        return all
    }

    public func rows(setID: String, kind: MediaKind) async throws -> [AssetRow] {
        switch kind {
        case .screenshot: try await screenshotRows(setID: setID)
        case .preview: try await previewRows(setID: setID)
        }
    }

    /// GET one row — `nil` on 404, for the DELETE reconcile (404 = done, 200 = resend).
    public func screenshot(id: String) async throws -> AssetRow? {
        let output = try await puller.asc.client.appScreenshotsGetInstance(.init(path: .init(id: id)))
        switch output {
        case .ok(let ok): return AssetRow(screenshot: try ok.body.json.data)
        case .notFound: return nil
        default: throw apiError("appScreenshotsGet", errorResponse(of: output))
        }
    }

    public func preview(id: String) async throws -> AssetRow? {
        let output = try await puller.asc.client.appPreviewsGetInstance(.init(path: .init(id: id)))
        switch output {
        case .ok(let ok): return AssetRow(preview: try ok.body.json.data)
        case .notFound: return nil
        default: throw apiError("appPreviewsGet", errorResponse(of: output))
        }
    }

    public func row(id: String, kind: MediaKind) async throws -> AssetRow? {
        switch kind {
        case .screenshot: try await screenshot(id: id)
        case .preview: try await preview(id: id)
        }
    }
}

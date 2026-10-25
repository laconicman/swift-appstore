import AppStoreKit
import AppStoreOpenAPI
import Foundation

/// `asc media status` — the read-only check the owner runs after a push: every
/// localization's sets with each member's delivery state(s). Pure reads; any
/// version state is allowed (a live `READY_FOR_SALE` version is a fine target).
public struct MediaStatus: Sendable {
    /// One set's member listing.
    public struct SetReport: Sendable {
        public var setID: String
        public var rawType: String
        public var kind: MediaKind
        /// Members in Apple's stored order (= display order).
        public var rows: [AssetRow]
    }

    /// One localization's sets.
    public struct LocaleReport: Sendable {
        public var locale: String
        public var localizationID: String
        public var sets: [SetReport]
    }

    public struct Report: Sendable {
        public var versionString: String
        public var versionState: String
        public var locales: [LocaleReport]
    }

    private let reader: MediaReader

    public init(asc: AppStoreConnect) {
        reader = MediaReader(asc: asc)
    }

    public func report(
        appID: String?,
        bundleId: String?,
        platform: String,
        selector: VersionSelector,
        locales: [String] = []
    ) async throws -> Report {
        let target = try await reader.target(appID: appID, bundleId: bundleId, platform: platform, selector: selector)
        var reports: [LocaleReport] = []
        for loc in target.localizations {
            guard let locale = loc.attributes?.locale else { continue }
            if !locales.isEmpty, !locales.contains(locale) { continue }
            var sets: [SetReport] = []
            for set in try await reader.screenshotSets(localizationID: loc.id) {
                sets.append(.init(
                    setID: set.id,
                    rawType: set.attributes?.screenshotDisplayType?.rawValue ?? "?",
                    kind: .screenshot,
                    rows: try await reader.screenshotRows(setID: set.id)
                ))
            }
            for set in try await reader.previewSets(localizationID: loc.id) {
                sets.append(.init(
                    setID: set.id,
                    rawType: set.attributes?.previewType?.rawValue ?? "?",
                    kind: .preview,
                    rows: try await reader.previewRows(setID: set.id)
                ))
            }
            sets.sort { $0.rawType < $1.rawType }
            reports.append(.init(locale: locale, localizationID: loc.id, sets: sets))
        }
        reports.sort { $0.locale < $1.locale }
        return Report(
            versionString: target.version.attributes?.versionString ?? target.version.id,
            versionState: target.version.attributes?.appStoreState?.rawValue ?? "?",
            locales: reports
        )
    }
}

import Foundation

/// Which App Store version `pull`/`diff`/`apply` targets.
public enum VersionSelector: Sendable {
    /// Prefer a version in an editable state, then an in-flight one, then the live one.
    case latest
    /// The `READY_FOR_SALE` version only.
    case live
    /// Exact `versionString` match.
    case exact(String)

    public init(_ string: String) {
        switch string {
        case "latest": self = .latest
        case "live": self = .live
        default: self = .exact(string)
        }
    }
}

/// App Store Connect state for one listing, normalized to the same `ListingSnapshot` shape the
/// local metadata tree uses — the pull side of the three-way diff.
public struct LiveListing: Sendable {
    public var app: Baseline.AppReference
    public var version: Baseline.VersionReference
    public var appInfo: Baseline.AppInfoReference
    public var reviewDetailID: String?
    public var localizationIDs: [String: Baseline.LocalizationIDs]
    public var values: ListingSnapshot
    /// `demoAccountRequired` on the live review detail — recorded so pull can note that a demo
    /// credential exists upstream even though the password itself is never exported.
    public var demoAccountRequired: Bool?

    /// Version states in which metadata may be edited, per the surface matrix's verified list.
    /// READY_FOR_REVIEW/WAITING_FOR_REVIEW admit text but not screenshots — fine here, the
    /// listing spine carries only text.
    public static let editableVersionStates: Set<String> = [
        "PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "INVALID_BINARY", "WAITING_FOR_REVIEW",
        "ACCEPTED", "WAITING_FOR_EXPORT_COMPLIANCE", "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED",
    ]

    /// appInfo states that can no longer be edited; anything else is treated as editable.
    public static let frozenAppInfoStates: Set<String> = ["READY_FOR_SALE", "REPLACED_WITH_NEW_INFO"]

    /// Version-selection precedence for `.latest`: editable states first (roughly in pipeline
    /// order), then in-flight non-editable, then live — same order as mgcrea's fetch, extended
    /// with the editable states its list omits.
    static let versionPrecedence: [String] = [
        "PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "INVALID_BINARY", "WAITING_FOR_EXPORT_COMPLIANCE",
        "DEVELOPER_REJECTED", "METADATA_REJECTED", "REJECTED",
        "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE",
        "PROCESSING_FOR_DISTRIBUTION", "READY_FOR_DISTRIBUTION",
        "READY_FOR_SALE",
    ]

    public var versionIsEditable: Bool {
        Self.editableVersionStates.contains(version.appStoreState)
    }

    public var appInfoIsEditable: Bool {
        appInfo.appStoreState.map { !Self.frozenAppInfoStates.contains($0) } ?? true
    }

    public func makeBaseline() -> Baseline {
        Baseline(
            exportedAt: Date(),
            app: app,
            version: version,
            appInfo: appInfo,
            reviewDetailID: reviewDetailID,
            localizationIDs: localizationIDs,
            digests: Baseline.digests(for: values)
        )
    }
}

import AppStoreOpenAPI
import Foundation

/// Which asset family a staged set belongs to — screenshots on `appScreenshotSets`,
/// previews on `appPreviewSets`. Everything kind-dependent hangs off this enum so the
/// state machine below stays one code path.
public enum MediaKind: String, Sendable, CaseIterable {
    case screenshot
    case preview

    /// Per-set caps from the reference recipes: 10 screenshots, 3 previews —
    /// a set over cap is refused whole, never truncated.
    public var cap: Int {
        switch self {
        case .screenshot: 10
        case .preview: 3
        }
    }

    /// Filename extensions a set directory may hold.
    public var fileExtensions: Set<String> {
        switch self {
        case .screenshot: ["png", "jpg", "jpeg"]
        case .preview: ["mp4", "mov"]
        }
    }

    /// The field name Apple prints in ASC UI — used in plan/status output.
    public var noun: String { rawValue }
}

/// A validated `<TYPE>` directory name: a `screenshotDisplayType` (`APP_IPHONE_67`, …)
/// or a `previewType` (`IPHONE_67`, … — the display types minus the `APP_` prefix).
/// An unknown name fails fast at scan time rather than mid-push.
public enum MediaSetType: Sendable, Hashable, CustomStringConvertible {
    case screenshot(Components.Schemas.ScreenshotDisplayType)
    case preview(Components.Schemas.PreviewType)

    public var kind: MediaKind {
        switch self {
        case .screenshot: .screenshot
        case .preview: .preview
        }
    }

    /// The raw enum value — matches the directory name in `--source`.
    public var rawValue: String {
        switch self {
        case .screenshot(let t): t.rawValue
        case .preview(let t): t.rawValue
        }
    }

    public var description: String { rawValue }

    public init?(rawValue: String) {
        if let type = Components.Schemas.ScreenshotDisplayType(rawValue: rawValue) {
            self = .screenshot(type)
        } else if let type = Components.Schemas.PreviewType(rawValue: rawValue) {
            self = .preview(type)
        } else {
            return nil
        }
    }
}

/// One member row of a live set, normalized across kinds so the planner and the
/// state machine never branch on screenshot-vs-preview shape.
public struct AssetRow: Sendable, Equatable {
    public var id: String
    public var fileName: String
    public var sourceFileChecksum: String?
    /// `assetDeliveryState` — and for previews `videoDeliveryState` must be COMPLETE too.
    public var assetState: Components.Schemas.AppMediaAssetState.StatePayload?
    public var videoState: Components.Schemas.AppMediaVideoState.StatePayload?
    /// `uploadOperations` only ever appear on the create response — a row returned by
    /// list/GET never has them, so an `AWAITING_UPLOAD` row seen here is a stranded
    /// reservation from a crashed run and must be deleted and re-created.
    public var uploadOperations: [Components.Schemas.UploadOperation]?

    public var kind: MediaKind { isPreviewRow ? .preview : .screenshot }
    private var isPreviewRow = false

    public init(screenshot: Components.Schemas.AppScreenshot) {
        id = screenshot.id
        fileName = screenshot.attributes?.fileName ?? ""
        sourceFileChecksum = screenshot.attributes?.sourceFileChecksum
        assetState = screenshot.attributes?.assetDeliveryState?.state
        videoState = nil
        uploadOperations = screenshot.attributes?.uploadOperations
    }

    public init(preview: Components.Schemas.AppPreview) {
        id = preview.id
        fileName = preview.attributes?.fileName ?? ""
        sourceFileChecksum = preview.attributes?.sourceFileChecksum
        assetState = preview.attributes?.assetDeliveryState?.state
        videoState = preview.attributes?.videoDeliveryState?.state
        uploadOperations = preview.attributes?.uploadOperations
        isPreviewRow = true
    }

    /// The pair previews.py calls `pair(x)` — kept as a tuple for status output.
    public var statePair: (asset: String, video: String?) {
        (assetState?.rawValue ?? "?", isPreviewRow ? videoState?.rawValue ?? "?" : nil)
    }

    /// A row is kept only when BOTH delivery states are COMPLETE — for previews the
    /// transcode (`videoDeliveryState`) lags the byte upload by 10–15 min.
    public var isComplete: Bool {
        assetState == .complete && (!isPreviewRow || videoState == .complete)
    }

    public var isFailed: Bool {
        assetState == .failed || videoState == .failed
    }

    /// Anything not COMPLETE — `AWAITING_UPLOAD` orphans, `UPLOAD_COMPLETE` stubs,
    /// `PROCESSING` previews, `FAILED` rows. Same-named instances are deleted before
    /// re-upload; other-named ones are swept after replacements land.
    public var isUnfinished: Bool { !isComplete }
}

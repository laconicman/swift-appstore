import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// `.asc-baseline.json` — the pull sidecar that makes the diff three-way.
///
/// Written by `asc pull` alongside the metadata files. It records which App Store Connect
/// resources the files came from (so `apply` can PATCH them by id), the state they were in,
/// and a short SHA-256 digest of every exported value. On the next `diff`/`apply`, a live value
/// whose digest differs from the baseline proves the remote changed since the last pull —
/// a conflict the owner resolves by re-pulling, not something `apply` silently overwrites.
public struct Baseline: Codable, Sendable {
    public var schemaVersion: Int = 1
    public var exportedAt: Date
    public var app: AppReference
    public var version: VersionReference
    public var appInfo: AppInfoReference
    public var reviewDetailID: String?
    public var localizationIDs: [String: LocalizationIDs]
    /// Digest per exported file, keyed by path relative to the metadata root
    /// (`en-US/name.txt`, `copyright.txt`, `review_information/notes.txt`).
    public var digests: [String: String]

    public struct AppReference: Codable, Sendable {
        public var id: String
        public var bundleId: String
        public var primaryLocale: String?
        public var sku: String?
    }

    public struct VersionReference: Codable, Sendable {
        public var id: String
        public var versionString: String
        public var platform: String
        public var appStoreState: String
    }

    public struct AppInfoReference: Codable, Sendable {
        public var id: String
        public var appStoreState: String?
    }

    /// ASC row ids for a locale — `nil` where that localization doesn't exist remotely.
    public struct LocalizationIDs: Codable, Sendable {
        public var version: String?
        public var appInfo: String?

        public init(version: String? = nil, appInfo: String? = nil) {
            self.version = version
            self.appInfo = appInfo
        }
    }

    public static let fileName = ".asc-baseline.json"

    public static func digestKey(field: ListingField, locale: String?) -> String {
        locale.map { "\($0)/\(field.filePath)" } ?? field.filePath
    }

    /// First 8 hex chars of the SHA-256 of the normalized value — enough to detect drift,
    /// short enough to keep the sidecar readable.
    public static func digest(of value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    public static func digests(for snapshot: ListingSnapshot) -> [String: String] {
        var digests: [String: String] = [:]
        for (locale, values) in snapshot.localized {
            for (field, value) in values {
                digests[digestKey(field: field, locale: locale)] = digest(of: value)
            }
        }
        for (field, value) in snapshot.shared {
            digests[digestKey(field: field, locale: nil)] = digest(of: value)
        }
        return digests
    }

    /// A baseline only means something for the app it was pulled from. A different app id or
    /// bundle id means the digests describe another record's history — trusting them would
    /// mislabel remote state as drift or, worse, mask it. Returns a message on mismatch.
    public func identityViolation(against live: LiveListing) -> String? {
        guard app.id == live.app.id, app.bundleId == live.app.bundleId else {
            return "\(Self.fileName) was pulled for \(app.bundleId) (id \(app.id)); " +
                "live listing is \(live.app.bundleId) (id \(live.app.id)) — re-run `asc pull` against this app"
        }
        return nil
    }

    /// Softer drift worth surfacing: the version or appInfo moved on since the pull. Digests
    /// are still valid — they describe field values at pull time — but the owner should know
    /// the record shifted underneath.
    public func identityNotes(against live: LiveListing) -> [String] {
        var notes: [String] = []
        if version.id != live.version.id {
            notes.append("baseline was pulled at version \(version.versionString) (\(version.appStoreState)); " +
                         "live is \(live.version.versionString) (\(live.version.appStoreState))")
        }
        if appInfo.id != live.appInfo.id {
            notes.append("baseline was pulled against appInfo \(appInfo.id); live is \(live.appInfo.id)")
        }
        return notes
    }

    public static func load(root: URL) throws -> Baseline? {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Baseline.self, from: Data(contentsOf: url))
    }

    public func write(to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

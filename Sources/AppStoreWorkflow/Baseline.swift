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
    public var schemaVersion: Int = 2
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

    /// SHA-256 of the normalized value — the full digest, so a collision masking remote
    /// drift is not a question that needs answering.
    public static func digest(of value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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
        if schemaVersion != 2 {
            return "\(Self.fileName) uses schema v\(schemaVersion); digests were re-shaped in v2 — re-run `asc pull` to re-seed"
        }
        guard app.id == live.app.id, app.bundleId == live.app.bundleId else {
            return "\(Self.fileName) was pulled for \(app.bundleId) (id \(app.id)); " +
                "live listing is \(live.app.bundleId) (id \(live.app.id)) — re-run `asc pull` against this app"
        }
        return nil
    }

    /// Carries digests forward for files pull kept despite the remote value disappearing:
    /// the baseline keeps describing what was last pulled, so a field that reappears remotely
    /// diffs against real provenance instead of looking brand-new.
    public mutating func carryDigests(from old: Baseline?, for paths: [String]) {
        guard let old else { return }
        for path in paths {
            if let digest = old.digests[path] { digests[path] = digest }
        }
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

import Foundation

/// `spec-manifest.json` — the pin that says exactly which Apple spec is vendored and what was
/// done to it. Committed next to `openapi.json` and rewritten by the tool on every run.
struct SpecManifest: Codable {
    struct Upstream: Codable {
        let file: String
        let sha256: String
        let paths: Int
        let operations: Int
        let schemas: Int
    }

    struct Vendored: Codable {
        struct Normalizations: Codable {
            let emptyEnumsDropped: Int
        }

        let file: String
        let sha256: String
        let normalizations: Normalizations
    }

    /// A tier's selection pinned per operation id, watermarked with the spec version
    /// the selection was last reviewed against (`reviewedAtSpec`). A spec bump then
    /// lets `--check` say exactly which operations *newly joined* the tier instead of
    /// drowning that signal in a generic diff — nil on manifests written before the
    /// watermark existed.
    struct Tier: Codable {
        let name: String
        let config: String
        let operations: Int
        let operationIDs: [String]?
        let reviewedAtSpec: String?
    }

    let specVersion: String
    let openAPIVersion: String
    let source: String
    let downloadedAt: String
    let upstream: Upstream
    let vendored: Vendored
    let tiers: [Tier]

    static func read(from url: URL) throws -> SpecManifest {
        try JSONDecoder().decode(SpecManifest.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(UInt8(ascii: "\n"))
        try data.write(to: url, options: .atomic)
    }
}

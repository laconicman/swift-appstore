import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Maintainer tool that (re)vendors Apple's App Store Connect OpenAPI document for
/// AppStoreKit — the counterpart of `gitlab-spec-tool` in swift-gitlab.
///
///     swift run asc-spec-tool                     # fetch Apple's zip, normalize, write spec + manifest
///     swift run asc-spec-tool --no-fetch          # re-normalize the vendored spec in place, re-pin manifest
///     swift run asc-spec-tool --from spec.zip     # use an already-downloaded zip (or .json) instead of fetching
///     swift run asc-spec-tool --check             # fetch and print a drift report against the vendored spec;
///                                                 # writes nothing, exits 1 when anything drifted
///
/// Pipeline: **fetch → unzip → normalize → pin → (report)**.
///
///  * Apple ships the spec only as a zip (`openapi.oas.json` inside). The tool records the
///    sha256 of that upstream file *and* of the normalized file it writes, so `--check` can
///    tell "Apple published a new spec" apart from "someone edited the vendored copy".
///  * Normalizations are the minimum needed for `swift-openapi-generator` to emit compilable
///    Swift, each one idempotent and a no-op on a spec that does not exhibit the quirk
///    (see `SpecDocument.normalized()` and `Upstream/` for the dated evidence).
///  * The manifest (`spec-manifest.json`) also counts the operations each generator-config tier
///    selects, so the README's tier table is derived, not hand-maintained.
@main
struct ASCSpecTool {
    static let specZipURL = URL(string: "https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip")!
    static let upstreamFileName = "openapi.oas.json"
    static let defaultOutputDirectory = "Sources/AppStoreOpenAPI"
    static let vendoredFileName = "openapi.json"
    static let manifestFileName = "spec-manifest.json"
    static let tierConfigs: [(tier: String, file: String)] = [
        ("release", "openapi-generator-config.yaml"),
        ("full", "openapi-generator-config.full.yaml"),
    ]

    struct Options {
        var fetch = true
        var check = false
        var source: String?
        var outputDirectory = defaultOutputDirectory
    }

    static func main() async throws {
        let options = parse(CommandLine.arguments.dropFirst())
        let outputDirectory = URL(fileURLWithPath: options.outputDirectory, isDirectory: true)
        let vendoredURL = outputDirectory.appendingPathComponent(vendoredFileName)
        let manifestURL = outputDirectory.appendingPathComponent(manifestFileName)

        let previousManifest = try? SpecManifest.read(from: manifestURL)

        // 1. Obtain the upstream document bytes.
        let upstreamData: Data
        let upstreamSHA256: String
        let downloadedAt: String
        // Normalizations already applied to the input, so the manifest keeps counting them when
        // the (already-normalized) vendored file is re-run through the pipeline.
        var priorNormalizations = SpecManifest.Vendored.Normalizations(emptyEnumsDropped: 0)
        if let source = options.source {
            upstreamData = try SpecArchive.specData(fromFileAt: URL(fileURLWithPath: source))
            upstreamSHA256 = upstreamData.sha256Hex
            downloadedAt = previousManifest?.downloadedAt ?? today()
        } else if options.fetch {
            log("Fetching \(specZipURL.absoluteString)")
            let (zipData, _) = try await URLSession.shared.data(from: specZipURL)
            upstreamData = try SpecArchive.specData(fromZipData: zipData)
            upstreamSHA256 = upstreamData.sha256Hex
            downloadedAt = today()
        } else {
            // Re-normalizing in place: the upstream pin is whatever the manifest already says.
            guard let manifest = previousManifest else {
                throw ToolError.noManifest(manifestURL.path)
            }
            upstreamData = try Data(contentsOf: vendoredURL)
            upstreamSHA256 = manifest.upstream.sha256
            downloadedAt = manifest.downloadedAt
            priorNormalizations = manifest.vendored.normalizations
        }

        // 2. Parse + normalize.
        let upstream = try SpecDocument(data: upstreamData)
        let (normalized, stats) = upstream.normalized()
        let vendoredData = try normalized.serialized()
        let normalizations = SpecManifest.Vendored.Normalizations(
            emptyEnumsDropped: priorNormalizations.emptyEnumsDropped + stats.emptyEnumsDropped
        )

        // 3. Drift report against what is currently vendored (if anything is).
        if let vendoredData = try? Data(contentsOf: vendoredURL),
           let vendored = try? SpecDocument(data: vendoredData) {
            let report = DriftReport(from: vendored, to: normalized)
            print(report.rendered(fromVersion: vendored.version, toVersion: normalized.version))
            if options.check {
                exit(report.isEmpty ? 0 : 1)
            }
        } else if options.check {
            throw ToolError.nothingVendored(vendoredURL.path)
        }

        // 4. Write the spec and re-pin the manifest.
        try vendoredData.write(to: vendoredURL, options: .atomic)

        let tiers = try tierConfigs.compactMap { tier, file -> SpecManifest.Tier? in
            let configURL = outputDirectory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
            let config = try GeneratorConfig(contentsOf: configURL)
            return SpecManifest.Tier(
                name: tier,
                config: file,
                operations: config.selectedOperationCount(in: normalized)
            )
        }

        let manifest = SpecManifest(
            specVersion: normalized.version,
            openAPIVersion: normalized.openAPIVersion,
            source: specZipURL.absoluteString,
            downloadedAt: downloadedAt,
            upstream: .init(
                file: upstreamFileName,
                sha256: upstreamSHA256,
                paths: upstream.pathCount,
                operations: upstream.operationCount,
                schemas: upstream.schemaCount
            ),
            vendored: .init(
                file: vendoredFileName,
                sha256: vendoredData.sha256Hex,
                normalizations: normalizations
            ),
            tiers: tiers
        )
        try manifest.write(to: manifestURL)

        print("""
        Wrote \(vendoredURL.path)
          spec version:        \(normalized.version) (OpenAPI \(normalized.openAPIVersion))
          paths / operations:  \(normalized.pathCount) / \(normalized.operationCount)
          schemas:             \(normalized.schemaCount)
          empty enums dropped: \(normalizations.emptyEnumsDropped) (\(stats.emptyEnumsDropped) in this run)
        Wrote \(manifestURL.path)
          upstream sha256:     \(manifest.upstream.sha256)
          vendored sha256:     \(manifest.vendored.sha256)
        \(tiers.map { "  tier \($0.name): \($0.operations) operations (\($0.config))" }.joined(separator: "\n"))
        """)
    }

    // MARK: Arguments

    /// Hand-rolled parsing keeps the tool dependency-light: `--no-fetch`, `--check`,
    /// `--from <zip|json>`, and an optional positional output directory.
    static func parse(_ arguments: ArraySlice<String>) -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--no-fetch": options.fetch = false
            case "--check": options.check = true
            case "--from": if let value = iterator.next() { options.source = value }
            default: if !argument.hasPrefix("--") { options.outputDirectory = argument }
            }
        }
        return options
    }

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

enum ToolError: Error, CustomStringConvertible {
    case couldNotParse(String)
    case noManifest(String)
    case nothingVendored(String)
    case unzipFailed(Int32)
    case specNotInArchive(String)

    var description: String {
        switch self {
        case .couldNotParse(let what): "could not parse \(what) as an OpenAPI JSON document"
        case .noManifest(let path): "--no-fetch needs an existing manifest at \(path)"
        case .nothingVendored(let path): "--check needs a vendored spec at \(path)"
        case .unzipFailed(let status): "unzip exited with status \(status)"
        case .specNotInArchive(let name): "\(name) not found in the downloaded archive"
        }
    }
}

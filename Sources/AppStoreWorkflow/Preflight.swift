import Foundation
import AppStoreKit
import AppStoreOpenAPI

/// Archive-time checks that catch the failures App Store Connect rejects at upload — the
/// LearnWords 1.2.2 class of bug (upload error 90068 from a nested bundle's
/// `MinimumOSVersion`, extension version drift, missing `PrivacyInfo.xcprivacy`).
///
/// Input is a built `.app` or an `.xcarchive`. Every nested bundle with an `Info.plist` is
/// inspected: the app itself, app extensions, embedded frameworks, watch apps.
public enum Preflight {

    public struct BundleReport: Sendable {
        public var path: String        // path relative to the inspected root
        public var bundleId: String?
        public var version: String?    // CFBundleShortVersionString
        public var build: String?      // CFBundleVersion
        public var minOS: String?      // MinimumOSVersion (iOS) or LSMinimumSystemVersion (macOS)
        public var hasPrivacyManifest: Bool
    }

    public enum Finding: Sendable, CustomStringConvertible {
        case belowFloor(bundle: String, found: String, floor: String)
        case missingMinOS(bundle: String)
        case missingPrivacyManifest(bundle: String)
        case versionMismatch([String: String])   // bundle -> version
        case buildMismatch([String: String])
        case buildNumberReused(version: String, build: String)

        public var description: String {
            switch self {
            case .belowFloor(let b, let f, let floor): "\(b): MinimumOSVersion \(f) is below the \(floor) floor — this is the 90068 upload failure"
            case .missingMinOS(let b): "\(b): no MinimumOSVersion in Info.plist"
            case .missingPrivacyManifest(let b): "\(b): no PrivacyInfo.xcprivacy — required for every bundle since 2024-05-01"
            case .versionMismatch(let m): "CFBundleShortVersionString differs across bundles: \(m.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))"
            case .buildMismatch(let m): "CFBundleVersion differs across bundles: \(m.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))"
            case .buildNumberReused(let v, let b): "build \(b) for version \(v) already exists on App Store Connect — bump CFBundleVersion"
            }
        }
    }

    public struct Report: Sendable {
        public var bundles: [BundleReport]
        public var findings: [Finding]
        public var ok: Bool { findings.isEmpty }
    }

    /// Inspects a `.app` or `.xcarchive` directory. `floor` is the deployment target every
    /// bundle must meet (e.g. `"15.0"`).
    public static func inspect(at url: URL, floor: String) throws -> Report {
        let root = try appRoot(at: url)
        var bundles: [BundleReport] = []
        for bundle in bundleDirectories(under: root) {
            bundles.append(inspect(bundle: bundle, root: root))
        }
        guard !bundles.isEmpty else {
            throw WorkflowError.notFound("no bundles with Info.plist under \(url.path)")
        }

        var findings: [Finding] = []
        for bundle in bundles {
            if let minOS = bundle.minOS {
                if compareVersions(minOS, floor) == .orderedAscending {
                    findings.append(.belowFloor(bundle: bundle.path, found: minOS, floor: floor))
                }
            } else {
                findings.append(.missingMinOS(bundle: bundle.path))
            }
            if !bundle.hasPrivacyManifest {
                findings.append(.missingPrivacyManifest(bundle: bundle.path))
            }
        }
        // Version/build equality only across executable bundles: extensions must match the
        // app (TD-24), but frameworks legitimately carry their own versioning.
        let executable = bundles.filter { $0.path.hasSuffix(".app") || $0.path.hasSuffix(".appex") }
        let versions = Dictionary(uniqueKeysWithValues: executable.map { ($0.path, $0.version ?? "?") })
        if Set(versions.values).count > 1 { findings.append(.versionMismatch(versions)) }
        let builds = Dictionary(uniqueKeysWithValues: executable.map { ($0.path, $0.build ?? "?") })
        if Set(builds.values).count > 1 { findings.append(.buildMismatch(builds)) }

        return Report(bundles: bundles, findings: findings)
    }

    /// Checks whether `(version, build)` already exists on ASC for the app — the "build number
    /// reuse" failure Xcode reports at upload. Needs a configured API key.
    public static func buildReuse(asc: AppStoreConnect, appID: String, version: String, build: String) async throws -> Bool {
        let output = try await asc.client.buildsGetCollection(.init(query: .init(
            filter_lbrack_version_rbrack_: [build],
            filter_lbrack_preReleaseVersion_version_rbrack_: [version],
            filter_lbrack_app_rbrack_: [appID],
            limit: 1
        )))
        guard case .ok(let ok) = output else { throw apiError("buildsGetCollection", errorResponse(of: output)) }
        return !(try ok.body.json.data.isEmpty)
    }

    // MARK: - Bundle discovery

    /// The directory whose children are the bundles to check: a `.app` directly, or
    /// `Products/Applications` inside an `.xcarchive`.
    static func appRoot(at url: URL) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkflowError.notFound(url.path)
        }
        if url.pathExtension == "xcarchive" {
            let products = url.appendingPathComponent("Products/Applications")
            guard FileManager.default.fileExists(atPath: products.path) else {
                throw WorkflowError.notFound("\(url.path): no Products/Applications — is this an app archive?")
            }
            return products
        }
        return url
    }

    /// Every bundle directory containing an Info.plist: the app itself, then nested
    /// `.appex`/`.framework`/`.app`/`.xctest`/`.bundle` wherever they sit.
    static func bundleDirectories(under root: URL) -> [URL] {
        let fm = FileManager.default
        let exts: Set<String> = ["app", "appex", "framework", "xctest", "bundle"]
        var found: [URL] = []
        if infoPlist(in: root) != nil { found.append(root) }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return found
        }
        for case let url as URL in enumerator where exts.contains(url.pathExtension) {
            if infoPlist(in: url) != nil {
                found.append(url)
                // Do NOT skipDescendants: the app's PlugIns/ and Frameworks/ hold the .appex
                // and .framework bundles — skipping them is exactly how a nested bundle
                // escapes the MinimumOSVersion check that 90068 was about.
            }
        }
        return found.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    /// `Info.plist` location for the platform layout: flat in iOS bundles, `Contents/` in
    /// macOS `.app`s, `Resources/` inside frameworks.
    static func infoPlist(in bundle: URL) -> URL? {
        for candidate in [
            bundle.appendingPathComponent("Info.plist"),
            bundle.appendingPathComponent("Contents/Info.plist"),
            bundle.appendingPathComponent("Resources/Info.plist"),
        ] where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    static func inspect(bundle: URL, root: URL) -> BundleReport {
        let prefix = root.path + "/"
        let relative = bundle.path.hasPrefix(prefix) ? String(bundle.path.dropFirst(prefix.count)) : bundle.lastPathComponent
        var report = BundleReport(
            path: relative,
            bundleId: nil, version: nil, build: nil, minOS: nil, hasPrivacyManifest: false
        )
        guard let plistURL = infoPlist(in: bundle),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return report }

        report.bundleId = plist["CFBundleIdentifier"] as? String
        report.version = plist["CFBundleShortVersionString"] as? String
        report.build = plist["CFBundleVersion"] as? String
        report.minOS = (plist["MinimumOSVersion"] as? String) ?? (plist["LSMinimumSystemVersion"] as? String)
        report.hasPrivacyManifest = [
            bundle.appendingPathComponent("PrivacyInfo.xcprivacy"),
            bundle.appendingPathComponent("Contents/Resources/PrivacyInfo.xcprivacy"),
            bundle.appendingPathComponent("Resources/PrivacyInfo.xcprivacy"),
        ].contains { FileManager.default.fileExists(atPath: $0.path) }
        return report
    }

    /// Numeric dot-component compare: `15.0` < `15.0.1` < `16.0`.
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

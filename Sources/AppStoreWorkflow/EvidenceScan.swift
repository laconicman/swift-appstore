import Foundation

/// Evidence harvested from an app project — the raw material questionnaire sheets cite.
/// Every entry names the file it came from; nothing here answers a question, it only
/// reports what the project declares or references.
public struct ProjectEvidence: Sendable {
    /// One `NSPrivacyCollectedDataTypes` entry — a declared data type plus the
    /// manifest's optional linked/tracking/purposes fields.
    public struct CollectedDatum: Sendable, Equatable {
        /// `NSPrivacyCollectedDataType`; "?" when the manifest omits the key.
        public var dataType: String
        /// `NSPrivacyCollectedDataTypePurposes` — nil when the manifest omits the
        /// key; unknown is not false.
        public var purposes: [String]?
        /// `NSPrivacyCollectedDataTypeLinked` — nil when omitted.
        public var linked: Bool?
        /// `NSPrivacyCollectedDataTypeTracking` — nil when omitted.
        public var tracking: Bool?
        /// Repo-relative path of the manifest the entry came from.
        public var source: String
    }
    /// One `NSPrivacyAccessedAPITypes` entry — a required-reason API category and
    /// the manifest's declared reasons for calling it.
    public struct AccessedAPI: Sendable, Equatable {
        /// `NSPrivacyAccessedAPIType` (e.g. `NSPrivacyAccessedAPICategoryUserDefaults`).
        public var type: String
        /// `NSPrivacyAccessedAPITypeReasons` codes.
        public var reasons: [String]
        /// Repo-relative path of the manifest the entry came from.
        public var source: String
    }
    /// A signal symbol found in a `.swift` source file — evidence of presence only.
    /// A text hit is not proof of a live code path; sheets cite it as "referenced by".
    public struct Signal: Sendable, Equatable {
        public var name: String
        public var file: String
    }

    /// `NSPrivacyCollectedDataTypes` entries, one record per manifest item.
    public var collectedData: [CollectedDatum] = []
    /// `NSPrivacyAccessedAPITypes` (required-reason APIs), one record per manifest item.
    public var accessedAPIs: [AccessedAPI] = []
    /// `NSPrivacyTracking` as declared per manifest — a manifest that omits the key
    /// produced no entry, so "all false" is provable only when every manifest appears here.
    public var trackingDeclarations: [(value: Bool, source: String)] = []
    /// `NSPrivacyTrackingDomains` entries across manifests.
    public var trackingDomains: [String] = []
    /// `ITSAppUsesNonExemptEncryption` occurrences (value, plist path) — the app target's
    /// plist is authoritative, but conflicting declarations across bundles are surfaced.
    public var encryptionDeclarations: [(value: Bool, source: String)] = []
    /// `*UsageDescription` keys found in Info.plists — privacy-relevant capabilities.
    public var usageDescriptions: [(key: String, source: String)] = []
    /// `UIBackgroundModes` values found in Info.plists.
    public var backgroundModes: [(mode: String, source: String)] = []
    /// Entitlement key → compact value summary, per file.
    public var entitlements: [(key: String, summary: String, source: String)] = []
    /// `.framework`/`.tbd` names linked per `project.pbxproj`.
    public var linkedFrameworks: [String] = []
    /// SwiftPM dependency URLs from `project.pbxproj` or `Package.swift` manifests.
    public var packageDependencies: [String] = []
    /// Signal hits: symbol → file, sorted. A hit is evidence of a reference, nothing more.
    public var signals: [Signal] = []
    /// Symbols that were searched for and not found — evidence of absence.
    public var absentSignals: [String] = []
    /// Source files too large or unreadable to scan — their presence means absence
    /// claims are not backed by complete coverage.
    public var skippedSourceFiles: [String] = []
    /// Source files actually examined — a `No` answer needs this non-empty plus
    /// `skippedSourceFiles` empty to claim real coverage.
    public var scannedSourceFiles: [String] = []
    /// Repo-relative paths of every file that fed the evidence, sorted.
    public var filesScanned: [String] = []
    /// Same paths bucketed by role — sheets cite only the buckets they depend on, so a
    /// change flags exactly the sheets whose inputs moved.
    public var plistFiles: [String] = []
    public var privacyManifestFiles: [String] = []
    public var entitlementFiles: [String] = []
    public var projectFiles: [String] = []
    public var signalFiles: [String] = []

    public init() {}
}

/// Project-tree evidence collector for `asc questionnaire`. Pure reads, no network —
/// the scanner reports what files declare; interpretation lives in `Questionnaire`.
public enum EvidenceScan {
    /// Symbols whose presence/absence in `.swift` sources feeds questionnaire answers.
    /// Absence is only evidence of "not referenced", never proof of "not used".
    public static let signalSymbols = [
        "SFSpeechRecognizer", "requiresOnDeviceRecognition",
        "WKWebView", "SFSafariViewController", "UIWebView",
        "ATTrackingManager", "ASIdentifierManager",
        "HKHealthStore", "CLLocationManager", "CNContactStore",
        "PHPhotoLibrary", "AVCaptureDevice",
        "NSUserActivity", "SKAdNetwork",
        "accessibilityLabel", "accessibilityHint", "accessibilityValue", "UIAccessibility",
    ]

    private static let skippedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage", "node_modules",
    ]
    /// Signal scanning reads text; cap per file so a checked-in blob can't stall the scan.
    private static let maxSourceBytes = 512 * 1024
    /// Credential-shaped names/extensions are never opened — the scan is read-only but
    /// must not even read a `.p8` or env file that happens to sit in the source tree.
    private static let sensitiveFileNames: Set<String> = ["demo_password.txt", ".env"]
    private static let sensitiveExtensions: Set<String> = ["p8", "pem", "key", "p12", "mobileprovision"]
    /// Source files the signal scan reads — Swift plus the ObjC/C/C++ family, since an
    /// app can implement the scanned features in any of them.
    private static let sourceExtensions: Set<String> = ["swift", "m", "mm", "h", "c", "cc", "cpp", "hpp"]
    /// Markdown/HTML characters stripped from untrusted evidence text (paths, plist
    /// values) before it reaches a sheet — evidence must not be able to author markup.
    private static let markupCharacters = CharacterSet(charactersIn: "[]<>`*_#|~\r\n")

    /// Removes markup-significant characters and line breaks from untrusted text.
    static func sanitized(_ text: String) -> String {
        String(text.unicodeScalars.filter { !markupCharacters.contains($0) })
    }

    /// Walks `root` for evidence files and parses each into `ProjectEvidence`. Read-only;
    /// deterministic — recognized files are bucketed during traversal, then processed in
    /// sorted path order, and every emitted list is sorted before returning.
    public static func scan(root: URL) throws -> ProjectEvidence {
        // Resolve symlinks up front: the directory enumerator yields resolved paths,
        // so an unresolved root (/var → /private/var) would mangle every relative path.
        let root = ASCConfiguration.fullyResolved(root)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            throw WorkflowError.misconfigured("app source not found: \(root.path)")
        }
        var evidence = ProjectEvidence()
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WorkflowError.misconfigured("cannot enumerate \(root.path)")
        }
        var buckets: [(URL, String, WritableKeyPath<ProjectEvidence, [String]>?)] = []
        var swiftFiles: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let name = url.lastPathComponent, ext = url.pathExtension
            // Check the symlink target too — a link named `Info.plist` must not be
            // allowed to open a `.p8` or other credential file it points at.
            let resolved = url.resolvingSymlinksInPath()
            if sensitiveFileNames.contains(name) || sensitiveExtensions.contains(ext)
                || sensitiveFileNames.contains(resolved.lastPathComponent)
                || sensitiveExtensions.contains(resolved.pathExtension) { continue }
            let rel = sanitized(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            switch name {
            case "Info.plist": buckets.append((url, rel, \ProjectEvidence.plistFiles))
            case "PrivacyInfo.xcprivacy": buckets.append((url, rel, \ProjectEvidence.privacyManifestFiles))
            case "project.pbxproj", "Package.swift", "Podfile", "Podfile.lock":
                buckets.append((url, rel, \ProjectEvidence.projectFiles))
            default:
                if ext == "entitlements" { buckets.append((url, rel, \ProjectEvidence.entitlementFiles)) }
                else if sourceExtensions.contains(ext) { swiftFiles.append(url) }
            }
        }
        for (url, rel, bucket) in buckets.sorted(by: { $0.1 < $1.1 }) {
            switch url.lastPathComponent {
            case "Info.plist": try readInfoPlist(url, rel: rel, into: &evidence)
            case "PrivacyInfo.xcprivacy": try readPrivacyManifest(url, rel: rel, into: &evidence)
            case "project.pbxproj": try readProject(url, rel: rel, into: &evidence)
            case "Package.swift": try readPackageManifest(url, rel: rel, into: &evidence)
            case "Podfile", "Podfile.lock": try readPodfile(url, rel: rel, into: &evidence)
            default: try readEntitlements(url, rel: rel, into: &evidence)
            }
            evidence.filesScanned.append(rel)
            if let bucket { evidence[keyPath: bucket].append(rel) }
        }
        try scanSignals(swiftFiles.sorted(by: { $0.path < $1.path }), root: root, into: &evidence)
        evidence.filesScanned = Set(evidence.filesScanned).sorted()
        evidence.collectedData.sort { ($0.source, $0.dataType) < ($1.source, $1.dataType) }
        evidence.accessedAPIs.sort { ($0.source, $0.type) < ($1.source, $1.type) }
        evidence.trackingDeclarations.sort { $0.source < $1.source }
        evidence.trackingDomains.sort()
        evidence.encryptionDeclarations.sort { $0.source < $1.source }
        evidence.usageDescriptions.sort { ($0.source, $0.key) < ($1.source, $1.key) }
        evidence.backgroundModes.sort { ($0.source, $0.mode) < ($1.source, $1.mode) }
        evidence.entitlements.sort { ($0.source, $0.key) < ($1.source, $1.key) }
        evidence.skippedSourceFiles.sort()
        evidence.scannedSourceFiles.sort()
        return evidence
    }

    // MARK: - per-file readers

    private static func plist(_ url: URL) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return nil
        }
        return object as? [String: Any]
    }

    private static func readInfoPlist(_ url: URL, rel: String, into e: inout ProjectEvidence) throws {
        guard let plist = try plist(url) else {
            throw WorkflowError.misconfigured("unreadable plist: \(rel)")
        }
        if let flag = plist["ITSAppUsesNonExemptEncryption"] as? Bool {
            e.encryptionDeclarations.append((flag, rel))
        }
        for key in plist.keys.sorted() where key.hasSuffix("UsageDescription") {
            e.usageDescriptions.append((key: sanitized(key), source: rel))
        }
        if let modes = plist["UIBackgroundModes"] as? [String] {
            for mode in modes.sorted() { e.backgroundModes.append((sanitized(mode), rel)) }
        }
    }

    private static func readPrivacyManifest(_ url: URL, rel: String, into e: inout ProjectEvidence) throws {
        guard let plist = try plist(url) else {
            throw WorkflowError.misconfigured("unreadable plist: \(rel)")
        }
        if let tracking = plist["NSPrivacyTracking"] as? Bool {
            e.trackingDeclarations.append((tracking, rel))
        }
        if let domains = plist["NSPrivacyTrackingDomains"] as? [String] {
            e.trackingDomains.append(contentsOf: domains)
        }
        for item in plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [] {
            e.collectedData.append(.init(
                dataType: sanitized(item["NSPrivacyCollectedDataType"] as? String ?? "?"),
                purposes: (item["NSPrivacyCollectedDataTypePurposes"] as? [String])?.map(sanitized),
                linked: item["NSPrivacyCollectedDataTypeLinked"] as? Bool,
                tracking: item["NSPrivacyCollectedDataTypeTracking"] as? Bool,
                source: rel
            ))
        }
        for item in plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [] {
            e.accessedAPIs.append(.init(
                type: sanitized(item["NSPrivacyAccessedAPIType"] as? String ?? "?"),
                reasons: (item["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []).map(sanitized),
                source: rel
            ))
        }
    }

    private static func readEntitlements(_ url: URL, rel: String, into e: inout ProjectEvidence) throws {
        guard let plist = try plist(url) else {
            throw WorkflowError.misconfigured("unreadable plist: \(rel)")
        }
        for key in plist.keys.sorted() {
            let value = plist[key]!
            let summary: String
            switch value {
            case let b as Bool: summary = "\(b)"
            case let s as String: summary = sanitized(s)
            case let a as [String]: summary = sanitized(a.joined(separator: ","))
            case let a as [Any]: summary = "[\(a.count) items]"
            default: summary = "…"
            }
            e.entitlements.append((key: sanitized(key), summary: summary, source: rel))
        }
    }

    private static func readProject(_ url: URL, rel: String, into e: inout ProjectEvidence) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw WorkflowError.misconfigured("unreadable project file: \(rel)")
        }
        var frameworks = Set<String>()
        for match in text.matches(of: /([A-Za-z0-9_+.-]+\.(?:framework|tbd))/) {
            frameworks.insert(sanitized(String(match.1)))
        }
        e.linkedFrameworks.append(contentsOf: frameworks)
        for match in text.matches(of: /repositoryURL = "([^"]+)"/) {
            e.packageDependencies.append(sanitized(String(match.1)))
        }
        e.linkedFrameworks = Array(Set(e.linkedFrameworks)).sorted()
        e.packageDependencies = Array(Set(e.packageDependencies)).sorted()
    }

    /// SwiftPM-only projects have no `project.pbxproj` — `.package(url:)` declarations
    /// in the manifest are the dependency inventory there.
    private static func readPackageManifest(_ url: URL, rel: String, into e: inout ProjectEvidence) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw WorkflowError.misconfigured("unreadable package manifest: \(rel)")
        }
        for match in text.matches(of: /\.package\(url:\s*"([^"]+)"/) {
            e.packageDependencies.append(sanitized(String(match.1)))
        }
        e.packageDependencies = Array(Set(e.packageDependencies)).sorted()
    }

    /// CocoaPods manifests are dependency inventories too: `pod 'Name'` declarations
    /// in a Podfile, `- Name (version)` pins in Podfile.lock.
    private static func readPodfile(_ url: URL, rel: String, into e: inout ProjectEvidence) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw WorkflowError.misconfigured("unreadable pod manifest: \(rel)")
        }
        for match in text.matches(of: /pod\s+['"]([^'"]+)['"]/) {
            e.packageDependencies.append(sanitized(String(match.1)))
        }
        for match in text.matches(of: /^\s+- ([A-Za-z0-9_+\/.-]+)\s*\(/.anchorsMatchLineEndings()) {
            e.packageDependencies.append(sanitized(String(match.1)))
        }
        e.packageDependencies = Array(Set(e.packageDependencies)).sorted()
    }

    private static func scanSignals(_ files: [URL], root: URL, into e: inout ProjectEvidence) throws {
        var found: [String: Set<String>] = [:]
        for url in files.sorted(by: { $0.path < $1.path }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rel = sanitized(url.path.replacingOccurrences(of: root.path + "/", with: ""))
            guard size <= maxSourceBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                e.skippedSourceFiles.append(rel)
                continue
            }
            e.scannedSourceFiles.append(rel)
            e.filesScanned.append(rel)
            var touched = false
            for symbol in signalSymbols where matched(symbol, in: text) {
                found[symbol, default: []].insert(rel)
                touched = true
            }
            if touched { e.filesScanned.append(rel); e.signalFiles.append(rel) }
        }
        for symbol in signalSymbols {
            if let files = found[symbol] {
                for file in files.sorted() { e.signals.append(.init(name: symbol, file: file)) }
            } else {
                e.absentSignals.append(symbol)
            }
        }
    }

    /// Presence test per symbol. Most symbols are evidence by mention; the on-device
    /// speech pin only counts when a non-comment line assigns it `true` — a comment or
    /// `= false` must not close the destination question.
    private static func matched(_ symbol: String, in text: String) -> Bool {
        guard symbol == "requiresOnDeviceRecognition" else { return text.contains(symbol) }
        for rawLine in text.split(separator: "\n") {
            let code = rawLine.range(of: "//").map { rawLine[..<$0.lowerBound] } ?? rawLine
            if code.firstMatch(of: /requiresOnDeviceRecognition\s*=\s*true/) != nil { return true }
        }
        return false
    }
}

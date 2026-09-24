import Foundation

/// Evidence harvested from an app project — the raw material questionnaire sheets cite.
/// Every entry names the file it came from; nothing here answers a question, it only
/// reports what the project declares or references.
public struct ProjectEvidence: Sendable {
    public struct CollectedDatum: Sendable, Equatable {
        public var dataType: String
        public var purposes: [String]
        public var linked: Bool
        public var tracking: Bool
        public var source: String
    }
    public struct AccessedAPI: Sendable, Equatable {
        public var type: String
        public var reasons: [String]
        public var source: String
    }
    /// A signal symbol found in a `.swift` source file — evidence of presence only.
    /// A text hit is not proof of a live code path; sheets cite it as "referenced by".
    public struct Signal: Sendable, Equatable {
        public var name: String
        public var file: String
    }

    public var collectedData: [CollectedDatum] = []
    public var accessedAPIs: [AccessedAPI] = []
    /// `NSPrivacyTracking` — nil when no privacy manifest was found at all.
    public var trackingDeclared: Bool?
    public var trackingDomains: [String] = []
    /// `ITSAppUsesNonExemptEncryption` occurrences (value, plist path) — the app target's
    /// plist is authoritative, but conflicting declarations across bundles are surfaced.
    public var encryptionDeclarations: [(value: Bool, source: String)] = []
    public var usageDescriptions: [(key: String, source: String)] = []
    public var backgroundModes: [(mode: String, source: String)] = []
    /// Entitlement key → compact value summary, per file.
    public var entitlements: [(key: String, summary: String, source: String)] = []
    public var linkedFrameworks: [String] = []
    public var packageDependencies: [String] = []
    public var signals: [Signal] = []
    /// Symbols that were searched for and not found — evidence of absence.
    public var absentSignals: [String] = []
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
    ]

    private static let skippedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "Pods", "Carthage", "node_modules",
    ]
    /// Signal scanning reads text; cap per file so a checked-in blob can't stall the scan.
    private static let maxSourceBytes = 512 * 1024

    public static func scan(root: URL) throws -> ProjectEvidence {
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
        var swiftFiles: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            switch url.lastPathComponent {
            case "Info.plist":
                try readInfoPlist(url, rel: rel, into: &evidence)
            case "PrivacyInfo.xcprivacy":
                try readPrivacyManifest(url, rel: rel, into: &evidence)
            case "project.pbxproj":
                try readProject(url, rel: rel, into: &evidence)
            default:
                if url.pathExtension == "entitlements" {
                    try readEntitlements(url, rel: rel, into: &evidence)
                    evidence.filesScanned.append(rel)
                    evidence.entitlementFiles.append(rel)
                } else if url.pathExtension == "swift" {
                    swiftFiles.append(url)
                }
                continue
            }
            evidence.filesScanned.append(rel)
            switch url.lastPathComponent {
            case "Info.plist": evidence.plistFiles.append(rel)
            case "PrivacyInfo.xcprivacy": evidence.privacyManifestFiles.append(rel)
            case "project.pbxproj": evidence.projectFiles.append(rel)
            default: break
            }
        }
        try scanSignals(swiftFiles, root: root, into: &evidence)
        evidence.filesScanned = Set(evidence.filesScanned).sorted()
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
        for (key, _) in plist where key.hasSuffix("UsageDescription") {
            e.usageDescriptions.append((key: key, source: rel))
        }
        if let modes = plist["UIBackgroundModes"] as? [String] {
            for mode in modes { e.backgroundModes.append((mode, rel)) }
        }
    }

    private static func readPrivacyManifest(_ url: URL, rel: String, into e: inout ProjectEvidence) throws {
        guard let plist = try plist(url) else {
            throw WorkflowError.misconfigured("unreadable plist: \(rel)")
        }
        if let tracking = plist["NSPrivacyTracking"] as? Bool {
            e.trackingDeclared = (e.trackingDeclared ?? false) || tracking
        }
        if let domains = plist["NSPrivacyTrackingDomains"] as? [String] {
            e.trackingDomains.append(contentsOf: domains)
        }
        for item in plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? [] {
            e.collectedData.append(.init(
                dataType: item["NSPrivacyCollectedDataType"] as? String ?? "?",
                purposes: item["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? [],
                linked: item["NSPrivacyCollectedDataTypeLinked"] as? Bool ?? false,
                tracking: item["NSPrivacyCollectedDataTypeTracking"] as? Bool ?? false,
                source: rel
            ))
        }
        for item in plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [] {
            e.accessedAPIs.append(.init(
                type: item["NSPrivacyAccessedAPIType"] as? String ?? "?",
                reasons: item["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [],
                source: rel
            ))
        }
    }

    private static func readEntitlements(_ url: URL, rel: String, into e: inout ProjectEvidence) throws {
        guard let plist = try plist(url) else {
            throw WorkflowError.misconfigured("unreadable plist: \(rel)")
        }
        for (key, value) in plist {
            let summary: String
            switch value {
            case let b as Bool: summary = "\(b)"
            case let s as String: summary = s
            case let a as [String]: summary = a.joined(separator: ",")
            case let a as [Any]: summary = "[\(a.count) items]"
            default: summary = "…"
            }
            e.entitlements.append((key: key, summary: summary, source: rel))
        }
    }

    private static func readProject(_ url: URL, rel: String, into e: inout ProjectEvidence) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw WorkflowError.misconfigured("unreadable project file: \(rel)")
        }
        var frameworks = Set<String>()
        for match in text.matches(of: /([A-Za-z0-9_+.-]+\.(?:framework|tbd))/) {
            frameworks.insert(String(match.1))
        }
        e.linkedFrameworks.append(contentsOf: frameworks)
        for match in text.matches(of: /repositoryURL = "([^"]+)"/) {
            e.packageDependencies.append(String(match.1))
        }
        e.linkedFrameworks = Array(Set(e.linkedFrameworks)).sorted()
        e.packageDependencies = Array(Set(e.packageDependencies)).sorted()
    }

    private static func scanSignals(_ files: [URL], root: URL, into e: inout ProjectEvidence) throws {
        var found: [String: Set<String>] = [:]
        for url in files.sorted(by: { $0.path < $1.path }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxSourceBytes,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            var touched = false
            for symbol in signalSymbols where text.contains(symbol) {
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
}

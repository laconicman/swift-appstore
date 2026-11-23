import Foundation
import Yams

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
    /// `NSPrivacyTrackingDomains` entries, each with the manifest that declared it.
    public var trackingDomains: [(domain: String, source: String)] = []
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
    /// Dependency manifests the scan actually read — `project.pbxproj`,
    /// `Package.swift`, `Podfile`/`Podfile.lock`. Distinct from `projectFiles`,
    /// which also holds XcodeGen `project.yml` and `.xcconfig` files that carry
    /// build settings but no dependency inventory this scan extracts. The SDK
    /// question's "none found" answer is only honest when one of these was seen.
    public var dependencyFiles: [String] = []
    /// Files whose `INFOPLIST_KEY_*` build settings generate Info.plist entries at
    /// build time — XcodeGen `project.yml`, `.xcconfig`. Distinct from `plistFiles`
    /// because the keys arrive via build settings, not a literal plist.
    public var infoplistSettingFiles: [String] = []

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
            case "project.pbxproj", "Package.swift", "Podfile", "Podfile.lock", "project.yml":
                buckets.append((url, rel, \ProjectEvidence.projectFiles))
            default:
                if ext == "entitlements" { buckets.append((url, rel, \ProjectEvidence.entitlementFiles)) }
                else if ext == "xcconfig" { buckets.append((url, rel, \ProjectEvidence.projectFiles)) }
                else if sourceExtensions.contains(ext) { swiftFiles.append(url) }
            }
        }
        // `.xcconfig` files carry no target of their own; `project.yml`'s
        // `configFiles:` references are the only provenance available, so a config
        // referenced solely by non-app targets cannot declare the shipping app's
        // plist settings. Each spec is parsed once here — the same effective-target
        // resolution feeds both the exclusion set and the evidence readers.
        var xcodeGenDocs: [String: Node] = [:]
        var extensionOnlyConfigs = Set<String>()
        for (url, _, _) in buckets where url.lastPathComponent == "project.yml" {
            let resolved = ASCConfiguration.fullyResolved(url).path
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let doc = try? Yams.compose(yaml: text)
            else { continue }
            xcodeGenDocs[resolved] = doc
            extensionOnlyConfigs.formUnion(
                xcodeGenExtensionOnlyConfigs(doc, directory: url.deletingLastPathComponent()))
        }
        // `INFOPLIST_FILE` targets that are themselves bucketed (a real `Info.plist`)
        // must not be read twice — compare on the same realpath basis `fullyResolved` gives.
        let knownFiles = Set(buckets.map { ASCConfiguration.fullyResolved($0.0).path })
        for (url, rel, bucket) in buckets.sorted(by: { $0.1 < $1.1 }) {
            switch url.lastPathComponent {
            case "Info.plist": try readInfoPlist(url, rel: rel, into: &evidence)
            case "PrivacyInfo.xcprivacy": try readPrivacyManifest(url, rel: rel, into: &evidence)
            case "project.pbxproj": try readProject(url, rel: rel, into: &evidence)
            case "Package.swift": try readPackageManifest(url, rel: rel, into: &evidence)
            case "Podfile", "Podfile.lock": try readPodfile(url, rel: rel, into: &evidence)
            case "project.yml":
                try readXcodeGenProject(
                    url, rel: rel, root: root, knownFiles: knownFiles,
                    doc: xcodeGenDocs[ASCConfiguration.fullyResolved(url).path], into: &evidence)
            default:
                if url.pathExtension == "xcconfig" {
                    try readXCConfig(url, rel: rel, extensionOnly: extensionOnlyConfigs, into: &evidence)
                } else {
                    try readEntitlements(url, rel: rel, into: &evidence)
                }
            }
            evidence.filesScanned.append(rel)
            if let bucket { evidence[keyPath: bucket].append(rel) }
        }
        try scanSignals(swiftFiles.sorted(by: { $0.path < $1.path }), root: root, into: &evidence)
        evidence.filesScanned = Set(evidence.filesScanned).sorted()
        evidence.collectedData.sort { ($0.source, $0.dataType) < ($1.source, $1.dataType) }
        evidence.accessedAPIs.sort { ($0.source, $0.type) < ($1.source, $1.type) }
        evidence.trackingDeclarations.sort { $0.source < $1.source }
        evidence.trackingDomains.sort { ($0.source, $0.domain) < ($1.source, $1.domain) }
        evidence.encryptionDeclarations.sort { $0.source < $1.source }
        evidence.usageDescriptions.sort { ($0.source, $0.key) < ($1.source, $1.key) }
        evidence.backgroundModes.sort { ($0.source, $0.mode) < ($1.source, $1.mode) }
        evidence.entitlements.sort { ($0.source, $0.key) < ($1.source, $1.key) }
        // `INFOPLIST_FILE` targets are appended while their `project.yml` is processed,
        // which can land out of path order — sort so the bucket stays deterministic.
        evidence.plistFiles.sort()
        evidence.infoplistSettingFiles.sort()
        evidence.dependencyFiles.sort()
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
            for domain in domains.sorted() {
                e.trackingDomains.append((sanitized(domain), rel))
            }
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
        e.dependencyFiles.append(rel)
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
        e.dependencyFiles.append(rel)
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
        e.dependencyFiles.append(rel)
    }

    /// XcodeGen `project.yml` is a build-settings source, not a plist: `INFOPLIST_KEY_*`
    /// entries become Info.plist keys at build time, `INFOPLIST_FILE` can point at a
    /// partial plist (the merge pattern for keys the settings cannot express), and
    /// `info:`/`entitlements:` `properties` declare plist content inline. All are
    /// evidence a literal-`Info.plist` scan cannot see — issue #30. Specs brought in
    /// through XcodeGen's `include:` are not followed; the file itself is the spec.
    ///
    /// Only declarations that apply to the shipping app are evidence: the project-level
    /// `settings` every target inherits, each effective `type: application` target's
    /// `settings`, `info:` and `templates:`-supplied settings — resolved with
    /// XcodeGen's own layering, so a template default a concrete target overrides
    /// does not fabricate a conflict — and the `settingGroups` those pull in, at any
    /// `configs.*` level. An app-extension's declaration answers for the extension's
    /// own bundle — attributing it to the app would fabricate an export-compliance
    /// answer.
    private static func readXcodeGenProject(
        _ url: URL, rel: String, root: URL, knownFiles: Set<String>,
        doc providedDoc: Node?, into e: inout ProjectEvidence
    ) throws {
        let doc: Node?
        if let providedDoc {
            doc = providedDoc
        } else {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw WorkflowError.misconfigured("unreadable project file: \(rel)")
            }
            do {
                doc = try Yams.compose(yaml: text)
            } catch {
                // XcodeGen parses project.yml with the same library — a file Yams
                // rejects cannot generate a project either, so it is a broken file,
                // not missing evidence.
                throw WorkflowError.misconfigured("unparseable project file: \(rel)")
            }
        }
        guard let doc else { return }
        let sources = appSettingsSources(doc)
        var settings = sources.settings
        var plistPaths = sources.plistPaths
        // `info.properties` is plist content declared inline — the same evidence
        // `INFOPLIST_KEY_*` settings carry, minus the prefix.
        for pairs in sources.infoProperties {
            for (key, value) in pairs {
                settings.append((key, yamlStrings(value)))
            }
        }
        recordInfoplistSettings(settings, rel: rel, into: &e)
        // `entitlements.properties` is likewise inline `.entitlements` content.
        var seenEntitlements = Set<String>()
        for pairs in sources.entitlementProperties {
            for (key, value) in pairs {
                let entry = (key: sanitized(key), summary: yamlSummary(value), source: rel)
                if seenEntitlements.insert("\(entry.key)\u{0}\(entry.summary)").inserted {
                    e.entitlements.append(entry)
                }
            }
        }
        // Follow `INFOPLIST_FILE` targets so the partial plist's keys are evidence too.
        // Anything unresolvable or absent is skipped — the file may be generated.
        let directory = url.deletingLastPathComponent()
        for path in plistPaths {
            // `fullyResolved` puts the target on the same realpath basis as `root`,
            // so the repo-relative path strips cleanly even through /var symlinks.
            let resolved = projectPathURL(path, directory: directory)
            // Same discipline as the walk: only regular files inside the scanned
            // root, and never credential-shaped names — the scan must not even
            // read a `.p8`, and must not block on a FIFO the project happens to name.
            guard resolved.path.hasPrefix(root.path + "/"),
                  !knownFiles.contains(resolved.path),
                  !sensitiveFileNames.contains(resolved.lastPathComponent),
                  !sensitiveExtensions.contains(resolved.pathExtension),
                  (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            let targetRel = sanitized(resolved.path.replacingOccurrences(of: root.path + "/", with: ""))
            guard !e.plistFiles.contains(targetRel) else { continue }
            try readInfoPlist(resolved, rel: targetRel, into: &e)
            e.filesScanned.append(targetRel)
            e.plistFiles.append(targetRel)
        }
    }

    /// Resolves a path written inside `project.yml` — `$(SRCROOT)`/`$(PROJECT_DIR)`
    /// anchor at the spec's directory — onto the same realpath basis as `root`.
    private static func projectPathURL(_ path: String, directory: URL) -> URL {
        var path = path
        for variable in ["$(SRCROOT)", "$(PROJECT_DIR)"] where path.hasPrefix(variable) {
            path = String(path.dropFirst(variable.count))
            if path.hasPrefix("/") { path.removeFirst() }
            break
        }
        let target = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : directory.appendingPathComponent(path)
        return ASCConfiguration.fullyResolved(target)
    }

    /// The `.xcconfig` realpaths a `project.yml` ties exclusively to non-app targets —
    /// extension and test-bundle `configFiles:` (project-level references apply to the
    /// app too, so they never land here). Targets classify by their *effective* spec —
    /// a `type:` or `configFiles:` supplied through `targetTemplates` counts — and an
    /// app config's `#include`d files are app evidence even when a non-app target
    /// names them directly. Unparseable specs yield nothing: the file is broken
    /// evidence either way, and `readXcodeGenProject` reports it properly.
    private static func xcodeGenExtensionOnlyConfigs(_ doc: Node, directory: URL) -> Set<String> {
        let targetPairs = lookup(doc, "targets").map { effectivePairs($0) } ?? []
        var appConfigs = Set<String>()
        var otherConfigs = Set<String>()
        // Project-level configFiles apply to every target — app-scoped whenever the
        // spec can produce an app, or declares no targets to scope by at all;
        // otherwise they can only belong to the non-app targets.
        let hasApp = targetPairs.isEmpty
            || targetPairs.contains { effectiveTargetType($0.value, doc: doc) == "application" }
        if let configFiles = lookup(doc, "configFiles") {
            if hasApp {
                collectConfigFiles(configFiles, directory: directory, into: &appConfigs)
            } else {
                collectConfigFiles(configFiles, directory: directory, into: &otherConfigs)
            }
        }
        for pair in targetPairs {
            let target = pair.value
            var configs = Set<String>()
            if let configFiles = lookup(target, "configFiles") {
                collectConfigFiles(configFiles, directory: directory, into: &configs)
            }
            for template in flattenedTemplates(target, doc: doc) {
                if let configFiles = lookup(template, "configFiles") {
                    collectConfigFiles(configFiles, directory: directory, into: &configs)
                }
            }
            if effectiveTargetType(target, doc: doc) == "application" {
                appConfigs.formUnion(configs)
            } else {
                otherConfigs.formUnion(configs)
            }
        }
        // An `#include` inside an app config pulls the included file into the app's
        // build settings — app evidence even when a non-app target references it
        // directly. Includes chain; the visited set stops cycles. Plain relative
        // paths resolve against the including file; `$(SRCROOT)`/`$(PROJECT_DIR)`
        // anchor at the spec's directory like every other project.yml path.
        var queue = Array(appConfigs)
        while let config = queue.popLast() {
            guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { continue }
            for match in text.matches(
                of: /^[ \t]*#include\??[ \t]+"([^"]+)"/.anchorsMatchLineEndings()
            ) {
                let path = String(match.1)
                let anchored = path.hasPrefix("$(SRCROOT)") || path.hasPrefix("$(PROJECT_DIR)")
                let included = projectPathURL(
                    path,
                    directory: anchored
                        ? directory
                        : URL(fileURLWithPath: config).deletingLastPathComponent())
                if appConfigs.insert(included.path).inserted { queue.append(included.path) }
            }
        }
        return otherConfigs.subtracting(appConfigs)
    }

    /// Every path inside a `configFiles:` value — a scalar, a per-config mapping, or
    /// a sequence — resolved to a realpath. Mapping values may arrive through a YAML
    /// `<<` merge, so pairs come from `effectivePairs`.
    private static func collectConfigFiles(_ node: Node, directory: URL, into paths: inout Set<String>) {
        if let scalar = node.scalar {
            paths.insert(projectPathURL(scalar.string, directory: directory).path)
        } else if node.mapping != nil {
            for (_, value) in effectivePairs(node) {
                collectConfigFiles(value, directory: directory, into: &paths)
            }
        } else if let sequence = node.sequence {
            for element in sequence {
                collectConfigFiles(element, directory: directory, into: &paths)
            }
        }
    }

    /// `.xcconfig` files are the other home of `INFOPLIST_KEY_*` build settings — same
    /// generated-plist evidence in `KEY = value` syntax with `//` comments. A config
    /// `project.yml` ties only to non-app targets is skipped: it declares the
    /// extension's bundle, not the shipping app's. Configs with no project.yml
    /// provenance — `project.pbxproj` references, or none at all — stay unscoped.
    private static func readXCConfig(
        _ url: URL, rel: String, extensionOnly: Set<String>, into e: inout ProjectEvidence
    ) throws {
        guard !extensionOnly.contains(ASCConfiguration.fullyResolved(url).path) else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw WorkflowError.misconfigured("unreadable build settings: \(rel)")
        }
        var settings: [(key: String, values: [String])] = []
        // `.newlines`, not `split(separator: "\n")`: a CRLF pair is one Character,
        // so the LF separator would never match and the whole file reads as one line.
        for line in text.components(separatedBy: .newlines) {
            guard let match = line.firstMatch(
                of: /^[ \t]*INFOPLIST_KEY_([A-Za-z0-9_]+)[ \t]*=[ \t]*(.*)$/
            ) else { continue }
            var value = String(match.2)
            if let comment = value.range(of: "//") { value = String(value[..<comment.lowerBound]) }
            value = unquote(value).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            settings.append((String(match.1), [value]))
        }
        recordInfoplistSettings(settings, rel: rel, into: &e)
    }

    /// What `project.yml` declares that applies to the shipping app, with XcodeGen's
    /// layering already resolved: winning `(key, values)` build-setting declarations,
    /// partial-plist paths to follow, and each app target's merged inline plist
    /// properties (`info:`/`entitlements:`).
    private struct XcodeGenEvidenceSources {
        var settings: [(key: String, values: [String])] = []
        var plistPaths: [String] = []
        var infoProperties: [[(key: String, value: Node)]] = []
        var entitlementProperties: [[(key: String, value: Node)]] = []
    }

    /// One `INFOPLIST_KEY_*`/`INFOPLIST_FILE` declaration plus the precedence
    /// XcodeGen's layering gives it: `scope` is the `configs.*` name it applies to
    /// ("" = every config), `sourceRank` orders project < templates (in order) <
    /// the target itself, and `groupDepth` orders a settings object's own
    /// declarations above its `groups` references.
    private struct DeclaredSetting {
        var name: String
        var values: [String]
        var scope: String
        var sourceRank: Int
        var groupDepth: Int
    }

    /// The declarations that apply to the shipping app, resolved per effective
    /// application target the way XcodeGen's spec loader resolves them: project
    /// `settings` rank below the target's flattened `templates:` (each template's
    /// nested templates first, later entries higher), which rank below the target's
    /// own — and within one settings object a `groups` reference ranks below the
    /// object's own keys, at whatever `configs.*` level it was referenced.
    /// Declarations for different `configs.*` scopes are *not* conflicts — they are
    /// the per-config values Xcode would actually build. A spec with no `targets`
    /// gives no scope to judge by, so project-level declarations stay unscoped;
    /// a spec whose targets are all non-app has no shipping app to describe.
    private static func appSettingsSources(_ doc: Node) -> XcodeGenEvidenceSources {
        var sources = XcodeGenEvidenceSources()
        let targetPairs = lookup(doc, "targets").map { effectivePairs($0) } ?? []
        let apps = targetPairs
            .filter { effectiveTargetType($0.value, doc: doc) == "application" }
            .map { $0.value }
        guard !apps.isEmpty else {
            guard targetPairs.isEmpty, let projectSettings = lookup(doc, "settings") else {
                return sources
            }
            var winners: [String: DeclaredSetting] = [:]
            collectSettings(projectSettings, doc: doc, sourceRank: 0, into: &winners)
            flushWinners(winners, into: &sources)
            return sources
        }
        for target in apps {
            var winners: [String: DeclaredSetting] = [:]
            collectSettings(lookup(doc, "settings"), doc: doc, sourceRank: 0, into: &winners)
            let templates = flattenedTemplates(target, doc: doc)
            for (index, template) in templates.enumerated() {
                collectSettings(lookup(template, "settings"), doc: doc,
                                sourceRank: index + 1, into: &winners)
            }
            collectSettings(lookup(target, "settings"), doc: doc,
                            sourceRank: templates.count + 1, into: &winners)
            flushWinners(winners, into: &sources)
            sources.infoProperties.append(mergedPlistProperties(templates + [target], section: "info"))
            sources.entitlementProperties.append(
                mergedPlistProperties(templates + [target], section: "entitlements"))
        }
        return sources
    }

    /// Winning declarations → the `(key, values)` stream `recordInfoplistSettings`
    /// consumes, plus `INFOPLIST_FILE` paths to follow.
    private static func flushWinners(
        _ winners: [String: DeclaredSetting], into sources: inout XcodeGenEvidenceSources
    ) {
        for decl in winners.values {
            if decl.name == "INFOPLIST_FILE" {
                sources.plistPaths.append(contentsOf: decl.values)
            } else {
                sources.settings.append((decl.name, decl.values))
            }
        }
    }

    /// Walks one settings node — `base:`, `configs.*` (each itself a Settings
    /// schema), `groups:`/`presets:` references into `settingGroups`, and arbitrary
    /// nesting — offering every `INFOPLIST_KEY_*`/`INFOPLIST_FILE` leaf to `winners`.
    private static func collectSettings(
        _ node: Node?, doc: Node, sourceRank: Int,
        into winners: inout [String: DeclaredSetting]
    ) {
        guard let node else { return }
        var groupStack = Set<String>()
        walkSettings(node, doc: doc, scope: "", groupDepth: 0,
                     sourceRank: sourceRank, groupStack: &groupStack, into: &winners)
    }

    private static func walkSettings(
        _ node: Node, doc: Node, scope: String, groupDepth: Int,
        sourceRank: Int, groupStack: inout Set<String>,
        into winners: inout [String: DeclaredSetting]
    ) {
        for (keyNode, value) in effectivePairs(node) {
            guard let key = keyNode.string else { continue }
            switch key {
            case "groups", "presets":
                for name in yamlStrings(value) where groupStack.insert(name).inserted {
                    if let group = lookup(lookup(doc, "settingGroups"), name) {
                        walkSettings(group, doc: doc, scope: scope, groupDepth: groupDepth + 1,
                                     sourceRank: sourceRank, groupStack: &groupStack,
                                     into: &winners)
                    }
                    groupStack.remove(name)
                }
            case "configs":
                for (configKey, configNode) in effectivePairs(value) {
                    if let config = configKey.string {
                        walkSettings(configNode, doc: doc, scope: config, groupDepth: groupDepth,
                                     sourceRank: sourceRank, groupStack: &groupStack,
                                     into: &winners)
                    }
                }
            case "base":
                walkSettings(value, doc: doc, scope: scope, groupDepth: groupDepth,
                             sourceRank: sourceRank, groupStack: &groupStack, into: &winners)
            case "INFOPLIST_FILE":
                offer(&winners, name: key, values: yamlStrings(value), scope: scope,
                      sourceRank: sourceRank, groupDepth: groupDepth)
            default:
                if key.hasPrefix("INFOPLIST_KEY_") {
                    offer(&winners,
                          name: String(key.dropFirst("INFOPLIST_KEY_".count)),
                          values: yamlStrings(value), scope: scope,
                          sourceRank: sourceRank, groupDepth: groupDepth)
                } else {
                    walkSettings(value, doc: doc, scope: scope, groupDepth: groupDepth,
                                 sourceRank: sourceRank, groupStack: &groupStack,
                                 into: &winners)
                }
            }
        }
    }

    /// Records a declaration unless a higher-precedence one already holds its
    /// `(name, scope)` slot — higher `sourceRank` wins, and at equal rank the
    /// shallower `groupDepth` (the referencing object's own keys beat a `groups`
    /// reference's).
    private static func offer(
        _ winners: inout [String: DeclaredSetting],
        name: String, values: [String], scope: String,
        sourceRank: Int, groupDepth: Int
    ) {
        let id = "\(name)\u{0}\(scope)"
        if let existing = winners[id],
           existing.sourceRank > sourceRank
               || (existing.sourceRank == sourceRank && existing.groupDepth <= groupDepth) {
            return
        }
        winners[id] = DeclaredSetting(name: name, values: values, scope: scope,
                                      sourceRank: sourceRank, groupDepth: groupDepth)
    }

    /// A target's `templates:` flattened the way XcodeGen's `resolveTemplates`
    /// orders them — each template's own nested templates first, then the template
    /// itself — so later entries carry higher precedence when declarations compete.
    private static func flattenedTemplates(_ target: Node, doc: Node) -> [Node] {
        var templates: [Node] = []
        var seen = Set<String>()
        collectTemplates(target, doc: doc, into: &templates, seen: &seen)
        return templates
    }

    private static func collectTemplates(
        _ node: Node, doc: Node, into templates: inout [Node], seen: inout Set<String>
    ) {
        guard let names = lookup(node, "templates") else { return }
        for name in yamlStrings(names) where seen.insert(name).inserted {
            guard let template = lookup(lookup(doc, "targetTemplates"), name) else { continue }
            collectTemplates(template, doc: doc, into: &templates, seen: &seen)
            templates.append(template)
        }
    }

    /// The target's effective `type` — its own, else the highest-precedence
    /// template that declares one (XcodeGen merges template dicts beneath the
    /// target's own values).
    private static func effectiveTargetType(_ target: Node, doc: Node) -> String? {
        if let type = lookup(target, "type")?.string { return type }
        for template in flattenedTemplates(target, doc: doc).reversed() {
            if let type = lookup(template, "type")?.string { return type }
        }
        return nil
    }

    /// `info:`/`entitlements:` are `{path, properties}` — XcodeGen merges the dicts
    /// down the template chain, the concrete target winning per top-level property
    /// key. `path` is an output, never an input, so only `properties` pairs are
    /// evidence.
    private static func mergedPlistProperties(
        _ nodes: [Node], section: String
    ) -> [(key: String, value: Node)] {
        var merged: [String: Node] = [:]
        for node in nodes {
            guard let properties = lookup(lookup(node, section), "properties") else { continue }
            for (keyNode, value) in effectivePairs(properties) {
                if let key = keyNode.string { merged[key] = value }
            }
        }
        return merged.map { (key: $0.key, value: $0.value) }
    }

    /// Child lookup that sees through YAML `<<` merge keys — XcodeGen loads the
    /// spec as a dictionary where merges are already flattened, so a `settings:`
    /// supplied by an anchor must resolve the same way here.
    private static func lookup(_ node: Node?, _ key: String) -> Node? {
        guard let node else { return nil }
        return effectivePairs(node).first { $0.key.string == key }?.value
    }

    /// A mapping's pairs with `<<` merge entries expanded: merged mappings supply
    /// defaults that explicit keys override. `<<` accepts a mapping or a sequence
    /// of mappings, and a merge source may itself carry `<<`.
    private static func effectivePairs(_ node: Node) -> [(key: Node, value: Node)] {
        guard let mapping = node.mapping else { return [] }
        var merged: [(key: Node, value: Node)] = []
        var explicit: [(key: Node, value: Node)] = []
        for (keyNode, value) in mapping {
            if keyNode.string == "<<" {
                merged.append(contentsOf: mergeSourcePairs(value))
            } else {
                explicit.append((key: keyNode, value: value))
            }
        }
        let explicitKeys = Set(explicit.compactMap { $0.key.string })
        return merged.filter { pair in
            guard let key = pair.key.string else { return true }
            return !explicitKeys.contains(key)
        } + explicit
    }

    /// The pairs a `<<` value contributes — a mapping (recursively merge-expanded)
    /// or a sequence of mappings where earlier entries win over later ones.
    private static func mergeSourcePairs(_ node: Node) -> [(key: Node, value: Node)] {
        if node.mapping != nil { return effectivePairs(node) }
        guard let sequence = node.sequence else { return [] }
        var pairs: [(key: Node, value: Node)] = []
        var seen = Set<String>()
        for element in sequence {
            for pair in mergeSourcePairs(element) {
                guard let key = pair.key.string, seen.insert(key).inserted else { continue }
                pairs.append(pair)
            }
        }
        return pairs
    }

    /// Compact value summary for an inline `entitlements.properties` entry — the same
    /// shape `readEntitlements` gives plist-parsed values.
    private static func yamlSummary(_ node: Node) -> String {
        if let sequence = node.sequence {
            guard sequence.allSatisfy({ $0.scalar != nil }) else { return "[\(sequence.count) items]" }
            return sanitized(sequence.compactMap { $0.scalar?.string }.joined(separator: ","))
        }
        return sanitized(node.string ?? "…")
    }

    /// Leaf values of a YAML node as strings — scalars via their resolved string
    /// (falling back to the raw text), sequences flattened in order. Comments,
    /// quoting, block scalars and indentationless sequences are the parser's job.
    private static func yamlStrings(_ node: Node) -> [String] {
        if let scalar = node.scalar {
            return [node.string ?? scalar.string]
        }
        return node.array().flatMap(yamlStrings)
    }

    /// Feeds recognized `INFOPLIST_KEY_*` settings into the same buckets a literal
    /// Info.plist fills. The file lands in `infoplistSettingFiles` only when at least
    /// one recognized key was recorded — a `CFBundleDisplayName`-only file is not
    /// evidence for the sheets that cite these buckets.
    private static func recordInfoplistSettings(
        _ settings: [(key: String, values: [String])], rel: String, into e: inout ProjectEvidence
    ) {
        // The same setting legitimately repeats across targets and configs — identical
        // declarations would cite the same source once per occurrence.
        var unique: [(key: String, values: [String])] = []
        for setting in settings where !unique.contains(where: {
            $0.key == setting.key && $0.values == setting.values
        }) {
            unique.append(setting)
        }
        var recognized = false
        for (key, values) in unique {
            if key == "ITSAppUsesNonExemptEncryption" {
                if values.count == 1, let flag = plistBool(values[0]) {
                    e.encryptionDeclarations.append((flag, rel))
                    recognized = true
                }
            } else if key.hasSuffix("UsageDescription") {
                e.usageDescriptions.append((key: sanitized(key), source: rel))
                recognized = true
            } else if key == "UIBackgroundModes" {
                // `$(…)`/`${…}` are build-setting or template references — they name
                // no mode this scan can cite.
                for value in values where !value.contains("$(") && !value.contains("${") {
                    // Modes are bare tokens — accept comma- or space-separated lists.
                    for mode in value.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
                        let mode = unquote(String(mode))
                        if !mode.isEmpty {
                            e.backgroundModes.append((sanitized(mode), rel))
                            recognized = true
                        }
                    }
                }
            }
        }
        if recognized { e.infoplistSettingFiles.append(rel) }
    }

    /// `YES`/`NO`/`true`/`false` in either YAML quoting style → Bool; anything else is
    /// not a declaration this scanner can stand behind.
    private static func plistBool(_ text: String) -> Bool? {
        switch unquote(text).trimmingCharacters(in: .whitespaces).lowercased() {
        case "yes", "true": return true
        case "no", "false": return false
        default: return nil
        }
    }

    /// Strips one layer of matching single or double quotes.
    private static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              let first = trimmed.first, let last = trimmed.last, first == last,
              first == "\"" || first == "'"
        else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
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

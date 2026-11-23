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
        // resolution feeds both the exclusion sets and the evidence readers — and
        // app/non-app sets union across specs *before* subtracting, so a tests-only
        // project cannot hide a config the app project shares.
        var xcodeGenDocs: [String: Node] = [:]
        var appConfigs = Set<String>()
        var otherConfigs = Set<String>()
        for (url, _, _) in buckets where url.lastPathComponent == "project.yml" {
            let resolved = ASCConfiguration.fullyResolved(url).path
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let composed = try? Yams.compose(yaml: text)
            else { continue }
            // XcodeGen's spec load merges the file's dictionary onto its
            // includes — `:REPLACE`-suffixed keys normalize even with none, so
            // normalize the root the same way before any lookup.
            let doc = mergedSpec(composed, onto: Node([] as [(Node, Node)]))
            xcodeGenDocs[resolved] = doc
            let sets = xcodeGenExtensionOnlyConfigs(
                doc, directory: url.deletingLastPathComponent(), root: root)
            appConfigs.formUnion(sets.app)
            otherConfigs.formUnion(sets.other)
        }
        let extensionOnlyConfigs = otherConfigs.subtracting(appConfigs)
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
        let plistPaths = sources.plistPaths
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

    /// The `.xcconfig` realpaths a `project.yml` ties to app vs non-app targets,
    /// returned separately so the caller can union across specs before subtracting
    /// once — a tests-only spec must not hide a config the app project shares.
    /// Targets classify by their *effective* spec — `type:`/`configFiles:` merged
    /// through `targetTemplates` the way XcodeGen resolves them, so a per-config
    /// file a template replaces does not linger as app evidence — and an app
    /// config's `#include` chain is app evidence even when a non-app target names
    /// it directly. Unparseable specs yield nothing: the file is broken evidence
    /// either way, and `readXcodeGenProject` reports it properly.
    private static func xcodeGenExtensionOnlyConfigs(
        _ doc: Node, directory: URL, root: URL
    ) -> (app: Set<String>, other: Set<String>) {
        var appConfigs = Set<String>()
        var otherConfigs = Set<String>()
        let targets = effectiveTargets(doc)
        // Project-level configFiles apply to every target — app-scoped whenever the
        // spec can produce an app, or declares no targets to scope by at all;
        // otherwise they can only belong to the non-app targets.
        let hasApp = targets.isEmpty || targets.contains { $0.isApp }
        if let configFiles = lookup(doc, "configFiles") {
            if hasApp {
                collectConfigFiles(configFiles, directory: directory, into: &appConfigs)
            } else {
                collectConfigFiles(configFiles, directory: directory, into: &otherConfigs)
            }
        }
        for target in targets {
            var configs = Set<String>()
            // The effective spec is already variable-expanded; only the raw
            // template chain's provenance paths still need the target's
            // variables — `${target_name}` plus the attributes read between
            // the two expansion passes.
            let templates = flattenedTemplates(target.raw, doc: doc)
            if let configFiles = lookup(target.spec, "configFiles") {
                collectConfigFiles(configFiles, directory: directory, into: &configs)
            }
            if target.isApp {
                appConfigs.formUnion(configs)
            } else {
                otherConfigs.formUnion(configs)
            }
            // A config a template names but the merge supersedes is dead for the
            // build, yet it was still *declared* — keep it out of the unscoped
            // read unless an effective app path claims it. Effective app paths
            // win the subtraction, so live template configs are unaffected. The
            // raw template may carry `configFiles:REPLACE`, which the merge
            // honors — check the suffixed key first.
            if !templates.isEmpty {
                let variables = target.attributes
                    .merging(["target_name": target.name]) { _, new in new }
                for template in templates {
                    if let configFiles = lookup(template, "configFiles:REPLACE")
                        ?? lookup(template, "configFiles") {
                        collectConfigFiles(configFiles, directory: directory,
                                           into: &otherConfigs, variables: variables)
                    }
                }
            }
        }
        // An `#include` inside an app config pulls the included file into the app's
        // build settings — app evidence even when a non-app target references it
        // directly. Includes chain; the visited set stops cycles. Plain relative
        // paths resolve against the including file; `$(SRCROOT)`/`$(PROJECT_DIR)`
        // anchor at the spec's directory like every other project.yml path. The
        // chase opens files a checkout author names, so it applies the walk's own
        // discipline: inside the scan root, regular, never credential-shaped.
        var queue = appConfigs.filter { configFileEligible($0, root: root) }.sorted()
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
                guard configFileEligible(included.path, root: root),
                      appConfigs.insert(included.path).inserted
                else { continue }
                queue.append(included.path)
            }
        }
        return (appConfigs, otherConfigs)
    }

    /// Whether the include-chase may open `path` — the same discipline the file
    /// walk applies: inside the scan root, a regular file, never a
    /// credential-shaped name or extension.
    private static func configFileEligible(_ path: String, root: URL) -> Bool {
        let url = URL(fileURLWithPath: path)
        return path.hasPrefix(root.path + "/")
            && !sensitiveFileNames.contains(url.lastPathComponent)
            && !sensitiveExtensions.contains(url.pathExtension)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// Every path inside a `configFiles:` value — a scalar, a per-config mapping, or
    /// a sequence — resolved to a realpath. Mapping values may arrive through a YAML
    /// `<<` merge, so pairs come from `effectivePairs`.
    private static func collectConfigFiles(
        _ node: Node, directory: URL, into paths: inout Set<String>,
        variables: [String: String] = [:]
    ) {
        if let scalar = node.scalar {
            paths.insert(projectPathURL(
                expandVariables(scalar.string, variables), directory: directory).path)
        } else if node.mapping != nil {
            for (_, value) in effectivePairs(node) {
                collectConfigFiles(value, directory: directory, into: &paths,
                                   variables: variables)
            }
        } else if let sequence = node.sequence {
            for element in sequence {
                collectConfigFiles(element, directory: directory, into: &paths,
                                   variables: variables)
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

    /// How a declaration relates to the build-settings layer beneath it.
    private enum Inheritance: Hashable {
        /// A concrete value — replaces everything below.
        case concrete
        /// Concrete values plus inheritance references — the references take
        /// the layer below's values positionally (`Store/$(inherited)` +
        /// `Base.plist` → `Store/Base.plist`), and concrete elements survive.
        case appending
        /// Only inheritance references — defers to the layer below entirely.
        case deferred
    }

    /// One candidate `INFOPLIST_KEY_*`/`INFOPLIST_FILE` declaration for a
    /// `(name, config)` slot — config is an actual project configuration, so
    /// declarations for different configs are per-config values Xcode would
    /// actually build, not conflicts. Sibling `configs.*` selectors that
    /// disagree about one config are genuinely ambiguous (XcodeGen walks its
    /// `configSettings` dictionary in hash order), so a slot holds a *list* of
    /// alternative candidates; identical ones collapse.
    private struct DeclaredSetting: Hashable {
        var name: String
        /// Concrete values — inheritance references stripped. For `.appending`
        /// this is what the layer contributes on its own; after the layer
        /// merge it holds the resolved substitutions instead.
        var values: [String]
        /// `.appending` only: the raw strings with `$(inherited)` tokens
        /// intact, so the layer below's values can substitute into them.
        var templates: [String]
        var inheritance: Inheritance
    }

    /// The declarations that apply to the shipping app, resolved the way XcodeGen's
    /// spec loader and `SettingsBuilder.getBuildSettings` resolve them: each
    /// target's spec is first merged through its `templates:` chain
    /// (`merged(onto:)` semantics — dictionaries recurse, sequences concatenate,
    /// scalars replace), then its `settings` resolve once per actual project
    /// configuration — groups in list order recursively, then `base:`, then each
    /// matching `configs.*` selector against that same config name. Project-level
    /// `settings` sit underneath as the lower Xcode build-settings layer, so a
    /// target's `$(inherited)` defers to them. A spec with no `targets` gives no
    /// scope to judge by, so project-level declarations stay; a spec whose
    /// targets are all non-app has no shipping app to describe.
    private static func appSettingsSources(_ doc: Node) -> XcodeGenEvidenceSources {
        var sources = XcodeGenEvidenceSources()
        let targets = effectiveTargets(doc)
        let apps = targets.filter { $0.isApp }.map(\.spec)
        let configNames = projectConfigNames(doc)
        guard !apps.isEmpty else {
            guard targets.isEmpty, let projectSettings = lookup(doc, "settings") else {
                return sources
            }
            var winners: [String: [DeclaredSetting]] = [:]
            resolveAllConfigs(projectSettings, doc: doc, configNames: configNames,
                              into: &winners)
            flushWinners(winners, into: &sources)
            return sources
        }
        for target in targets where target.isApp {
            let spec = target.spec
            var projectWinners: [String: [DeclaredSetting]] = [:]
            var targetWinners: [String: [DeclaredSetting]] = [:]
            resolveAllConfigs(lookup(doc, "settings"), doc: doc,
                              configNames: configNames, into: &projectWinners)
            resolveAllConfigs(lookup(spec, "settings"), doc: doc,
                              configNames: configNames, into: &targetWinners)
            // The target layer wins each `(name, config)` slot — a concrete
            // candidate replaces the project's, an appending one substitutes
            // the project's values into its inheritance references, and a
            // deferred one yields to it entirely.
            var winners = projectWinners
            for (id, candidates) in targetWinners {
                let lower = winners[id] ?? []
                var resolved: [DeclaredSetting] = []
                for candidate in candidates {
                    let expanded: [DeclaredSetting]
                    switch candidate.inheritance {
                    case .concrete:
                        expanded = [candidate]
                    case .appending:
                        expanded = [mergeAppending(candidate, with: lower)]
                    case .deferred:
                        expanded = lower
                    }
                    for decl in expanded where !resolved.contains(decl) {
                        resolved.append(decl)
                    }
                }
                winners[id] = resolved
            }
            flushWinners(winners, into: &sources)
            if let properties = lookup(lookup(spec, "info"), "properties") {
                sources.infoProperties.append(plistPropertyPairs(properties))
            }
            if let properties = lookup(lookup(spec, "entitlements"), "properties") {
                sources.entitlementProperties.append(plistPropertyPairs(properties))
            }
        }
        return sources
    }

    /// Winning declarations → the `(key, values)` stream `recordInfoplistSettings`
    /// consumes, plus `INFOPLIST_FILE` paths to follow. Deferred markers and
    /// explicit empties occupy their winner slots (suppressing what they beat)
    /// but declare nothing themselves; ambiguous slots emit every distinct
    /// candidate so downstream sees the same disagreement XcodeGen's hash-order
    /// resolution would produce.
    private static func flushWinners(
        _ winners: [String: [DeclaredSetting]], into sources: inout XcodeGenEvidenceSources
    ) {
        for candidates in winners.values {
            for decl in candidates where !decl.values.isEmpty {
                if decl.name == "INFOPLIST_FILE" {
                    sources.plistPaths.append(contentsOf: decl.values)
                } else {
                    sources.settings.append((decl.name, decl.values))
                }
            }
        }
    }

    /// An `.appending` candidate resolved against the layer below: each raw
    /// template substitutes every lower-layer value into its inheritance
    /// references (`Store/$(inherited)` × `Base.plist` → `Store/Base.plist`),
    /// templates without references pass through, and an empty lower layer
    /// substitutes nothing — the reference resolves to empty, matching Xcode.
    /// Ambiguous lower candidates each produce their own substitution, so the
    /// disagreement survives as alternative values.
    private static func mergeAppending(
        _ candidate: DeclaredSetting, with lower: [DeclaredSetting]
    ) -> DeclaredSetting {
        var values: [String] = []
        for template in candidate.templates {
            if containsInheritanceReference(template) {
                let substitutions = lower.flatMap(\.values)
                for substitution in substitutions.isEmpty ? [""] : substitutions {
                    let resolved = substituteInheritanceReferences(template, with: substitution)
                    if !resolved.isEmpty, !values.contains(resolved) {
                        values.append(resolved)
                    }
                }
            } else if !values.contains(template) {
                values.append(template)
            }
        }
        return DeclaredSetting(
            name: candidate.name, values: values, templates: [], inheritance: .appending)
    }

    /// Every `targets:` entry resolved to its effective spec — the target dict
    /// after XcodeGen's template merge *and* variable expansion — plus its name,
    /// the raw node (for template-chain provenance), the attributes read between
    /// the two expansion passes, and whether the expanded `type:` is
    /// `application`.
    private static func effectiveTargets(
        _ doc: Node
    ) -> [(name: String, raw: Node, spec: Node, attributes: [String: String], isApp: Bool)] {
        guard let targets = lookup(doc, "targets") else { return [] }
        return effectivePairs(targets).map { pair in
            let name = pair.key.string ?? ""
            var spec = effectiveTargetSpec(pair.value, doc: doc)
            var attributes: [String: String] = [:]
            // XcodeGen expands the merged target dict twice when templates
            // resolve: `${target_name}` first — which also expands the
            // attribute values themselves — then the attributes. Type,
            // configFiles, settings keys and values, and inline properties
            // all read the expanded dict; shared `settingGroups` stay raw.
            if !flattenedTemplates(pair.value, doc: doc).isEmpty {
                spec = expandSpecVariables(spec, ["target_name": name])
                attributes = templateAttributes(spec)
                spec = expandSpecVariables(spec, attributes)
            }
            return (name: name, raw: pair.value, spec: spec, attributes: attributes,
                    isApp: lookup(spec, "type")?.string == "application")
        }
    }

    /// `templateAttributes:` pairs from a spec that already had
    /// `${target_name}` expanded — upstream reads them between its two
    /// expansion passes.
    private static func templateAttributes(_ spec: Node) -> [String: String] {
        guard let node = lookup(spec, "templateAttributes") else { return [:] }
        var attributes: [String: String] = [:]
        for (keyNode, value) in effectivePairs(node) {
            if let key = keyNode.string, let value = value.string {
                attributes[key] = value
            }
        }
        return attributes
    }

    /// `Dictionary.expand(variables:)` applied to a whole spec subtree — every
    /// scalar string, mapping keys included, gets the single left-to-right
    /// `${name}` pass. Rebuilt nodes carry no YAML styling, which the evidence
    /// readers never consult.
    private static func expandSpecVariables(_ node: Node, _ variables: [String: String]) -> Node {
        guard !variables.isEmpty else { return node }
        if let scalar = node.scalar {
            let text = node.string ?? scalar.string
            return text.isEmpty ? node : Node(expandVariables(text, variables))
        }
        if node.mapping != nil {
            var pairs: [(Node, Node)] = []
            for (keyNode, valueNode) in node.mapping! {
                let key = keyNode.string.map { Node(expandVariables($0, variables)) } ?? keyNode
                pairs.append((key, expandSpecVariables(valueNode, variables)))
            }
            return Node(pairs)
        }
        if let sequence = node.sequence {
            return Node(sequence.map { expandSpecVariables($0, variables) })
        }
        return node
    }

    /// The target dict after XcodeGen's `resolveTemplates` merge — each flattened
    /// template merged under the next, the concrete target on top. Upstream
    /// merges only when at least one template resolves: a standalone target's
    /// dict passes through untouched, `:REPLACE` keys and all. With templates,
    /// every layer goes through `mergedSpec` (starting from an empty mapping)
    /// so `:REPLACE` keys normalize even for the first template.
    private static func effectiveTargetSpec(_ target: Node, doc: Node) -> Node {
        let templates = flattenedTemplates(target, doc: doc)
        guard !templates.isEmpty else { return target }
        var acc = Node([] as [(Node, Node)])
        for template in templates {
            acc = mergedSpec(template, onto: acc)
        }
        return mergedSpec(target, onto: acc)
    }

    /// XcodeGen's spec-level dictionary merge (`Dictionary.merged(onto:)` in
    /// SpecFile.swift), applied to the effective (merge-key-expanded) pairs:
    /// dictionaries merge recursively, sequences concatenate with the
    /// lower-precedence entries first, scalars replace, and a `:REPLACE`-suffixed
    /// key substitutes its whole subtree.
    private static func mergedSpec(_ node: Node, onto base: Node) -> Node {
        if node.mapping != nil, base.mapping != nil {
            var merged = effectivePairs(base).map { ($0.key, $0.value) }
            var position: [String: Int] = [:]
            for (index, pair) in merged.enumerated() {
                if let key = pair.0.string { position[key] = index }
            }
            for pair in effectivePairs(node) {
                guard let key = pair.key.string else { continue }
                if key.hasSuffix(":REPLACE") {
                    let stripped = String(key.dropLast(":REPLACE".count))
                    let entry = (Node(stripped), pair.value)
                    if let index = position[stripped] {
                        merged[index] = entry
                    } else {
                        position[stripped] = merged.count
                        merged.append(entry)
                    }
                } else if let index = position[key] {
                    merged[index] = (merged[index].0,
                                     mergedSpec(pair.value, onto: merged[index].1))
                } else {
                    position[key] = merged.count
                    merged.append((pair.key, pair.value))
                }
            }
            return Node(merged)
        }
        if node.sequence != nil, base.sequence != nil {
            return Node(base.array() + node.array())
        }
        return node
    }

    /// The project's build configurations — the `configs:` mapping's keys
    /// (`{Debug: debug, AppStore: release}`), or XcodeGen's Debug/Release
    /// defaults when the spec declares none. `settings.configs.*` selectors
    /// resolve against these names.
    private static func projectConfigNames(_ doc: Node) -> [String] {
        guard let configs = lookup(doc, "configs"), configs.mapping != nil else {
            return ["Debug", "Release"]
        }
        let names = effectivePairs(configs).compactMap { $0.key.string }.sorted()
        return names.isEmpty ? ["Debug", "Release"] : names
    }

    /// `getBuildSettings`'s `configSettings` rule: a variant applies when the
    /// config name contains it — unless the variant names a *different* declared
    /// config, in which case it belongs to that config alone (`configs.Debug`
    /// never applies to `DebugEnterprise` when `Debug` exists).
    private static func variantMatches(
        _ variant: String, configName: String, configs: [String]
    ) -> Bool {
        guard configName.lowercased().contains(variant.lowercased()) else { return false }
        return !(configs.contains(variant) && variant != configName)
    }

    /// Resolves one Settings-schema node for every project configuration, the way
    /// `SettingsBuilder.getBuildSettings` does per `Config`: `groups:`/`presets:`
    /// references first — list order, each recursively resolved — then the
    /// object's own `base:` (or the whole mapping in flat form), then each
    /// `configs.*` selector matching this config name, recursing with the *same*
    /// name so nested selectors compose against the real configuration. Target
    /// specs arrive already variable-expanded; project settings and shared
    /// `settingGroups` stay raw, exactly as upstream leaves them.
    private static func resolveAllConfigs(
        _ node: Node?, doc: Node, configNames: [String],
        into winners: inout [String: [DeclaredSetting]]
    ) {
        guard let node else { return }
        for configName in configNames {
            var groupStack = Set<String>()
            resolveSettings(node, doc: doc, configName: configName, configs: configNames,
                            groupStack: &groupStack, into: &winners)
        }
    }

    private static func resolveSettings(
        _ node: Node, doc: Node, configName: String, configs: [String],
        groupStack: inout Set<String>,
        into winners: inout [String: [DeclaredSetting]]
    ) {
        // `Settings.init` treats the mapping as structured iff `base`, `configs`
        // or `groups` is present — anything else is flat build settings.
        let structured = effectivePairs(node).contains { pair in
            ["base", "configs", "groups"].contains(pair.key.string)
        }
        guard structured else {
            emitBuildSettings(node, configName: configName, into: &winners)
            return
        }
        let groupNames = lookup(node, "groups") ?? lookup(node, "presets")
        if let groupNames {
            for name in yamlStrings(groupNames) where groupStack.insert(name).inserted {
                if let group = lookup(lookup(doc, "settingGroups"), name) {
                    resolveSettings(group, doc: doc, configName: configName, configs: configs,
                                    groupStack: &groupStack, into: &winners)
                }
                groupStack.remove(name)
            }
        }
        if let base = lookup(node, "base") {
            emitBuildSettings(base, configName: configName, into: &winners)
        }
        if let configSettings = lookup(node, "configs") {
            // Every matching sibling selector applies to this config — XcodeGen
            // walks its `configSettings` dictionary in hash order, so disagreeing
            // variants are genuinely ambiguous. Resolve each into its own winner
            // set, then keep every distinct candidate rather than inventing an
            // order; the merged candidates replace what groups/base offered.
            var contested: [String: [DeclaredSetting]] = [:]
            for (variantNode, subNode) in effectivePairs(configSettings) {
                guard let variant = variantNode.string,
                      variantMatches(variant, configName: configName, configs: configs)
                else { continue }
                var variantWinners: [String: [DeclaredSetting]] = [:]
                var variantStack = groupStack
                resolveSettings(subNode, doc: doc, configName: configName, configs: configs,
                                groupStack: &variantStack, into: &variantWinners)
                mergeCandidates(variantWinners, into: &contested)
            }
            for (id, candidates) in contested {
                winners[id] = candidates
            }
        }
    }

    /// Unions per-variant winner slots into `contested` — identical
    /// declarations collapse, distinct ones stay as alternative candidates.
    private static func mergeCandidates(
        _ from: [String: [DeclaredSetting]], into winners: inout [String: [DeclaredSetting]]
    ) {
        for (id, candidates) in from {
            var merged = winners[id] ?? []
            for candidate in candidates where !merged.contains(candidate) {
                merged.append(candidate)
            }
            winners[id] = merged
        }
    }

    /// The object's own build settings — `base:` contents in structured form —
    /// offered in document order under `configName`'s slot. Target specs arrive
    /// already variable-expanded; project settings and shared groups stay raw.
    /// Values containing `$(inherited)`/`${inherited}` classify by what remains:
    /// nothing → the declaration defers to the layer below; concrete elements →
    /// it appends to (and inherits) the layer below; no references → concrete.
    private static func emitBuildSettings(
        _ node: Node, configName: String,
        into winners: inout [String: [DeclaredSetting]]
    ) {
        for (keyNode, value) in effectivePairs(node) {
            guard let key = keyNode.string else { continue }
            let name: String
            if key == "INFOPLIST_FILE" {
                name = key
            } else if key.hasPrefix("INFOPLIST_KEY_") {
                name = String(key.dropFirst("INFOPLIST_KEY_".count))
            } else {
                continue
            }
            let rawValues = yamlStrings(value)
            let hasReference = rawValues.contains(where: containsInheritanceReference)
            let concrete = hasReference
                ? rawValues.map { strippingInheritanceReferences($0) }.filter { !$0.isEmpty }
                : rawValues
            let inheritance: Inheritance = !hasReference
                ? .concrete
                : concrete.isEmpty ? .deferred : .appending
            winners["\(name)\u{0}\(configName)"] = [DeclaredSetting(
                name: name, values: concrete,
                templates: inheritance == .appending ? rawValues : [],
                inheritance: inheritance)]
        }
    }

    /// `$(inherited)`/`${inherited}` appearing anywhere in the value — as a
    /// standalone element or embedded in text.
    private static func containsInheritanceReference(_ value: String) -> Bool {
        value.contains("$(inherited)") || value.contains("${inherited}")
    }

    /// Removes every inheritance-reference token and tidies what remains —
    /// `fetch $(inherited)` leaves the concrete `fetch`.
    private static func strippingInheritanceReferences(_ value: String) -> String {
        unquote(value)
            .replacingOccurrences(of: "$(inherited)", with: "")
            .replacingOccurrences(of: "${inherited}", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Substitutes a lower layer's value into every inheritance-reference
    /// token, positionally — `Store/$(inherited)` × `Base.plist` resolves to
    /// `Store/Base.plist`, the path Xcode would actually build.
    private static func substituteInheritanceReferences(
        _ template: String, with value: String
    ) -> String {
        unquote(template)
            .replacingOccurrences(of: "$(inherited)", with: value)
            .replacingOccurrences(of: "${inherited}", with: value)
            .trimmingCharacters(in: .whitespaces)
    }

    /// `${name}` expansion, matching SpecFile's single left-to-right pass:
    /// unknown names stay literal, inserted values are never re-expanded, and a
    /// `$` that does not open `${…}` — an Xcode `$(…)` macro, say — stays
    /// verbatim while the scan continues for a later template reference.
    private static func expandVariables(_ text: String, _ variables: [String: String]) -> String {
        guard text.contains("${"), !variables.isEmpty else { return text }
        var result = ""
        var rest = Substring(text)
        while let dollar = rest.firstIndex(of: "$") {
            result += rest[..<dollar]
            rest = rest[dollar...]
            if rest.hasPrefix("${") {
                guard let close = rest.firstIndex(of: "}") else {
                    result += rest
                    return result
                }
                let name = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close])
                result += variables[name] ?? String(rest[...close])
                rest = rest[rest.index(after: close)...]
            } else {
                result += "$"
                rest = rest[rest.index(after: rest.startIndex)...]
            }
        }
        return result + rest
    }

    /// A target's `templates:` flattened the way XcodeGen's `resolveTemplates`
    /// orders them — each template's own nested templates first, then the template
    /// itself — so later entries carry higher precedence in the spec merge.
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

    /// `info:`/`entitlements:` `properties` pairs — already template-merged, so
    /// array values carry every inherited entry and `:REPLACE` was honored.
    private static func plistPropertyPairs(_ node: Node) -> [(key: String, value: Node)] {
        effectivePairs(node).compactMap { pair in
            pair.key.string.map { (key: $0, value: pair.value) }
        }
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
        for (key, values) in unique where !values.isEmpty {
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
                            // The same mode legitimately repeats across configs —
                            // cite the source once.
                            let entry = (mode: sanitized(mode), source: rel)
                            if !e.backgroundModes.contains(where: { $0 == entry }) {
                                e.backgroundModes.append(entry)
                            }
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

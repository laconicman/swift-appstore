import Foundation
import Testing
@testable import AppStoreWorkflow

/// `EvidenceScan.scan` direct coverage — `QuestionnaireTests` exercises the scan through the
/// sheets it feeds; this suite pins the entry points themselves: `signalSymbols` driving
/// detection, and `ProjectEvidence`'s empty init.
@Suite("EvidenceScan")
struct EvidenceScanTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("EvidenceScanTests-\(UUID().uuidString)", isDirectory: true)

    @Test("every listed signal symbol is detected; absence lands in absentSignals")
    func signalSymbolsDriveDetection() throws {
        let dir = root.appendingPathComponent("signals")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Text only — the scan greps, it never compiles. requiresOnDeviceRecognition needs
        // an explicit `= true` on a code line, everything else matches by mention.
        let text = EvidenceScan.signalSymbols.joined(separator: "\n")
            + "\nrequiresOnDeviceRecognition = true\n"
        try text.write(to: dir.appendingPathComponent("Signals.swift"), atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.signals.map(\.name) == EvidenceScan.signalSymbols)
        #expect(e.signalFiles == ["Signals.swift"])
        #expect(e.absentSignals.isEmpty)
        #expect(e.scannedSourceFiles == ["Signals.swift"])
    }

    @Test("a source file with no signal leaves every symbol in absentSignals")
    func absenceIsReported() throws {
        let dir = root.appendingPathComponent("quiet")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "let answer = 42\n".write(
            to: dir.appendingPathComponent("Plain.swift"), atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.signals.isEmpty)
        #expect(e.absentSignals == EvidenceScan.signalSymbols)
        #expect(e.signalFiles.isEmpty)
    }

    @Test("a fresh ProjectEvidence is all-empty — scan's starting point")
    func emptyInit() {
        let e = ProjectEvidence()
        #expect(e.collectedData.isEmpty && e.accessedAPIs.isEmpty)
        #expect(e.trackingDeclarations.isEmpty && e.trackingDomains.isEmpty)
        #expect(e.encryptionDeclarations.isEmpty && e.usageDescriptions.isEmpty)
        #expect(e.backgroundModes.isEmpty && e.entitlements.isEmpty)
        #expect(e.linkedFrameworks.isEmpty && e.packageDependencies.isEmpty)
        #expect(e.signals.isEmpty && e.absentSignals.isEmpty)
        #expect(e.skippedSourceFiles.isEmpty && e.scannedSourceFiles.isEmpty)
        #expect(e.filesScanned.isEmpty && e.signalFiles.isEmpty)
        #expect(e.plistFiles.isEmpty && e.privacyManifestFiles.isEmpty)
        #expect(e.entitlementFiles.isEmpty && e.projectFiles.isEmpty)
        #expect(e.dependencyFiles.isEmpty)
        #expect(e.infoplistSettingFiles.isEmpty)
    }

    @Test("scanning an empty directory yields the empty evidence")
    func emptyScan() throws {
        let dir = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = try EvidenceScan.scan(root: dir)
        #expect(e.filesScanned.isEmpty)
        #expect(e.absentSignals == EvidenceScan.signalSymbols)
    }

    @Test("a missing root is a misconfigured error, not empty evidence")
    func missingRootThrows() {
        #expect(throws: WorkflowError.self) {
            _ = try EvidenceScan.scan(root: root.appendingPathComponent("nope"))
        }
    }

    @Test("XcodeGen project.yml INFOPLIST_KEY_* settings feed the plist evidence buckets")
    func xcodeGenInfoplistKeys() throws {
        let dir = root.appendingPathComponent("xcodegen")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            name: Demo
            targets:
              App:
                type: application
                settings:
                  base:
                    GENERATE_INFOPLIST_FILE: YES
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
                    INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: "Used to set pickup."
                    INFOPLIST_KEY_UIBackgroundModes:
                      - audio
                      - fetch
                    INFOPLIST_KEY_CFBundleDisplayName: Demo
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(e.encryptionDeclarations.map(\.source) == ["project.yml"])
        #expect(e.usageDescriptions.contains {
            $0.key == "NSLocationWhenInUseUsageDescription" && $0.source == "project.yml"
        })
        #expect(e.backgroundModes.map(\.mode) == ["audio", "fetch"])
        #expect(e.backgroundModes.allSatisfy { $0.source == "project.yml" })
        #expect(e.infoplistSettingFiles == ["project.yml"])
        #expect(e.projectFiles == ["project.yml"])
        // Unrecognized INFOPLIST_KEY_ names are not evidence for these buckets.
        #expect(!e.usageDescriptions.contains { $0.key == "CFBundleDisplayName" })
    }

    @Test("comma-separated scalars and quoted YES/NO parse as the same evidence")
    func xcodeGenScalarForms() throws {
        let dir = root.appendingPathComponent("xcodegen-scalars")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            settings:
              base:
                INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "YES"
                INFOPLIST_KEY_UIBackgroundModes: audio, fetch
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [true])
        #expect(e.backgroundModes.map(\.mode) == ["audio", "fetch"])
    }

    @Test("INFOPLIST_FILE partial plists are followed as plist evidence, once")
    func infoplistFileFollowed() throws {
        let dir = root.appendingPathComponent("xcodegen-partial")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial: [String: Any] = [
            "UIBackgroundModes": ["remote-notification"],
            "NSSpeechRecognitionUsageDescription": "to test pronunciation",
        ]
        try PropertyListSerialization.data(fromPropertyList: partial, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Partial-Info.plist"))
        // Both spellings resolve to the same file — the second must not double-count.
        // (Project-level and target-level settings are distinct mappings, so the
        // duplicate key is legal YAML; two keys in one mapping would not be.)
        let yml = """
            settings:
              base:
                INFOPLIST_FILE: Partial-Info.plist
            targets:
              App:
                type: application
                settings:
                  base:
                    GENERATE_INFOPLIST_FILE: YES
                    INFOPLIST_FILE: $(SRCROOT)/Partial-Info.plist
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.plistFiles == ["Partial-Info.plist"])
        #expect(e.projectFiles == ["project.yml"])
        #expect(e.filesScanned.filter { $0 == "Partial-Info.plist" }.count == 1)
        #expect(e.backgroundModes.contains {
            $0.mode == "remote-notification" && $0.source == "Partial-Info.plist"
        })
        #expect(e.usageDescriptions.contains {
            $0.key == "NSSpeechRecognitionUsageDescription" && $0.source == "Partial-Info.plist"
        })
    }

    @Test("the same INFOPLIST_KEY_ under several targets records once")
    func xcodeGenDuplicatesRecordOnce() throws {
        let dir = root.appendingPathComponent("xcodegen-dup")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targets:
              App:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
                    INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: Used to set pickup.
              AppClip:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
                    INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: Used to set pickup.
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.count == 1)
        #expect(e.usageDescriptions.count == 1)
        #expect(e.backgroundModes.isEmpty)
    }

    @Test("INFOPLIST_FILE never opens credential-shaped or outside-root files")
    func infoplistFileSkipsUnsafeTargets() throws {
        let dir = root.appendingPathComponent("xcodegen-unsafe")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not a real key".write(to: dir.appendingPathComponent("AuthKey_TEST.p8"),
                                atomically: true, encoding: .utf8)
        let yml = """
            settings:
              base:
                INFOPLIST_FILE: AuthKey_TEST.p8
            targets:
              App:
                type: application
                settings:
                  base:
                    INFOPLIST_FILE: /etc/passwd
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.plistFiles.isEmpty)
        #expect(e.filesScanned == ["project.yml"])
    }

    @Test("CRLF project.yml still resolves INFOPLIST_FILE")
    func xcodeGenCRLF() throws {
        let dir = root.appendingPathComponent("xcodegen-crlf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial: [String: Any] = ["UIBackgroundModes": ["remote-notification"]]
        try PropertyListSerialization.data(fromPropertyList: partial, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Partial-Info.plist"))
        // YAML mandates CRLF tolerance — the spec parser must not see `\r` in values.
        let yml = "targets:\r\n  App:\r\n    type: application\r\n" +
            "    settings:\r\n      base:\r\n        INFOPLIST_FILE: Partial-Info.plist\r\n"
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.plistFiles == ["Partial-Info.plist"])
        #expect(e.backgroundModes.map(\.mode) == ["remote-notification"])
    }

    @Test(".xcconfig INFOPLIST_KEY_ settings feed the same buckets")
    func xcconfigInfoplistKeys() throws {
        let dir = root.appendingPathComponent("xcconfig")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = """
            // Build settings feeding the generated Info.plist.
            INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES
            INFOPLIST_KEY_NSLocationWhenInUseUsageDescription = Used to set pickup. // trailing comment
            INFOPLIST_KEY_UIBackgroundModes = audio, fetch
            """
        try config.write(to: dir.appendingPathComponent("Config.xcconfig"),
                         atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [true])
        #expect(e.encryptionDeclarations.map(\.source) == ["Config.xcconfig"])
        #expect(e.usageDescriptions.contains {
            $0.key == "NSLocationWhenInUseUsageDescription" && $0.source == "Config.xcconfig"
        })
        #expect(e.backgroundModes.map(\.mode) == ["audio", "fetch"])
        #expect(e.infoplistSettingFiles == ["Config.xcconfig"])
        #expect(e.projectFiles == ["Config.xcconfig"])
        // An xcconfig is a build-settings file, not a dependency manifest.
        #expect(e.dependencyFiles.isEmpty)
    }

    @Test("CRLF line endings do not hide .xcconfig settings")
    func xcconfigCRLF() throws {
        let dir = root.appendingPathComponent("xcconfig-crlf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = "// comment\r\nINFOPLIST_KEY_ITSAppUsesNonExemptEncryption = YES\r\n" +
            "INFOPLIST_KEY_UIBackgroundModes = audio, fetch\r\n"
        try config.write(to: dir.appendingPathComponent("Config.xcconfig"),
                         atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [true])
        #expect(e.backgroundModes.map(\.mode) == ["audio", "fetch"])
    }

    @Test("extension-target settings never answer for the app")
    func extensionSettingsExcluded() throws {
        let dir = root.appendingPathComponent("xcodegen-ext")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targets:
              App:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
              Widget:
                type: app-extension
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: YES
                    INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: Widget-only.
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // Only the application target's declaration is evidence — the widget's YES
        // must not turn the app's NO into a disagreement.
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(!e.usageDescriptions.contains { $0.key == "NSLocationWhenInUseUsageDescription" })
        #expect(e.infoplistSettingFiles == ["project.yml"])
    }

    @Test("a declaration only an extension makes leaves no app evidence at all")
    func extensionOnlyDeclarationIsInvisible() throws {
        let dir = root.appendingPathComponent("xcodegen-ext-only")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targets:
              App:
                type: application
                settings:
                  base:
                    GENERATE_INFOPLIST_FILE: YES
              Widget:
                type: app-extension
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.isEmpty)
        #expect(e.infoplistSettingFiles.isEmpty)
    }

    @Test("an extension's INFOPLIST_FILE partial plist is not followed for the app")
    func extensionPartialPlistNotFollowed() throws {
        let dir = root.appendingPathComponent("xcodegen-ext-plist")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial: [String: Any] = ["ITSAppUsesNonExemptEncryption": true]
        try PropertyListSerialization.data(fromPropertyList: partial, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Widget-Info.plist"))
        let yml = """
            targets:
              Widget:
                type: app-extension
                settings:
                  base:
                    INFOPLIST_FILE: Widget-Info.plist
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.plistFiles.isEmpty)
        #expect(e.encryptionDeclarations.isEmpty)
    }

    @Test("settingGroups referenced by the app target contribute; extension-only groups do not")
    func settingGroupsScopedByReference() throws {
        let dir = root.appendingPathComponent("xcodegen-groups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            settingGroups:
              shared:
                INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
              widgetOnly:
                INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: Widget-only.
            targets:
              App:
                type: application
                settings:
                  groups: [shared]
              Widget:
                type: app-extension
                settings:
                  groups: [widgetOnly]
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(e.usageDescriptions.isEmpty)
    }

    @Test("YAML comments, indentationless sequences and block scalars parse as modes")
    func yamlListForms() throws {
        let dir = root.appendingPathComponent("xcodegen-yaml-forms")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targets:
              App:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_UIBackgroundModes: # enabled modes
                    - audio # remote-notification is disabled
                    - fetch
              AppTV:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_UIBackgroundModes: |
                      audio
                      remote-notification
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // The comment must not leak words into the mode list; the block scalar's
        // folded lines are modes too.
        #expect(Set(e.backgroundModes.map(\.mode)) == ["audio", "fetch", "remote-notification"])
        #expect(!e.backgroundModes.contains { $0.mode == "#" || $0.mode == "remote-notification is disabled" })
    }

    @Test("a project.yml-only checkout has project files but no dependency inventory")
    func settingsFilesAreNotDependencyManifests() throws {
        let dir = root.appendingPathComponent("xcodegen-nodeps")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targets:
              App:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)
        try "PODS_ROOT = Pods".write(to: dir.appendingPathComponent("Config.xcconfig"),
                                   atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.projectFiles == ["Config.xcconfig", "project.yml"])
        #expect(e.dependencyFiles.isEmpty)
        #expect(e.encryptionDeclarations.map(\.value) == [false])
    }

    @Test("project.yml packages: urls are the dependency inventory when the xcodeproj is gitignored")
    func xcodeGenPackageURLs() throws {
        let dir = root.appendingPathComponent("xcodegen-packages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            name: Demo
            packages:
              Kit:
                url: https://github.com/example/Kit
                from: 1.0.0
              Utils:
                url: https://github.com/example/Utils
                exactVersion: 2.0.0
              Local:
                path: ../LocalPackage
              KitMirror:
                url: https://github.com/example/Kit
            targets:
              App:
                type: application
                dependencies:
                  - package: Kit
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // `path:`-only entries declare no remote URL; the duplicate `url:` dedupes.
        #expect(e.packageDependencies == [
            "https://github.com/example/Kit", "https://github.com/example/Utils",
        ])
        #expect(e.dependencyFiles == ["project.yml"])
    }

    /// `github:` is XcodeGen's shorthand for the same remote URL, and a `url:`
    /// may carry userinfo — credentials are stripped before the value becomes
    /// citable evidence (#38 review).
    @Test("project.yml github: expands and url credentials are stripped")
    func xcodeGenGitHubShorthandAndCredentialStrip() throws {
        let dir = root.appendingPathComponent("xcodegen-github")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            name: Demo
            packages:
              Kit:
                github: example/Kit
              Private:
                url: https://ci-token:x@github.com/example/Private
            targets:
              App:
                type: application
                dependencies:
                  - package: Kit
                  - package: Private
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == [
            "https://github.com/example/Kit", "https://github.com/example/Private",
        ])
    }

    /// A `path:` package the app links but whose manifest lives outside the
    /// scanned root is a blind spot — it lands in `uninspectedDependencies`
    /// rather than letting the SDK question answer "none found" over it.
    /// Declared-but-unlinked packages are not the app's SDKs and stay silent.
    @Test("project.yml path packages the app links are covered or flagged uninspected")
    func xcodeGenPathPackageCoverage() throws {
        let dir = root.appendingPathComponent("xcodegen-paths")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Inside the root with its own manifest → fully covered by the walk.
        let inside = dir.appendingPathComponent("LocalKit")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\n"
            .write(to: inside.appendingPathComponent("Package.swift"),
                   atomically: true, encoding: .utf8)
        let yml = """
            name: Demo
            packages:
              LocalKit:
                path: LocalKit
              OutsideKit:
                path: ../OutsideKit
              UnusedKit:
                path: ../UnusedKit
            targets:
              App:
                type: application
                dependencies:
                  - package: LocalKit
                  - package: OutsideKit
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // The linked in-root package's own manifest was scanned as a dependency.
        #expect(e.dependencyFiles.contains("LocalKit/Package.swift"))
        #expect(e.uninspectedDependencies == [
            "project.yml packages.OutsideKit (local path ../OutsideKit)",
        ])
    }

    /// `dependencies:` entries beyond `package:` — framework/sdk/carthage names
    /// join `linkedFrameworks`, `target:` recurses the in-project graph, and a
    /// target that resolves to nothing is a blind spot, not silence.
    @Test("project.yml target dependencies feed linkedFrameworks and flag blind spots")
    func xcodeGenTargetDependencies() throws {
        let dir = root.appendingPathComponent("xcodegen-target-deps")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            name: Demo
            targets:
              App:
                type: application
                dependencies:
                  - target: Core
                  - framework: Vendor/LibThing.framework
                  - sdk: XCTest.framework
                  - carthage: Carthage/Build/iOS/Alamofire.framework
                  - target: Ghost
              Core:
                type: framework
                dependencies:
                  - framework: Core/Inner.framework
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.linkedFrameworks == [
            "Alamofire.framework", "Inner.framework", "LibThing.framework", "XCTest.framework",
        ])
        #expect(e.uninspectedDependencies == [
            "project.yml: target dependency 'Ghost' not in this spec",
        ])
    }

    /// SwiftPM's `.package(path:)` gets the same coverage rule as XcodeGen's —
    /// a local checkout outside the scanned root can't be inspected.
    @Test("Package.swift path dependency outside the root is uninspected")
    func packageManifestPathDependency() throws {
        let dir = root.appendingPathComponent("swiftpm-path")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(path: \"../SharedKit\"),\n" +
            ".package(url: \"https://github.com/firebase/firebase-ios-sdk\", from: \"10.0.0\"),\n])\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/firebase/firebase-ios-sdk"])
        #expect(e.uninspectedDependencies == ["Package.swift: .package(path: ../SharedKit)"])
    }

    /// Coverage is the set of manifests the walk actually read, not "a
    /// Package.swift exists on disk": `.vendor/` is hidden, so the enumerator
    /// never opened it — the linked package is a blind spot the SDK question
    /// must not answer over (#38 review).
    @Test("a linked path package under a hidden directory is uninspected")
    func hiddenPathPackageIsUninspected() throws {
        let dir = root.appendingPathComponent("hidden-vendor")
        let vendor = dir.appendingPathComponent(".vendor/VendorKit")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\n"
            .write(to: vendor.appendingPathComponent("Package.swift"),
                   atomically: true, encoding: .utf8)
        let yml = """
            name: Demo
            packages:
              VendorKit:
                path: .vendor/VendorKit
            targets:
              App:
                type: application
                dependencies:
                  - package: VendorKit
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.dependencyFiles == ["project.yml"])
        #expect(e.uninspectedDependencies == [
            "project.yml packages.VendorKit (local path .vendor/VendorKit)",
        ])
    }

    /// The other boundary: a `path:` that resolves to the scan root itself is
    /// covered — the root's own `Package.swift` is in the walk's manifest set,
    /// so it must not read as a blind spot (#38 review).
    @Test("a path package resolving to the scan root is covered")
    func rootPathPackageIsCovered() throws {
        let dir = root.appendingPathComponent("root-package")
        let app = dir.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try ("// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"RootKit\")\n")
            .write(to: dir.appendingPathComponent("Package.swift"),
                   atomically: true, encoding: .utf8)
        try ("// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(path: \"../\"),\n])\n")
            .write(to: app.appendingPathComponent("Package.swift"),
                   atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.dependencyFiles.contains("App/Package.swift"))
        #expect(e.uninspectedDependencies.isEmpty)
    }

    /// `link: false` + `embed: false` declares the framework ships nothing —
    /// an explicit opt-out earns no linkedFrameworks entry. Either flag left
    /// enabled keeps the evidence (#38 review).
    @Test("unlinked and unembedded framework dependencies are not shipped evidence")
    func unlinkedUnembeddedFrameworkIsNotEvidence() throws {
        let dir = root.appendingPathComponent("xcodegen-link-embed")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            name: Demo
            targets:
              App:
                type: application
                dependencies:
                  - framework: Vendor/Ships.framework
                  - framework: Vendor/DevOnly.framework
                    link: false
                    embed: false
                  - framework: Vendor/EmbedOnly.framework
                    link: false
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // EmbedOnly keeps `embed` at its default — only both-false opts out.
        #expect(e.linkedFrameworks == ["EmbedOnly.framework", "Ships.framework"])
        #expect(e.uninspectedDependencies.isEmpty)
    }

    /// A commented-out `.package` is not a declaration: line comments, block
    /// comments and trailing comments must all stay invisible to the manifest
    /// readers (#38 review).
    @Test("commented-out package declarations are not dependencies")
    func commentedPackageDeclarationsAreIgnored() throws {
        let dir = root.appendingPathComponent("swiftpm-comments")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = ("// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "// .package(url: \"https://github.com/example/LineCommented\", from: \"1.0.0\"),\n" +
            "/*\n.package(path: \"../BlockCommented\")\n*/\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"), // .package(path: \"../TrailingCommented\")\n" +
            "    .package(path: \"../SharedKit\"),\n" +
            "])\n")
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies == ["Package.swift: .package(path: ../SharedKit)"])
    }

    /// CRLF is a single Character — a naive `"\n"` split sees a CRLF manifest
    /// as one //-led piece and drops every declaration while still recording
    /// the manifest as inspected (#38 review).
    @Test("a CRLF Package.swift keeps its dependencies")
    func crlfManifestKeepsDependencies() throws {
        let dir = root.appendingPathComponent("swiftpm-crlf")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\r\nimport PackageDescription\r\n" +
            "let package = Package(dependencies: [\r\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"),\r\n" +
            "    .package(path: \"../SharedKit\"),\r\n" +
            "])\r\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies == ["Package.swift: .package(path: ../SharedKit)"])
    }

    /// `//` inside `/* */` is ordinary text — truncating the line there orphans
    /// the closer, and a block-removal pass pairs it with a later `*/`, eating
    /// the live declaration between two comments. Swift block comments nest,
    /// so the lexer tracks depth (#38 review).
    @Test("block comments containing // and nesting do not hide live dependencies")
    func blockCommentWithSlashesKeepsDependencies() throws {
        let dir = root.appendingPathComponent("swiftpm-block-slashes")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "/* Use // for brief notes */\n" +
            "/* outer /* inner */ still comment */\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"),\n" +
            "])\n" +
            "/* End dependencies */\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies.isEmpty)
    }

    /// `\(` inside a string is code again — quoted expressions inside the
    /// interpolation can hold `/*`-looking text that must not open a comment
    /// and eat the declarations after it (#38 review).
    @Test("string interpolation with quoted comment markers keeps dependencies")
    func interpolationWithCommentMarkersKeepsDependencies() throws {
        let dir = root.appendingPathComponent("swiftpm-interpolation")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let generated = true\n" +
            "let pattern = \"\\(generated ? \"Generated/**\" : \"Sources/**\")\"\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"),\n" +
            "])\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies.isEmpty)
    }

    /// `/` can open a regex literal, not just comments and division — a `/*`
    /// or `"` inside `/…/` or `#/…/#` is pattern text, and comment markers
    /// after the regex still strip normally (#38 review).
    @Test("regex literals do not hide dependencies or resurrect comments")
    func regexLiteralsKeepDependencies() throws {
        let dir = root.appendingPathComponent("swiftpm-regex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let star = #/^/*Sources/#\n" +
            "let quoted = #/[^\"]+/#\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"),\n" +
            "    // .package(path: \"../CommentedKit\"),\n" +
            "])\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies.isEmpty)
    }

    /// EOF terminates a `//` comment — a manifest whose last line is a comment
    /// with no trailing newline is complete, and its dependencies count
    /// (#38 review).
    @Test("trailing line comment without newline keeps dependencies")
    func trailingCommentKeepsDependencies() throws {
        let dir = root.appendingPathComponent("swiftpm-trailing-comment")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"),\n" +
            "])\n" +
            "// end of manifest"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies.isEmpty)
    }

    /// `!` after an operand is postfix force-unwrap — `/` after it divides,
    /// it must not open a regex that swallows the rest of the manifest. No
    /// later `/` exists here, so a misread would leave the lexer unterminated
    /// and this test would fail (#38 review).
    @Test("force-unwrap division does not open a regex")
    func forceUnwrapDivisionKeepsDependencies() throws {
        let dir = root.appendingPathComponent("swiftpm-force-unwrap")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"),\n" +
            "])\n" +
            "let count = 10\n" +
            "let half = count! / 2\n" +
            "let done = true\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies.isEmpty)
    }

    /// `try!` is a keyword operator introducing an expression, not force
    /// unwrap — `/` after it may open a regex, whose own closing `/` must
    /// not be read as a fresh opener (#38 review).
    @Test("forced try before a regex keeps dependencies")
    func forcedTryRegexKeepsDependencies() throws {
        let dir = root.appendingPathComponent("swiftpm-forced-try")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"),\n" +
            "])\n" +
            "let match = try! /[0-9]+/.wholeMatch(in: \"42\")\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies.isEmpty)
    }

    /// A keyword used as a member name (`.repeat`) is an operand, not the
    /// keyword — `!` after it is force unwrap and `/` divides. No later `/`
    /// exists, so a misread would leave the lexer unterminated (#38 review).
    @Test("keyword-named member force unwrap does not open a regex")
    func memberKeywordForceUnwrapKeepsDependencies() throws {
        let dir = root.appendingPathComponent("swiftpm-member-keyword")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"),\n" +
            "])\n" +
            "struct Settings { let `repeat`: Int? }\n" +
            "let half = Settings(`repeat`: 10).repeat! / 2\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies.isEmpty)
    }

    /// `...` is an operator, not member access — its trailing dot must not
    /// make a following `try!` look like `.try`. The regex's `"` would open
    /// an unterminated string if the slash divided instead (#38 review).
    @Test("partial range before a forced regex keeps dependencies")
    func partialRangeBeforeRegexKeepsDependencies() throws {
        let dir = root.appendingPathComponent("swiftpm-partial-range")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/example/RealDep\", from: \"1.0.0\"),\n" +
            "])\n" +
            "let input = \"42\"\n" +
            "let tail = 0...\n" +
            "try! /a\"b/.wholeMatch(in: input)\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["https://github.com/example/RealDep"])
        #expect(e.uninspectedDependencies.isEmpty)
    }

    @Test("info:/entitlements: properties are inline plist evidence, app-scoped")
    func xcodeGenInlinePlistProperties() throws {
        let dir = root.appendingPathComponent("xcodegen-inline")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targets:
              App:
                type: application
                info:
                  path: App/Info.plist
                  properties:
                    ITSAppUsesNonExemptEncryption: false
                    NSLocationWhenInUseUsageDescription: Used to navigate.
                    UIBackgroundModes: [audio, fetch]
                entitlements:
                  path: App/App.entitlements
                  properties:
                    com.apple.developer.associated-domains: [applinks:example.com]
              Widget:
                type: app-extension
                info:
                  properties:
                    ITSAppUsesNonExemptEncryption: true
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // The widget's `true` must not contradict the app's `false`.
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(e.usageDescriptions.contains {
            $0.key == "NSLocationWhenInUseUsageDescription" && $0.source == "project.yml"
        })
        #expect(Set(e.backgroundModes.map(\.mode)) == ["audio", "fetch"])
        #expect(e.entitlements.contains {
            $0.key == "com.apple.developer.associated-domains"
                && $0.summary == "applinks:example.com" && $0.source == "project.yml"
        })
        #expect(e.infoplistSettingFiles == ["project.yml"])
        // `info.path`/`entitlements.path` are outputs — nothing was read from disk.
        #expect(e.plistFiles.isEmpty && e.entitlementFiles.isEmpty)
        #expect(e.filesScanned == ["project.yml"])
    }

    @Test("project-level settings groups and nested groups resolve transitively")
    func xcodeGenNestedGroups() throws {
        let dir = root.appendingPathComponent("xcodegen-nested-groups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            settings:
              groups: [outer]
            settingGroups:
              outer:
                groups: [inner]
                INFOPLIST_KEY_CFBundleDisplayName: Demo
              inner:
                INFOPLIST_KEY_UIBackgroundModes: fetch
            targets:
              App:
                type: application
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.backgroundModes.map(\.mode) == ["fetch"])
        #expect(e.backgroundModes.allSatisfy { $0.source == "project.yml" })
    }

    @Test("an xcconfig referenced only by an extension target is not app evidence")
    func xcconfigScopedByConfigFiles() throws {
        let dir = root.appendingPathComponent("xcconfig-scoped")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, mode) in [("Shared", "shared-mode"), ("App", "app-mode"),
                             ("Widget", "widget-mode"), ("Orphan", "orphan-mode")] {
            try "INFOPLIST_KEY_UIBackgroundModes = \(mode)\n"
                .write(to: dir.appendingPathComponent("\(name).xcconfig"),
                       atomically: true, encoding: .utf8)
        }
        let yml = """
            configFiles:
              Debug: Shared.xcconfig
            targets:
              App:
                type: application
                configFiles:
                  Debug: App.xcconfig
              Widget:
                type: app-extension
                configFiles:
                  Debug: Widget.xcconfig
                  Release: Widget.xcconfig
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // Project-level, app-target and unreferenced configs are read; the
        // widget-only config is not — its modes would answer for the wrong bundle.
        #expect(Set(e.backgroundModes.map(\.mode)) == ["shared-mode", "app-mode", "orphan-mode"])
        #expect(e.backgroundModes.allSatisfy { $0.source != "Widget.xcconfig" })
        // The file itself was still scanned — only its settings are gated.
        #expect(e.projectFiles.contains("Widget.xcconfig"))
        #expect(e.filesScanned.contains("Widget.xcconfig"))
    }

    @Test("targetTemplates settings apply only through application targets")
    func xcodeGenTargetTemplates() throws {
        let dir = root.appendingPathComponent("xcodegen-templates")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targetTemplates:
              appBase:
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
                    INFOPLIST_KEY_UIBackgroundModes: ${target_name}
              widgetBase:
                settings:
                  base:
                    INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: Widget-only.
            targets:
              App:
                type: application
                templates: [appBase]
              Widget:
                type: app-extension
                templates: [widgetBase]
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(e.usageDescriptions.isEmpty)
        // `${target_name}` expands through the merged target the way XcodeGen's
        // post-merge `expand` does — the build setting literally becomes `App`.
        #expect(e.backgroundModes.map(\.mode) == ["App"])
    }

    @Test("an application type inherited from a template still scopes its evidence")
    func templateDefinedApplicationTarget() throws {
        let dir = root.appendingPathComponent("xcodegen-template-type")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "INFOPLIST_KEY_UIBackgroundModes = template-mode\n"
            .write(to: dir.appendingPathComponent("Shared.xcconfig"),
                   atomically: true, encoding: .utf8)
        // `type:` and `configFiles:` both live only on the template — the target
        // itself declares neither, so raw-node classification would miss the app
        // entirely and leave Shared.xcconfig extension-only through the widget.
        let yml = """
            targetTemplates:
              appBase:
                type: application
                configFiles:
                  Debug: Shared.xcconfig
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
            targets:
              App:
                templates: [appBase]
              Widget:
                type: app-extension
                configFiles:
                  Debug: Shared.xcconfig
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(e.backgroundModes.map(\.mode) == ["template-mode"])
        #expect(e.backgroundModes.allSatisfy { $0.source == "Shared.xcconfig" })
    }

    @Test("a concrete target's declarations beat template defaults — no phantom conflict")
    func templateOverridesWin() throws {
        let dir = root.appendingPathComponent("xcodegen-template-override")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targetTemplates:
              appBase:
                info:
                  properties:
                    ITSAppUsesNonExemptEncryption: true
                    NSLocationWhenInUseUsageDescription: Template usage.
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: YES
            targets:
              App:
                type: application
                templates: [appBase]
                info:
                  properties:
                    ITSAppUsesNonExemptEncryption: false
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // The template's `true`/`YES` lost to the target's `false`/`NO` in both the
        // inline-properties and build-settings channels — recording both would
        // fabricate a conflict Xcode never builds.
        #expect(!e.encryptionDeclarations.isEmpty)
        #expect(e.encryptionDeclarations.allSatisfy { $0.value == false })
        // Non-conflicting template properties still merge in.
        #expect(e.usageDescriptions.contains {
            $0.key == "NSLocationWhenInUseUsageDescription" && $0.source == "project.yml"
        })
    }

    @Test("groups referenced inside settings.configs.* resolve at that config's scope")
    func configScopedSettingGroups() throws {
        let dir = root.appendingPathComponent("xcodegen-config-groups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            settings:
              configs:
                Release:
                  groups: [releaseOnly]
            settingGroups:
              releaseOnly:
                INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: Release-only usage.
            targets:
              App:
                type: application
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.usageDescriptions.contains {
            $0.key == "NSLocationWhenInUseUsageDescription" && $0.source == "project.yml"
        })
    }

    @Test("YAML merge keys supply type, settings and properties like explicit keys")
    func yamlMergeKeys() throws {
        let dir = root.appendingPathComponent("xcodegen-merge")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            enc: &enc
              INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
            usage: &usage
              NSLocationWhenInUseUsageDescription: Merged usage.
            appFields: &appFields
              type: application
              settings:
                base:
                  <<: *enc
                  INFOPLIST_KEY_UIBackgroundModes: audio
            targets:
              App:
                <<: *appFields
                info:
                  properties:
                    <<: *usage
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // `type` arrived through `<<` — without merge expansion the target is not
        // an app and none of this is evidence.
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(e.backgroundModes.map(\.mode) == ["audio"])
        #expect(e.usageDescriptions.contains {
            $0.key == "NSLocationWhenInUseUsageDescription" && $0.source == "project.yml"
        })
    }

    @Test("an xcconfig included by an app config is app evidence even when extension-referenced")
    func xcconfigIncludeFromAppConfig() throws {
        let dir = root.appendingPathComponent("xcconfig-include")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Shared is `#include`d by the app's config AND named directly by the
        // widget — the include chain makes it app evidence. Its self-include must
        // terminate, and Deeper proves includes chain transitively.
        try """
            #include "Shared.xcconfig"
            #include "Deeper.xcconfig"
            INFOPLIST_KEY_NSLocationWhenInUseUsageDescription = Shared usage.
            """.write(to: dir.appendingPathComponent("Shared.xcconfig"),
                     atomically: true, encoding: .utf8)
        try "INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription = Deeper usage.\n"
            .write(to: dir.appendingPathComponent("Deeper.xcconfig"),
                   atomically: true, encoding: .utf8)
        try "#include \"Shared.xcconfig\"\nINFOPLIST_KEY_UIBackgroundModes = app-mode\n"
            .write(to: dir.appendingPathComponent("App.xcconfig"),
                   atomically: true, encoding: .utf8)
        try "INFOPLIST_KEY_UIBackgroundModes = widget-mode\n"
            .write(to: dir.appendingPathComponent("Widget.xcconfig"),
                   atomically: true, encoding: .utf8)
        let yml = """
            targets:
              App:
                type: application
                configFiles:
                  Debug: App.xcconfig
              Widget:
                type: app-extension
                configFiles:
                  Debug: Widget.xcconfig
                  Release: Shared.xcconfig
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.usageDescriptions.contains {
            $0.key == "NSLocationWhenInUseUsageDescription" && $0.source == "Shared.xcconfig"
        })
        #expect(e.usageDescriptions.contains {
            $0.key == "NSLocationAlwaysAndWhenInUseUsageDescription"
                && $0.source == "Deeper.xcconfig"
        })
        #expect(e.backgroundModes.map(\.mode) == ["app-mode"])
        #expect(e.backgroundModes.allSatisfy { $0.source != "Widget.xcconfig" })
    }

    @Test("setting groups resolve in list order — a later group's nested value wins")
    func settingGroupOrderAndNesting() throws {
        let dir = root.appendingPathComponent("xcodegen-group-order")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `production` contributes its encryption value through `inner` — the
        // nested group's declaration must land at `production`'s position in the
        // list, after `defaults`, not ahead of it.
        let yml = """
            settingGroups:
              defaults:
                INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
              inner:
                INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: YES
              production:
                groups: [inner]
            targets:
              App:
                type: application
                settings:
                  groups: [defaults, production]
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [true])
    }

    @Test("a template's own base settings outrank groups the target adds")
    func templateBaseBeatsTargetGroups() throws {
        let dir = root.appendingPathComponent("xcodegen-template-vs-groups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // XcodeGen merges the template dict under the target's before resolving
        // settings — the merged object then resolves groups *before* its own
        // `base:`, so the template's explicit YES survives the target's group NO.
        let yml = """
            targetTemplates:
              appBase:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: YES
            settingGroups:
              prod:
                INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
            targets:
              App:
                templates: [appBase]
                settings:
                  groups: [prod]
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [true])
    }

    @Test("a configFiles entry replaced per-configuration is not app evidence")
    func configFilesMergePerConfiguration() throws {
        let dir = root.appendingPathComponent("xcodegen-configfiles-merge")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, mode) in [("Replaced", "replaced-mode"), ("Kept", "kept-mode"),
                             ("Shared", "shared-mode"), ("Widget", "widget-mode")] {
            try "INFOPLIST_KEY_UIBackgroundModes = \(mode)\n"
                .write(to: dir.appendingPathComponent("\(name).xcconfig"),
                       atomically: true, encoding: .utf8)
        }
        // `outer` replaces only Debug — Release still inherits `inner`'s Shared.
        // Replaced.xcconfig survives solely on the widget, so it is extension-only.
        let yml = """
            targetTemplates:
              inner:
                configFiles:
                  Debug: Replaced.xcconfig
                  Release: Shared.xcconfig
              outer:
                templates: [inner]
                configFiles:
                  Debug: Kept.xcconfig
            targets:
              App:
                type: application
                templates: [outer]
              Widget:
                type: app-extension
                configFiles:
                  Debug: Replaced.xcconfig
                  Release: Widget.xcconfig
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(Set(e.backgroundModes.map(\.mode)) == ["kept-mode", "shared-mode"])
        #expect(e.projectFiles.contains("Replaced.xcconfig"))
    }

    @Test("app and tests-only projects sharing an xcconfig still read it as app evidence")
    func sharedXcconfigAcrossProjects() throws {
        let dir = root.appendingPathComponent("xcconfig-shared-projects")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("App"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Tests"),
                                                withIntermediateDirectories: true)
        try "INFOPLIST_KEY_UIBackgroundModes = shared-mode\n"
            .write(to: dir.appendingPathComponent("Shared.xcconfig"),
                   atomically: true, encoding: .utf8)
        try """
            targets:
              App:
                type: application
                configFiles:
                  Debug: ../Shared.xcconfig
            """.write(to: dir.appendingPathComponent("App/project.yml"),
                     atomically: true, encoding: .utf8)
        try """
            targets:
              Tests:
                type: bundle.unit-test
                configFiles:
                  Debug: ../Shared.xcconfig
            """.write(to: dir.appendingPathComponent("Tests/project.yml"),
                     atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // Subtracting per-spec would let the tests-only project hide the config
        // the app project shares; unioning first keeps it app evidence.
        #expect(e.backgroundModes.map(\.mode) == ["shared-mode"])
    }

    @Test("inline plist arrays concatenate down the template chain")
    func infoPropertiesArraysMerge() throws {
        let dir = root.appendingPathComponent("xcodegen-info-array-merge")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targetTemplates:
              appBase:
                type: application
                info:
                  properties:
                    UIBackgroundModes:
                      - remote-notification
            targets:
              App:
                templates: [appBase]
                info:
                  properties:
                    UIBackgroundModes:
                      - fetch
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(Set(e.backgroundModes.map(\.mode)) == ["remote-notification", "fetch"])
    }

    @Test("a :REPLACE key substitutes the inherited plist value wholesale")
    func infoPropertiesReplace() throws {
        let dir = root.appendingPathComponent("xcodegen-info-replace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targetTemplates:
              appBase:
                type: application
                info:
                  properties:
                    UIBackgroundModes:
                      - remote-notification
            targets:
              App:
                templates: [appBase]
                info:
                  properties:
                    "UIBackgroundModes:REPLACE":
                      - fetch
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.backgroundModes.map(\.mode) == ["fetch"])
    }

    @Test("$(inherited) defers to the lower build-settings layer instead of masking it")
    func inheritedSettingDefers() throws {
        let dir = root.appendingPathComponent("xcodegen-inherited")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            settings:
              base:
                INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO
            targets:
              App:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: $(inherited)
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [false])
    }

    @Test("the config include chase never opens files outside the safe set")
    func xcconfigChaseStaysInsideSafeFiles() throws {
        let dir = root.appendingPathComponent("xcconfig-chase-safety")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Both blocked includes would pull Shared.xcconfig into app evidence if
        // the chase opened them: one lives outside the scan root, the other has a
        // credential-shaped extension.
        try "#include \"../Outside.xcconfig\"\n#include \"Config.p8\"\nINFOPLIST_KEY_UIBackgroundModes = app-mode\n"
            .write(to: dir.appendingPathComponent("App.xcconfig"),
                   atomically: true, encoding: .utf8)
        try "#include \"xcconfig-chase-safety/Shared.xcconfig\"\n"
            .write(to: root.appendingPathComponent("Outside.xcconfig"),
                   atomically: true, encoding: .utf8)
        try "#include \"Shared.xcconfig\"\n"
            .write(to: dir.appendingPathComponent("Config.p8"),
                   atomically: true, encoding: .utf8)
        try "INFOPLIST_KEY_UIBackgroundModes = shared-mode\n"
            .write(to: dir.appendingPathComponent("Shared.xcconfig"),
                   atomically: true, encoding: .utf8)
        let yml = """
            targets:
              App:
                type: application
                configFiles:
                  Debug: App.xcconfig
              Widget:
                type: app-extension
                configFiles:
                  Debug: Shared.xcconfig
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.backgroundModes.map(\.mode) == ["app-mode"])
        #expect(e.projectFiles.contains("Shared.xcconfig"))
    }

    @Test("a config a template names but the target replaces stays non-app")
    func supersededTemplateConfigKeepsNonAppProvenance() throws {
        let dir = root.appendingPathComponent("superseded-template-config")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "INFOPLIST_KEY_UIBackgroundModes = defaults-mode\n"
            .write(to: dir.appendingPathComponent("WidgetDefaults.xcconfig"),
                   atomically: true, encoding: .utf8)
        try "INFOPLIST_KEY_UIBackgroundModes = widget-mode\n"
            .write(to: dir.appendingPathComponent("Widget.xcconfig"),
                   atomically: true, encoding: .utf8)
        try "INFOPLIST_KEY_UIBackgroundModes = app-mode\n"
            .write(to: dir.appendingPathComponent("App.xcconfig"),
                   atomically: true, encoding: .utf8)
        let yml = """
            targetTemplates:
              widgetBase:
                configFiles:
                  Debug: WidgetDefaults.xcconfig
            targets:
              App:
                type: application
                configFiles:
                  Debug: App.xcconfig
              Widget:
                type: app-extension
                templates: [widgetBase]
                configFiles:
                  Debug: Widget.xcconfig
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // WidgetDefaults is superseded by the widget's own configFiles — dead for
        // the build, and never an app config. Only the app's file may contribute.
        #expect(e.backgroundModes.map(\.mode) == ["app-mode"])
    }

    @Test("$(inherited) inside one settings layer erases the group's value")
    func inheritedWithinLayerSuppressesGroupValue() throws {
        let dir = root.appendingPathComponent("inherited-within-layer")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            settingGroups:
              locked:
                INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "NO"
            targets:
              App:
                type: application
                settings:
                  groups: [locked]
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: $(inherited)
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // The flattened build-settings dict holds $(inherited), not the group's
        // NO — and with no lower layer declaring the key, nothing is evidence.
        #expect(e.encryptionDeclarations.isEmpty)
    }

    @Test("$(inherited) inside one settings layer defers to the project layer")
    func inheritedWithinLayerDefersToProjectDecl() throws {
        let dir = root.appendingPathComponent("inherited-defers-to-project")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            settings:
              base:
                INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "YES"
            settingGroups:
              locked:
                INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "NO"
            targets:
              App:
                type: application
                settings:
                  groups: [locked]
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: $(inherited)
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // Target's $(inherited) erases the group NO within its layer, then defers
        // to the project layer's YES — the value Xcode would actually build.
        #expect(e.encryptionDeclarations.map(\.value) == [true])
    }

    @Test("nested configs selectors resolve against the actual config name")
    func nestedConfigSelectorsResolvePerConfig() throws {
        let dir = root.appendingPathComponent("nested-config-selectors")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            settingGroups:
              debugGroup:
                configs:
                  Debug:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "NO"
            targets:
              App:
                type: application
                settings:
                  configs:
                    Debug:
                      groups: [debugGroup]
                      base:
                        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "YES"
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // For config Debug: the group's nested Debug selector emits NO first,
        // then the Debug node's own base emits YES — YES wins. The buggy path
        // scope recorded both as separate declarations ([false, true]).
        #expect(e.encryptionDeclarations.map(\.value) == [true])
    }

    @Test("an explicit empty array clears modes a group declares")
    func emptyArrayClearsInheritedArray() throws {
        let dir = root.appendingPathComponent("empty-array-clears")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            settingGroups:
              modes:
                INFOPLIST_KEY_UIBackgroundModes: [remote-notification]
            targets:
              App:
                type: application
                settings:
                  groups: [modes]
                  base:
                    INFOPLIST_KEY_UIBackgroundModes: []
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // `[]` is a concrete winning value — it suppresses the group's array the
        // way Xcode's flattened dict does, leaving no modes to cite.
        #expect(e.backgroundModes.isEmpty)
    }

    @Test("a sole template's :REPLACE keys normalize through the merge")
    func firstTemplateReplacementKeysNormalize() throws {
        let dir = root.appendingPathComponent("first-template-replace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targetTemplates:
              base:
                settings:REPLACE:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "NO"
            targets:
              App:
                type: application
                templates: [base]
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // The first (only) template still passes through mergedSpec, so its
        // `settings:REPLACE` key strips to `settings` instead of staying literal
        // and invisible.
        #expect(e.encryptionDeclarations.map(\.value) == [false])
    }

    @Test("overlapping configs selectors keep both candidates as ambiguity")
    func overlappingSelectorsStayAmbiguous() throws {
        let dir = root.appendingPathComponent("overlapping-selectors")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            configs:
              AppStore: release
            settings:
              configs:
                AppStore:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "YES"
                store:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "NO"
            targets:
              App:
                type: application
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // "AppStore" contains-matches both `AppStore` and `store`; XcodeGen walks
        // its configSettings dictionary in hash order, so either value can win —
        // the sheet must see the disagreement, not a fabricated certainty.
        #expect(Set(e.encryptionDeclarations.map(\.value)) == [true, false])
    }

    @Test("a top-level configs:REPLACE still names the real configurations")
    func topLevelConfigsReplace() throws {
        let dir = root.appendingPathComponent("configs-replace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            configs:REPLACE:
              AppStore: release
            settings:
              configs:
                AppStore:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "NO"
            targets:
              App:
                type: application
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // Without root-level :REPLACE normalization the spec falls back to
        // Debug/Release and the AppStore-scoped declaration is invisible.
        #expect(e.encryptionDeclarations.map(\.value) == [false])
    }

    @Test("an appending inherited list unions with the project layer's modes")
    func appendingInheritedUnionsLowerLayer() throws {
        let dir = root.appendingPathComponent("appending-inherited")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            configs:
              AppStore: release
            settings:
              base:
                INFOPLIST_KEY_UIBackgroundModes: [remote-notification]
            targets:
              App:
                type: application
                settings:
                  configs:
                    AppStore:
                      base:
                        INFOPLIST_KEY_UIBackgroundModes: ['$(inherited)', audio]
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // `['$(inherited)', audio]` keeps `audio` *and* inherits the project's
        // `remote-notification` — both are modes the build can emit.
        #expect(Set(e.backgroundModes.map(\.mode)) == ["audio", "remote-notification"])
    }

    @Test("${target_name} in configFiles expands to the live app config")
    func targetNameVariableExpandsConfigPaths() throws {
        let dir = root.appendingPathComponent("target-name-config")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "INFOPLIST_KEY_UIBackgroundModes = app-mode\n"
            .write(to: dir.appendingPathComponent("App.xcconfig"),
                   atomically: true, encoding: .utf8)
        let yml = """
            targetTemplates:
              appBase:
                configFiles:
                  Debug: App.xcconfig
            targets:
              App:
                type: application
                templates: [appBase]
                configFiles:
                  Debug: "${target_name}.xcconfig"
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // `${target_name}.xcconfig` resolves to the same App.xcconfig the
        // template named — the app's effective path must cancel the template's
        // non-app provenance or the live config reads as dead.
        #expect(e.backgroundModes.map(\.mode) == ["app-mode"])
    }

    @Test("settings:REPLACE on a template-free target stays literal")
    func templateFreeTargetKeepsReplaceLiteral() throws {
        let dir = root.appendingPathComponent("template-free-replace")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targets:
              App:
                type: application
                settings:REPLACE:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "NO"
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // XcodeGen merges a target only when a template resolves — with none,
        // `settings:REPLACE` is a literal key that declares nothing.
        #expect(e.encryptionDeclarations.isEmpty)
    }

    @Test("a template's configFiles:REPLACE paths keep non-app provenance")
    func templateConfigFilesReplaceProvenance() throws {
        let dir = root.appendingPathComponent("configfiles-replace-prov")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "INFOPLIST_KEY_UIBackgroundModes = old-mode\n"
            .write(to: dir.appendingPathComponent("Old.xcconfig"),
                   atomically: true, encoding: .utf8)
        try "INFOPLIST_KEY_UIBackgroundModes = new-mode\n"
            .write(to: dir.appendingPathComponent("New.xcconfig"),
                   atomically: true, encoding: .utf8)
        try "INFOPLIST_KEY_UIBackgroundModes = app-mode\n"
            .write(to: dir.appendingPathComponent("App.xcconfig"),
                   atomically: true, encoding: .utf8)
        let yml = """
            targetTemplates:
              widgetBase:
                configFiles:REPLACE:
                  Debug: Old.xcconfig
            targets:
              App:
                type: application
                configFiles:
                  Debug: App.xcconfig
              Widget:
                type: app-extension
                templates: [widgetBase]
                configFiles:
                  Debug: New.xcconfig
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // Old.xcconfig is what the template's :REPLACE declared before the
        // widget overrode it — dead for the build and non-app by provenance.
        #expect(e.backgroundModes.map(\.mode) == ["app-mode"])
    }

    @Test("templateAttributes never expand inside shared settingGroups")
    func sharedGroupsStayUnexpanded() throws {
        let dir = root.appendingPathComponent("group-vars")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // XcodeGen expands the merged *target* dict, then looks groups up by
        // name in the unexpanded project dict — a `${…}` inside a group is a
        // literal build-setting reference, not a template variable.
        let yml = """
            settingGroups:
              shared:
                base:
                  INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: ${ENCRYPTION_FLAG}
            targetTemplates:
              app:
                type: application
            targets:
              App:
                templates: [app]
                templateAttributes:
                  ENCRYPTION_FLAG: "NO"
                settings:
                  groups: [shared]
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // The attribute must not substitute into the group — the literal
        // `${ENCRYPTION_FLAG}` is no declaration the sheet can stand behind.
        #expect(e.encryptionDeclarations.isEmpty)
        #expect(!e.infoplistSettingFiles.contains("project.yml"))
    }

    @Test("an Xcode $(…) macro does not block a later ${…} template variable")
    func xcodeMacroBeforeTemplateVariable() throws {
        let dir = root.appendingPathComponent("macro-then-var")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Plists"), withIntermediateDirectories: true)
        let partial: [String: Any] = [
            "ITSAppUsesNonExemptEncryption": false,
        ]
        try PropertyListSerialization.data(fromPropertyList: partial, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Plists/App-Partial.plist"))
        // `$(SRCROOT)` is an Xcode build macro — the template expander must
        // skip it and still resolve the `${target_name}` after it.
        let yml = """
            targetTemplates:
              app:
                type: application
            targets:
              App:
                templates: [app]
                settings:
                  base:
                    INFOPLIST_FILE: '$(SRCROOT)/Plists/${target_name}-Partial.plist'
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(e.encryptionDeclarations.map(\.source) == ["Plists/App-Partial.plist"])
    }

    @Test("templateAttributes values get the target_name pass before substituting")
    func attributeValueExpandsTargetName() throws {
        let dir = root.appendingPathComponent("attr-target-name")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Plists"), withIntermediateDirectories: true)
        let partial: [String: Any] = [
            "NSCameraUsageDescription": "to scan parcels",
        ]
        try PropertyListSerialization.data(fromPropertyList: partial, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Plists/App-Partial.plist"))
        // Upstream expands `${target_name}` through the whole merged dict —
        // including inside `templateAttributes` — before substituting the
        // attributes, so `plistPath` arrives already resolved.
        let yml = """
            targetTemplates:
              app:
                type: application
                settings:
                  base:
                    INFOPLIST_FILE: '${plistPath}'
            targets:
              App:
                templates: [app]
                templateAttributes:
                  plistPath: 'Plists/${target_name}-Partial.plist'
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.usageDescriptions.map(\.key) == ["NSCameraUsageDescription"])
        #expect(e.usageDescriptions.map(\.source) == ["Plists/App-Partial.plist"])
    }

    @Test("a templated type resolves before the app/non-app split")
    func templatedTypeClassifiesApp() throws {
        let dir = root.appendingPathComponent("templated-type")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `type:` arrives through `${productType}` — upstream expands the whole
        // merged target before reading the product type.
        let yml = """
            targetTemplates:
              app:
                type: '${productType}'
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "NO"
            targets:
              App:
                templates: [app]
                templateAttributes:
                  productType: application
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(e.encryptionDeclarations.map(\.source) == ["project.yml"])
    }

    @Test("a scalar INFOPLIST_FILE substitutes $(inherited) positionally")
    func scalarInfoplistFileInheritsPositionally() throws {
        let dir = root.appendingPathComponent("scalar-inherit-path")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Store"), withIntermediateDirectories: true)
        let base: [String: Any] = ["ITSAppUsesNonExemptEncryption": false]
        let derived: [String: Any] = ["ITSAppUsesNonExemptEncryption": true]
        for (path, plist) in [("Base-Partial.plist", base), ("Store/Base-Partial.plist", derived)] {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: dir.appendingPathComponent(path))
        }
        // `INFOPLIST_FILE` is a scalar — `Store/$(inherited)` resolves to
        // `Store/Base-Partial.plist`, not the bare base path.
        let yml = """
            settings:
              base:
                INFOPLIST_FILE: Base-Partial.plist
            targets:
              App:
                type: application
                settings:
                  base:
                    INFOPLIST_FILE: 'Store/$(inherited)'
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [true])
        #expect(e.encryptionDeclarations.map(\.source) == ["Store/Base-Partial.plist"])
    }

    @Test("a mode shared across configs cites its source once")
    func sharedModesAcrossConfigsCiteOnce() throws {
        let dir = root.appendingPathComponent("mode-dedupe")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yml = """
            targets:
              App:
                type: application
                settings:
                  configs:
                    Debug:
                      INFOPLIST_KEY_UIBackgroundModes: [audio, remote-notification]
                    Release:
                      INFOPLIST_KEY_UIBackgroundModes: [remote-notification, fetch]
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.backgroundModes.map(\.mode).sorted() == ["audio", "fetch", "remote-notification"])
        #expect(e.backgroundModes.allSatisfy { $0.source == "project.yml" })
    }

    @Test("an explicit mode survives an unresolved macro in the same inherited value")
    func explicitModeSurvivesInheritedMacro() throws {
        let dir = root.appendingPathComponent("mode-macro-mix")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The project value is an Xcode macro the scanner cannot evaluate; the
        // target appends `remote-notification` explicitly. Positional
        // substitution joins them into one string — the literal mode must not
        // be discarded for its unresolvable sibling.
        let yml = """
            settings:
              base:
                INFOPLIST_KEY_UIBackgroundModes: '$(SHARED_BACKGROUND_MODES)'
            targets:
              App:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_UIBackgroundModes: 'remote-notification $(inherited)'
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.backgroundModes.map(\.mode) == ["remote-notification"])
        #expect(e.backgroundModes.allSatisfy { $0.source == "project.yml" })
    }

    @Test("a non-string templateAttributes value voids the whole attribute pass")
    func nonStringAttributeVoidsPass() throws {
        let dir = root.appendingPathComponent("attr-nonstring")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Plists"), withIntermediateDirectories: true)
        // The plist exists so a wrongly-expanded `plistPath` would produce
        // evidence — the voided pass must leave `${plistPath}` unresolved.
        let partial: [String: Any] = ["NSCameraUsageDescription": "to scan parcels"]
        try PropertyListSerialization.data(fromPropertyList: partial, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Plists/App-Partial.plist"))
        // Upstream casts templateAttributes `as? [String: String]` — the YAML
        // `true` is a bool, so *no* attribute expands, not just the bad one.
        let yml = """
            targetTemplates:
              app:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: '${FLAG}'
                    INFOPLIST_FILE: '${plistPath}'
            targets:
              App:
                templates: [app]
                templateAttributes:
                  FLAG: true
                  plistPath: 'Plists/App-Partial.plist'
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.isEmpty)
        #expect(e.usageDescriptions.isEmpty)
        #expect(e.infoplistSettingFiles.isEmpty)
    }

    @Test("a quoted bool-like attribute stays a string through expansion")
    func quotedBoolAttributeStaysString() throws {
        let dir = root.appendingPathComponent("attr-quoted-bool")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `FLAG: "YES"` is a string upstream — the [String: String] cast
        // succeeds and `${FLAG}` expands to YES. Rebuilding the scalar with
        // an implicit tag would re-resolve it as a bool and void the pass.
        let yml = """
            targetTemplates:
              app:
                type: application
                settings:
                  configs:
                    Debug:
                      INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: "NO"
                    Release:
                      INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: '${FLAG}'
            targets:
              App:
                templates: [app]
                templateAttributes:
                  FLAG: "YES"
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        // Both configurations declare — the sheet sees the disagreement
        // rather than only Debug's NO.
        #expect(Set(e.encryptionDeclarations.map(\.value)) == [false, true])
    }

    @Test("a :default= fallback's spaces do not leak modes")
    func macroFallbackDoesNotLeakModes() throws {
        let dir = root.appendingPathComponent("macro-default-fallback")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `$(SHARED:default=…)` is one macro reference — its fallback text can
        // contain spaces, and none of it is a literal mode.
        let yml = """
            targets:
              App:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_UIBackgroundModes: 'audio $(SHARED:default=audio remote-notification fetch)'
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.backgroundModes.map(\.mode) == ["audio"])
    }

    @Test("an escaped $$ inside a macro does not swallow the modes after it")
    func escapedDollarInsideMacro() throws {
        let dir = root.appendingPathComponent("macro-escaped-dollar")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `$$` is Xcode's literal-dollar escape — `$${` opens no nested
        // reference, so the `)` still closes the outer macro and the literal
        // mode after it survives.
        try "INFOPLIST_KEY_UIBackgroundModes = $(SHARED:default=$${) remote-notification\n"
            .write(to: dir.appendingPathComponent("Shared.xcconfig"),
                   atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.backgroundModes.map(\.mode) == ["remote-notification"])
        #expect(e.backgroundModes.allSatisfy { $0.source == "Shared.xcconfig" })
    }

    @Test("a local-tagged template value still constructs as a string")
    func localTaggedTemplateValueExpands() throws {
        let dir = root.appendingPathComponent("tagged-template-value")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Yams has no constructor for `!template` and falls back to the scalar
        // text — upstream's JSON dict sees a String and expands it.
        let yml = """
            targetTemplates:
              app:
                type: application
                settings:
                  base:
                    INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: !template '${FLAG}'
            targets:
              App:
                templates: [app]
                templateAttributes:
                  FLAG: "NO"
            """
        try yml.write(to: dir.appendingPathComponent("project.yml"),
                      atomically: true, encoding: .utf8)

        let e = try EvidenceScan.scan(root: dir)
        #expect(e.encryptionDeclarations.map(\.value) == [false])
        #expect(e.encryptionDeclarations.map(\.source) == ["project.yml"])
    }
}

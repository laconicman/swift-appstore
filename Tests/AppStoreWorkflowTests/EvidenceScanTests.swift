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
                configFiles: App.xcconfig
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
        // `${target_name}` is a template placeholder, not a mode.
        #expect(e.backgroundModes.isEmpty)
    }
}

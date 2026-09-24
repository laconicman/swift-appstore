import Foundation
import Testing
@testable import AppStoreWorkflow

/// `asc questionnaire`: project scan → four answer sheets → deterministic rewrite.
@Suite("Questionnaire answer sheets")
struct QuestionnaireTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Q-\(UUID().uuidString)", isDirectory: true)

    /// A minimal app project: app plist with the export key + speech usage, an iCloud
    /// entitlement, a privacy manifest collecting crash data, a pbxproj with a package,
    /// and a controller referencing SFSpeechRecognizer without on-device pinning.
    func fixtureProject() throws -> URL {
        let fm = FileManager.default
        let app = root.appendingPathComponent("App")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "ITSAppUsesNonExemptEncryption": false,
            "NSSpeechRecognitionUsageDescription": "to test pronunciation",
            "NSMicrophoneUsageDescription": "to listen to speech",
            "UIBackgroundModes": ["remote-notification"],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        let entitlements: [String: Any] = [
            "com.apple.developer.icloud-services": ["CloudKit"],
            "aps-environment": "development",
        ]
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("App.entitlements"))
        let privacy: [String: Any] = [
            "NSPrivacyTracking": false,
            "NSPrivacyCollectedDataTypes": [[
                "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeCrashData",
                "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
                "NSPrivacyCollectedDataTypeLinked": false,
                "NSPrivacyCollectedDataTypeTracking": false,
            ]],
        ]
        try PropertyListSerialization.data(fromPropertyList: privacy, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("PrivacyInfo.xcprivacy"))
        let pbx = """
            remoteSwiftPackage = { repositoryURL = "https://github.com/example/KaPow"; };
            SwiftUI.framework in Frameworks
            """
        let projDir = root.appendingPathComponent("App.xcodeproj")
        try fm.createDirectory(at: projDir, withIntermediateDirectories: true)
        try pbx.write(to: projDir.appendingPathComponent("project.pbxproj"),
                      atomically: true, encoding: .utf8)
        try "import Speech\nlet r = SFSpeechRecognizer()\n".write(
            to: app.appendingPathComponent("Dictation.swift"), atomically: true, encoding: .utf8)
        return root
    }

    func sheet(_ name: String, in sheets: [AnswerSheet]) -> AnswerSheet {
        guard let sheet = sheets.first(where: { $0.fileName == name }) else {
            Issue.record("missing sheet \(name)"); fatalError("missing sheet")
        }
        return sheet
    }

    @Test func exportComplianceAnsweredFromPlist() throws {
        let e = try EvidenceScan.scan(root: fixtureProject())
        let s = sheet("export-compliance.md", in: Questionnaire.sheets(for: e))
        let crypto = try #require(s.items.first)
        #expect(crypto.answer?.contains("No") == true)
        #expect(crypto.evidence.contains { $0.contains("ITSAppUsesNonExemptEncryption") })
        #expect(s.openCount == 1)  // the ECCN/France owner follow-ups stay open
    }

    @Test func conflictingEncryptionDeclarationsStayOpen() throws {
        _ = try fixtureProject()
        // A second bundle declares the opposite — disagreement must not resolve silently.
        let ext = root.appendingPathComponent("Ext.appex")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["ITSAppUsesNonExemptEncryption": true], format: .xml, options: 0
        ).write(to: ext.appendingPathComponent("Info.plist"))
        let s = sheet("export-compliance.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: root)))
        #expect(s.items.first?.isOpen == true)
        #expect(s.items.first?.question.contains("disagree") == true)
    }

    @Test func privacySheetCitesManifestsAndFlagsSpeech() throws {
        let e = try EvidenceScan.scan(root: fixtureProject())
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: e))
        let tracking = try #require(s.items.first { $0.question.contains("track") })
        #expect(tracking.answer?.contains("No") == true)
        #expect(tracking.evidence.contains { $0.contains("PrivacyInfo.xcprivacy") })
        #expect(s.items.contains { $0.question.contains("Crash Data") && $0.answer != nil })
        // The task doc's flagged unknown: speech recognizer without on-device pinning.
        let speech = try #require(s.items.first { $0.question.contains("Speech recognition") })
        #expect(speech.isOpen)
        #expect(speech.evidence.contains { $0.contains("Dictation.swift") })
    }

    /// A text hit is context, not proof: a comment naming the pin must not register,
    /// and even a real `= true` assignment cannot prove it covers every recognizer —
    /// the destination stays open either way, citing what was found.
    @Test func onDevicePinningIsContextNotProof() throws {
        _ = try fixtureProject()
        try "// requiresOnDeviceRecognition = true".write(
            to: root.appendingPathComponent("App/Commented.swift"), atomically: true, encoding: .utf8)
        var s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: root)))
        var speech = try #require(s.items.first { $0.question.contains("Speech recognition") })
        #expect(speech.isOpen)
        #expect(speech.guidance?.contains("not set") == true)

        try "recognizer.requiresOnDeviceRecognition = true".write(
            to: root.appendingPathComponent("App/Pinning.swift"), atomically: true, encoding: .utf8)
        s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: root)))
        speech = try #require(s.items.first { $0.question.contains("Speech recognition") })
        #expect(speech.isOpen)
        #expect(speech.guidance?.contains("cannot prove") == true)
        #expect(speech.evidence.contains { $0.contains("Pinning.swift") })
    }

    /// A manifest that omits NSPrivacyTracking is not a "false" — partial declaration
    /// coverage keeps the tracking question open and names the silent manifest.
    @Test func manifestOmittingTrackingKeyStaysOpen() throws {
        _ = try fixtureProject()
        let sdk = root.appendingPathComponent("SDK")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["NSPrivacyCollectedDataTypes": []], format: .xml, options: 0
        ).write(to: sdk.appendingPathComponent("PrivacyInfo.xcprivacy"))
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: root)))
        let tracking = try #require(s.items.first { $0.question.contains("track") })
        #expect(tracking.isOpen)
        #expect(tracking.evidence.contains { $0.contains("key absent") })
    }

    /// No project.pbxproj and no Package.swift → no dependency inventory was scanned;
    /// "no SDKs" would be a fabricated answer.
    @Test func noDependencyInventoryLeavesSDKQuestionOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: dir)))
        let sdk = try #require(s.items.first { $0.question.contains("SDK") })
        #expect(sdk.isOpen)
    }

    /// A SwiftPM-only project still yields a dependency inventory via Package.swift.
    @Test func packageManifestFeedsDependencyInventory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\nimport PackageDescription\n" +
            "let package = Package(dependencies: [\n" +
            "    .package(url: \"https://github.com/firebase/firebase-ios-sdk\", from: \"10.0.0\"),\n])\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)
        let e = try EvidenceScan.scan(root: dir)
        #expect(e.projectFiles == ["Package.swift"])
        #expect(e.packageDependencies == ["https://github.com/firebase/firebase-ios-sdk"])
    }

    /// Credential-shaped files in the source tree are never opened.
    @Test func sensitiveFilesAreNeverOpened() throws {
        _ = try fixtureProject()
        try "SECRET".write(to: root.appendingPathComponent("AuthKey_ABC.p8"),
                           atomically: true, encoding: .utf8)
        let e = try EvidenceScan.scan(root: root)
        #expect(!e.filesScanned.contains { $0.hasSuffix(".p8") })
    }

    /// Speech permission in the plist but no recognizer signal — the question must
    /// still surface rather than silently dropping off the sheet.
    @Test func speechPermissionWithoutSignalStillAsks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["NSSpeechRecognitionUsageDescription": "x"], format: .xml, options: 0
        ).write(to: dir.appendingPathComponent("Info.plist"))
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: dir)))
        #expect(s.items.first { $0.question.contains("Speech recognition") }?.isOpen == true)
    }

    @Test func ageRatingCodeAnswersAndOwnerQuestions() throws {
        let s = sheet("age-rating.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: fixtureProject())))
        #expect(s.items.first { $0.question.contains("web access") }?.answer?.contains("No") == true)
        #expect(s.items.first { $0.question.contains("User-generated") }?.isOpen == true)
    }

    @Test func accessibilityLabelsStayOpenForTheAudit() throws {
        let s = sheet("accessibility-labels.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: fixtureProject())))
        #expect(s.items.allSatisfy { $0.isOpen })
        #expect(s.items.contains { $0.question.contains("VoiceOver") })
    }

    @Test func noManifestLeavesTrackingOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: dir)))
        #expect(s.items.first?.isOpen == true)
    }

    @Test func regenerateIsDeterministicAndDiffsOnlyOnChange() throws {
        let project = try fixtureProject()
        let e1 = try EvidenceScan.scan(root: project)
        let e2 = try EvidenceScan.scan(root: project)
        let sheets1 = Questionnaire.sheets(for: e1).map { $0.render() }
        let sheets2 = Questionnaire.sheets(for: e2).map { $0.render() }
        #expect(sheets1 == sheets2)

        let out = root.appendingPathComponent("out")
        let first = try SheetStore.write(Questionnaire.sheets(for: e1), to: out)
        #expect(first.added.count == 4)
        let second = try SheetStore.write(Questionnaire.sheets(for: e2), to: out)
        #expect(second.unchanged.count == 4 && second.changed.isEmpty)

        // A code change moves an open item's context — the diff flags exactly that sheet.
        try "recognizer.requiresOnDeviceRecognition = true".write(
            to: project.appendingPathComponent("App/Pinning.swift"), atomically: true, encoding: .utf8)
        let third = try SheetStore.write(
            Questionnaire.sheets(for: try EvidenceScan.scan(root: project)), to: out)
        #expect(third.changed == ["app-privacy.md"])
    }

    /// An Objective-C file counts toward source coverage — WKWebView in .m must
    /// surface as a found signal, not get a fabricated "No".
    @Test func objectiveCSourcesAreScanned() throws {
        _ = try fixtureProject()
        try "#import <WebKit/WebKit.h>\nWKWebView *w;".write(
            to: root.appendingPathComponent("App/Browser.m"), atomically: true, encoding: .utf8)
        let s = sheet("age-rating.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: root)))
        let web = try #require(s.items.first { $0.question.contains("web access") })
        #expect(web.isOpen)
        #expect(web.evidence.contains { $0.contains("Browser.m") })
    }

    /// An unscanned source file (over the size cap) voids absence claims —
    /// the age-rating answers stay open and name the skipped file.
    @Test func skippedSourceFilesVoidAbsenceClaims() throws {
        _ = try fixtureProject()
        let big = String(repeating: "x", count: 600 * 1024)
        try big.write(to: root.appendingPathComponent("App/Huge.swift"),
                      atomically: true, encoding: .utf8)
        let s = sheet("age-rating.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: root)))
        let web = try #require(s.items.first { $0.question.contains("web access") })
        #expect(web.isOpen)
        #expect(web.evidence.contains { $0.contains("Huge.swift") })
    }

    /// iCloud entitlements are context, not a destination answer.
    @Test func iCloudEntitlementLeavesDestinationOpen() throws {
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: fixtureProject())))
        let item = try #require(s.items.first { $0.question.contains("off-device") })
        #expect(item.isOpen)
        #expect(item.evidence.contains { $0.contains("icloud-services") })
    }

    /// A package repo that hosts a collector product must flag the SDK question —
    /// firebase-ios-sdk is the name FirebaseAnalytics actually ships under.
    @Test func repoNamedCollectorKeepsSDKQuestionOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = "// swift-tools-version: 5.9\n" +
            ".package(url: \"https://github.com/firebase/firebase-ios-sdk\", from: \"10.0.0\")\n"
        try manifest.write(to: dir.appendingPathComponent("Package.swift"),
                           atomically: true, encoding: .utf8)
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: dir)))
        let sdk = try #require(s.items.first { $0.question.contains("SDK") })
        #expect(sdk.isOpen)
    }

    /// A symlink named Info.plist pointing at a credential file is never opened.
    @Test func symlinkedPlistCannotReachCredentials() throws {
        _ = try fixtureProject()
        let dir = root.appendingPathComponent("Trap")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "PRIVATEKEY".write(to: dir.appendingPathComponent("AuthKey.p8"),
                               atomically: true, encoding: .utf8)
        // A symlink named like a recognized file but pointing at a credential:
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("Info.plist").path,
            withDestinationPath: dir.appendingPathComponent("AuthKey.p8").path)
        let e = try EvidenceScan.scan(root: dir)
        #expect(e.filesScanned.isEmpty)
    }

    /// Untrusted plist text cannot author Markdown in the rendered sheet.
    @Test func evidenceCannotInjectMarkup() throws {
        _ = try fixtureProject()
        let bad = root.appendingPathComponent("Bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["UIBackgroundModes": ["fetch\n\n# <script>injected"]],
            format: .xml, options: 0
        ).write(to: bad.appendingPathComponent("Info.plist"))
        let sheets = Questionnaire.sheets(for: try EvidenceScan.scan(root: root))
        let body = sheets.map { $0.render() }.joined()
        #expect(!body.contains("<script>"))
        #expect(!body.contains("injected\n"))
    }

    /// Guidance on an answered item must render — an answered encryption declaration
    /// still needs its exemption follow-up shown.
    @Test func answeredItemGuidanceRenders() throws {
        let item = SheetItem("q", answer: "a", guidance: "follow up", evidence: [])
        let sheet = AnswerSheet(title: "t", fileName: "t.md", items: [item], evidenceBase: [])
        #expect(sheet.render().contains("follow up"))
    }

    /// A linked ad SDK overrides the source-symbol scan — the age-rating ad
    /// question stays open even when no ATT/IDFA symbol appears in sources.
    @Test func adDependencyKeepsRatingQuestionOpen() throws {
        _ = try fixtureProject()
        try "GoogleMobileAds.framework in Frameworks".write(
            to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"),
            atomically: true, encoding: .utf8)
        let s = sheet("age-rating.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: root)))
        let ads = try #require(s.items.first { $0.question.contains("advertising") })
        #expect(ads.isOpen)
        #expect(ads.evidence.contains { $0.contains("GoogleMobileAds") })
    }

    /// A manifest entry that omits linked/tracking/purposes must not print defaults
    /// as facts — the item stays open naming the missing keys.
    @Test func partialCollectedDatumStaysOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["NSPrivacyCollectedDataTypes": [[
                "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeCrashData",
            ]]], format: .xml, options: 0
        ).write(to: dir.appendingPathComponent("PrivacyInfo.xcprivacy"))
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: dir)))
        let datum = try #require(s.items.first { $0.question.contains("Crash Data") })
        #expect(datum.isOpen)
        #expect(datum.guidance?.contains("Linked") == true)
    }

    /// Zero scanned source files cannot ground a "No" — every source-based
    /// age-rating answer stays open.
    @Test func emptySourceScanCannotAnswerNo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = sheet("age-rating.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: dir)))
        #expect(s.items.first { $0.question.contains("web access") }?.isOpen == true)
        #expect(s.items.first { $0.question.contains("advertising") }?.isOpen == true)
    }

    /// Podfile declarations feed the dependency inventory — a CocoaPods collector
    /// leaves the SDK question open rather than answering "none found".
    @Test func podfileFeedsDependencyInventory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "platform :ios, '15.0'\npod 'FirebaseAnalytics'\n".write(
            to: dir.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let e = try EvidenceScan.scan(root: dir)
        #expect(e.packageDependencies == ["FirebaseAnalytics"])
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: e))
        #expect(s.items.first { $0.question.contains("SDK") }?.isOpen == true)
    }

    /// No manifest data declarations → the collection question still appears, open.
    @Test func noDeclaredDataStillAsksCollection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: dir)))
        #expect(s.items.first { $0.question.contains("collect user data") }?.isOpen == true)
    }

    /// accessibilityLabel is now a scanned symbol — it shows up as item context.
    @Test func accessibilitySignalsAreCollected() throws {
        _ = try fixtureProject()
        try "view.accessibilityLabel = \"dictate\"".write(
            to: root.appendingPathComponent("App/A11y.swift"), atomically: true, encoding: .utf8)
        let s = sheet("accessibility-labels.md",
                      in: Questionnaire.sheets(for: try EvidenceScan.scan(root: root)))
        #expect(s.items.contains { $0.evidence.contains { $0.contains("A11y.swift") } })
    }

    @Test func containedResolvesSymlinkedCwd() throws {
        // /tmp → /private/tmp on macOS: containment must compare fully-resolved paths or
        // every legitimate output under a symlinked cwd is refused.
        let base = URL(fileURLWithPath: "/tmp").appendingPathComponent("Q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let inside = try ASCConfiguration.contained(base.appendingPathComponent("questionnaires"), under: base)
        #expect(inside.path.hasPrefix("/private/tmp/"))
    }
}

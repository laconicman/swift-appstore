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

    @Test func onDeviceSpeechPinningClosesTheQuestion() throws {
        _ = try fixtureProject()
        try "// requiresOnDeviceRecognition = true".write(
            to: root.appendingPathComponent("App/Pinning.swift"), atomically: true, encoding: .utf8)
        let s = sheet("app-privacy.md", in: Questionnaire.sheets(for: try EvidenceScan.scan(root: root)))
        #expect(s.items.first { $0.question.contains("Speech recognition") }?.answer?.contains("On-device") == true)
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

        // A code change flips an answer — the diff flags exactly that sheet.
        try "// requiresOnDeviceRecognition = true".write(
            to: project.appendingPathComponent("App/Pinning.swift"), atomically: true, encoding: .utf8)
        let third = try SheetStore.write(
            Questionnaire.sheets(for: try EvidenceScan.scan(root: project)), to: out)
        #expect(third.changed == ["app-privacy.md"])
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

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
}

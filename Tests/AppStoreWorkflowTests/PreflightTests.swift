import Foundation
import Testing
@testable import AppStoreWorkflow

/// Archive inspection — synthetic .app/.xcarchive fixtures in a temp directory.
/// These are the LearnWords 1.2.2 failure classes: MinimumOSVersion below the floor in a
/// nested bundle, version/build drift across extensions, missing PrivacyInfo.xcprivacy.
@Suite("Preflight archive inspection")
struct PreflightTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PreflightTests-\(UUID().uuidString)", isDirectory: true)

    /// Writes an Info.plist (+ optional privacy manifest) into a bundle dir.
    func makeBundle(
        _ path: String, version: String = "1.2.2", build: String = "7",
        minOS: String? = "15.0", privacy: Bool = true, bundleId: String? = nil
    ) throws {
        let dir = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": bundleId ?? "com.example.\(dir.lastPathComponent)",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        if let minOS { plist["MinimumOSVersion"] = minOS }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))
        if privacy {
            try "<plist><dict/></plist>".write(
                to: dir.appendingPathComponent("PrivacyInfo.xcprivacy"), atomically: true, encoding: .utf8
            )
        }
    }

    @Test("compareVersions is numeric, not lexical — 15.0 < 15.0.1 < 16.0")
    func versionCompare() {
        #expect(Preflight.compareVersions("15.0", "15.0") == .orderedSame)
        #expect(Preflight.compareVersions("15.0", "15.0.1") == .orderedAscending)
        #expect(Preflight.compareVersions("9.0", "15.0") == .orderedAscending)   // lexical would say 9 > 15
        #expect(Preflight.compareVersions("16.0", "15.0") == .orderedDescending)
    }

    @Test("a nested appex below the floor is flagged — the 90068 class")
    func belowFloorExtension() throws {
        try makeBundle("App.app", minOS: "15.0")
        try makeBundle("App.app/PlugIns/Widget.appex", minOS: "14.0", bundleId: "com.example.app.Widget")

        let report = try Preflight.inspect(at: root.appendingPathComponent("App.app"), floor: "15.0")
        #expect(report.bundles.count == 2)
        #expect(report.findings.contains {
            if case .belowFloor(let b, let found, _) = $0 { return b.hasSuffix("Widget.appex") && found == "14.0" }
            return false
        })
        #expect(!report.ok)
    }

    @Test("a bundle with no MinimumOSVersion is flagged, not assumed OK")
    func missingMinOS() throws {
        try makeBundle("App.app", minOS: nil)
        let report = try Preflight.inspect(at: root.appendingPathComponent("App.app"), floor: "15.0")
        #expect(report.findings.contains {
            if case .missingMinOS(let b) = $0 { return b.hasSuffix("App.app") }
            return false
        })
    }

    @Test("missing PrivacyInfo.xcprivacy is flagged per bundle")
    func missingPrivacyManifest() throws {
        try makeBundle("App.app", privacy: true)
        try makeBundle("App.app/PlugIns/Action.appex", privacy: false, bundleId: "com.example.app.Action")
        let report = try Preflight.inspect(at: root.appendingPathComponent("App.app"), floor: "15.0")
        #expect(report.findings.contains {
            if case .missingPrivacyManifest(let b) = $0 { return b.hasSuffix("Action.appex") }
            return false
        })
        #expect(report.findings.allSatisfy {
            if case .missingPrivacyManifest(let b) = $0 { return !b.hasSuffix("App.app") }
            return true
        })
    }

    @Test("version/build drift across bundles is flagged")
    func drift() throws {
        try makeBundle("App.app", version: "1.2.2", build: "7")
        try makeBundle("App.app/PlugIns/Widget.appex", version: "1.2.1", build: "7", bundleId: "com.example.app.Widget")
        let report = try Preflight.inspect(at: root.appendingPathComponent("App.app"), floor: "15.0")
        #expect(report.findings.contains {
            if case .versionMismatch = $0 { return true }
            return false
        })
        #expect(!report.findings.contains {
            if case .buildMismatch = $0 { return true }
            return false
        })
    }

    @Test("a consistent archive inspects clean")
    func clean() throws {
        try makeBundle("App.app")
        try makeBundle("App.app/PlugIns/Widget.appex", bundleId: "com.example.app.Widget")
        let report = try Preflight.inspect(at: root.appendingPathComponent("App.app"), floor: "15.0")
        #expect(report.ok)
        #expect(report.bundles.count == 2)
    }

    @Test(".xcarchive roots resolve through Products/Applications")
    func xcarchive() throws {
        try makeBundle("App.xcarchive/Products/Applications/App.app")
        let report = try Preflight.inspect(at: root.appendingPathComponent("App.xcarchive"), floor: "15.0")
        #expect(report.ok)
        #expect(report.bundles.count == 1)
    }

    @Test("an .xcarchive without Products/Applications is a not-found error")
    func malformedArchive() throws {
        let dir = root.appendingPathComponent("Bad.xcarchive")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(throws: WorkflowError.self) {
            _ = try Preflight.inspect(at: dir, floor: "15.0")
        }
    }
}

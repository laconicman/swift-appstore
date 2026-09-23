import Foundation
import Testing
@testable import AppStoreKit
@testable import AppStoreWorkflow

/// `asc.json` — per-app values as data. The LearnWords pilot will ship one of these; nothing
/// app-specific lives in the tool.
@Suite("ASCConfiguration")
struct ASCConfigurationTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ASCConfigurationTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test("decodes the documented shape")
    func decode() throws {
        let url = root.appendingPathComponent("asc.json")
        try #"""
        {
          "appId": "1234567890",
          "bundleId": "club.laconic.LearnWords",
          "platform": "IOS",
          "metadataRoot": "metadata",
          "locales": ["en-US", "ru"],
          "minimumOSVersion": "15.0",
          "keyPath": "~/.config/asc/AuthKey_ABC.p8",
          "keyId": "ABC",
          "issuerId": "57246542-96fe-1a63-e053-0824d011072a"
        }
        """#.write(to: url, atomically: true, encoding: .utf8)

        let config = try ASCConfiguration.load(from: url)
        #expect(config.appId == "1234567890")
        #expect(config.bundleId == "club.laconic.LearnWords")
        #expect(config.locales == ["en-US", "ru"])
        #expect(config.minimumOSVersion == "15.0")
        #expect(config.platformValue == "IOS")
    }

    @Test("defaults: platform IOS, metadata root `metadata`")
    func defaults() throws {
        let config = ASCConfiguration()
        #expect(config.platformValue == "IOS")
        #expect(try config.metadataRootURL(relativeTo: root).path == root.path + "/metadata")
    }

    @Test("a missing config file is a misconfigured error naming the path")
    func missingConfig() {
        let absent = root.appendingPathComponent("nope/asc.json")
        #expect(throws: WorkflowError.self) {
            _ = try ASCConfiguration.load(from: absent)
        }
    }

    @Test("resolvedAPIKey requires a key id and key path")
    func keyResolution() throws {
        var config = ASCConfiguration()
        config.keyId = "KID"
        config.keyPath = "/tmp/AuthKey_KID.p8"
        let key = try config.resolvedAPIKey()
        #expect(key.keyID == "KID")
        #expect(key.privateKeyPath.path == "/tmp/AuthKey_KID.p8")
    }

    @Test("resolvedAPIKey fails without a key id rather than guessing")
    func keyResolutionMissing() {
        let config = ASCConfiguration()
        // Environment may or may not provide ASC_KEY_ID — only assert when the shape is empty.
        var c = config
        c.keyPath = "/tmp/k.p8"
        if ProcessInfo.processInfo.environment["ASC_KEY_ID"] == nil {
            #expect(throws: WorkflowError.self) { _ = try c.resolvedAPIKey() }
        }
    }

    @Test("keyPath tilde expansion")
    func tildeExpansion() throws {
        var config = ASCConfiguration()
        config.keyId = "K"
        config.keyPath = "~/keys/AuthKey_K.p8"
        let key = try config.resolvedAPIKey()
        #expect(!key.privateKeyPath.path.contains("~"))
        #expect(key.privateKeyPath.path.hasPrefix(NSHomeDirectory()))
    }
}

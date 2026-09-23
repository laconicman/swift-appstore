import Foundation
import AppStoreKit

/// `asc.json` — the per-app configuration. All LearnWords-specific values live here, not in
/// the tool: bundle id, app id, platform, where the metadata tree is, the deployment floor
/// preflight checks against, and the expected locale list.
public struct ASCConfiguration: Decodable, Sendable {
    public var appId: String?
    public var bundleId: String?
    /// `IOS`, `MAC_OS`, `TV_OS`, `VISION_OS` — an ASC platform filter value.
    public var platform: String?
    /// Directory holding the fastlane-layout metadata tree, relative to the working directory.
    public var metadataRoot: String?
    /// Expected locale codes; `asc validate` warns about locale dirs outside this list.
    public var locales: [String]?
    /// Deployment floor for `asc preflight` (e.g. `"15.0"`).
    public var minimumOSVersion: String?
    /// Credential wiring — env vars (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`) win over
    /// the file so CI can inject them. The `.p8` is referenced by path only.
    public var keyId: String?
    public var issuerId: String?
    public var keyPath: String?

    public init() {}

    public static func load(from url: URL) throws -> ASCConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkflowError.misconfigured("config not found: \(url.path) (expected an asc.json)")
        }
        return try JSONDecoder().decode(ASCConfiguration.self, from: Data(contentsOf: url))
    }

    /// API key resolution order: environment first, then config values.
    public func resolvedAPIKey() throws -> APIKey {
        let env = ProcessInfo.processInfo.environment
        guard let keyID = env["ASC_KEY_ID"] ?? keyId else {
            throw WorkflowError.misconfigured("no key id — set ASC_KEY_ID or `keyId` in asc.json")
        }
        guard let keyPath = env["ASC_KEY_PATH"] ?? self.keyPath else {
            throw WorkflowError.misconfigured("no key path — set ASC_KEY_PATH or `keyPath` in asc.json")
        }
        let issuerID = env["ASC_ISSUER_ID"] ?? issuerId
        let path = NSString(string: keyPath).expandingTildeInPath
        return APIKey(keyID: keyID, issuerID: issuerID, privateKeyPath: URL(fileURLWithPath: path))
    }

    public func metadataRootURL(relativeTo base: URL) -> URL {
        base.appendingPathComponent(metadataRoot ?? "metadata")
    }

    public var platformValue: String { platform ?? "IOS" }
}

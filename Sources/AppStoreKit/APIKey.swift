import Foundation

/// An App Store Connect API key, referenced by the **path** of its `.p8` file.
///
/// The private key is read from disk only at signing time and never held as a `String`, so
/// it cannot leak into logs, `description`, or a serialized configuration. This is the one
/// credential shape AppStoreKit accepts: there is deliberately no `init(privateKeyPEM:)`.
///
/// Team keys carry an issuer ID; individual keys (App Store Connect → user profile →
/// Individual API Key) have none and are identified by `sub: "user"` in the token instead —
/// see <https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests>.
public struct APIKey: Sendable, Hashable {
    /// The 10-character key identifier shown in App Store Connect (`kid` JWT header).
    public var keyID: String
    /// The team's issuer ID (`iss` claim). `nil` for an individual key.
    public var issuerID: String?
    /// Location of the `AuthKey_<keyID>.p8` file.
    public var privateKeyPath: URL

    public init(keyID: String, issuerID: String?, privateKeyPath: URL) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyPath = privateKeyPath
    }

    /// Environment variables read by ``APIKey/init(environment:)``. Shared with the future
    /// `asc` command line so both agree on one convention.
    public enum EnvironmentVariable {
        public static let keyID = "ASC_KEY_ID"
        public static let issuerID = "ASC_ISSUER_ID"
        public static let privateKeyPath = "ASC_KEY_PATH"
    }

    /// Reads `ASC_KEY_ID`, `ASC_ISSUER_ID` (optional) and `ASC_KEY_PATH` from `environment`,
    /// returning `nil` unless both required variables are present and non-empty.
    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let keyID = environment[EnvironmentVariable.keyID], !keyID.isEmpty,
              let path = environment[EnvironmentVariable.privateKeyPath], !path.isEmpty
        else { return nil }
        let issuerID = environment[EnvironmentVariable.issuerID].flatMap { $0.isEmpty ? nil : $0 }
        self.init(keyID: keyID, issuerID: issuerID, privateKeyPath: URL(fileURLWithPath: path))
    }
}

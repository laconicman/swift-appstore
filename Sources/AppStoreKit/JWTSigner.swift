import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Mints App Store Connect bearer tokens: ES256-signed JWTs per
/// <https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests>.
///
/// `CryptoKit` signs on Apple platforms and `swift-crypto`'s API-identical `Crypto` module
/// everywhere else, which is what lets the test suite (and CI) run on Linux. The `.p8` is
/// read from ``APIKey/privateKeyPath`` on every mint and parsed straight into a
/// `P256.Signing.PrivateKey`; its text is never stored on the signer.
public struct JWTSigner: Sendable {
    /// Apple rejects tokens whose `exp - iat` exceeds 20 minutes for ordinary requests.
    public static let maximumLifetime: TimeInterval = 20 * 60
    public static let audience = "appstoreconnect-v1"

    public let key: APIKey
    public let lifetime: TimeInterval

    public init(key: APIKey, lifetime: TimeInterval = JWTSigner.maximumLifetime) {
        self.key = key
        self.lifetime = min(lifetime, Self.maximumLifetime)
    }

    /// A signed token and the instant it stops being valid.
    public struct Token: Sendable, Hashable {
        public let value: String
        public let issuedAt: Date
        public let expiresAt: Date
    }

    /// Signs a fresh token. `now` is injectable so tests can pin `iat`/`exp`.
    public func mint(now: Date = Date()) throws -> Token {
        let privateKey = try loadPrivateKey()
        let issuedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let expiresAt = issuedAt.addingTimeInterval(lifetime)

        let header = Header(kid: key.keyID)
        let claims = Claims(
            iss: key.issuerID,
            sub: key.issuerID == nil ? "user" : nil,
            iat: Int(issuedAt.timeIntervalSince1970),
            exp: Int(expiresAt.timeIntervalSince1970),
            aud: Self.audience
        )
        let signingInput = try [Self.base64URL(JSONEncoder().encode(header)),
                                Self.base64URL(JSONEncoder().encode(claims))].joined(separator: ".")
        // JWS wants the raw 64-byte `r || s` signature, not the DER encoding.
        let signature = try privateKey.signature(for: Data(signingInput.utf8)).rawRepresentation
        return Token(
            value: signingInput + "." + Self.base64URL(signature),
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
    }

    // MARK: Private

    private struct Header: Encodable {
        let alg = "ES256"
        let kid: String
        let typ = "JWT"
    }

    private struct Claims: Encodable {
        let iss: String?
        let sub: String?
        let iat: Int
        let exp: Int
        let aud: String
    }

    private func loadPrivateKey() throws -> P256.Signing.PrivateKey {
        let pem: String
        do {
            pem = try String(contentsOf: key.privateKeyPath, encoding: .utf8)
        } catch {
            throw JWTSignerError.unreadablePrivateKey(path: key.privateKeyPath, underlying: error)
        }
        do {
            return try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw JWTSignerError.invalidPrivateKey(path: key.privateKeyPath)
        }
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Deliberately reports only the *path* of the offending key, never any of its content.
public enum JWTSignerError: Error, CustomStringConvertible, Sendable {
    case unreadablePrivateKey(path: URL, underlying: any Error)
    case invalidPrivateKey(path: URL)

    public var description: String {
        switch self {
        case .unreadablePrivateKey(let path, let underlying):
            "Could not read the App Store Connect private key at \(path.path): \(underlying)"
        case .invalidPrivateKey(let path):
            "The file at \(path.path) is not a PEM-encoded P-256 private key (expected an AuthKey_<KEYID>.p8 from App Store Connect)."
        }
    }
}

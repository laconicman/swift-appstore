import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import AppStoreKit

/// A freshly generated P-256 key written to a temporary `AuthKey_<id>.p8`, so the signer is
/// exercised through its only real interface — a file path. Never a real App Store Connect key.
struct ThrowawayKey {
    static let keyID = "TESTKEY123"
    static let issuerID = "57246542-96fe-1a63-e053-0824d011072a"

    let apiKey: APIKey
    let publicKey: P256.Signing.PublicKey
    private let directory: URL

    init(issuerID: String? = ThrowawayKey.issuerID) throws {
        let privateKey = P256.Signing.PrivateKey()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoreKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("AuthKey_\(Self.keyID).p8")
        try privateKey.pemRepresentation.write(to: path, atomically: true, encoding: .utf8)
        apiKey = APIKey(keyID: Self.keyID, issuerID: issuerID, privateKeyPath: path)
        publicKey = privateKey.publicKey
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Decoded view of a compact JWS/JWT for assertions.
struct DecodedJWT {
    let header: [String: Any]
    let claims: [String: Any]
    let signature: Data
    let signingInput: Data

    init(_ token: String) throws {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3 else { throw Malformed() }
        header = try Self.json(parts[0])
        claims = try Self.json(parts[1])
        signature = try Self.base64URLDecode(parts[2])
        signingInput = Data("\(parts[0]).\(parts[1])".utf8)
    }

    func isValidSignature(for publicKey: P256.Signing.PublicKey) throws -> Bool {
        publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: signingInput)
    }

    struct Malformed: Error {}

    private static func json(_ segment: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: base64URLDecode(segment)) as? [String: Any] else {
            throw Malformed()
        }
        return object
    }

    private static func base64URLDecode(_ segment: String) throws -> Data {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw Malformed() }
        return data
    }
}

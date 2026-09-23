import Foundation
import Testing
@testable import AppStoreKit

@Suite("JWTSigner")
struct JWTSignerTests {
    @Test("mints an ES256 token with Apple's header and claims, verifiable with the public key")
    func mintsVerifiableToken() throws {
        let key = try ThrowawayKey()
        defer { key.remove() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let token = try JWTSigner(key: key.apiKey).mint(now: now)
        let jwt = try DecodedJWT(token.value)

        #expect(jwt.header["alg"] as? String == "ES256")
        #expect(jwt.header["typ"] as? String == "JWT")
        #expect(jwt.header["kid"] as? String == ThrowawayKey.keyID)
        #expect(jwt.claims["iss"] as? String == ThrowawayKey.issuerID)
        #expect(jwt.claims["aud"] as? String == "appstoreconnect-v1")
        #expect(jwt.claims["iat"] as? Int == 1_700_000_000)
        #expect(jwt.claims["exp"] as? Int == 1_700_000_000 + 20 * 60)
        #expect(jwt.claims["sub"] == nil)
        #expect(try jwt.isValidSignature(for: key.publicKey))
        #expect(token.expiresAt.timeIntervalSince(token.issuedAt) == 20 * 60)
    }

    @Test("an individual key (no issuer) uses sub=user instead of iss")
    func individualKey() throws {
        let key = try ThrowawayKey(issuerID: nil)
        defer { key.remove() }

        let jwt = try DecodedJWT(JWTSigner(key: key.apiKey).mint().value)

        #expect(jwt.claims["iss"] == nil)
        #expect(jwt.claims["sub"] as? String == "user")
    }

    @Test("lifetime is capped at Apple's 20-minute maximum")
    func lifetimeCap() throws {
        let key = try ThrowawayKey()
        defer { key.remove() }

        let token = try JWTSigner(key: key.apiKey, lifetime: 3600).mint()

        #expect(token.expiresAt.timeIntervalSince(token.issuedAt) == JWTSigner.maximumLifetime)
    }

    @Test("a missing .p8 reports the path and nothing else")
    func missingKeyFile() throws {
        let missing = APIKey(
            keyID: "NOPE",
            issuerID: nil,
            privateKeyPath: URL(fileURLWithPath: "/nonexistent/AuthKey_NOPE.p8")
        )

        #expect(throws: JWTSignerError.self) { try JWTSigner(key: missing).mint() }
    }

    @Test("a file that is not a P-256 key is rejected without echoing its contents")
    func malformedKeyFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("AppStoreKitTests-\(UUID()).p8")
        try "this is not a key".write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        let key = APIKey(keyID: "BAD", issuerID: nil, privateKeyPath: path)

        let error = #expect(throws: JWTSignerError.self) { try JWTSigner(key: key).mint() }

        let description = String(describing: error)
        #expect(description.contains(path.path))
        #expect(!description.contains("this is not a key"))
    }

    @Test("APIKey reads the ASC_* environment convention")
    func environmentKey() {
        let env = ["ASC_KEY_ID": "K", "ASC_ISSUER_ID": "I", "ASC_KEY_PATH": "/keys/AuthKey_K.p8"]

        let key = APIKey(environment: env)

        #expect(key?.keyID == "K")
        #expect(key?.issuerID == "I")
        #expect(key?.privateKeyPath.path == "/keys/AuthKey_K.p8")
        #expect(APIKey(environment: ["ASC_KEY_ID": "K"]) == nil)
    }
}

import Foundation

/// Scrubs credential material from text before it reaches an error surface or log.
/// The one string that can ever carry the token is `Authorization: Bearer <jwt>` —
/// Apple's 401 text can echo it, and a transport error may quote request detail.
public enum Redactor {
    /// Replaces `Bearer <token>` (any case) with `Bearer <redacted>`.
    public static func redact(_ text: String) -> String {
        text.replacing(/bearer\s+\S+/.ignoresCase(), with: "Bearer <redacted>")
    }
}

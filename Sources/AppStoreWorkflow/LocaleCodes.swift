import Foundation

/// Apple's App Store Connect locale shortcodes.
///
/// Source: developer.apple.com/documentation/appstoreconnectapi
/// "Managing metadata in your app by using locale shortcodes" — verified 2026-09-23;
/// the page lists 50 locales ("175 regions and 50 languages"). Apple adds locales over
/// time; treat this list as versioned data, not a universal truth.
public enum LocaleCodes {
    public static let all: Set<String> = [
        "ar-SA", "bn-BD", "ca", "zh-Hans", "zh-Hant", "hr", "cs", "da", "nl-NL",
        "en-AU", "en-CA", "en-GB", "en-US",
        "fi", "fr-FR", "fr-CA", "de-DE", "el", "gu-IN", "he", "hi", "hu", "id", "it",
        "ja", "kn-IN", "ko", "ms", "ml-IN", "mr-IN", "no", "or-IN",
        "pl", "pt-BR", "pt-PT", "pa-IN", "ro", "ru", "sk", "sl-SI",
        "es-MX", "es-ES", "sv", "ta-IN", "te-IN", "th", "tr", "uk", "ur-PK", "vi",
    ]

    public static func isValid(_ code: String) -> Bool { all.contains(code) }
}

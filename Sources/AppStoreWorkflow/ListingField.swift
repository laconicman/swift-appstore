import Foundation

/// Every metadata field the workflow tracks, in one catalog.
///
/// The catalog is the single place where a fastlane-layout file name meets its App Store
/// Connect attribute, its limit, and its editability rule (see `docs/surface-matrix.md` in the
/// AppStore project). The file names follow fastlane `deliver` conventions so the same
/// `metadata/` tree works for both tools; `privacy_choices_url.txt` and
/// `review_information/demo_account_required.txt` are extensions fastlane doesn't write.
///
/// `demoAccountPassword` is deliberately absent: pull never writes it, apply never sends it,
/// and `MetadataStore` reports a stray `demo_password.txt` as ignored. Review credentials are
/// managed in App Store Connect, not committed to a repository.
public enum ListingField: String, CaseIterable, Sendable, Codable {
    // appInfoLocalizations — one row per locale, scoped to the appInfo (editable state)
    case name, subtitle, privacyPolicyUrl, privacyChoicesUrl, privacyPolicyText
    // appStoreVersionLocalizations — one row per locale, scoped to the version (editable state,
    // except promotionalText which is editable anytime)
    case description, keywords, whatsNew, promotionalText, marketingUrl, supportUrl
    // appInfo relationships — shared across locales (editable state)
    case primaryCategory, secondaryCategory
    case primarySubcategoryOne, primarySubcategoryTwo, secondarySubcategoryOne, secondarySubcategoryTwo
    // appStoreVersion attribute — shared (anytime)
    case copyright
    // appStoreReviewDetail attributes — shared (anytime)
    case contactFirstName, contactLastName, contactPhone, contactEmail, demoAccountName, demoAccountRequired, reviewNotes

    /// The ASC resource the value lives on, and therefore the PATCH target it groups under.
    public enum Target: Sendable {
        case appInfoLocalization, versionLocalization, appInfo, version, reviewDetail
    }

    public var target: Target {
        switch self {
        case .name, .subtitle, .privacyPolicyUrl, .privacyChoicesUrl, .privacyPolicyText:
            .appInfoLocalization
        case .description, .keywords, .whatsNew, .promotionalText, .marketingUrl, .supportUrl:
            .versionLocalization
        case .primaryCategory, .secondaryCategory,
             .primarySubcategoryOne, .primarySubcategoryTwo, .secondarySubcategoryOne, .secondarySubcategoryTwo:
            .appInfo
        case .copyright:
            .version
        case .contactFirstName, .contactLastName, .contactPhone, .contactEmail,
             .demoAccountName, .demoAccountRequired, .reviewNotes:
            .reviewDetail
        }
    }

    /// Localized fields live under `metadata/<locale>/`; shared fields at the metadata root.
    public var isLocalized: Bool {
        target == .appInfoLocalization || target == .versionLocalization
    }

    /// Path relative to the metadata root for shared fields, or to the locale directory for
    /// localized ones.
    public var filePath: String {
        switch self {
        case .name: "name.txt"
        case .subtitle: "subtitle.txt"
        case .privacyPolicyUrl: "privacy_url.txt"
        case .privacyChoicesUrl: "privacy_choices_url.txt"
        case .privacyPolicyText: "apple_tv_privacy_policy.txt"
        case .description: "description.txt"
        case .keywords: "keywords.txt"
        case .whatsNew: "release_notes.txt"
        case .promotionalText: "promotional_text.txt"
        case .marketingUrl: "marketing_url.txt"
        case .supportUrl: "support_url.txt"
        case .primaryCategory: "primary_category.txt"
        case .secondaryCategory: "secondary_category.txt"
        case .primarySubcategoryOne: "primary_first_sub_category.txt"
        case .primarySubcategoryTwo: "primary_second_sub_category.txt"
        case .secondarySubcategoryOne: "secondary_first_sub_category.txt"
        case .secondarySubcategoryTwo: "secondary_second_sub_category.txt"
        case .copyright: "copyright.txt"
        case .contactFirstName: "review_information/first_name.txt"
        case .contactLastName: "review_information/last_name.txt"
        case .contactPhone: "review_information/phone_number.txt"
        case .contactEmail: "review_information/email_address.txt"
        case .demoAccountName: "review_information/demo_user.txt"
        case .demoAccountRequired: "review_information/demo_account_required.txt"
        case .reviewNotes: "review_information/notes.txt"
        }
    }

    /// The App Store Connect attribute name (camelCase), used in diff output.
    public var attribute: String { rawValue }

    /// Maximum length in Unicode characters. `nil` = no character limit.
    public var maxCharacters: Int? {
        switch self {
        case .name, .subtitle: 30
        // Characters, not bytes: the live LearnWords `ru` keyword list is 72 characters /
        // 130 UTF-8 bytes and is READY_FOR_SALE (verified 2026-09-29) — a byte rule would
        // refuse a write Apple accepts.
        case .keywords: 100
        case .promotionalText: 170
        case .description, .whatsNew, .privacyPolicyText: 4_000
        default: nil
        }
    }

    /// Maximum length in UTF-8 bytes. Only review notes keep a byte ceiling, and only as
    /// the stricter of the two readings until a live listing settles it the way keywords
    /// were settled (see `maxCharacters`).
    public var maxUTF8Bytes: Int? {
        switch self {
        case .reviewNotes: 4_000
        default: nil
        }
    }

    /// Fields that must parse as an http(s) URL. Privacy URLs additionally require https.
    public var isURL: Bool {
        self == .privacyPolicyUrl || self == .privacyChoicesUrl || self == .marketingUrl || self == .supportUrl
    }

    public var httpsOnly: Bool {
        self == .privacyPolicyUrl || self == .privacyChoicesUrl
    }

    /// Holds the literal `true`/`false` on disk for the boolean review attribute.
    public var isBoolean: Bool { self == .demoAccountRequired }

    /// Required per the surface matrix. Required-ness applies wherever the field's scope
    /// exists: localized requireds must be non-empty in every local locale directory.
    public var required: Bool {
        switch self {
        case .name, .description, .keywords, .supportUrl, .privacyPolicyUrl, .primaryCategory, .copyright:
            true
        default: false
        }
    }

    /// Editable without a new version per the surface matrix (`promotionalText`, `copyright`,
    /// App Review details). Everything else is editable only in an editable state, which the
    /// applier enforces against the live version/appInfo state.
    public var editableAnytime: Bool {
        switch self {
        case .promotionalText, .copyright,
             .contactFirstName, .contactLastName, .contactPhone, .contactEmail,
             .demoAccountName, .demoAccountRequired, .reviewNotes:
            true
        default: false
        }
    }

    /// File names that exist in fastlane layouts but carry a credential; never written or sent.
    public static let sensitiveFileNames = ["demo_password.txt"]

    /// Files under `review_information/` that are not part of the catalog and not sensitive are
    /// reported as unknown so typos don't silently no-op.
    public static let localizedFields = allCases.filter(\.isLocalized)
    public static let sharedFields = allCases.filter { !$0.isLocalized }
}

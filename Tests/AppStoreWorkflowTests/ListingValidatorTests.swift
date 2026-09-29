import Foundation
import Testing
@testable import AppStoreWorkflow

/// Offline limits per the surface matrix — character vs byte limits, https-only privacy URLs,
/// locale codes, required fields. These are Apple's hard limits; the same checks gate `apply`.
@Suite("ListingValidator limits")
struct ListingValidatorTests {
    func tree(localized: [String: FieldValues] = [:], shared: FieldValues = [:]) -> MetadataTree {
        MetadataTree(snapshot: ListingSnapshot(localized: localized, shared: shared))
    }

    func errors(_ issues: [ValidationIssue]) -> [ValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    @Test("name over 30 characters is an error")
    func nameLimit() {
        let issues = ListingValidator.validate(local: tree(localized: ["en-US": [.name: String(repeating: "x", count: 31)]]))
        #expect(errors(issues).contains { $0.path == "en-US/name.txt" })
    }

    @Test("promotional text over 170 characters is an error")
    func promoLimit() {
        let issues = ListingValidator.validate(local: tree(localized: ["en-US": [.promotionalText: String(repeating: "x", count: 171)]]))
        #expect(errors(issues).contains { $0.path == "en-US/promotional_text.txt" })
    }

    @Test("keywords' 100 limit counts characters — a 130-byte Cyrillic list is valid")
    func keywordsAreCharacters() {
        // The live LearnWords `ru` list: 72 characters, 130 UTF-8 bytes, READY_FOR_SALE.
        // A byte rule would refuse it; Apple accepted it.
        let cyrillic = String(repeating: "слово,", count: 12) // 72 chars, 132 bytes
        let ok = ListingValidator.validate(local: tree(localized: ["ru": [.keywords: cyrillic]]))
        #expect(!errors(ok).contains { $0.path == "ru/keywords.txt" })

        // 101 characters fail regardless of script.
        let tooLong = String(repeating: "a", count: 101)
        let issues = ListingValidator.validate(local: tree(localized: ["en-US": [.keywords: tooLong]]))
        #expect(errors(issues).contains { $0.path == "en-US/keywords.txt" && $0.message.contains("character") })
    }

    @Test("privacy URL must be https; support/marketing may be http(s) but must parse")
    func urlRules() {
        let issues = ListingValidator.validate(local: tree(localized: ["en-US": [
            .privacyPolicyUrl: "http://example.com/privacy",
            .supportUrl: "not a url",
        ]]))
        let paths = errors(issues).map(\.path)
        #expect(paths.contains("en-US/privacy_url.txt"))
        #expect(paths.contains("en-US/support_url.txt"))

        let ok = ListingValidator.validate(local: tree(localized: ["en-US": [
            .privacyPolicyUrl: "https://example.com/privacy",
            .supportUrl: "https://example.com/help",
        ]]))
        #expect(!errors(ok).contains { $0.path.hasSuffix("privacy_url.txt") || $0.path.hasSuffix("support_url.txt") })
    }

    @Test("demo_account_required must be `true` or `false`")
    func booleanField() {
        let bad = ListingValidator.validate(local: tree(shared: [.demoAccountRequired: "yes"]))
        #expect(errors(bad).contains { $0.path == "review_information/demo_account_required.txt" })
        let good = ListingValidator.validate(local: tree(shared: [.demoAccountRequired: "true"]))
        #expect(!errors(good).contains { $0.path == "review_information/demo_account_required.txt" })
    }

    @Test("invalid locale code is an error")
    func invalidLocale() {
        let issues = ListingValidator.validate(local: tree(localized: ["xx-XX": [.name: "App"]]))
        #expect(errors(issues).contains { $0.path == "xx-XX" })
        // And Apple's real codes pass — including the newer additions.
        let ok = ListingValidator.validate(local: tree(localized: [
            "en-US": [.name: "App"], "ta-IN": [.name: "App"], "sl-SI": [.name: "App"], "bn-BD": [.name: "App"],
        ], shared: [.copyright: "c", .primaryCategory: "EDUCATION"]))
        #expect(!errors(ok).contains { $0.message.contains("locale code") })
    }

    @Test("required localized fields must be present and non-empty")
    func requiredFields() {
        // en-US has a name file but no description/keywords/support/privacy → four errors.
        let issues = ListingValidator.validate(local: tree(localized: ["en-US": [.name: "App"]]))
        let paths = errors(issues).map(\.path)
        #expect(paths.contains("en-US/description.txt"))
        #expect(paths.contains("en-US/keywords.txt"))
        #expect(paths.contains("en-US/support_url.txt"))
        #expect(paths.contains("en-US/privacy_url.txt"))
        #expect(!paths.contains("en-US/name.txt"))
    }

    @Test("config locale list warns both ways: extra local dirs and missing local dirs")
    func expectedLocales() {
        let extra = ListingValidator.validate(
            local: tree(localized: ["en-US": [.name: "App"], "de-DE": [.name: "App"]]),
            expectedLocales: ["en-US"]
        )
        #expect(extra.contains { $0.severity == .warning && $0.path == "de-DE" })

        let missing = ListingValidator.validate(
            local: tree(localized: ["en-US": [.name: "App"]]),
            expectedLocales: ["en-US", "fr-FR"]
        )
        #expect(missing.contains { $0.severity == .warning && $0.path == "fr-FR" })
    }

    @Test("shared required fields: copyright and primary category")
    func sharedRequired() {
        let issues = ListingValidator.validate(local: tree(localized: ["en-US": [.name: "App"]]))
        let paths = errors(issues).map(\.path)
        #expect(paths.contains("copyright.txt"))
        #expect(paths.contains("primary_category.txt"))
    }

    @Test("validatePlanned only checks values a write would set")
    func plannedOnly() {
        let entries = [
            FieldDiff(field: .name, locale: "en-US", kind: .change, local: String(repeating: "x", count: 31), live: "ok"),
            FieldDiff(field: .description, locale: "en-US", kind: .unchanged, local: nil, live: "remote"),
        ]
        let issues = ListingValidator.validatePlanned(entries)
        #expect(issues.count == 1)
        #expect(issues[0].path == "en-US/name.txt")
    }

    @Test("unknown and credential files produce warnings, not errors")
    func warningFiles() {
        var snapshot = ListingSnapshot()
        snapshot.localized["en-US"] = [.name: "App"]
        let tree = MetadataTree(
            snapshot: snapshot,
            unknownFiles: ["en-US/desciption.txt"],
            ignoredFiles: ["review_information/demo_password.txt"]
        )
        let issues = ListingValidator.validate(local: tree)
        #expect(issues.contains { $0.severity == .warning && $0.path == "en-US/desciption.txt" })
        #expect(issues.contains { $0.severity == .warning && $0.path == "review_information/demo_password.txt" })
        #expect(!issues.contains { $0.severity == .error && $0.path == "en-US/desciption.txt" })
    }

    // MARK: - URL scheme restriction

    @Test("non-http(s) URL schemes are rejected for support/marketing URLs")
    func urlSchemeRestricted() throws {
        let tree = MetadataTree(snapshot: ListingSnapshot(localized: [
            "en-US": [.supportUrl: "ftp://example.com/help", .name: "Name",
                      .description: "desc", .keywords: "a", .whatsNew: "n",
                      .subtitle: "s", .promotionalText: "p"],
        ]))
        let issues = ListingValidator.validate(local: tree, expectedLocales: nil)
        #expect(issues.contains {
            $0.path == "en-US/support_url.txt" && $0.message.contains("http")
        })
    }
}

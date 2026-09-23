import Foundation

/// One validation finding.
public struct ValidationIssue: Sendable {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var path: String
    public var message: String

    public init(_ severity: Severity, _ path: String, _ message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

/// Offline validation of the local metadata tree — field limits, locale codes, required
/// fields, URL shape. `asc validate` runs it over the whole tree; `ListingApplier` runs it
/// over planned values before any write (limits are Apple's hard limits, so a violation means
/// the PATCH would 422 anyway — fail locally, atomically, instead).
public enum ListingValidator {
    public static func validate(local: MetadataTree, expectedLocales: [String]? = nil) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let snapshot = local.snapshot

        for file in local.unknownFiles {
            issues.append(.init(.warning, file, "not a known metadata field — ignored by pull/diff/apply"))
        }
        for file in local.ignoredFiles {
            issues.append(.init(.warning, file, "carries a credential — never written or sent by this tool; manage it in App Store Connect"))
        }

        for locale in snapshot.locales {
            let values = snapshot.localized[locale] ?? [:]
            if !LocaleCodes.isValid(locale) {
                issues.append(.init(.error, locale, "not an App Store Connect locale code"))
            }
            if let expectedLocales, !expectedLocales.contains(locale) {
                issues.append(.init(.warning, locale, "not in the config `locales` list"))
            }
            for field in ListingField.localizedFields {
                guard let value = values[field] else { continue }
                issues += check(field: field, value: value, path: "\(locale)/\(field.filePath)")
            }
            // Required fields must exist and be non-empty in every locale that has any files.
            for field in ListingField.localizedFields where field.required {
                if (values[field] ?? "").isEmpty {
                    issues.append(.init(.error, "\(locale)/\(field.filePath)", "required field missing or empty"))
                }
            }
            // What's New is required on updates; flag absence as a warning rather than an error.
            if (values[.whatsNew] ?? "").isEmpty {
                issues.append(.init(.warning, "\(locale)/release_notes.txt", "empty — required when submitting an update"))
            }
        }

        if let expectedLocales {
            for locale in expectedLocales where !snapshot.locales.contains(locale) {
                issues.append(.init(.warning, locale, "in the config `locales` list but has no local metadata"))
            }
        }

        for field in ListingField.sharedFields {
            guard let value = snapshot.shared[field] else { continue }
            issues += check(field: field, value: value, path: field.filePath)
        }
        for field in [ListingField.copyright, .primaryCategory] where (snapshot.shared[field] ?? "").isEmpty {
            issues.append(.init(.error, field.filePath, "required field missing or empty"))
        }
        // Review contact is required for submission but legitimately managed only in ASC —
        // warn rather than fail when the file group is absent.
        let reviewFields = ListingField.sharedFields.filter { $0.target == .reviewDetail }
        if reviewFields.allSatisfy({ (snapshot.shared[$0] ?? "").isEmpty }) {
            issues.append(.init(.warning, "review_information/", "no review contact pulled — required for submission"))
        }
        return issues.sorted { ($0.path, $0.severity.rawValue) < ($1.path, $1.severity.rawValue) }
    }

    /// Validates just the values a write would set — the pre-write abort check.
    public static func validatePlanned(_ entries: [FieldDiff]) -> [ValidationIssue] {
        entries
            .filter { $0.kind == .change || $0.kind == .create || $0.kind == .blocked }
            .flatMap { check(field: $0.field, value: $0.local ?? "", path: $0.path) }
    }

    static func check(field: ListingField, value: String, path: String) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if let max = field.maxCharacters, value.count > max {
            issues.append(.init(.error, path, "\(value.count) characters exceeds Apple's \(max)-character limit"))
        }
        if let max = field.maxUTF8Bytes, value.utf8.count > max {
            issues.append(.init(.error, path, "\(value.utf8.count) bytes exceeds Apple's \(max)-byte limit"))
        }
        if field.isURL, !value.isEmpty {
            guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
                issues.append(.init(.error, path, "not a valid URL"))
                return issues
            }
            if field.httpsOnly && url.scheme != "https" {
                issues.append(.init(.error, path, "must be an https URL"))
            }
        }
        if field.isBoolean, !["true", "false"].contains(value) {
            issues.append(.init(.error, path, "must be `true` or `false`"))
        }
        if field == .keywords, value.contains(";") || value.contains("\n") {
            issues.append(.init(.warning, path, "keywords are a comma-separated list — `;` and newlines aren't separators"))
        }
        return issues
    }
}

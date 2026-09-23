import Foundation

/// One field's classification in a local-vs-live-vs-baseline comparison.
public enum ChangeKind: String, Sendable {
    /// Local equals live and live matches the pull baseline — nothing to do.
    case unchanged
    /// Local equals live, but live drifted from the baseline: someone pushed the same value
    /// upstream (or it was never pulled). Reported for visibility; nothing to write.
    case converged
    /// Local differs from live, and live still matches the baseline — safe to write.
    case change
    /// Local differs from live and live drifted from the baseline — the remote was edited
    /// since the last pull. `apply` refuses these unless forced; the fix is `asc pull` + review.
    case conflict
    /// The local file exists but is empty — would clear the remote value. Refused unless
    /// `--allow-clear`.
    case blocked
    /// No remote localization row exists for this locale (or no review detail); writing means
    /// creating it. Planned only when `createMissingLocales`/review-detail creation applies.
    case create
}

/// One classified field value.
public struct FieldDiff: Sendable {
    public var field: ListingField
    public var locale: String?       // nil for shared fields
    public var kind: ChangeKind
    public var local: String?        // nil = no file locally
    public var live: String?         // nil = field unset remotely

    /// The path the diff prints and the baseline digests key by.
    public var path: String { Baseline.digestKey(field: field, locale: locale) }
}

/// The whole listing comparison.
public struct ListingDiff: Sendable {
    public var entries: [FieldDiff]
    /// Locales that exist on the live listing but not in the local tree — reported because the
    /// tool has no delete path; pruning a locale is a manual decision.
    public var remoteOnlyLocales: [String]

    public init(entries: [FieldDiff], remoteOnlyLocales: [String]) {
        self.entries = entries
        self.remoteOnlyLocales = remoteOnlyLocales
    }

    public var isEmpty: Bool {
        entries.allSatisfy { $0.kind == .unchanged || $0.kind == .converged } && remoteOnlyLocales.isEmpty
    }

    public func entries(ofKind kind: ChangeKind) -> [FieldDiff] { entries.filter { $0.kind == kind } }
}

/// Three-way classification: local files vs live values vs the pull baseline.
public enum ListingDiffer {
    public static func diff(local: MetadataTree, live: LiveListing, baseline: Baseline?) -> ListingDiff {
        var entries: [FieldDiff] = []

        let localLocales = Set(local.snapshot.localized.keys)
        let liveLocales = Set(live.values.localized.keys)
        let remoteOnly = liveLocales.subtracting(localLocales).sorted()

        for locale in localLocales.sorted() {
            let localValues = local.snapshot.localized[locale] ?? [:]
            let liveValues = live.values.localized[locale] ?? [:]
            // Rows are per-target: a locale can have a version-localization row without an
            // appInfo-localization row (and vice versa). "Create" is decided per row, not
            // per locale — otherwise fields on the absent row would diff as updates against
            // an id that doesn't exist.
            let ids = live.localizationIDs[locale]

            for field in ListingField.localizedFields {
                guard let localValue = localValues[field] else { continue }  // no file → untouched
                let rowMissing = field.target == .appInfoLocalization
                    ? ids?.appInfo == nil
                    : ids?.version == nil
                if rowMissing {
                    entries.append(.init(field: field, locale: locale, kind: .create, local: localValue, live: nil))
                    continue
                }
                let liveValue = liveValues[field]
                entries.append(classify(field: field, locale: locale, local: localValue, live: liveValue, baseline: baseline))
            }
        }

        for field in ListingField.sharedFields {
            guard let localValue = local.snapshot.shared[field] else { continue }
            let liveValue = live.values.shared[field]
            let rowMissing = field.target == .reviewDetail && live.reviewDetailID == nil
            if rowMissing {
                entries.append(.init(field: field, locale: nil, kind: .create, local: localValue, live: nil))
            } else {
                entries.append(classify(field: field, locale: nil, local: localValue, live: liveValue, baseline: baseline))
            }
        }

        return ListingDiff(entries: entries, remoteOnlyLocales: remoteOnly)
    }

    private static func classify(
        field: ListingField, locale: String?, local: String, live: String?, baseline: Baseline?
    ) -> FieldDiff {
        let liveValue = live ?? ""
        let key = Baseline.digestKey(field: field, locale: locale)
        // No baseline (never pulled) → nothing to detect drift against: every difference is a
        // plain change. With a baseline, an absent digest means the field was unset at pull
        // time, so digest("") stands in for it.
        let baselineDigest = baseline.map { $0.digests[key] ?? Baseline.digest(of: "") }
        let liveDigest = Baseline.digest(of: liveValue)

        if local == liveValue {
            let converged = baselineDigest != nil && baselineDigest != liveDigest
            return .init(field: field, locale: locale, kind: converged ? .converged : .unchanged, local: local, live: liveValue)
        }
        // Drift outranks emptiness: an empty local file against a *drifted* remote is a
        // conflict (needs --force), not a mere blocked clear (needs only --allow-clear) —
        // otherwise --allow-clear could silently overwrite edits nobody reviewed.
        if let baselineDigest, baselineDigest != liveDigest {
            return .init(field: field, locale: locale, kind: .conflict, local: local, live: liveValue)
        }
        if local.isEmpty {
            return .init(field: field, locale: locale, kind: .blocked, local: local, live: liveValue)
        }
        return .init(field: field, locale: locale, kind: .change, local: local, live: liveValue)
    }
}

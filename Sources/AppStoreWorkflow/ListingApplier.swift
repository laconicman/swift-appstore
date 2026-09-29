import Foundation
import AppStoreKit
import AppStoreOpenAPI

public struct ApplyOptions: Sendable {
    /// Write even where the remote drifted from the pull baseline (conflict entries).
    public var force: Bool
    /// Permit empty local files to clear remote values (blocked entries).
    public var allowClear: Bool
    /// Permit creating missing localization rows / the review detail (create entries).
    public var createMissing: Bool

    public init(force: Bool = false, allowClear: Bool = false, createMissing: Bool = false) {
        self.force = force
        self.allowClear = allowClear
        self.createMissing = createMissing
    }
}

/// A grouped write: one PATCH or POST per (target, locale) — never one call per field, so a
/// partial failure is attributable to a single scope and the request count stays low.
public enum Write: Sendable {
    case versionLocalizationUpdate(id: String, locale: String, values: FieldValues)
    case versionLocalizationCreate(versionID: String, locale: String, values: FieldValues)
    case appInfoLocalizationUpdate(id: String, locale: String, values: FieldValues)
    case appInfoLocalizationCreate(appInfoID: String, locale: String, values: FieldValues)
    case versionUpdate(id: String, copyright: String)
    case appInfoUpdate(id: String, categories: FieldValues)
    case reviewDetailUpdate(id: String, values: FieldValues)
    case reviewDetailCreate(versionID: String, values: FieldValues)

    public var label: String {
        switch self {
        case .versionLocalizationUpdate(_, let l, _): "PATCH appStoreVersionLocalizations (\(l))"
        case .versionLocalizationCreate(_, let l, _): "POST appStoreVersionLocalizations (\(l))"
        case .appInfoLocalizationUpdate(_, let l, _): "PATCH appInfoLocalizations (\(l))"
        case .appInfoLocalizationCreate(_, let l, _): "POST appInfoLocalizations (\(l))"
        case .versionUpdate: "PATCH appStoreVersions (copyright)"
        case .appInfoUpdate: "PATCH appInfos (categories)"
        case .reviewDetailUpdate: "PATCH appStoreReviewDetails"
        case .reviewDetailCreate: "POST appStoreReviewDetails"
        }
    }
}

/// What an apply did — the report `asc apply` prints. Writes stop at the first failure; it is
/// recorded here rather than thrown so the report shows exactly how far the run got.
public struct ApplyResult: Sendable {
    public var applied: [String] = []
    public var skipped: [String] = []
    public var failed: String?
    /// Values Apple returned that differ from what was sent (whitespace/case normalization).
    /// The caller writes them back to the files so file, baseline digest, and live state agree —
    /// otherwise the next diff reports the same field as a change forever.
    public var normalized: [(field: ListingField, locale: String?, value: String)] = []

    public var ok: Bool { failed == nil }
}

/// Executes a ``ListingDiff`` against App Store Connect.
///
/// Gates, all evaluated before the first write (a half-applied listing is worse than none):
/// conflicts refuse unless `force`; empty-file clears refuse unless `allowClear`; editable-state
/// fields refuse while the version/appInfo state isn't editable (Apple would 409 anyway — we
/// fail locally with the clearer error). Planned values are validated first; any violation
/// aborts everything.
public struct ListingApplier: Sendable {
    public let asc: AppStoreConnect

    public init(asc: AppStoreConnect) {
        self.asc = asc
    }

    /// Builds the write plan from a diff. Throws for gate failures — `diff` entries of kind
    /// `create` are dropped unless `options.createMissing`.
    public func plan(_ diff: ListingDiff, live: LiveListing, options: ApplyOptions) throws -> ([Write], ApplyResult) {
        var result = ApplyResult()

        let conflicts = diff.entries(ofKind: .conflict).map(\.path)
        if !conflicts.isEmpty && !options.force { throw WorkflowError.conflict(conflicts) }

        let blocked = diff.entries(ofKind: .blocked).map(\.path)
        if !blocked.isEmpty && !options.allowClear { throw WorkflowError.blocked(blocked) }

        // The write set first: what will actually be sent. Conflicts join under --force,
        // blocked clears under --allow-clear, creates under --create-missing. Everything that
        // writes must pass BOTH gates — the editable-state check and field validation apply to
        // the same set, so --force can't sneak an invalid or frozen-state write past them.
        var writeEntries = diff.entries.filter { $0.kind == .change }
        if options.force { writeEntries += diff.entries(ofKind: .conflict) }
        if options.allowClear { writeEntries += diff.entries(ofKind: .blocked) }
        if options.createMissing { writeEntries += diff.entries(ofKind: .create) }
        for entry in diff.entries(ofKind: .create) where !options.createMissing {
            result.skipped.append("\(entry.path) — needs --create-missing-locales")
        }

        // Editable-state gate: version-localization writes need an editable version; appInfo
        // writes need a non-frozen appInfo. `editableAnytime` fields (promo text, copyright,
        // review details) are exempt per the surface matrix.
        var notEditable: [String] = []
        for entry in writeEntries {
            guard !entry.field.editableAnytime else { continue }
            switch entry.field.target {
            case .versionLocalization, .version:
                if !live.versionIsEditable {
                    notEditable.append("\(entry.path) — version \(live.version.versionString) is \(live.version.appStoreState)")
                }
            case .appInfoLocalization, .appInfo:
                if !live.appInfoIsEditable {
                    notEditable.append("\(entry.path) — appInfo is \(live.appInfo.appStoreState ?? "unknown")")
                }
            case .reviewDetail:
                break
            }
        }
        if !notEditable.isEmpty { throw WorkflowError.notEditable(notEditable) }

        // Field validation over the exact values being written — a violation here aborts
        // everything before the first write, so Apple never sees an over-limit PATCH.
        // Warnings are advisory (printed by validate); only errors abort the write set.
        var invalid = ListingValidator.checkValues(writeEntries.map { (field: $0.field, value: $0.local ?? "", path: $0.path) })
            .filter { $0.severity == .error }
            .map { "\($0.path): \($0.message)" }
        // A forced conflict whose local value is empty is still a clear — it needs
        // --allow-clear on top of --force, not force alone.
        let forcedClears = writeEntries.filter { $0.kind == .conflict && ($0.local ?? "").isEmpty }
        if !forcedClears.isEmpty && !options.allowClear {
            invalid.append(contentsOf: forcedClears.map {
                "\($0.path): forced write would clear a drifted value — add --allow-clear"
            })
        }
        // Category clears aren't expressible: the generated relationship payload encodes
        // `data: nil` by omitting the key (synthesized Codable), which is a no-op rather than
        // JSON:API's `"data": null` — and sending `id: ""` is worse. Refuse instead.
        for entry in writeEntries where entry.field.target == .appInfo && (entry.local ?? "").isEmpty {
            invalid.append("\(entry.path): category fields cannot be cleared via the API — remove it in App Store Connect")
        }
        // Apple requires `name` to create an app-info localization. Enforced here in plan —
        // inside `perform` the same failure would fire after earlier writes had applied,
        // splitting a run across a fixable error.
        let createdAppInfoLocales = Set(writeEntries.filter {
            $0.kind == .create && $0.field.target == .appInfoLocalization
        }.compactMap(\.locale))
        for locale in createdAppInfoLocales {
            let hasName = writeEntries.contains {
                $0.locale == locale && $0.field == .name && !($0.local ?? "").isEmpty
            }
            if !hasName { invalid.append("\(locale)/name.txt is required to create an app-info localization") }
        }
        if !invalid.isEmpty {
            throw WorkflowError.invalid(invalid)
        }

        // Group by (target, locale) preserving order; create entries are separate because they
        // POST rather than PATCH.
        var writes: [Write] = []
        var groups: [String: FieldValues] = [:]
        var order: [String] = []
        for entry in writeEntries {
            let creating = entry.kind == .create
            let key = "\(creating ? "create" : "update")|\(entry.field.target)|\(entry.locale ?? "")"
            if groups[key] == nil { order.append(key) }
            groups[key, default: [:]][entry.field] = entry.local ?? ""
        }
        for key in order {
            let parts = key.split(separator: "|")
            let creating = parts[0] == "create"
            let locale = parts.count > 2 ? String(parts[2]) : ""
            let values = groups[key] ?? [:]
            switch (parts[1], creating) {
            case ("versionLocalization", false):
                guard let id = live.localizationIDs[locale]?.version else { continue }
                writes.append(.versionLocalizationUpdate(id: id, locale: locale, values: values))
            case ("versionLocalization", true):
                writes.append(.versionLocalizationCreate(versionID: live.version.id, locale: locale, values: values))
            case ("appInfoLocalization", false):
                guard let id = live.localizationIDs[locale]?.appInfo else { continue }
                writes.append(.appInfoLocalizationUpdate(id: id, locale: locale, values: values))
            case ("appInfoLocalization", true):
                writes.append(.appInfoLocalizationCreate(appInfoID: live.appInfo.id, locale: locale, values: values))
            case ("version", _):
                if let copyright = values[.copyright] { writes.append(.versionUpdate(id: live.version.id, copyright: copyright)) }
            case ("appInfo", _):
                writes.append(.appInfoUpdate(id: live.appInfo.id, categories: values))
            case ("reviewDetail", false):
                if let id = live.reviewDetailID { writes.append(.reviewDetailUpdate(id: id, values: values)) }
            case ("reviewDetail", true):
                writes.append(.reviewDetailCreate(versionID: live.version.id, values: values))
            default: break
            }
        }
        return (writes, result)
    }

    /// Runs the plan sequentially; baseline digests for applied fields are updated from the
    /// *response* values (Apple may normalize), so the next diff sees truth.
    public func apply(_ writes: [Write], baseline: inout Baseline, live: LiveListing) async -> ApplyResult {
        var result = ApplyResult()
        for write in writes {
            do {
                try await perform(write, baseline: &baseline, normalized: &result.normalized)
                result.applied.append(write.label)
            } catch {
                result.failed = "\(write.label): \(Redactor.redact("\(error)"))"
                break
            }
        }
        baseline.exportedAt = Date()
        return result
    }

    // MARK: - Writes

    private func perform(_ write: Write, baseline: inout Baseline, normalized: inout [(field: ListingField, locale: String?, value: String)]) async throws {
        switch write {
        case .versionLocalizationUpdate(let id, let locale, let values):
            let output = try await asc.client.appStoreVersionLocalizationsUpdateInstance(.init(
                path: .init(id: id), body: .json(.init(data: .init(
                    attributes: .init(
                        description: values[.description], keywords: values[.keywords],
                        marketingUrl: values[.marketingUrl], promotionalText: values[.promotionalText],
                        supportUrl: values[.supportUrl], whatsNew: values[.whatsNew]
                    ),
                    id: id, _type: .appStoreVersionLocalizations
                )))
            ))
            guard case .ok(let ok) = output else { throw apiError("appStoreVersionLocalizationsUpdate", errorResponse(of: output)) }
            updateDigests(try ok.body.json.data.attributes, locale: locale, baseline: &baseline, fallback: values, normalized: &normalized)

        case .versionLocalizationCreate(let versionID, let locale, let values):
            let output = try await asc.client.appStoreVersionLocalizationsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(
                    description: values[.description], keywords: values[.keywords], locale: locale,
                    marketingUrl: values[.marketingUrl], promotionalText: values[.promotionalText],
                    supportUrl: values[.supportUrl], whatsNew: values[.whatsNew]
                ),
                relationships: .init(appStoreVersion: .init(data: .init(id: versionID, _type: .appStoreVersions))),
                _type: .appStoreVersionLocalizations
            )))))
            guard case .created(let created) = output else { throw apiError("appStoreVersionLocalizationsCreate", errorResponse(of: output)) }
            baseline.localizationIDs[locale, default: .init()].version = try created.body.json.data.id
            updateDigests(try created.body.json.data.attributes, locale: locale, baseline: &baseline, fallback: values, normalized: &normalized)

        case .appInfoLocalizationUpdate(let id, let locale, let values):
            let output = try await asc.client.appInfoLocalizationsUpdateInstance(.init(
                path: .init(id: id), body: .json(.init(data: .init(
                    attributes: .init(
                        name: values[.name], privacyChoicesUrl: values[.privacyChoicesUrl],
                        privacyPolicyText: values[.privacyPolicyText], privacyPolicyUrl: values[.privacyPolicyUrl],
                        subtitle: values[.subtitle]
                    ),
                    id: id, _type: .appInfoLocalizations
                )))
            ))
            guard case .ok(let ok) = output else { throw apiError("appInfoLocalizationsUpdate", errorResponse(of: output)) }
            updateDigests(try ok.body.json.data.attributes, locale: locale, baseline: &baseline, fallback: values, normalized: &normalized)

        case .appInfoLocalizationCreate(let appInfoID, let locale, let values):
            guard let name = values[.name], !name.isEmpty else {
                throw WorkflowError.invalid(["\(locale)/name.txt is required to create an app-info localization"])
            }
            let output = try await asc.client.appInfoLocalizationsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(
                    locale: locale, name: name,
                    privacyChoicesUrl: values[.privacyChoicesUrl], privacyPolicyText: values[.privacyPolicyText],
                    privacyPolicyUrl: values[.privacyPolicyUrl], subtitle: values[.subtitle]
                ),
                relationships: .init(appInfo: .init(data: .init(id: appInfoID, _type: .appInfos))),
                _type: .appInfoLocalizations
            )))))
            guard case .created(let created) = output else { throw apiError("appInfoLocalizationsCreate", errorResponse(of: output)) }
            baseline.localizationIDs[locale, default: .init()].appInfo = try created.body.json.data.id
            updateDigests(try created.body.json.data.attributes, locale: locale, baseline: &baseline, fallback: values, normalized: &normalized)

        case .versionUpdate(let id, let copyright):
            let output = try await asc.client.appStoreVersionsUpdateInstance(.init(
                path: .init(id: id), body: .json(.init(data: .init(
                    attributes: .init(copyright: copyright), id: id, _type: .appStoreVersions
                )))
            ))
            guard case .ok = output else { throw apiError("appStoreVersionsUpdate", errorResponse(of: output)) }
            baseline.digests[Baseline.digestKey(field: .copyright, locale: nil)] = Baseline.digest(of: copyright)

        case .appInfoUpdate(let id, let categories):
            typealias R = Components.Schemas.AppInfoUpdateRequest.DataPayload.RelationshipsPayload
            func rel(_ id: String?) -> R.PrimaryCategoryPayload? {
                id.map { .init(data: .init(id: $0, _type: .appCategories)) }
            }
            // The four subcategory payloads are distinct generated types sharing one shape.
            func sub1(_ id: String?) -> R.PrimarySubcategoryOnePayload? { id.map { .init(data: .init(id: $0, _type: .appCategories)) } }
            func sub2(_ id: String?) -> R.PrimarySubcategoryTwoPayload? { id.map { .init(data: .init(id: $0, _type: .appCategories)) } }
            func sec(_ id: String?) -> R.SecondaryCategoryPayload? { id.map { .init(data: .init(id: $0, _type: .appCategories)) } }
            func ssub1(_ id: String?) -> R.SecondarySubcategoryOnePayload? { id.map { .init(data: .init(id: $0, _type: .appCategories)) } }
            func ssub2(_ id: String?) -> R.SecondarySubcategoryTwoPayload? { id.map { .init(data: .init(id: $0, _type: .appCategories)) } }
            let output = try await asc.client.appInfosUpdateInstance(.init(
                path: .init(id: id), body: .json(.init(data: .init(
                    id: id,
                    relationships: .init(
                        primaryCategory: rel(categories[.primaryCategory]),
                        primarySubcategoryOne: sub1(categories[.primarySubcategoryOne]),
                        primarySubcategoryTwo: sub2(categories[.primarySubcategoryTwo]),
                        secondaryCategory: sec(categories[.secondaryCategory]),
                        secondarySubcategoryOne: ssub1(categories[.secondarySubcategoryOne]),
                        secondarySubcategoryTwo: ssub2(categories[.secondarySubcategoryTwo])
                    ),
                    _type: .appInfos
                )))
            ))
            guard case .ok = output else { throw apiError("appInfosUpdate", errorResponse(of: output)) }
            for (field, value) in categories {
                baseline.digests[Baseline.digestKey(field: field, locale: nil)] = Baseline.digest(of: value)
            }

        case .reviewDetailUpdate(let id, let values):
            let output = try await asc.client.appStoreReviewDetailsUpdateInstance(.init(
                path: .init(id: id), body: .json(.init(data: .init(
                    attributes: reviewAttributes(values), id: id, _type: .appStoreReviewDetails
                )))
            ))
            guard case .ok(let ok) = output else { throw apiError("appStoreReviewDetailsUpdate", errorResponse(of: output)) }
            updateReviewDigests(try ok.body.json.data.attributes, baseline: &baseline, fallback: values, normalized: &normalized)

        case .reviewDetailCreate(let versionID, let values):
            let output = try await asc.client.appStoreReviewDetailsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: reviewAttributes(values),
                relationships: .init(appStoreVersion: .init(data: .init(id: versionID, _type: .appStoreVersions))),
                _type: .appStoreReviewDetails
            )))))
            guard case .created(let created) = output else { throw apiError("appStoreReviewDetailsCreate", errorResponse(of: output)) }
            baseline.reviewDetailID = try created.body.json.data.id
            updateReviewDigests(try created.body.json.data.attributes, baseline: &baseline, fallback: values, normalized: &normalized)
        }
    }

    private func reviewAttributes(_ values: FieldValues) -> Components.Schemas.AppStoreReviewDetailUpdateRequest.DataPayload.AttributesPayload {
        .init(
            contactEmail: values[.contactEmail], contactFirstName: values[.contactFirstName],
            contactLastName: values[.contactLastName], contactPhone: values[.contactPhone],
            demoAccountName: values[.demoAccountName],
            demoAccountRequired: values[.demoAccountRequired].map { $0 == "true" },
            notes: values[.reviewNotes]
        )
    }

    private func reviewAttributes(_ values: FieldValues) -> Components.Schemas.AppStoreReviewDetailCreateRequest.DataPayload.AttributesPayload {
        .init(
            contactEmail: values[.contactEmail], contactFirstName: values[.contactFirstName],
            contactLastName: values[.contactLastName], contactPhone: values[.contactPhone],
            demoAccountName: values[.demoAccountName],
            demoAccountRequired: values[.demoAccountRequired].map { $0 == "true" },
            notes: values[.reviewNotes]
        )
    }

    // MARK: - Baseline digest refresh

    private func updateDigests(
        _ attributes: Components.Schemas.AppStoreVersionLocalization.AttributesPayload?,
        locale: String, baseline: inout Baseline, fallback: FieldValues,
        normalized: inout [(field: ListingField, locale: String?, value: String)]
    ) {
        let map: [ListingField: String?] = [
            .description: attributes?.description, .keywords: attributes?.keywords,
            .whatsNew: attributes?.whatsNew, .promotionalText: attributes?.promotionalText,
            .marketingUrl: attributes?.marketingUrl, .supportUrl: attributes?.supportUrl,
        ]
        for (field, remote) in map where fallback[field] != nil {
            let value = remote ?? fallback[field] ?? ""
            baseline.digests[Baseline.digestKey(field: field, locale: locale)] = Baseline.digest(of: value)
            if let remote, remote != fallback[field] {
                normalized.append((field, locale, remote))
            }
        }
    }

    private func updateDigests(
        _ attributes: Components.Schemas.AppInfoLocalization.AttributesPayload?,
        locale: String, baseline: inout Baseline, fallback: FieldValues,
        normalized: inout [(field: ListingField, locale: String?, value: String)]
    ) {
        let map: [ListingField: String?] = [
            .name: attributes?.name, .subtitle: attributes?.subtitle,
            .privacyPolicyUrl: attributes?.privacyPolicyUrl, .privacyChoicesUrl: attributes?.privacyChoicesUrl,
            .privacyPolicyText: attributes?.privacyPolicyText,
        ]
        for (field, remote) in map where fallback[field] != nil {
            let value = remote ?? fallback[field] ?? ""
            baseline.digests[Baseline.digestKey(field: field, locale: locale)] = Baseline.digest(of: value)
            if let remote, remote != fallback[field] {
                normalized.append((field, locale, remote))
            }
        }
    }

    private func updateReviewDigests(
        _ attributes: Components.Schemas.AppStoreReviewDetail.AttributesPayload?,
        baseline: inout Baseline, fallback: FieldValues,
        normalized: inout [(field: ListingField, locale: String?, value: String)]
    ) {
        var map: [ListingField: String?] = [
            .contactFirstName: attributes?.contactFirstName, .contactLastName: attributes?.contactLastName,
            .contactPhone: attributes?.contactPhone, .contactEmail: attributes?.contactEmail,
            .demoAccountName: attributes?.demoAccountName, .reviewNotes: attributes?.notes,
        ]
        map[.demoAccountRequired] = attributes?.demoAccountRequired.map { $0 ? "true" : "false" }
        for (field, remote) in map where fallback[field] != nil {
            let value = remote ?? fallback[field] ?? ""
            baseline.digests[Baseline.digestKey(field: field, locale: nil)] = Baseline.digest(of: value)
            if let remote, remote != fallback[field] {
                normalized.append((field, nil, remote))
            }
        }
    }
}

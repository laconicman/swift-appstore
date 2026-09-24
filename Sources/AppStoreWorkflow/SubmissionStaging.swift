import Foundation
import AppStoreKit
import AppStoreOpenAPI

/// What `asc submit` stages: an App Store version carrying a build, inside a review
/// submission draft. Final submission (`submitted: true`) is never sent — the owner
/// clicks it in App Store Connect after reviewing the staged state.
public struct SubmissionRequest: Sendable {
    /// Marketing version to stage (e.g. "1.3.0"). Nil reuses the editable version as-is.
    public var versionString: String?
    /// Build number (`CFBundleVersion`) to attach. Nil picks the newest VALID, unexpired build.
    public var buildNumber: String?
    /// `inAppPurchaseVersion`/`subscriptionVersion` ids to co-stage — ASC only accepts
    /// *versioned* product relationships on a submission item (see
    /// `Upstream/reviewsubmissionitems-relationship-types.md`).
    public var iapVersionIDs: [String]
    public var subscriptionVersionIDs: [String]

    public init(
        versionString: String? = nil, buildNumber: String? = nil,
        iapVersionIDs: [String] = [], subscriptionVersionIDs: [String] = []
    ) {
        self.versionString = versionString
        self.buildNumber = buildNumber
        self.iapVersionIDs = iapVersionIDs
        self.subscriptionVersionIDs = subscriptionVersionIDs
    }
}

/// The read-only picture `plan` produces — printed by `asc submit` before any `--yes`.
public struct SubmissionPlan: Sendable {
    public enum VersionAction: Sendable, Equatable {
        /// Editable version already matches the requested string (or none was requested).
        case useExisting(id: String, versionString: String, state: String)
        /// Editable version exists under a different string — PATCH the string.
        case rename(id: String, from: String, to: String)
        /// No editable version — POST a new one.
        case create(versionString: String)
    }

    /// ReviewSubmission states that accept new items (drafts). Anything else is in-flight.
    public static let draftSubmissionStates: Set<String> = ["READY_FOR_REVIEW", "UNRESOLVED_ISSUES"]

    /// Resolved app resource id.
    public var appID: String
    /// `IOS`/`MAC_OS`/`TV_OS`/`VISION_OS` — validated in `plan` before any read.
    public var platform: String
    /// What staging does to the version resource: reuse, rename, or create.
    public var versionAction: VersionAction
    /// Build to attach (id, numbers for display). Nil when no eligible build exists —
    /// staging then proceeds without an attach and reports it as a blocking gap.
    public var buildID: String?
    /// One-line build summary for the preview ("build 9 uploaded …").
    public var buildDescription: String
    /// True when the target version carries a different (or no) build and a PATCH is needed.
    public var buildAttachNeeded: Bool
    /// An existing submission draft to reuse (its id), or nil to create one.
    public var draftID: String?
    /// Non-nil when a submission is in-flight on this app+platform — staging must refuse.
    public var inFlightState: String?
    /// Set when the chosen build's `minOsVersion` exceeds the configured floor — the
    /// 90068 class: attaching it ships a version that doesn't support the floor's OS.
    public var buildAboveFloor: String?
    /// Set when the draft already stages an appStoreVersion item for a *different*
    /// version — staging replaces it (DELETE + POST), shown as an explicit step.
    public var versionItemRepoint: String?
    /// Items already staged on the draft (labels) — a re-run must not duplicate them.
    public var alreadyStaged: [String]
    /// Human-readable stage steps, in order — the preview.
    public var steps: [String]

    /// Staging is blocked by a hard condition (in-flight submission, no eligible build,
    /// build above the deployment floor).
    public var blockedReasons: [String] {
        var reasons: [String] = []
        if let inFlightState { reasons.append("a submission is already \(inFlightState) — staging must wait for it to resolve") }
        if buildID == nil { reasons.append("no VALID, unexpired build to attach") }
        if let buildAboveFloor { reasons.append(buildAboveFloor) }
        return reasons
    }
}

/// What `stage` did — mirrors `ApplyResult`: stop at first failure, report how far it got.
public struct SubmissionResult: Sendable {
    /// Writes that completed, in order.
    public var staged: [String] = []
    /// Steps already satisfied — no write sent.
    public var skipped: [String] = []
    /// First failure, if any — everything after it did not run.
    public var failed: String?
    /// The draft id once known — the pointer the owner needs to find it in ASC.
    public var draftID: String?
    /// True when nothing failed — `staged` + `skipped` then describe the whole run.
    public var ok: Bool { failed == nil }
}

/// Plans and stages a review submission. All gates run in `plan`/`stage` before the first
/// write; reads are GET-only so a bare `asc submit` is a preview.
public struct SubmissionStager: Sendable {
    public let asc: AppStoreConnect

    public init(asc: AppStoreConnect) {
        self.asc = asc
    }

    // MARK: - Plan (reads only)

    /// Builds the staging plan. Throws for hard misconfiguration (no app, unknown platform,
    /// non-editable target version); soft blockers land in `plan.blockedReasons`.
    /// `minimumOSVersion` is the configured deployment floor: a build whose own
    /// `minOsVersion` sits above it is the 90068 class — flag it, never attach it.
    public func plan(
        appID: String?, bundleId: String?, platform: String,
        minimumOSVersion: String? = nil, request: SubmissionRequest
    ) async throws -> SubmissionPlan {
        // Validate before any read: an unknown platform would silently unfilter the
        // version/submission queries below rather than fail.
        _ = try platformValue(platform)
        let app = try await resolveApp(appID: appID, bundleId: bundleId)
        let versions = try await versions(appID: app.id, platform: platform)
        let submissions = try await reviewSubmissions(appID: app.id, platform: platform)

        // Version: an editable one wins; a non-editable exact match is a hard stop (you
        // cannot re-stage READY_FOR_SALE); otherwise a create.
        let editable = versions.filter {
            LiveListing.editableVersionStates.contains($0.attributes?.appStoreState?.rawValue ?? "")
        }
        var plan = SubmissionPlan(
            appID: app.id, platform: platform,
            versionAction: .create(versionString: request.versionString ?? ""),
            buildID: nil, buildDescription: "none", buildAttachNeeded: false,
            draftID: nil, inFlightState: nil, buildAboveFloor: nil, alreadyStaged: [], steps: []
        )

        if let wanted = request.versionString,
           let exact = versions.first(where: { $0.attributes?.versionString == wanted }),
           !LiveListing.editableVersionStates.contains(exact.attributes?.appStoreState?.rawValue ?? "") {
            throw WorkflowError.invalid([
                "version \(wanted) exists in state \(exact.attributes?.appStoreState?.rawValue ?? "?") — not editable; pick a new version string"
            ])
        }
        if let target = editable.first {
            let current = target.attributes?.versionString ?? "?"
            if let wanted = request.versionString, wanted != current {
                plan.versionAction = .rename(id: target.id, from: current, to: wanted)
            } else {
                plan.versionAction = .useExisting(
                    id: target.id, versionString: current,
                    state: target.attributes?.appStoreState?.rawValue ?? "?")
            }
        } else {
            guard let wanted = request.versionString, !wanted.isEmpty else {
                throw WorkflowError.misconfigured(
                    "no editable \(platform) version exists — pass --version to create one")
            }
            plan.versionAction = .create(versionString: wanted)
        }

        // Build: newest VALID + unexpired + App-Store-eligible for the *target* marketing
        // version — an internal-only or other-release build must never reach a plan.
        let builds = try await builds(
            appID: app.id, buildNumber: request.buildNumber,
            versionString: plan.versionLabel, platform: platform)
        if let build = builds.first {
            plan.buildID = build.id
            plan.buildDescription =
                "build \(build.attributes?.version ?? "?") uploaded \(build.attributes?.uploadedDate.map { "\($0)" } ?? "?")"
            if let floor = minimumOSVersion, let buildMin = build.attributes?.minOsVersion,
               Preflight.compareVersions(buildMin, floor) == .orderedDescending {
                plan.buildDescription += " (minOsVersion \(buildMin) > floor \(floor))"
                plan.buildAboveFloor =
                    "build \(build.attributes?.version ?? "?") requires \(buildMin) — above the \(floor) deployment floor (the 90068 class); fix the floor or rebuild"
            }
        } else if request.buildNumber != nil {
            plan.buildDescription = "no VALID unexpired build with number \(request.buildNumber!)"
        } else {
            plan.buildDescription = "no VALID unexpired build found"
        }

        // In-flight check + draft discovery from the same list.
        let inFlight = submissions.first {
            guard let s = $0.attributes?.state?.rawValue else { return false }
            return !SubmissionPlan.draftSubmissionStates.contains(s) && s != "COMPLETE"
        }
        if let inFlight { plan.inFlightState = inFlight.attributes?.state?.rawValue }
        let draft = submissions.first {
            SubmissionPlan.draftSubmissionStates.contains($0.attributes?.state?.rawValue ?? "")
        }
        plan.draftID = draft?.id

        // Items already on the draft — restaging must not duplicate.
        if let draft {
            plan.alreadyStaged = try await stagedItems(draftID: draft.id).flatMap(\.labels)
        }

        // Build attach needed if the target version carries a different build — and a
        // freshly created version carries none, so a create always attaches.
        if let buildID = plan.buildID {
            if let versionID = plan.versionID {
                let attached = try await attachedBuildID(versionID: versionID)
                plan.buildAttachNeeded = attached != buildID
            } else {
                plan.buildAttachNeeded = true
            }
        }

        // Preview steps.
        switch plan.versionAction {
        case .useExisting(_, let v, let s): plan.steps.append("use editable version \(v) (\(s))")
        case .rename(_, let from, let to): plan.steps.append("rename editable version \(from) → \(to)")
        case .create(let v): plan.steps.append("create version \(v)")
        }
        if plan.buildID != nil {
            plan.steps.append(plan.buildAttachNeeded
                ? "attach \(plan.buildDescription)" : "build already attached (\(plan.buildDescription))")
        }
        plan.steps.append(plan.draftID == nil
            ? "create review submission draft" : "reuse review submission draft \(plan.draftID!)")
        // A draft carrying a version item for a *different* version gets it replaced
        // (DELETE + POST) — that's an explicit step, and it's what makes an interrupted
        // run resumable.
        let staged = Set(plan.alreadyStaged)
        if let other = plan.alreadyStaged
            .filter({ $0.hasPrefix("appStoreVersion:") })
            .compactMap({ $0.split(separator: ":").last.map(String.init) })
            .first(where: { $0 != plan.versionID }) {
            plan.versionItemRepoint = other
            plan.steps.append("replace staged version item \(other) → \(plan.versionLabel)")
        } else if plan.versionID.map({ !staged.contains("appStoreVersion:\($0)") }) ?? true {
            plan.steps.append("stage item: appStoreVersion")
        }
        for id in request.iapVersionIDs where !staged.contains("inAppPurchaseVersion:\(id)") {
            plan.steps.append("stage item: inAppPurchaseVersion \(id)")
        }
        for id in request.subscriptionVersionIDs where !staged.contains("subscriptionVersion:\(id)") {
            plan.steps.append("stage item: subscriptionVersion \(id)")
        }
        plan.steps.append("final submission stays in App Store Connect — never sent from here")
        return plan
    }

    // MARK: - Stage (writes — --yes only)

    /// Executes the plan. Re-checks the hard gates first: a plan rendered stale between
    /// preview and `--yes` must not write through. Like `ListingApplier.apply`, a
    /// transport failure (including mutation-outcome-unknown) lands in `result.failed`
    /// with everything already staged still listed — never silently retried.
    public func stage(_ plan: SubmissionPlan, request: SubmissionRequest) async -> SubmissionResult {
        var result = SubmissionResult()
        if let reason = plan.blockedReasons.first {
            result.failed = reason
            return result
        }
        do {
            try await run(plan, request: request, result: &result)
        } catch {
            result.failed = Redactor.redact("\(error)")
        }
        return result
    }

    private func run(_ plan: SubmissionPlan, request: SubmissionRequest, result: inout SubmissionResult) async throws {
        // The plan is a snapshot — re-read the in-flight gate before the first write.
        // A submission that went in-flight between preview and `--yes` aborts here.
        let fresh = try await reviewSubmissions(appID: plan.appID, platform: plan.platform)
        if let inFlight = fresh.first(where: {
            guard let s = $0.attributes?.state?.rawValue else { return false }
            return !SubmissionPlan.draftSubmissionStates.contains(s) && s != "COMPLETE"
        }) {
            result.failed = "a submission is now \(inFlight.attributes?.state?.rawValue ?? "?") — aborting without writes"
            return
        }

        // 1. Version — create or rename.
        var versionID: String
        switch plan.versionAction {
        case .useExisting(let id, _, _):
            versionID = id
            result.skipped.append("version \(plan.versionLabel) already editable")
        case .rename(let id, let from, let to):
            let output = try await asc.client.appStoreVersionsUpdateInstance(.init(
                path: .init(id: id), body: .json(.init(data: .init(
                    attributes: .init(versionString: to), id: id, _type: .appStoreVersions
                )))
            ))
            guard case .ok = output else {
                result.failed = "rename version \(from)→\(to): \(errorResponse(of: output) ?? "?")"
                return
            }
            versionID = id
            result.staged.append("renamed version \(from) → \(to)")
        case .create(let wanted):
            let output = try await asc.client.appStoreVersionsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(platform: try platformValue(plan.platform), versionString: wanted),
                relationships: .init(app: .init(data: .init(id: plan.appID, _type: .apps))),
                _type: .appStoreVersions
            )))))
            guard case .created(let created) = output else {
                result.failed = "create version \(wanted): \(errorResponse(of: output) ?? "?")"
                return
            }
            versionID = try created.body.json.data.id
            result.staged.append("created version \(wanted)")
        }

        // 2. Build attach — pure relationship PATCH, safe to re-send.
        if let buildID = plan.buildID {
            if plan.buildAttachNeeded {
                let output = try await asc.client.appStoreVersionsBuildUpdateToOneRelationship(.init(
                    path: .init(id: versionID), body: .json(.init(data: .init(id: buildID, _type: .builds)))
                ))
                guard case .noContent = output else {
                    result.failed = "attach build \(buildID): \(errorResponse(of: output) ?? "?")"
                    return
                }
                result.staged.append("attached build \(buildID) to version \(versionID)")
            } else {
                result.skipped.append("build already attached")
            }
        }

        // 3. Draft — reuse or create.
        var draftID: String
        if let existing = plan.draftID {
            draftID = existing
            result.skipped.append("reusing draft \(existing)")
        } else {
            let output = try await asc.client.reviewSubmissionsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(platform: try platformValue(plan.platform)),
                relationships: .init(app: .init(data: .init(id: plan.appID, _type: .apps))),
                _type: .reviewSubmissions
            )))))
            guard case .created(let created) = output else {
                result.failed = "create review submission draft: \(errorResponse(of: output) ?? "?")"
                return
            }
            draftID = try created.body.json.data.id
            result.staged.append("created draft \(draftID)")
        }
        result.draftID = draftID

        // 4. Items — re-fetch what the draft carries *now* (it may have changed since the
        // preview), then replace/skip/post accordingly.
        let freshItems = plan.draftID == nil ? [] : try await stagedItems(draftID: draftID)
        let stagedNow = Set(freshItems.flatMap(\.labels))
        if let stale = freshItems.first(where: {
            $0.appStoreVersionID != nil && $0.appStoreVersionID != versionID
        }) {
            // Re-point: DELETE the item staging another version, POST ours.
            let del = try await asc.client.reviewSubmissionItemsDeleteInstance(.init(path: .init(id: stale.id)))
            guard case .noContent = del else {
                result.failed = "replace version item \(stale.id): \(errorResponse(of: del) ?? "?")"
                return
            }
            try await addItem(draftID: draftID, versionID: versionID, result: &result)
            if result.failed != nil { return }
            result.staged.append("replaced staged version item (was \(stale.appStoreVersionID ?? "?"))")
        } else if !stagedNow.contains("appStoreVersion:\(versionID)") {
            try await addItem(draftID: draftID, versionID: versionID, result: &result)
            if result.failed != nil { return }
        } else {
            result.skipped.append("version item already staged")
        }
        for id in request.iapVersionIDs where !stagedNow.contains("inAppPurchaseVersion:\(id)") {
            try await addItem(draftID: draftID, iapVersionID: id, result: &result)
            if result.failed != nil { return }
        }
        for id in request.subscriptionVersionIDs where !stagedNow.contains("subscriptionVersion:\(id)") {
            try await addItem(draftID: draftID, subscriptionVersionID: id, result: &result)
            if result.failed != nil { return }
        }
    }

    // MARK: - Reads

    private func resolveApp(appID: String?, bundleId: String?) async throws -> Components.Schemas.App {
        if let appID {
            let output = try await asc.client.appsGetInstance(.init(path: .init(id: appID)))
            guard case .ok(let ok) = output else { throw apiError("appsGetInstance", errorResponse(of: output)) }
            return try ok.body.json.data
        }
        guard let bundleId, !bundleId.isEmpty else {
            throw WorkflowError.misconfigured("config needs `appId` or `bundleId`")
        }
        let output = try await asc.client.appsGetCollection(
            query: .init(filter_lbrack_bundleId_rbrack_: [bundleId], limit: 2)
        )
        guard case .ok(let ok) = output else { throw apiError("appsGetCollection", errorResponse(of: output)) }
        let apps = try ok.body.json.data
        guard let app = apps.first else { throw WorkflowError.notFound("no app with bundleId \(bundleId)") }
        guard apps.count == 1 else { throw WorkflowError.ambiguous("\(apps.count) apps match bundleId \(bundleId)") }
        return app
    }

    private func versions(appID: String, platform: String) async throws -> [Components.Schemas.AppStoreVersion] {
        typealias F = Operations.AppsAppStoreVersionsGetToManyRelated.Input.Query.FilterLbrackPlatformRbrackPayloadPayload
        let filter: F? = switch platform {
        case "IOS": .ios
        case "MAC_OS": .macOs
        case "TV_OS": .tvOs
        case "VISION_OS": .visionOs
        default: nil
        }
        let output = try await asc.client.appsAppStoreVersionsGetToManyRelated(
            .init(path: .init(id: appID), query: .init(filter_lbrack_platform_rbrack_: filter.map { [$0] }, limit: 200))
        )
        guard case .ok(let ok) = output else { throw apiError("appStoreVersions", errorResponse(of: output)) }
        var all: [Components.Schemas.AppStoreVersion] = []
        for try await page in asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data
        }
        return all
    }

    private func builds(
        appID: String, buildNumber: String?, versionString: String, platform: String
    ) async throws -> [Components.Schemas.Build] {
        typealias P = Operations.BuildsGetCollection.Input.Query.FilterLbrackPreReleaseVersionPlatformRbrackPayloadPayload
        let platformFilter: P? = switch platform {
        case "IOS": .ios
        case "MAC_OS": .macOs
        case "TV_OS": .tvOs
        case "VISION_OS": .visionOs
        default: nil
        }
        let output = try await asc.client.buildsGetCollection(
            .init(query: .init(
                filter_lbrack_version_rbrack_: buildNumber.map { [$0] },
                filter_lbrack_expired_rbrack_: ["false"],
                filter_lbrack_processingState_rbrack_: [.valid],
                filter_lbrack_preReleaseVersion_version_rbrack_: [versionString],
                filter_lbrack_preReleaseVersion_platform_rbrack_: platformFilter.map { [$0] },
                filter_lbrack_buildAudienceType_rbrack_: [.appStoreEligible],
                filter_lbrack_app_rbrack_: [appID],
                sort: [._hyphen_uploadedDate],
                limit: 5
            ))
        )
        guard case .ok(let ok) = output else { throw apiError("buildsGetCollection", errorResponse(of: output)) }
        var all: [Components.Schemas.Build] = []
        for try await page in asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data
        }
        return all
    }

    private func reviewSubmissions(appID: String, platform: String) async throws -> [Components.Schemas.ReviewSubmission] {
        typealias F = Operations.ReviewSubmissionsGetCollection.Input.Query.FilterLbrackPlatformRbrackPayloadPayload
        let filter: F? = switch platform {
        case "IOS": .ios
        case "MAC_OS": .macOs
        case "TV_OS": .tvOs
        case "VISION_OS": .visionOs
        default: nil
        }
        let output = try await asc.client.reviewSubmissionsGetCollection(
            .init(query: .init(
                filter_lbrack_platform_rbrack_: filter.map { [$0] },
                filter_lbrack_app_rbrack_: [appID],
                limit: 50
            ))
        )
        guard case .ok(let ok) = output else { throw apiError("reviewSubmissionsGetCollection", errorResponse(of: output)) }
        var all: [Components.Schemas.ReviewSubmission] = []
        for try await page in asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            all += page.data
        }
        return all
    }

    private func attachedBuildID(versionID: String) async throws -> String? {
        let output = try await asc.client.appStoreVersionsBuildGetToOneRelated(.init(path: .init(id: versionID)))
        switch output {
        case .ok(let ok): return try ok.body.json.data.id
        case .notFound: return nil
        default: throw apiError("versionBuild", errorResponse(of: output))
        }
    }

    /// An item already on a draft — the item resource id plus what it points at, so
    /// restaging can dedupe and a version item can be replaced.
    struct StagedItem: Sendable {
        var id: String
        var appStoreVersionID: String?
        var iapVersionID: String?
        var subscriptionVersionID: String?
        /// Dedup label used in `plan.alreadyStaged` (`"<relType>:<target id>"`).
        var labels: [String] {
            var out: [String] = []
            if let v = appStoreVersionID { out.append("appStoreVersion:\(v)") }
            if let v = iapVersionID { out.append("inAppPurchaseVersion:\(v)") }
            if let v = subscriptionVersionID { out.append("subscriptionVersion:\(v)") }
            return out
        }
    }

    /// Items already on the draft — enough to make restaging a no-op and to find the
    /// resource id when a staged version item must be replaced.
    private func stagedItems(draftID: String) async throws -> [StagedItem] {
        let output = try await asc.client.reviewSubmissionsItemsGetToManyRelated(
            .init(path: .init(id: draftID), query: .init(limit: 200))
        )
        guard case .ok(let ok) = output else { throw apiError("reviewSubmissionItems", errorResponse(of: output)) }
        var items: [StagedItem] = []
        for try await page in asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            for item in page.data {
                let rels = item.relationships
                items.append(StagedItem(
                    id: item.id,
                    appStoreVersionID: rels?.appStoreVersion?.data?.id,
                    iapVersionID: rels?.inAppPurchaseVersion?.data?.id,
                    subscriptionVersionID: rels?.subscriptionVersion?.data?.id
                ))
            }
        }
        return items
    }

    // MARK: - Writes

    private func addItem(draftID: String, versionID: String, result: inout SubmissionResult) async throws {
        let output = try await asc.client.reviewSubmissionItemsCreateInstance(.init(body: .json(.init(data: .init(
            relationships: .init(
                appStoreVersion: .init(data: .init(id: versionID, _type: .appStoreVersions)),
                reviewSubmission: .init(data: .init(id: draftID, _type: .reviewSubmissions))
            ),
            _type: .reviewSubmissionItems
        )))))
        guard case .created = output else {
            result.failed = "stage appStoreVersion: \(errorResponse(of: output) ?? "?")"
            return
        }
        result.staged.append("staged appStoreVersion \(versionID)")
    }

    private func addItem(draftID: String, iapVersionID: String, result: inout SubmissionResult) async throws {
        let output = try await asc.client.reviewSubmissionItemsCreateInstance(.init(body: .json(.init(data: .init(
            relationships: .init(
                inAppPurchaseVersion: .init(data: .init(id: iapVersionID, _type: .inAppPurchaseVersions)),
                reviewSubmission: .init(data: .init(id: draftID, _type: .reviewSubmissions))
            ),
            _type: .reviewSubmissionItems
        )))))
        guard case .created = output else {
            result.failed = "stage inAppPurchaseVersion \(iapVersionID): \(errorResponse(of: output) ?? "?")"
            return
        }
        result.staged.append("staged inAppPurchaseVersion \(iapVersionID)")
    }

    private func addItem(draftID: String, subscriptionVersionID: String, result: inout SubmissionResult) async throws {
        let output = try await asc.client.reviewSubmissionItemsCreateInstance(.init(body: .json(.init(data: .init(
            relationships: .init(
                reviewSubmission: .init(data: .init(id: draftID, _type: .reviewSubmissions)),
                subscriptionVersion: .init(data: .init(id: subscriptionVersionID, _type: .subscriptionVersions))
            ),
            _type: .reviewSubmissionItems
        )))))
        guard case .created = output else {
            result.failed = "stage subscriptionVersion \(subscriptionVersionID): \(errorResponse(of: output) ?? "?")"
            return
        }
        result.staged.append("staged subscriptionVersion \(subscriptionVersionID)")
    }

    private func platformValue(_ platform: String) throws -> Components.Schemas.Platform {
        switch platform {
        case "IOS": return .ios
        case "MAC_OS": return .macOs
        case "TV_OS": return .tvOs
        case "VISION_OS": return .visionOs
        default: throw WorkflowError.misconfigured("unknown platform \(platform)")
        }
    }
}

extension SubmissionPlan {
    /// The version resource id the plan resolved to — nil when the action creates one.
    var versionID: String? {
        switch versionAction {
        case .useExisting(let id, _, _), .rename(let id, _, _): id
        case .create: nil
        }
    }

    /// Display label for the resolved/requested version string.
    var versionLabel: String {
        switch versionAction {
        case .useExisting(_, let v, _): v
        case .rename(_, _, let to), .create(let to): to
        }
    }
}

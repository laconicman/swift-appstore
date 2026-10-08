import Foundation
import AppStoreKit
import AppStoreOpenAPI

/// What `asc submit` stages: an App Store version carrying a build, inside a review
/// submission draft. Final submission (`submitted: true`) is never sent — the owner
/// clicks it in App Store Connect after reviewing the staged state.
public struct SubmissionRequest: Sendable {
    /// Marketing version to stage (e.g. "1.3.0"). Nil reuses the editable version as-is.
    public var versionString: String?
    /// `next-patch`/`next-minor` — derive the target string from the platform's live
    /// (READY_FOR_SALE) version instead of passing an exact `versionString`.
    /// Mutually exclusive with `versionString`.
    public var versionBump: VersionBump?

    /// How `--version`'s `next-*` selectors bump the live version string.
    public enum VersionBump: String, Sendable {
        case patch = "next-patch"
        case minor = "next-minor"

        /// Positional bump: patch targets the third component, minor the second —
        /// a missing slot is padded with `0`s, and slots after the bumped one reset
        /// to `0`. `1.2.2` → `1.2.3` / `1.3.0`; `1.2` → `1.2.1` / `1.3`.
        /// A non-numeric component is a config error, not a guess.
        public func applied(to live: String) throws -> String {
            var parts = live.split(separator: ".").map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else {
                throw WorkflowError.misconfigured(
                    "can't derive \(rawValue) from live version \"\(live)\" — pass an exact --version string")
            }
            func bump(_ index: Int) {
                while parts.count <= index { parts.append("0") }
                parts[index] = "\(Int(parts[index])! + 1)"
                for i in (index + 1)..<parts.count { parts[i] = "0" }
            }
            switch self {
            case .patch: bump(2)
            case .minor: bump(1)
            }
            return parts.joined(separator: ".")
        }
    }

    /// Build number (`CFBundleVersion`) to attach. Nil picks the newest VALID, unexpired build.
    public var buildNumber: String?
    /// `inAppPurchaseVersion`/`subscriptionVersion` ids to co-stage — ASC only accepts
    /// *versioned* product relationships on a submission item (see
    /// `Upstream/reviewsubmissionitems-relationship-types.md`).
    public var iapVersionIDs: [String]
    public var subscriptionVersionIDs: [String]
    /// Replace a draft's `appStoreVersion` item when it points at a different version.
    /// Off (the default), a foreign item *blocks* staging: it is either an interrupted
    /// run or the owner deliberately staging another release — never silently deleted.
    public var replaceItem: Bool
    /// Create an INACTIVE phased release on the staged version, right after the build
    /// attach — the pre-submit hook Apple flips ACTIVE at release. An existing phased
    /// release is left untouched: asc never sends ACTIVE, PATCH, or DELETE.
    public var phasedRelease: Bool

    public init(
        versionString: String? = nil, versionBump: VersionBump? = nil, buildNumber: String? = nil,
        iapVersionIDs: [String] = [], subscriptionVersionIDs: [String] = [],
        replaceItem: Bool = false, phasedRelease: Bool = false
    ) {
        self.versionString = versionString
        self.versionBump = versionBump
        self.buildNumber = buildNumber
        self.replaceItem = replaceItem
        self.phasedRelease = phasedRelease
        // Repeatable flags can repeat an id — a dup would POST the same item twice.
        var seen = Set<String>()
        self.iapVersionIDs = iapVersionIDs.filter { seen.insert($0).inserted }
        seen.removeAll()
        self.subscriptionVersionIDs = subscriptionVersionIDs.filter { seen.insert($0).inserted }
    }
}

/// The read-only picture `plan` produces — printed by `asc submit` before any `--yes`.
public struct SubmissionPlan: Sendable {
    /// What staging does to the version resource — the first step of every plan.
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

    /// Version states a submission can still be staged on — narrower than
    /// `LiveListing.editableVersionStates`, which covers *metadata* editing: `ACCEPTED`,
    /// `WAITING_FOR_REVIEW` and later are already committed to a release and must not be
    /// renamed or given a new build for the next one.
    public static let stageableVersionStates: Set<String> = [
        "PREPARE_FOR_SUBMISSION", "READY_FOR_REVIEW", "INVALID_BINARY",
        "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "WAITING_FOR_EXPORT_COMPLIANCE",
    ]

    /// Resolved app resource id.
    public var appID: String
    /// `IOS`/`MAC_OS`/`TV_OS`/`VISION_OS` — validated in `plan` before any read.
    public var platform: String
    /// What staging does to the version resource: reuse, rename, or create.
    public var versionAction: VersionAction
    /// Build to attach (id, numbers for display). Nil when no eligible build exists —
    /// staging then proceeds without an attach and reports it as a blocking gap.
    public var buildID: String?
    /// One-line build summary for the preview ("build 9 uploaded …"), or the reason
    /// none could be attached.
    public var buildDescription: String
    /// Why a `--build N` pin missed — INTERNAL_ONLY, expired, wrong state, or wrong
    /// release. Nil when no build was pinned or the pin hit; replaces the generic
    /// "no VALID…" line in `blockedReasons`.
    public var buildMissReason: String?
    /// True when the target version carries a different (or no) build and a PATCH is needed.
    public var buildAttachNeeded: Bool
    /// The target version already has a phased release — a requested create will be
    /// skipped rather than duplicated. Plan-time fact; `stage()` re-reads it live.
    public var phasedReleaseExists: Bool
    /// An existing submission draft to reuse (its id), or nil to create one.
    public var draftID: String?
    /// Non-nil when a submission is in-flight on this app+platform — staging must refuse.
    public var inFlightState: String?
    /// Set when the chosen build's deployment minimum sits *below* the configured floor —
    /// the 90068 class; a blocker.
    public var buildBelowFloor: String?
    /// Set when the build's minimum sits *above* the configured floor — stale config,
    /// not a defect; surfaced through `warnings`, never `blockedReasons`.
    public var floorDrift: String?
    /// Set when the draft already stages an appStoreVersion item for a *different*
    /// version and the request opted into replacing it — staging POSTs the target,
    /// then DELETEs every stale one (a rejected POST keeps the old item).
    public var versionItemRepoint: String?
    /// The READY_FOR_SALE version a `next-*` bump derived from at preview time —
    /// nil for an exact `--version`. If the live release moved between preview and
    /// `--yes`, the derived target is obsolete and `stage()` must re-plan.
    public var liveVersionBasis: String?
    /// Version ids the draft stages `appStoreVersion` items for that are *not* the
    /// plan's target — populated only when `replaceItem` is off, turning them into
    /// blockers rather than a repoint. Named individually in `blockedReasons`.
    public var blockingVersionItems: [String]
    /// Items already staged on the draft (labels) — a re-run must not duplicate them.
    public var alreadyStaged: [String]
    /// Human-readable stage steps, in order — the preview.
    public var steps: [String]

    /// Staging is blocked by a hard condition (in-flight submission, no eligible build,
    /// build below the deployment floor).
    public var blockedReasons: [String] {
        var reasons: [String] = []
        if let inFlightState { reasons.append("a submission is already \(inFlightState) — staging must wait for it to resolve") }
        if buildID == nil { reasons.append(buildMissReason ?? "no VALID, unexpired build to attach") }
        if let buildBelowFloor { reasons.append(buildBelowFloor) }
        if !blockingVersionItems.isEmpty {
            reasons.append(
                "draft \(draftID ?? "?") already stages version item(s) for \(blockingVersionItems.joined(separator: ", ")) — pass --replace-item to replace them, or remove them in App Store Connect")
        }
        return reasons
    }

    /// Advisory lines — printed with `!` like blockers, but `--yes` still stages.
    public var warnings: [String] {
        floorDrift.map { [$0] } ?? []
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
    /// `minOsVersion` sits *below* it is the 90068 class — the same direction
    /// `Preflight.inspect` flags — and blocks. Sitting above it is stale config
    /// (the listing's compatibility comes from the build): a warning, not a block.
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
        // An exact --version passes through; next-patch/next-minor derive from this
        // platform's READY_FOR_SALE version before any of the checks below.
        let wantedVersion = try wantedVersionString(request: request, versions: versions, platform: platform)
        // Only a derived version can go stale — an exact --version means what it says.
        let liveVersionBasis = request.versionBump == nil
            ? nil : topLiveVersion(versions)?.attributes?.versionString

        // Version: a stageable one wins; a non-stageable exact match is a hard stop (you
        // cannot re-stage READY_FOR_SALE); otherwise a create. `stageableVersionStates`,
        // not `editableVersionStates` — an ACCEPTED version takes metadata edits but can
        // never be repurposed for the next release.
        let editable = versions.filter {
            SubmissionPlan.stageableVersionStates.contains($0.attributes?.appStoreState?.rawValue ?? "")
        }
        var plan = SubmissionPlan(
            appID: app.id, platform: platform,
            versionAction: .create(versionString: wantedVersion ?? ""),
            buildID: nil, buildDescription: "none", buildMissReason: nil,
            buildAttachNeeded: false, phasedReleaseExists: false,
            draftID: nil, inFlightState: nil, buildBelowFloor: nil, floorDrift: nil,
            liveVersionBasis: liveVersionBasis,
            blockingVersionItems: [], alreadyStaged: [], steps: []
        )

        if let wantedVersion,
           let exact = versions.first(where: { $0.attributes?.versionString == wantedVersion }),
           !SubmissionPlan.stageableVersionStates.contains(exact.attributes?.appStoreState?.rawValue ?? "") {
            throw WorkflowError.invalid([
                "version \(wantedVersion) exists in state \(exact.attributes?.appStoreState?.rawValue ?? "?") — not editable; pick a new version string"
            ])
        }
        if let target = editable.first {
            let current = target.attributes?.versionString ?? "?"
            if let wantedVersion, wantedVersion != current {
                // A next-* bump lands here too: the derived string becomes a rename
                // of the editable version, and the preview says so.
                plan.versionAction = .rename(id: target.id, from: current, to: wantedVersion)
            } else {
                plan.versionAction = .useExisting(
                    id: target.id, versionString: current,
                    state: target.attributes?.appStoreState?.rawValue ?? "?")
            }
        } else {
            guard let wantedVersion, !wantedVersion.isEmpty else {
                throw WorkflowError.misconfigured(
                    "no editable \(platform) version exists — pass --version to create one")
            }
            plan.versionAction = .create(versionString: wantedVersion)
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
            // The floor check reads the platform's own minimum — `minOsVersion` is the
            // iOS attribute; macOS/visionOS builds report theirs separately.
            let buildMin: String? = switch platform {
            // macOS reports both a declared and a computed minimum — compare the floor
            // against the higher of the two, not whichever happens to be present.
            case "MAC_OS":
                [build.attributes?.lsMinimumSystemVersion, build.attributes?.computedMinMacOsVersion]
                    .compactMap { $0 }
                    .max { Preflight.compareVersions($0, $1) == .orderedAscending }
            case "VISION_OS": build.attributes?.computedMinVisionOsVersion
            default: build.attributes?.minOsVersion
            }
            if let floor = minimumOSVersion, let buildMin {
                let number = build.attributes?.version ?? "?"
                switch Preflight.compareVersions(buildMin, floor) {
                case .orderedAscending:
                    // Same direction Preflight flags as the 90068 upload failure.
                    plan.buildDescription += " (minOS \(buildMin) < floor \(floor))"
                    plan.buildBelowFloor =
                        "build \(number) declares minOS \(buildMin) — below the \(floor) deployment floor (the 90068 class); rebuild at the floor or lower the floor"
                case .orderedDescending:
                    // Config drift, not a defect — the listing's compatibility comes
                    // from the build, so the floor is merely stale. Warn and stage.
                    plan.buildDescription += " (minOS \(buildMin) > floor \(floor))"
                    plan.floorDrift =
                        "asc.json minimumOSVersion \(floor) is stale — build \(number) requires \(buildMin); the listing's compatibility comes from the build"
                case .orderedSame: break
                }
            }
        } else if let pinned = request.buildNumber {
            // A pin that missed gets one diagnostic GET — audience/state/expiry
            // filters dropped — so the blocker can say *why*, not just that.
            let reason = try await diagnoseBuildMiss(
                appID: app.id, buildNumber: pinned,
                versionString: plan.versionLabel, platform: platform)
            plan.buildMissReason = reason
            plan.buildDescription = reason
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

        // A requested phased release is checked now so the preview can say "already
        // on version" — a create action has no id yet, so its step just says so.
        if request.phasedRelease, let versionID = plan.versionID {
            plan.phasedReleaseExists = try await phasedReleaseExists(versionID: versionID)
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
        if request.phasedRelease {
            if plan.versionID == nil {
                plan.steps.append("create phased release (INACTIVE) on the new version")
            } else if plan.phasedReleaseExists {
                plan.steps.append("phased release already on version \(plan.versionID!) — skip")
            } else {
                plan.steps.append("create phased release (INACTIVE) on version \(plan.versionID!)")
            }
        }
        plan.steps.append(plan.draftID == nil
            ? "create review submission draft" : "reuse review submission draft \(plan.draftID!)")
        // A draft carrying a version item for a *different* version: a blocker by
        // default (the item may be deliberate), or an explicit repoint under
        // `replaceItem` — POST the target, then DELETE every stale one, which is
        // what makes an interrupted run resumable.
        let staged = Set(plan.alreadyStaged)
        let staleVersions = plan.alreadyStaged
            .filter { $0.hasPrefix("appStoreVersion:") }
            .compactMap { $0.split(separator: ":").last.map(String.init) }
            .filter { $0 != plan.versionID }
        if !staleVersions.isEmpty && !request.replaceItem {
            plan.blockingVersionItems = staleVersions
        } else if let other = staleVersions.first {
            plan.versionItemRepoint = other
            // Every stale item is named — `stage()` deletes them all, so the preview must
            // not understate what `--yes` removes.
            plan.steps.append("replace staged version item \(other) → \(plan.versionLabel)")
            for extra in staleVersions.dropFirst() {
                plan.steps.append("remove stale version item \(extra)")
            }
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
        // The plan is a snapshot — the in-flight gate and the draft identity are re-read
        // live. A submission that went in-flight aborts with zero writes; a draft that
        // appeared since the preview is reused rather than duplicated.
        let fresh = try await reviewSubmissions(appID: plan.appID, platform: plan.platform)
        if let inFlight = fresh.first(where: {
            guard let s = $0.attributes?.state?.rawValue else { return false }
            return !SubmissionPlan.draftSubmissionStates.contains(s) && s != "COMPLETE"
        }) {
            result.failed = "a submission is now \(inFlight.attributes?.state?.rawValue ?? "?") — aborting without writes"
            return
        }
        let resolvedDraftID = fresh.first {
            SubmissionPlan.draftSubmissionStates.contains($0.attributes?.state?.rawValue ?? "")
        }?.id
        // The version and the selected build are also snapshot state: re-read both before
        // the first write. A renamed/created version on someone else's edit, or a build
        // that left the eligible set (expired, re-processed, audience change), aborts
        // with a re-plan message instead of writing on top of it.
        if let drift = try await versionDrift(plan) {
            result.failed = drift
            return
        }
        if let buildID = plan.buildID {
            let eligible = try await builds(
                appID: plan.appID, buildNumber: nil,
                versionString: plan.versionLabel, platform: plan.platform)
            guard eligible.contains(where: { $0.id == buildID }) else {
                result.failed = "build \(buildID) is no longer in the VALID+unexpired+APP_STORE_ELIGIBLE set for \(plan.versionLabel) — re-run to re-plan"
                return
            }
        }
        // The draft's items are read before the first write too — a failed fetch must not
        // leave a renamed version or attached build half-staged.
        var prefetched: [StagedItem] = []
        if let resolvedDraftID { prefetched = try await stagedItems(draftID: resolvedDraftID) }
        // The foreign-item gate, re-read like every other gate: a version item pointing
        // at another version (for a create, *any* version item is foreign) may be the
        // owner staging deliberately — without --replace-item nothing is written.
        let foreignVersionIDs = prefetched.compactMap(\.appStoreVersionID)
            .filter { $0 != plan.versionID }
        if !foreignVersionIDs.isEmpty && !request.replaceItem {
            result.failed = "draft \(resolvedDraftID ?? "?") stages version item(s) for \(foreignVersionIDs.joined(separator: ", ")) — pass --replace-item to replace them, or remove them in App Store Connect; no writes sent"
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

        // 2. Build attach — pure relationship PATCH, safe to re-send. Eligibility was
        // re-verified pre-write; here we re-read what the version carries so a build
        // attached by another client after the preview is seen, not overwritten.
        if let buildID = plan.buildID {
            if try await attachedBuildID(versionID: versionID) != buildID {
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

        // 2b. Phased release — only under the flag. INACTIVE is the only state asc ever
        // sends (Apple flips it ACTIVE at release); an existing one — any state — is the
        // owner's and is left untouched, never PATCHed or DELETEd.
        if request.phasedRelease {
            switch try await phasedReleaseExists(versionID: versionID) {
            case true:
                result.skipped.append("phased release already on version \(versionID)")
            case false:
                let output = try await asc.client.appStoreVersionPhasedReleasesCreateInstance(.init(body: .json(.init(data: .init(
                    attributes: .init(phasedReleaseState: .inactive),
                    relationships: .init(appStoreVersion: .init(data: .init(id: versionID, _type: .appStoreVersions))),
                    _type: .appStoreVersionPhasedReleases
                )))))
                guard case .created = output else {
                    result.failed = "create phased release (INACTIVE): \(errorResponse(of: output) ?? "?")"
                    return
                }
                result.staged.append("created phased release (INACTIVE) on version \(versionID)")
            }
        }

        // 3. Draft — reuse the live one (which may have appeared since the preview) or create.
        var draftID: String
        if let existing = resolvedDraftID {
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

        // 4. Items — the pre-write snapshot: a draft created this run carries nothing.
        let freshItems = resolvedDraftID == nil ? [] : prefetched
        let stagedNow = Set(freshItems.flatMap(\.labels))
        let staleItems = freshItems.filter {
            $0.appStoreVersionID != nil && $0.appStoreVersionID != versionID
        }
        if request.replaceItem && !staleItems.isEmpty {
            // Re-point, reachable only under --replace-item: the pre-write gate
            // refused when stale items existed without it. POST ours FIRST (only
            // if not already staged — a run that died between POST and DELETE
            // leaves both items, and a second POST would just fail again), then
            // DELETE every stale one. A rejected POST keeps the old items.
            if !stagedNow.contains("appStoreVersion:\(versionID)") {
                try await addItem(draftID: draftID, versionID: versionID, result: &result)
                if result.failed != nil { return }
            }
            for stale in staleItems {
                let del = try await asc.client.reviewSubmissionItemsDeleteInstance(.init(path: .init(id: stale.id)))
                guard case .noContent = del else {
                    result.failed = "remove replaced version item \(stale.id): \(errorResponse(of: del) ?? "?")"
                    return
                }
                result.staged.append("removed stale version item (was \(stale.appStoreVersionID ?? "?"))")
            }
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

    /// The version string to stage: an exact `--version`, or `next-patch`/`next-minor`
    /// derived from the platform's READY_FOR_SALE version. Both set is ambiguous and
    /// fails; a bump with no live version is a config error, not a guess.
    private func wantedVersionString(
        request: SubmissionRequest, versions: [Components.Schemas.AppStoreVersion], platform: String
    ) throws -> String? {
        guard let bump = request.versionBump else { return request.versionString }
        guard request.versionString == nil else {
            throw WorkflowError.misconfigured("pass either an exact --version or a next-* selector, not both")
        }
        // ASC order isn't a version sort — if a platform ever shows two live rows,
        // derive from the highest one.
        let live = topLiveVersion(versions)
        guard let live else {
            throw WorkflowError.misconfigured(
                "no released \(platform) version to derive from — pass an exact --version string")
        }
        return try bump.applied(to: live.attributes?.versionString ?? "")
    }

    /// The highest READY_FOR_SALE version on this platform — the base a `next-*`
    /// bump derives from, and the drift reference for a derived plan.
    private func topLiveVersion(
        _ versions: [Components.Schemas.AppStoreVersion]
    ) -> Components.Schemas.AppStoreVersion? {
        versions.filter {
            $0.attributes?.appStoreState?.rawValue == "READY_FOR_SALE"
        }.max {
            Preflight.compareVersions(
                $0.attributes?.versionString ?? "", $1.attributes?.versionString ?? "") == .orderedAscending
        }
    }

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

    /// One GET for a `--build N` that missed the eligible query — same app + number
    /// scope, but *without* the audience/state/expiry filters that excluded it, so the
    /// blocker can name the reason instead of a bare "not found". Failure-path only:
    /// the happy path never pays for this request.
    private func diagnoseBuildMiss(
        appID: String, buildNumber: String, versionString: String, platform: String
    ) async throws -> String {
        let output = try await asc.client.buildsGetCollection(
            .init(query: .init(
                filter_lbrack_version_rbrack_: [buildNumber],
                filter_lbrack_app_rbrack_: [appID],
                sort: [._hyphen_uploadedDate],
                limit: 10,
                include: [.preReleaseVersion]
            ))
        )
        guard case .ok(let ok) = output else { throw apiError("buildsGetCollection", errorResponse(of: output)) }
        // Follow pages — a popular build number can push the matching row past the
        // first page, and the blocker must name *its* release's exclusion reason.
        var matching: [Components.Schemas.Build] = []
        var prereleases: [String: Components.Schemas.PrereleaseVersion] = [:]
        for try await page in asc.pages(startingWith: try ok.body.json, links: { $0.links }) {
            matching += page.data
            for item in page.included ?? [] {
                if case .preReleaseVersions(let p) = item { prereleases[p.id] = p }
            }
        }
        guard !matching.isEmpty else { return "no build \(buildNumber) exists for this app" }
        func release(of build: Components.Schemas.Build) -> (version: String?, platform: String?)? {
            guard let id = build.relationships?.preReleaseVersion?.data?.id,
                  let p = prereleases[id] else { return nil }
            return (p.attributes?.version, p.attributes?.platform?.rawValue)
        }

        // The build for the target release+platform is the one whose exclusion reason
        // matters; fall back to the newest match when the number exists only elsewhere.
        let build = matching.first(where: {
            release(of: $0)?.version == versionString && release(of: $0)?.platform == platform
        }) ?? matching[0]

        if build.attributes?.buildAudienceType == .internalOnly {
            return "build \(buildNumber) is INTERNAL_ONLY — not eligible for App Store review"
        }
        if build.attributes?.expired == true {
            return "build \(buildNumber) expired on \(build.attributes?.expirationDate.map { "\($0)" } ?? "?")"
        }
        if let state = build.attributes?.processingState, state != .valid {
            return "build \(buildNumber) \(state == .processing ? "is still" : "is") \(state.rawValue)"
        }
        if let rel = release(of: build) {
            if rel.version != versionString {
                return "build \(buildNumber) belongs to release \(rel.version ?? "?"), not \(versionString)"
            }
            if rel.platform != platform {
                return "build \(buildNumber) belongs to platform \(rel.platform ?? "?"), not \(platform)"
            }
        }
        return "build \(buildNumber) is not in the VALID+unexpired+APP_STORE_ELIGIBLE set for \(versionString) (\(platform))"
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

    /// Nil when the live version list still supports the planned action; a reason string
    /// when it drifted between preview and `--yes` — the owner re-runs for a fresh plan
    /// rather than staging on top of someone else's edits.
    private func versionDrift(_ plan: SubmissionPlan) async throws -> String? {
        let live = try await versions(appID: plan.appID, platform: plan.platform)
        if let basis = plan.liveVersionBasis {
            let now = topLiveVersion(live)?.attributes?.versionString
            guard now == basis else {
                return "the live release moved \(basis) → \(now ?? "none") since the preview — the derived version is obsolete; re-run to re-plan"
            }
        }
        let editable = live.filter {
            SubmissionPlan.stageableVersionStates.contains($0.attributes?.appStoreState?.rawValue ?? "")
        }
        switch plan.versionAction {
        case .useExisting(let id, let v, _), .rename(let id, let v, _):
            guard let current = live.first(where: { $0.id == id }) else {
                return "version \(id) no longer exists — re-run to re-plan"
            }
            let state = current.attributes?.appStoreState?.rawValue ?? "?"
            guard SubmissionPlan.stageableVersionStates.contains(state) else {
                return "version \(v) is now \(state) — no longer stageable; re-run to re-plan"
            }
            let now = current.attributes?.versionString ?? ""
            guard now == v else {
                return "version was renamed \(v) → \(now) since the preview — re-run to re-plan"
            }
            return nil
        case .create(let wanted):
            if let e = editable.first {
                return "an editable version (\(e.attributes?.versionString ?? "?")) appeared since the preview — re-run to re-plan"
            }
            if live.contains(where: { $0.attributes?.versionString == wanted }) {
                return "version \(wanted) now exists in a non-editable state — re-run to re-plan"
            }
            return nil
        }
    }

    /// Whether the version already carries a phased release — the GET runs at plan
    /// time (preview honesty) and again live at stage time (idempotent re-run).
    private func phasedReleaseExists(versionID: String) async throws -> Bool {
        let output = try await asc.client.appStoreVersionsAppStoreVersionPhasedReleaseGetToOneRelated(
            .init(path: .init(id: versionID))
        )
        switch output {
        case .ok: return true
        case .notFound: return false
        default: throw apiError("versionPhasedRelease", errorResponse(of: output))
        }
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

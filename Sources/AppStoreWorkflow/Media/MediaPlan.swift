import AppStoreKit
import AppStoreOpenAPI
import Foundation

/// The `--yes`-less half of `media push`: a full description of what *would* happen,
/// produced by reads only. Mirrors `SubmissionPlan`'s shape.
public struct MediaPlan: Sendable {
    /// One staged file × its live-set disposition.
    public struct FileAction: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// No matching live row (or a non-COMPLETE/checksum-mismatched one): reserve + upload.
            case upload
            /// A live row with the same `fileName`, matching md5 and COMPLETE states — kept.
            case keep
        }
        public var kind: Kind
        public var fileName: String
        /// For `.keep`: the live row reused.
        public var liveID: String?
    }

    /// A live row that ends up deleted — the reason distinguishes the traps.
    public struct Deletion: Sendable, Equatable {
        public enum Reason: String, Sendable {
            /// Same name as a staged file but wrong checksum / not COMPLETE — a replacement
            /// lands first, then this goes (deferred delete).
            case superseded
            /// `AWAITING_UPLOAD`/`FAILED`/`PROCESSING` residue — unfinishable, deleted
            /// once the replacements landed.
            case orphan
            /// Remote row whose name isn't staged at all — the staged dir is authoritative.
            case unstaged
        }
        public var id: String
        public var fileName: String
        public var reason: Reason
        /// `true` when the delete may have to happen *before* all uploads land — a set at
        /// cap needs the slot freed. Gated on a verified replacement when possible.
        public var mayFreeEarly: Bool
    }

    /// One `<locale>/<TYPE>` staged set against its live counterpart.
    public struct SetPlan: Sendable {
        public var locale: String
        /// `nil` when the staged locale has no localization on the version — the set is
        /// unpushable and the reason sits in `blocked`.
        public var localizationID: String?
        public var type: MediaSetType
        /// Live set id, or `nil` → "will create".
        public var existingSetID: String?
        public var actions: [FileAction]
        public var deletions: [Deletion]
        /// Non-nil when this set can't proceed — e.g. missing localization. Other sets
        /// still push; the run exits non-zero.
        public var blocked: String?

        public var uploads: [FileAction] { actions.filter { $0.kind == .upload } }
        public var keeps: [FileAction] { actions.filter { $0.kind == .keep } }
    }

    /// `"1.3.0"` for output headers.
    public var versionString: String
    /// e.g. `PREPARE_FOR_SUBMISSION` — printed so the owner sees the gate that passed.
    public var versionState: String
    public var sets: [SetPlan]

    public var isEmpty: Bool { sets.allSatisfy { $0.actions.isEmpty && $0.deletions.isEmpty && $0.blocked == nil } }
    /// Any blocked set fails the whole run — partial pushes are worse than none.
    public var blockers: [String] {
        sets.compactMap { set in set.blocked.map { "\(set.locale)/\(set.type.rawValue): \($0)" } }
    }
}

/// Builds a ``MediaPlan`` from a scanned source + live state. Pure reads.
public struct MediaPlanner: Sendable {
    private let reader: MediaReader

    public init(asc: AppStoreConnect) {
        reader = MediaReader(asc: asc)
    }

    public func plan(
        appID: String?,
        bundleId: String?,
        platform: String,
        selector: VersionSelector,
        staged: StagedMedia
    ) async throws -> MediaPlan {
        let target = try await reader.target(appID: appID, bundleId: bundleId, platform: platform, selector: selector)
        try reader.requireEditable(target)

        var plans: [MediaPlan.SetPlan] = []
        for locale in staged.locales {
            for stagedSet in staged.sets[locale] ?? [] {
                plans.append(try await planSet(stagedSet, target: target))
            }
        }
        return MediaPlan(
            versionString: target.version.attributes?.versionString ?? target.version.id,
            versionState: target.version.attributes?.appStoreState?.rawValue ?? "?",
            sets: plans
        )
    }

    private func planSet(_ staged: StagedSet, target: MediaReader.Target) async throws -> MediaPlan.SetPlan {
        var plan = MediaPlan.SetPlan(
            locale: staged.locale,
            localizationID: target.localizationID(locale: staged.locale),
            type: staged.type,
            existingSetID: nil,
            actions: [],
            deletions: [],
            blocked: nil
        )
        guard let locID = plan.localizationID else {
            plan.blocked = "no \(staged.locale) localization on this version"
            return plan
        }

        let liveSets = try await reader.sets(localizationID: locID, kind: staged.type.kind)
        let liveSet = liveSets.first { $0.rawType == staged.type.rawValue }
        plan.existingSetID = liveSet?.id
        let rows: [AssetRow] = if let setID = liveSet?.id {
            try await reader.rows(setID: setID, kind: staged.type.kind)
        } else {
            []
        }

        var checksums: [String: String] = [:]
        for file in staged.files {
            checksums[file.fileName] = try? file.checksum()
        }

        // Same-name disposition mirrors previews.py: a live row is kept only when its
        // name, md5 and delivery state all agree; anything else gets replaced.
        for file in staged.files {
            let matching = rows.filter { $0.fileName == file.fileName }
            let keep = matching.first { $0.isComplete && $0.sourceFileChecksum == checksums[file.fileName] }
            plan.actions.append(.init(kind: keep == nil ? .upload : .keep, fileName: file.fileName, liveID: keep?.id))
        }

        let keptIDs = Set(plan.keeps.compactMap(\.liveID))
        let stagedNames = Set(staged.files.map(\.fileName))
        for row in rows where !keptIDs.contains(row.id) {
            let reason: MediaPlan.Deletion.Reason
            if !stagedNames.contains(row.fileName) {
                reason = .unstaged
            } else if row.isUnfinished {
                reason = .orphan
            } else {
                reason = .superseded
            }
            // A set at cap must free slots during the upload pass — any delete may be
            // promoted to early, in the order the state machine prefers.
            plan.deletions.append(.init(id: row.id, fileName: row.fileName, reason: reason, mayFreeEarly: true))
        }

        // Cap pressure check: live rows that survive + new uploads must fit the cap.
        let surviving = rows.count - plan.deletions.count
        let needed = plan.uploads.count
        if surviving + needed > staged.type.kind.cap {
            plan.blocked = "\(surviving) live rows kept + \(needed) uploads exceed cap \(staged.type.kind.cap) — delete remote rows or stage fewer files"
        }
        return plan
    }
}

import AppStoreKit
import AppStoreOpenAPI
import Foundation

/// The `--yes` half of `media push`: executes a ``MediaPlan``'s writes.
///
/// This is a direct port of the two proven recipes — `tools/asc-api/screenshots.py` and
/// `tools/asc-api/previews.py` in the AppStore repo — unified on the preview one's
/// richer dedup semantics. Every trap below is live-verified there; the comments stay.
///
/// - Create set → `409` means it already exists → GET the localization's sets and reuse
///   the matching id (never a blind re-POST).
/// - Reservation → PUT **every** `uploadOperations` entry (previews arrive as several ops,
///   PNGs as one) carrying `offset`/`length` and the op's `requestHeaders` → PATCH
///   `uploaded: true` + `sourceFileChecksum` (md5 hex). A PATCH after only `ops[0]`
///   fails `409 ASSET_UPLOAD_OPERATIONS_NOT_COMPLETED`.
/// - Duplicate `fileName` does **not** 409 — idempotency is the client's. Keep a
///   same-named row whose checksum matches and whose delivery states are `COMPLETE`;
///   upload replacements first, delete stale/orphaned rows only after every replacement
///   landed. An `AWAITING_UPLOAD` orphan from a crashed run has no `uploadOperations`
///   on GET — it must be deleted and re-created.
/// - Poll the *set* after PATCH until every committed row is `COMPLETE` (for previews
///   BOTH `assetDeliveryState` and `videoDeliveryState`; transcode takes 10–15 min),
///   once per cycle per set — bounded, with a "still processing" exit.
public struct MediaPusher: Sendable {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    /// How a set's push ended.
    public enum Outcome: String, Sendable, Equatable {
        /// Set converged: uploads verified COMPLETE, all non-committed rows swept.
        case pushed
        /// Uploads landed but processing (usually transcode) outlasted the deadline —
        /// the deletes were not swept; re-run `asc media status` to check.
        case processing
        /// Something broke — see `detail`. Earlier files may have uploaded already.
        case failed
    }

    public struct SetResult: Sendable {
        public var locale: String
        public var type: MediaSetType
        public var setID: String?
        public var uploaded: [String]
        public var kept: [String]
        public var deleted: [String]
        public var outcome: Outcome
        public var detail: String
    }

    let asc: AppStoreConnect
    private let reader: MediaReader
    /// Set-level poll cadence — previews.py polls once per 15 s cycle per set.
    public var pollInterval: TimeInterval = 15
    /// Set-level settle ceiling — transcode takes 10–15 min; previews.py waits ~30 min.
    public var settleDeadline: TimeInterval = 30 * 60
    /// Per-row verify budget for the cap-sacrifice path — previews.py's `wait_complete`.
    public var verifyDeadline: TimeInterval = 15 * 60
    /// Injectable for tests.
    public var sleep: Sleep

    public init(
        asc: AppStoreConnect,
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.asc = asc
        reader = MediaReader(asc: asc)
        self.sleep = sleep
    }

    /// Execute a plan. Re-resolves the target live (like `SubmissionStager.stage`) so the
    /// editable gate and the localization/set listings reflect now, not plan time.
    /// Each set runs to its own outcome — a failed set doesn't stop the others.
    public func push(
        appID: String?,
        bundleId: String?,
        platform: String,
        selector: VersionSelector,
        staged: StagedMedia
    ) async throws -> [SetResult] {
        let target = try await reader.target(appID: appID, bundleId: bundleId, platform: platform, selector: selector)
        try reader.requireEditable(target)
        var results: [SetResult] = []
        for locale in staged.locales {
            for set in staged.sets[locale] ?? [] {
                results.append(await pushSet(set, target: target))
            }
        }
        return results
    }

    private func pushSet(_ staged: StagedSet, target: MediaReader.Target) async -> SetResult {
        var result = SetResult(
            locale: staged.locale, type: staged.type, setID: nil,
            uploaded: [], kept: [], deleted: [], outcome: .failed, detail: "not run"
        )
        do {
            guard let locID = target.localizationID(locale: staged.locale) else {
                result.detail = "no \(staged.locale) localization on this version"
                return result
            }
            let kind = staged.type.kind
            let setID = try await resolveSetID(staged: staged, localizationID: locID)
            result.setID = setID

            var committed: [String: String] = [:]    // fileName -> final row id
            var deferred: [(old: String, new: String)] = []  // superseded row -> its replacement

            for file in staged.files {
                let data = try file.read()
                let md5 = try file.checksum()
                var rows = try await reader.rows(setID: setID, kind: kind)
                let same = rows.filter { $0.fileName == file.fileName }
                let good = same.filter { $0.isComplete && $0.sourceFileChecksum == md5 }
                let stale = same.filter { $0.isComplete && $0.sourceFileChecksum != md5 }
                let stubs = same.filter { $0.isUnfinished }

                if let keep = good.first {
                    committed[file.fileName] = keep.id
                    result.kept.append(file.fileName)
                    // A verified sibling survives — superseded rows and stubs go now.
                    for row in stale + stubs {
                        try await delete(row, kind: kind)
                        rows.removeAll { $0.id == row.id }
                        result.deleted.append(row.fileName)
                    }
                    continue
                }

                // Stubs (AWAITING_UPLOAD orphans, FAILED, mid-transcode of this same
                // file) are unfinishable — drop them before measuring the cap.
                for row in stubs {
                    try await delete(row, kind: kind)
                    rows.removeAll { $0.id == row.id }
                    result.deleted.append(row.fileName)
                }
                if rows.count >= kind.cap {
                    // Set is at cap — the new reservation needs a free slot. Prefer a
                    // superseded row whose replacement already verified; otherwise this
                    // file's own stale row, then any row the final sweep would delete.
                    let victim = try await freeSlot(
                        deferred: &deferred, stale: stale, rows: rows,
                        committedIDs: Set(committed.values), kind: kind
                    )
                    try await delete(victim, kind: kind)
                    rows.removeAll { $0.id == victim.id }
                    result.deleted.append(victim.fileName)
                }

                let newID = try await upload(file: file, data: data, md5: md5, setID: setID, kind: kind)
                committed[file.fileName] = newID
                result.uploaded.append(file.fileName)
                for row in stale { deferred.append((old: row.id, new: newID)) }
            }

            // Settle: one poll per cycle per set — transcode lags the byte upload.
            let deadline = Date().addingTimeInterval(settleDeadline)
            while true {
                let rows = try await reader.rows(setID: setID, kind: kind)
                let committedIDs = Set(committed.values)
                let live = rows.filter { committedIDs.contains($0.id) }
                if live.count == committed.count, live.allSatisfy(\.isComplete) {
                    // Every replacement verified — sweep whatever the staged dir
                    // didn't commit: superseded rows, orphans, unstaged leftovers.
                    for row in rows where !committedIDs.contains(row.id) {
                        try await delete(row, kind: kind)
                        result.deleted.append(row.fileName)
                    }
                    result.outcome = .pushed
                    result.detail = "\(result.uploaded.count) uploaded, \(result.kept.count) kept, \(result.deleted.count) deleted"
                    return result
                }
                if let bad = live.first(where: \.isFailed) {
                    result.detail = "\(bad.fileName): Apple processing FAILED — check App Store Connect"
                    return result
                }
                if Date() >= deadline {
                    result.outcome = .processing
                    result.detail = "still processing — re-run `asc media status` to check"
                    return result
                }
                try await sleep(pollInterval)
            }
        } catch {
            result.detail = "\(error)"
            return result
        }
    }

    // MARK: - Set resolution

    /// POST the set. A `409` (or a POST whose outcome is unknown) means "look, don't
    /// re-send": GET the localization's sets and reuse the one with our type.
    private func resolveSetID(staged: StagedSet, localizationID: String) async throws -> String {
        do {
            switch staged.type {
            case .screenshot(let type):
                let output = try await asc.client.appScreenshotSetsCreateInstance(.init(body: .json(.init(data: .init(
                    attributes: .init(screenshotDisplayType: type),
                    relationships: .init(appStoreVersionLocalization: .init(data: .init(id: localizationID, _type: .appStoreVersionLocalizations))),
                    _type: .appScreenshotSets
                )))))
                switch output {
                case .created(let ok): return try ok.body.json.data.id
                case .conflict: break // exists — reconcile below
                default: throw apiError("appScreenshotSetsCreate", errorResponse(of: output))
                }
            case .preview(let type):
                let output = try await asc.client.appPreviewSetsCreateInstance(.init(body: .json(.init(data: .init(
                    attributes: .init(previewType: type),
                    relationships: .init(appStoreVersionLocalization: .init(data: .init(id: localizationID, _type: .appStoreVersionLocalizations))),
                    _type: .appPreviewSets
                )))))
                switch output {
                case .created(let ok): return try ok.body.json.data.id
                case .conflict: break // exists — reconcile below
                default: throw apiError("appPreviewSetsCreate", errorResponse(of: output))
                }
            }
        } catch is MutationOutcomeUnknownError {
            // POST died before a response — reconcile by re-listing; a blind retry
            // could create a second set.
        }
        let sets = try await reader.sets(localizationID: localizationID, kind: staged.type.kind)
        if let existing = sets.first(where: { $0.rawType == staged.type.rawValue }) {
            return existing.id
        }
        throw WorkflowError.conflict(["set create conflicted but no \(staged.type.rawValue) set exists on \(staged.locale)"])
    }

    // MARK: - Cap pressure

    private func freeSlot(
        deferred: inout [(old: String, new: String)],
        stale: [AssetRow],
        rows: [AssetRow],
        committedIDs: Set<String>,
        kind: MediaKind
    ) async throws -> AssetRow {
        // 1. a superseded row whose own replacement verified — safest sacrifice.
        for (index, pair) in deferred.enumerated() {
            if try await awaitComplete(rowID: pair.new, kind: kind), let row = rows.first(where: { $0.id == pair.old }) {
                deferred.remove(at: index)
                return row
            }
        }
        // 2. this file's own stale row — costs one frame if the replacement fails.
        if let victim = stale.first { return victim }
        // 3. any row the final sweep deletes anyway.
        if let victim = rows.first(where: { !committedIDs.contains($0.id) }) { return victim }
        throw WorkflowError.conflict(["set is at cap but nothing is safe to delete"])
    }

    /// previews.py's `wait_complete` — the only per-row poll, one-second cadence,
    /// used only when cap pressure needs a verified replacement before a sacrifice.
    private func awaitComplete(rowID: String, kind: MediaKind) async throws -> Bool {
        let deadline = Date().addingTimeInterval(verifyDeadline)
        while Date() < deadline {
            if let row = try await reader.row(id: rowID, kind: kind) {
                if row.isComplete { return true }
                if row.isFailed { return false }
            }
            try await sleep(1)
        }
        return false
    }

    // MARK: - Reserve / upload / mark-uploaded

    /// POST the reservation → PUT every uploadOperation → PATCH uploaded+checksum.
    private func upload(file: StagedFile, data: Data, md5: String, setID: String, kind: MediaKind) async throws -> String {
        var reservation: (id: String, ops: [Components.Schemas.UploadOperation])?
        for attempt in 1...2 {
            do {
                reservation = try await createReservation(fileName: file.fileName, fileSize: data.count, setID: setID, kind: kind)
                break
            } catch let error as MutationOutcomeUnknownError {
                guard attempt == 1 else { throw error }
                // The row may have been created — but a GET never carries
                // uploadOperations, so it can't be finished: delete and re-create.
                if let stranded = try await reader.rows(setID: setID, kind: kind).first(where: { $0.fileName == file.fileName }) {
                    try await delete(stranded, kind: kind)
                }
                // Nothing matching → the POST never landed; safe to send it again.
            }
        }
        guard let (id, ops) = reservation else {
            throw WorkflowError.conflict(["reservation for \(file.fileName) produced no upload operations"])
        }
        for (index, op) in ops.enumerated() {
            let lo = op.offset ?? 0
            guard lo < data.count || (lo == 0 && data.isEmpty) else {
                throw WorkflowError.conflict(["upload op \(index) offset \(lo) beyond \(file.fileName) (\(data.count) bytes)"])
            }
            let end = min(lo + (op.length ?? data.count - lo), data.count)
            try await asc.putUploadOperation(op, bytes: data.subdata(in: lo..<end), operationID: "media-upload-\(file.fileName)-\(index)")
        }
        try await markUploaded(id: id, md5: md5, kind: kind)
        return id
    }

    private func createReservation(fileName: String, fileSize: Int, setID: String, kind: MediaKind) async throws -> (id: String, ops: [Components.Schemas.UploadOperation]) {
        switch kind {
        case .screenshot:
            let output = try await asc.client.appScreenshotsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(appScreenshotSet: .init(data: .init(id: setID, _type: .appScreenshotSets))),
                _type: .appScreenshots
            )))))
            guard case .created(let ok) = output else {
                throw apiError("appScreenshotsCreate", errorResponse(of: output))
            }
            let row = try ok.body.json.data
            return (row.id, row.attributes?.uploadOperations ?? [])
        case .preview:
            let output = try await asc.client.appPreviewsCreateInstance(.init(body: .json(.init(data: .init(
                attributes: .init(fileName: fileName, fileSize: fileSize),
                relationships: .init(appPreviewSet: .init(data: .init(id: setID, _type: .appPreviewSets))),
                _type: .appPreviews
            )))))
            guard case .created(let ok) = output else {
                throw apiError("appPreviewsCreate", errorResponse(of: output))
            }
            let row = try ok.body.json.data
            return (row.id, row.attributes?.uploadOperations ?? [])
        }
    }

    /// PATCH `uploaded: true` + `sourceFileChecksum`. An outcome-unknown PATCH is
    /// reconciled by GET: a `sourceFileChecksum` that already matches proves the
    /// update landed; otherwise the PATCH is sent once more (it's idempotent).
    private func markUploaded(id: String, md5: String, kind: MediaKind) async throws {
        for attempt in 1...2 {
            do {
                try await patchUploaded(id: id, md5: md5, kind: kind)
                return
            } catch let error as MutationOutcomeUnknownError {
                guard attempt == 1 else { throw error }
                if let row = try await reader.row(id: id, kind: kind), row.sourceFileChecksum == md5 { return }
            }
        }
    }

    private func patchUploaded(id: String, md5: String, kind: MediaKind) async throws {
        switch kind {
        case .screenshot:
            let output = try await asc.client.appScreenshotsUpdateInstance(.init(
                path: .init(id: id),
                body: .json(.init(data: .init(
                    attributes: .init(sourceFileChecksum: md5, uploaded: true),
                    id: id, _type: .appScreenshots
                )))
            ))
            guard case .ok = output else { throw apiError("appScreenshotsUpdate", errorResponse(of: output)) }
        case .preview:
            let output = try await asc.client.appPreviewsUpdateInstance(.init(
                path: .init(id: id),
                body: .json(.init(data: .init(
                    attributes: .init(sourceFileChecksum: md5, uploaded: true),
                    id: id, _type: .appPreviews
                )))
            ))
            guard case .ok = output else { throw apiError("appPreviewsUpdate", errorResponse(of: output)) }
        }
    }

    /// DELETE one row. A 404 is success (the row is already gone — the idempotent
    /// outcome we wanted); an outcome-unknown DELETE is reconciled by GET before
    /// one resend, per `NonIdempotentWriteGuard`'s guidance.
    private func delete(_ row: AssetRow, kind: MediaKind) async throws {
        for attempt in 1...2 {
            do {
                try await deleteRow(id: row.id, kind: kind)
                return
            } catch let error as MutationOutcomeUnknownError {
                guard attempt == 1 else { throw error }
                if try await reader.row(id: row.id, kind: kind) == nil { return }
            }
        }
    }

    private func deleteRow(id: String, kind: MediaKind) async throws {
        switch kind {
        case .screenshot:
            let output = try await asc.client.appScreenshotsDeleteInstance(.init(path: .init(id: id)))
            switch output {
            case .noContent, .notFound: return
            default: throw apiError("appScreenshotsDelete", errorResponse(of: output))
            }
        case .preview:
            let output = try await asc.client.appPreviewsDeleteInstance(.init(path: .init(id: id)))
            switch output {
            case .noContent, .notFound: return
            default: throw apiError("appPreviewsDelete", errorResponse(of: output))
            }
        }
    }
}

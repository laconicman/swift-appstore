import Foundation
import HTTPTypes
import Testing
@testable import AppStoreKit
@testable import AppStoreWorkflow
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// `asc media` — the scanner (pure filesystem), the planner (reads over a scripted
/// transport), and the pusher's reservation → chunked PUT → PATCH state machine.
/// No network: every POST/PATCH/PUT the machine emits is inspectable.
@Suite("MediaSource scanner")
struct MediaSourceTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MediaSourceTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    private func stage(_ parts: [String], bytes: Int = 4) throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString)
        for part in parts {
            let file = dir.appendingPathComponent(part)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: bytes).write(to: file)
        }
        return dir
    }

    @Test("a valid tree scans into per-locale sets with sorted files")
    func valid() throws {
        let dir = try stage([
            "en-GB/APP_IPHONE_67/2-home.png",
            "en-GB/APP_IPHONE_67/10-store.png",
            "en-GB/IPHONE_67/rolls.mp4",
            "ru/APP_IPHONE_67/1.png",
        ])
        let staged = try MediaSource.scan(root: dir)
        #expect(staged.locales == ["en-GB", "ru"])
        let enSets = staged.sets["en-GB"] ?? []
        #expect(enSets.map(\.type.rawValue) == ["APP_IPHONE_67", "IPHONE_67"])
        #expect(enSets[0].files.map(\.fileName) == ["10-store.png", "2-home.png"])
        #expect(enSets[0].type.kind == .screenshot)
        #expect(enSets[1].type.kind == .preview)
    }

    @Test("unknown TYPE dir names fail fast")
    func unknownType() throws {
        let dir = try stage(["en-GB/IPHONE_69/1.png"])
        #expect(throws: WorkflowError.self) { try MediaSource.scan(root: dir) }
    }

    @Test("a set over cap refuses the whole set, not just the overflow")
    func overCap() throws {
        let dir = try stage((1...11).map { "en-GB/APP_IPHONE_67/\($0).png" })
        #expect(throws: WorkflowError.self) { try MediaSource.scan(root: dir) }
    }

    @Test("wrong-extension, empty set, unknown locale and missing --locale all report")
    func violations() throws {
        let dir = try stage(["en-GB/APP_IPHONE_67/notes.txt", "xx-YY/APP_IPHONE_67/1.png"])
        #expect(throws: WorkflowError.self) { try MediaSource.scan(root: dir) }
        let ok = try stage(["en-GB/APP_IPHONE_67/1.png"])
        #expect(throws: WorkflowError.self) { try MediaSource.scan(root: ok, locales: ["fr"]) }
    }

    @Test("--locale narrows the scan to matching dirs")
    func localeFilter() throws {
        let dir = try stage(["en-GB/APP_IPHONE_67/1.png", "ru/APP_IPHONE_67/1.png"])
        let staged = try MediaSource.scan(root: dir, locales: ["ru"])
        #expect(staged.locales == ["ru"])
    }
}

/// Shared canned responses for the workflow tests below.
enum MediaFixtures {
    static let appJSON = #"""
    {"data":{"type":"apps","id":"APP1","attributes":{
      "bundleId":"com.example.app","name":"Example","primaryLocale":"en-US"}},
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/APP1"}}
    """#

    static let editableVersionJSON = #"""
    {"data":[{"type":"appStoreVersions","id":"V1","attributes":{
      "versionString":"1.2.2","platform":"IOS","appStoreState":"PREPARE_FOR_SUBMISSION"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/APP1/appStoreVersions"}}
    """#

    static let liveVersionJSON = #"""
    {"data":[{"type":"appStoreVersions","id":"V1","attributes":{
      "versionString":"1.2.1","platform":"IOS","appStoreState":"READY_FOR_SALE"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/apps/APP1/appStoreVersions"}}
    """#

    static let localizationsJSON = #"""
    {"data":[{"type":"appStoreVersionLocalizations","id":"LOC1","attributes":{"locale":"en-GB"}}],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersions/V1/appStoreVersionLocalizations"}}
    """#

    static let screenshotSetJSON = #"""
    {"type":"appScreenshotSets","id":"SET1","attributes":{"screenshotDisplayType":"APP_IPHONE_67"}}
    """#

    static let previewSetJSON = #"""
    {"type":"appPreviewSets","id":"PSET1","attributes":{"previewType":"IPHONE_67"}}
    """#

    static func screenshotSetsJSON(_ rows: String) -> String { """
    {"data":[\(rows)],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/LOC1/appScreenshotSets"}}
    """ }

    static func previewSetsJSON(_ rows: String) -> String { """
    {"data":[\(rows)],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/LOC1/appPreviewSets"}}
    """ }

    static func screenshotsJSON(_ rows: String) -> String { """
    {"data":[\(rows)],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appScreenshotSets/SET1/appScreenshots"}}
    """ }

    static func previewsJSON(_ rows: String) -> String { """
    {"data":[\(rows)],
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appPreviewSets/PSET1/appPreviews"}}
    """ }

    static func screenshotRow(_ id: String, name: String, checksum: String? = nil,
                              assetState: String = "COMPLETE") -> String { """
    {"type":"appScreenshots","id":"\(id)","attributes":{
      "fileName":"\(name)","sourceFileChecksum":\(checksum.map { "\"\($0)\"" } ?? "null"),
      "assetDeliveryState":{"state":"\(assetState)"}}}
    """ }

    static func previewRow(_ id: String, name: String, checksum: String? = nil,
                           assetState: String = "COMPLETE", videoState: String = "COMPLETE") -> String { """
    {"type":"appPreviews","id":"\(id)","attributes":{
      "fileName":"\(name)","sourceFileChecksum":\(checksum.map { "\"\($0)\"" } ?? "null"),
      "assetDeliveryState":{"state":"\(assetState)"},
      "videoDeliveryState":{"state":"\(videoState)"}}}
    """ }

    static func reservationJSON(id: String, name: String, ops: String) -> String { """
    {"data":{"type":"appScreenshots","id":"\(id)","attributes":{
      "fileName":"\(name)","uploadOperations":[\(ops)]}},
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appScreenshots/\(id)"}}
    """ }

    static func previewReservationJSON(id: String, name: String, ops: String) -> String { """
    {"data":{"type":"appPreviews","id":"\(id)","attributes":{
      "fileName":"\(name)","uploadOperations":[\(ops)]}},
     "links":{"self":"https://api.appstoreconnect.apple.com/v1/appPreviews/\(id)"}}
    """ }

    static let uploadOp = #"""
    {"method":"PUT","offset":0,"length":4,
     "url":"https://upload.example.com/abc","requestHeaders":[{"name":"X-Up","value":"yes"}]}
    """#

    static func conflictJSON() -> String { """
    {"errors":[{"status":"409","code":"RESOURCE_CONFLICT","title":"Conflict","detail":"exists"}]}
    """ }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// An `AppStoreConnect` over `script` with retry sleeps neutralized — the upload PUT
    /// retries instantly so failure paths stay deterministic.
    static func connect(_ script: [ScriptedTransport.Step]) throws -> (AppStoreConnect, ScriptedTransport) {
        let key = try ThrowawayKey()
        let transport = ScriptedTransport(script)
        let asc = try AppStoreConnect(
            tokens: BearerTokenCache(signer: JWTSigner(key: key.apiKey)),
            transport: transport,
            sleep: { _ in }
        )
        return (asc, transport)
    }

    /// The reads every push does first: app → versions → localizations.
    static var targetReads: [ScriptedTransport.Step] {
        [.json(.ok, appJSON), .json(.ok, editableVersionJSON), .json(.ok, localizationsJSON)]
    }

    static func stagedDir(_ parts: [String: Data], under root: URL) throws -> URL {
        for (part, data) in parts {
            let file = root.appendingPathComponent(part)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        return root
    }
}

@Suite("MediaPlanner over a scripted transport")
struct MediaPlannerTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MediaPlannerTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test("READY_FOR_SALE is refused for push")
    func refusesLiveVersion() async throws {
        let dir = try MediaFixtures.stagedDir(["en-GB/APP_IPHONE_67/1.png": Data(repeating: 1, count: 4)], under: root)
        let staged = try MediaSource.scan(root: dir)
        let (asc, _) = try MediaFixtures.connect([
            .json(.ok, MediaFixtures.appJSON), .json(.ok, MediaFixtures.liveVersionJSON),
            .json(.ok, MediaFixtures.localizationsJSON),
        ])
        let planner = MediaPlanner(asc: asc)
        await #expect(throws: WorkflowError.self) {
            _ = try await planner.plan(appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged)
        }
    }

    @Test("no live set → all uploads, set marked 'will create'")
    func freshSet() async throws {
        let data = Data(repeating: 7, count: 5)
        let dir = try MediaFixtures.stagedDir(["en-GB/APP_IPHONE_67/1.png": data], under: root)
        let staged = try MediaSource.scan(root: dir)
        let (asc, _) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                .json(.ok, MediaFixtures.screenshotSetsJSON("")),
            ]
        )
        let plan = try await MediaPlanner(asc: asc).plan(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        #expect(plan.blockers.isEmpty)
        let set = try #require(plan.sets.first)
        #expect(set.existingSetID == nil)
        #expect(set.uploads.map(\.fileName) == ["1.png"])
        #expect(set.deletions.isEmpty)
    }

    @Test("live rows classify as keep / superseded / orphan / unstaged")
    func classification() async throws {
        let same = Data(repeating: 1, count: 4)
        let changed = Data(repeating: 2, count: 4)
        let dir = try MediaFixtures.stagedDir([
            "en-GB/APP_IPHONE_67/keep.png": same,
            "en-GB/APP_IPHONE_67/change.png": changed,
        ], under: root)
        let staged = try MediaSource.scan(root: dir)
        let rows = [
            MediaFixtures.screenshotRow("A_KEEP", name: "keep.png", checksum: MediaFixtures.md5(same)),
            MediaFixtures.screenshotRow("A_STALE", name: "change.png", checksum: String(repeating: "0", count: 32)),
            MediaFixtures.screenshotRow("A_ORPHAN", name: "change.png", assetState: "AWAITING_UPLOAD"),
            MediaFixtures.screenshotRow("A_UNSTAGED", name: "extra.png"),
        ].joined(separator: ",")
        let (asc, _) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                .json(.ok, MediaFixtures.screenshotSetsJSON(MediaFixtures.screenshotSetJSON)),
                .json(.ok, MediaFixtures.screenshotsJSON(rows)),
            ]
        )
        let plan = try await MediaPlanner(asc: asc).plan(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        let set = try #require(plan.sets.first)
        #expect(set.existingSetID == "SET1")
        #expect(set.keeps.map(\.fileName) == ["keep.png"])
        #expect(set.uploads.map(\.fileName) == ["change.png"])
        #expect(set.deletions.map(\.reason) == [.superseded, .orphan, .unstaged])
    }

    @Test("a staged locale with no localization is blocked")
    func missingLocalization() async throws {
        let dir = try MediaFixtures.stagedDir(["ru/APP_IPHONE_67/1.png": Data(repeating: 1, count: 4)], under: root)
        let staged = try MediaSource.scan(root: dir)
        let (asc, _) = try MediaFixtures.connect(MediaFixtures.targetReads)
        let plan = try await MediaPlanner(asc: asc).plan(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        #expect(plan.blockers.count == 1)
    }
}

@Suite("MediaPusher over a scripted transport")
struct MediaPusherTests {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MediaPusherTests-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func pusher(_ asc: AppStoreConnect) -> MediaPusher {
        var pusher = MediaPusher(asc: asc, sleep: { _ in })
        pusher.pollInterval = 0
        pusher.settleDeadline = 60
        pusher.verifyDeadline = 60
        return pusher
    }

    @Test("happy path: 409 set-create → reuse → reserve → PUT → PATCH → COMPLETE")
    func pushScreenshot() async throws {
        let data = Data(repeating: 9, count: 4)
        let dir = try MediaFixtures.stagedDir(["en-GB/APP_IPHONE_67/1.png": data], under: root)
        let staged = try MediaSource.scan(root: dir)
        let md5 = MediaFixtures.md5(data)
        let (asc, transport) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                // create set → 409 → list sets → SET1
                .json(.conflict, MediaFixtures.conflictJSON()),
                .json(.ok, MediaFixtures.screenshotSetsJSON(MediaFixtures.screenshotSetJSON)),
                // per-file member list → empty
                .json(.ok, MediaFixtures.screenshotsJSON("")),
                // reservation → PUT → PATCH
                .json(.created, MediaFixtures.reservationJSON(id: "A1", name: "1.png", ops: MediaFixtures.uploadOp)),
                .respond(HTTPResponse(status: .ok), body: nil),
                .json(.ok, MediaFixtures.reservationJSON(id: "A1", name: "1.png", ops: "")),
                // settle poll → A1 COMPLETE → reorder PATCH
                .json(.ok, MediaFixtures.screenshotsJSON(
                    MediaFixtures.screenshotRow("A1", name: "1.png", checksum: md5))),
                .respond(HTTPResponse(status: .noContent), body: nil),
            ]
        )
        let results = try await pusher(asc).push(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        #expect(results.count == 1)
        #expect(results[0].outcome == .pushed)
        #expect(results[0].setID == "SET1")
        #expect(results[0].uploaded == ["1.png"])

        let exchanges = await transport.exchanges
        let puts = exchanges.filter { $0.request.method == .put }
        #expect(puts.count == 1)
        // The byte PUT must go to the op's URL with the op's headers and NO bearer —
        // the ES256 token is App Store Connect's, not Apple's upload host's.
        #expect(puts[0].request.authority == "upload.example.com")
        #expect(puts[0].request.headerFields[HTTPField.Name("X-Up")!] == "yes")
        #expect(puts[0].request.headerFields[.authorization] == nil)
        #expect(puts[0].body == data)
    }

    @Test("identical live row is kept — second run uploads nothing")
    func idempotentRerun() async throws {
        let data = Data(repeating: 3, count: 4)
        let dir = try MediaFixtures.stagedDir(["en-GB/APP_IPHONE_67/1.png": data], under: root)
        let staged = try MediaSource.scan(root: dir)
        let md5 = MediaFixtures.md5(data)
        let (asc, transport) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                .json(.conflict, MediaFixtures.conflictJSON()),
                .json(.ok, MediaFixtures.screenshotSetsJSON(MediaFixtures.screenshotSetJSON)),
                .json(.ok, MediaFixtures.screenshotsJSON(
                    MediaFixtures.screenshotRow("A1", name: "1.png", checksum: md5))),
                // settle poll — the kept row is already complete → reorder PATCH
                .json(.ok, MediaFixtures.screenshotsJSON(
                    MediaFixtures.screenshotRow("A1", name: "1.png", checksum: md5))),
                .respond(HTTPResponse(status: .noContent), body: nil),
            ]
        )
        let results = try await pusher(asc).push(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        #expect(results[0].outcome == .pushed)
        #expect(results[0].kept == ["1.png"])
        #expect(results[0].uploaded.isEmpty)
        let exchanges = await transport.exchanges
        #expect(exchanges.allSatisfy { $0.request.method == .get || $0.request.method == .post || $0.request.method == .patch })
        #expect(exchanges.filter { $0.request.method == .post }.count == 1) // the set-create 409
        #expect(exchanges.filter { $0.request.method == .patch }.count == 1) // the order fix-up
    }

    @Test("AWAITING_UPLOAD orphan from a crashed run is deleted and re-created")
    func orphanRecreate() async throws {
        let data = Data(repeating: 5, count: 4)
        let dir = try MediaFixtures.stagedDir(["en-GB/APP_IPHONE_67/1.png": data], under: root)
        let staged = try MediaSource.scan(root: dir)
        let md5 = MediaFixtures.md5(data)
        let (asc, transport) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                .json(.conflict, MediaFixtures.conflictJSON()),
                .json(.ok, MediaFixtures.screenshotSetsJSON(MediaFixtures.screenshotSetJSON)),
                .json(.ok, MediaFixtures.screenshotsJSON(
                    MediaFixtures.screenshotRow("A_ORPHAN", name: "1.png", assetState: "AWAITING_UPLOAD"))),
                // stub delete
                .respond(HTTPResponse(status: .noContent), body: nil),
                // reservation → PUT → PATCH → settle
                .json(.created, MediaFixtures.reservationJSON(id: "A1", name: "1.png", ops: MediaFixtures.uploadOp)),
                .respond(HTTPResponse(status: .ok), body: nil),
                .json(.ok, MediaFixtures.reservationJSON(id: "A1", name: "1.png", ops: "")),
                .json(.ok, MediaFixtures.screenshotsJSON(
                    MediaFixtures.screenshotRow("A1", name: "1.png", checksum: md5))),
                .respond(HTTPResponse(status: .noContent), body: nil),
            ]
        )
        let results = try await pusher(asc).push(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        #expect(results[0].outcome == .pushed)
        #expect(results[0].deleted == ["1.png"])
        let exchanges = await transport.exchanges
        #expect(exchanges.contains { $0.request.method == .delete && $0.request.path?.contains("A_ORPHAN") == true })
    }

    @Test("a preview uploads every chunked op as its own PUT slice")
    func chunkedPreview() async throws {
        let data = Data((0..<10).map { UInt8($0) })
        let dir = try MediaFixtures.stagedDir(["en-GB/IPHONE_67/rolls.mp4": data], under: root)
        let staged = try MediaSource.scan(root: dir)
        let md5 = MediaFixtures.md5(data)
        let ops = #"""
        {"method":"PUT","offset":0,"length":6,"url":"https://upload.example.com/a",
         "requestHeaders":[{"name":"X-Up","value":"yes"}]},
        {"method":"PUT","offset":6,"length":4,"url":"https://upload.example.com/b",
         "requestHeaders":[{"name":"X-Up","value":"yes"}]}
        """#
        let (asc, transport) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                .json(.created, """
                {"data":\(MediaFixtures.previewSetJSON),"links":{"self":"x"}}
                """),
                .json(.ok, MediaFixtures.previewsJSON("")),
                .json(.created, MediaFixtures.previewReservationJSON(id: "P1", name: "rolls.mp4", ops: ops)),
                .respond(HTTPResponse(status: .ok), body: nil),
                .respond(HTTPResponse(status: .ok), body: nil),
                .json(.ok, """
                {"data":\(MediaFixtures.previewRow("P1", name: "rolls.mp4", checksum: md5)),"links":{"self":"x"}}
                """),
                .json(.ok, MediaFixtures.previewsJSON(
                    MediaFixtures.previewRow("P1", name: "rolls.mp4", checksum: md5))),
                .respond(HTTPResponse(status: .noContent), body: nil),
            ]
        )
        let results = try await pusher(asc).push(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        #expect(results[0].outcome == .pushed)
        let puts = await transport.exchanges.filter { $0.request.method == .put }
        #expect(puts.count == 2)
        #expect(puts[0].body == data.subdata(in: 0..<6))
        #expect(puts[1].body == data.subdata(in: 6..<10))
    }

    @Test("unverified processing exits 'still processing', never sweeps")
    func stillProcessing() async throws {
        let data = Data(repeating: 6, count: 4)
        let dir = try MediaFixtures.stagedDir(["en-GB/APP_IPHONE_67/1.png": data], under: root)
        let staged = try MediaSource.scan(root: dir)
        let (asc, _) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                .json(.created, """
                {"data":\(MediaFixtures.screenshotSetJSON),"links":{"self":"x"}}
                """),
                .json(.ok, MediaFixtures.screenshotsJSON("")),
                .json(.created, MediaFixtures.reservationJSON(id: "A1", name: "1.png", ops: MediaFixtures.uploadOp)),
                .respond(HTTPResponse(status: .ok), body: nil),
                .json(.ok, MediaFixtures.reservationJSON(id: "A1", name: "1.png", ops: "")),
                .json(.ok, MediaFixtures.screenshotsJSON(
                    MediaFixtures.screenshotRow("A1", name: "1.png", assetState: "UPLOAD_COMPLETE"))),
            ]
        )
        var p = pusher(asc)
        p.settleDeadline = 0  // deadline already passed → the first poll decides
        let results = try await p.push(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        #expect(results[0].outcome == .processing)
        #expect(results[0].detail.contains("media status"))
    }

    @Test("a FAILED asset fails the set")
    func failedAsset() async throws {
        let data = Data(repeating: 8, count: 4)
        let dir = try MediaFixtures.stagedDir(["en-GB/APP_IPHONE_67/1.png": data], under: root)
        let staged = try MediaSource.scan(root: dir)
        let (asc, _) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                .json(.created, """
                {"data":\(MediaFixtures.screenshotSetJSON),"links":{"self":"x"}}
                """),
                .json(.ok, MediaFixtures.screenshotsJSON("")),
                .json(.created, MediaFixtures.reservationJSON(id: "A1", name: "1.png", ops: MediaFixtures.uploadOp)),
                .respond(HTTPResponse(status: .ok), body: nil),
                .json(.ok, MediaFixtures.reservationJSON(id: "A1", name: "1.png", ops: "")),
                .json(.ok, MediaFixtures.screenshotsJSON(
                    MediaFixtures.screenshotRow("A1", name: "1.png", assetState: "FAILED"))),
            ]
        )
        let results = try await pusher(asc).push(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        #expect(results[0].outcome == .failed)
    }

    @Test("set at cap frees a slot only by deleting a doomed row first")
    func capSacrifice() async throws {
        let data = Data(repeating: 4, count: 4)
        let dir = try MediaFixtures.stagedDir(["en-GB/IPHONE_67/new.mp4": data], under: root)
        let staged = try MediaSource.scan(root: dir)
        let md5 = MediaFixtures.md5(data)
        let threeRows = [
            MediaFixtures.previewRow("P_A", name: "a.mp4"),
            MediaFixtures.previewRow("P_B", name: "b.mp4"),
            MediaFixtures.previewRow("P_C", name: "c.mp4"),
        ].joined(separator: ",")
        let (asc, transport) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                .json(.created, """
                {"data":\(MediaFixtures.previewSetJSON),"links":{"self":"x"}}
                """),
                .json(.ok, MediaFixtures.previewsJSON(threeRows)),
                // victim delete (cap pressure) — P_A goes first
                .respond(HTTPResponse(status: .noContent), body: nil),
                .json(.created, MediaFixtures.previewReservationJSON(id: "P1", name: "new.mp4", ops: MediaFixtures.uploadOp)),
                .respond(HTTPResponse(status: .ok), body: nil),
                .json(.ok, """
                {"data":\(MediaFixtures.previewRow("P1", name: "new.mp4", checksum: md5)),"links":{"self":"x"}}
                """),
                // settle poll → new row complete (P_A is gone); sweep deletes the rest
                .json(.ok, MediaFixtures.previewsJSON([
                    MediaFixtures.previewRow("P_B", name: "b.mp4"),
                    MediaFixtures.previewRow("P_C", name: "c.mp4"),
                    MediaFixtures.previewRow("P1", name: "new.mp4", checksum: md5),
                ].joined(separator: ","))),
                .respond(HTTPResponse(status: .noContent), body: nil),
                .respond(HTTPResponse(status: .noContent), body: nil),
                // reorder PATCH after the sweep
                .respond(HTTPResponse(status: .noContent), body: nil),
            ]
        )
        let results = try await pusher(asc).push(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest, staged: staged
        )
        #expect(results[0].outcome == .pushed)
        #expect(results[0].deleted.sorted().joined(separator: ",") == "a.mp4,b.mp4,c.mp4")
        let exchanges = await transport.exchanges
        let deletes = exchanges.filter { $0.request.method == .delete }
        #expect(deletes.count == 3)
    }
}

@Suite("MediaStatus over a scripted transport")
struct MediaStatusTests {
    @Test("status lists each localization's sets with per-asset delivery states")
    func report() async throws {
        let (asc, _) = try MediaFixtures.connect(
            MediaFixtures.targetReads + [
                .json(.ok, MediaFixtures.screenshotSetsJSON(MediaFixtures.screenshotSetJSON)),
                .json(.ok, MediaFixtures.screenshotsJSON([
                    MediaFixtures.screenshotRow("A1", name: "1.png", checksum: "abc"),
                    MediaFixtures.screenshotRow("A2", name: "2.png", assetState: "UPLOAD_COMPLETE"),
                ].joined(separator: ","))),
                .json(.ok, MediaFixtures.previewSetsJSON(MediaFixtures.previewSetJSON)),
                .json(.ok, MediaFixtures.previewsJSON(
                    MediaFixtures.previewRow("P1", name: "rolls.mp4", videoState: "PROCESSING"))),
            ]
        )
        let report = try await MediaStatus(asc: asc).report(
            appID: "APP1", bundleId: nil, platform: "IOS", selector: .latest
        )
        #expect(report.versionString == "1.2.2")
        #expect(report.locales.count == 1)
        let loc = try #require(report.locales.first)
        #expect(loc.locale == "en-GB")
        #expect(loc.sets.map(\.rawType) == ["APP_IPHONE_67", "IPHONE_67"])
        #expect(loc.sets[0].rows.map(\.fileName) == ["1.png", "2.png"])
        #expect(loc.sets[0].rows[1].statePair.asset == "UPLOAD_COMPLETE")
        #expect(loc.sets[1].rows[0].statePair.video == "PROCESSING")
    }
}

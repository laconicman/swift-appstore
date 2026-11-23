import Foundation
import Testing
@testable import asc
@testable import AppStoreWorkflow

@Suite("asc argument handling")
struct ASCMainTests {
    /// An optional config is one that may be *absent* — a present file that fails
    /// decoding (a typo'd key) must surface, not silently decode to nil.
    @Test("optional config: absent file is nil, broken file throws")
    func optionalConfigAbsentVsBroken() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("asc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var args = Arguments(command: .validate)
        args.configPath = "asc.json"
        #expect(try args.configuration(relativeTo: dir, required: false) == nil)

        try #"{"locle": ["en-US"]}"#.write(
            to: dir.appendingPathComponent("asc.json"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            _ = try args.configuration(relativeTo: dir, required: false)
        }
    }

    /// The media verb is positional and consumed before the flags — an absent,
    /// flag-shaped, or unknown verb is a usage error thrown before asc.json is
    /// read, so `asc media --help` prints help with no config present (#36).
    @Test("media verb is validated before config loads")
    func mediaVerbPrecedesConfig() async throws {
        for argv in [["media"], ["media", "--help"], ["media", "bogus"]] {
            let args = try Arguments.parse(argv[...])
            let error = await #expect(throws: WorkflowError.self) {
                _ = try await ASC.run(args)
            }
            guard case .usage? = error else {
                Issue.record("expected .usage for \(argv), got \(String(describing: error))")
                continue
            }
        }
        // A real verb passes the guard and reaches config loading — no asc.json
        // in the package root, so the failure is misconfigured, never usage.
        let args = try Arguments.parse(["media", "push"][...])
        let error = await #expect(throws: WorkflowError.self) {
            _ = try await ASC.run(args)
        }
        guard case .misconfigured? = error else {
            Issue.record("media push must reach config loading, got \(String(describing: error))")
            return
        }
    }
}

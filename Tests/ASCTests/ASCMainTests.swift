import Foundation
import Testing
@testable import asc

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
}

import Foundation
import Testing
@testable import asc_spec_tool

/// The `reviewAtSpec` watermark + "new since pin" digest — adopted from the asc-mcp
/// field trial: a spec bump must isolate "operations newly joining a tier" from
/// generic spec churn.
@Suite("Spec manifest watermarks")
struct SpecToolTests {
    /// Two spec docs: v1 ships ops A+B, v2 adds op C tagged `ReleaseTag`.
    func spec(version: String, ops: [(id: String, tag: String)]) throws -> SpecDocument {
        var paths: [String: Any] = [:]
        for op in ops {
            paths["/v1/\(op.id)"] = [
                "get": ["operationId": op.id, "tags": [op.tag], "responses": ["200": [:]]],
            ]
        }
        let doc: [String: Any] = [
            "openapi": "3.0.0",
            "info": ["version": version],
            "paths": paths,
        ]
        return SpecDocument(root: doc)
    }

    func configYAML(tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("openapi-generator-config.yaml")
        try "generate: [types]\nfilter:\n  tags: [\(tag)]\n".write(
            to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func digestReportsNewlySelectedOperations() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfgURL = dir.appendingPathComponent(ASCSpecTool.tierConfigs[0].file)
        try "generate: [types]\nfilter:\n  tags: [ReleaseTag]\n".write(
            to: cfgURL, atomically: true, encoding: .utf8)

        let v2 = try spec(version: "4.5", ops: [
            ("opA", "ReleaseTag"), ("opB", "Other"), ("opC", "ReleaseTag"),
        ])
        let previous = SpecManifest(
            specVersion: "4.4.1", openAPIVersion: "3.0.0", source: "x", downloadedAt: "d",
            upstream: .init(file: "u", sha256: "s", paths: 2, operations: 2, schemas: 0),
            vendored: .init(file: "v", sha256: "s", normalizations: .init(emptyEnumsDropped: 0)),
            tiers: [.init(name: "release", config: ASCSpecTool.tierConfigs[0].file,
                          operations: 1, operationIDs: ["opA"], reviewedAtSpec: "4.4.1")]
        )
        let lines = ASCSpecTool.tierDigest(previous: previous, candidate: v2, configDir: dir)
        #expect(lines.contains { $0.contains("+1") && $0.contains("4.4.1") })
        #expect(lines.contains { $0.contains("+ opC") })
        #expect(!lines.contains { $0.contains("opB") })
    }

    @Test func unpinnedTierReportsNoWatermark() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfgURL = dir.appendingPathComponent(ASCSpecTool.tierConfigs[0].file)
        try "generate: [types]\nfilter:\n  tags: [ReleaseTag]\n".write(
            to: cfgURL, atomically: true, encoding: .utf8)
        let v2 = try spec(version: "4.5", ops: [("opA", "ReleaseTag")])
        let lines = ASCSpecTool.tierDigest(previous: nil, candidate: v2, configDir: dir)
        #expect(lines.contains { $0.contains("no operation pin") })
    }

    @Test func unchangedTierProducesNoDigestLine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfgURL = dir.appendingPathComponent(ASCSpecTool.tierConfigs[0].file)
        try "generate: [types]\nfilter:\n  tags: [ReleaseTag]\n".write(
            to: cfgURL, atomically: true, encoding: .utf8)
        let v2 = try spec(version: "4.5", ops: [("opA", "ReleaseTag"), ("opB", "Other")])
        let previous = SpecManifest(
            specVersion: "4.4.1", openAPIVersion: "3.0.0", source: "x", downloadedAt: "d",
            upstream: .init(file: "u", sha256: "s", paths: 2, operations: 2, schemas: 0),
            vendored: .init(file: "v", sha256: "s", normalizations: .init(emptyEnumsDropped: 0)),
            tiers: [.init(name: "release", config: ASCSpecTool.tierConfigs[0].file,
                          operations: 1, operationIDs: ["opA"], reviewedAtSpec: "4.4.1")]
        )
        let lines = ASCSpecTool.tierDigest(previous: previous, candidate: v2, configDir: dir)
        #expect(lines.isEmpty || lines.allSatisfy { !$0.contains("release:") })
    }
}

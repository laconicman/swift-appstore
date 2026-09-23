import Foundation

/// A parsed OpenAPI JSON document with the handful of queries and rewrites the tool needs.
///
/// Apple publishes JSON, so this is built on `JSONSerialization` rather than Yams: it round-trips
/// the document losslessly (the spec contains only strings, integers and booleans — no floats,
/// no nulls — verified against v4.5) and `.sortedKeys` makes the written file deterministic, so
/// the vendored sha256 only changes when the content does.
struct SpecDocument {
    static let httpMethods: Set<String> = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    let root: [String: Any]

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["openapi"] != nil, object["paths"] != nil
        else { throw ToolError.couldNotParse("document") }
        root = object
    }

    init(root: [String: Any]) {
        self.root = root
    }

    // MARK: Queries

    var version: String { (root["info"] as? [String: Any])?["version"] as? String ?? "unknown" }
    var openAPIVersion: String { root["openapi"] as? String ?? "unknown" }
    var paths: [String: Any] { root["paths"] as? [String: Any] ?? [:] }
    var schemas: [String: Any] { ((root["components"] as? [String: Any])?["schemas"] as? [String: Any]) ?? [:] }

    var pathCount: Int { paths.count }
    var schemaCount: Int { schemas.count }
    var operationCount: Int { operations.count }

    /// Every operation keyed by `operationId`, with the path/method it lives at and its
    /// canonical JSON so two spec versions can be compared operation by operation.
    var operations: [String: Operation] {
        var result: [String: Operation] = [:]
        for (path, item) in paths {
            guard let item = item as? [String: Any] else { continue }
            for (method, operation) in item where Self.httpMethods.contains(method) {
                guard let operation = operation as? [String: Any] else { continue }
                let id = operation["operationId"] as? String ?? "\(method.uppercased()) \(path)"
                result[id] = Operation(
                    id: id,
                    method: method.uppercased(),
                    path: path,
                    tags: operation["tags"] as? [String] ?? [],
                    canonical: Self.canonicalJSON(operation)
                )
            }
        }
        return result
    }

    struct Operation {
        let id: String
        let method: String
        let path: String
        let tags: [String]
        let canonical: String
    }

    // MARK: Normalization

    struct NormalizationStats {
        var emptyEnumsDropped = 0
    }

    /// Applies the rewrites `swift-openapi-generator` needs to produce compilable Swift.
    ///
    /// 1. Empty enums — `"enum": []` on a string schema makes the generator emit a Swift enum
    ///    with no cases and a `String` raw type, which does not compile. Dropping the `enum` key
    ///    leaves a plain `string` — the only faithful reading of "no allowed values are listed".
    ///    Idempotent: a spec with no empty enums passes through untouched.
    func normalized() -> (SpecDocument, NormalizationStats) {
        var stats = NormalizationStats()
        let rewritten = Self.normalizeValue(root, stats: &stats) as? [String: Any] ?? root
        return (SpecDocument(root: rewritten), stats)
    }

    private static func normalizeValue(_ value: Any, stats: inout NormalizationStats) -> Any {
        switch value {
        case let map as [String: Any]:
            var result: [String: Any] = [:]
            for (key, child) in map {
                if key == "enum", let values = child as? [Any], values.isEmpty {
                    stats.emptyEnumsDropped += 1
                    continue
                }
                result[key] = normalizeValue(child, stats: &stats)
            }
            return result
        case let array as [Any]:
            return array.map { normalizeValue($0, stats: &stats) }
        default:
            return value
        }
    }

    // MARK: Serialization

    func serialized() throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(UInt8(ascii: "\n"))
        return data
    }

    static func canonicalJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

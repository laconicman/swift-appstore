import Foundation
import Yams

/// The `filter` section of a `swift-openapi-generator` config, evaluated against a spec the
/// same way the generator does (operation IDs ∪ tags ∪ paths, a union), so the manifest can
/// report how many operations each tier actually generates.
struct GeneratorConfig {
    let operations: Set<String>
    let tags: Set<String>
    let paths: Set<String>
    let hasFilter: Bool

    init(contentsOf url: URL) throws {
        let yaml = try String(contentsOf: url, encoding: .utf8)
        guard let root = try Yams.compose(yaml: yaml) else {
            throw ToolError.couldNotParse(url.lastPathComponent)
        }
        let filter = root["filter"]
        hasFilter = filter != nil
        operations = Self.strings(filter?["operations"])
        tags = Self.strings(filter?["tags"])
        paths = Self.strings(filter?["paths"])
    }

    /// The operation ids the filter selects — the union the generator uses.
    func selectedOperations(in document: SpecDocument) -> Set<String> {
        guard hasFilter else { return Set(document.operations.keys) }
        return Set(document.operations.values.filter { operation in
            operations.contains(operation.id)
                || paths.contains(operation.path)
                || operation.tags.contains(where: tags.contains)
        }.map(\.id))
    }

    func selectedOperationCount(in document: SpecDocument) -> Int {
        selectedOperations(in: document).count
    }

    private static func strings(_ node: Node?) -> Set<String> {
        guard case .sequence(let sequence)? = node else { return [] }
        return Set(sequence.compactMap(\.string))
    }
}

import Foundation

/// Operation-level diff between two spec documents: what Apple added, removed, or changed
/// since the vendored copy. "Changed" compares the operation's canonical JSON, so a new query
/// parameter, a retyped response, or an edited description all count — the maintainer decides
/// which matter by reading the generated diff after re-vendoring.
struct DriftReport {
    let added: [SpecDocument.Operation]
    let removed: [SpecDocument.Operation]
    let changed: [SpecDocument.Operation]
    let schemasAdded: [String]
    let schemasRemoved: [String]
    let schemasChanged: [String]

    init(from old: SpecDocument, to new: SpecDocument) {
        let oldOps = old.operations
        let newOps = new.operations
        added = newOps.filter { oldOps[$0.key] == nil }.values.sorted { $0.id < $1.id }
        removed = oldOps.filter { newOps[$0.key] == nil }.values.sorted { $0.id < $1.id }
        changed = newOps.compactMap { id, op in
            guard let before = oldOps[id], before.canonical != op.canonical else { return nil }
            return op
        }.sorted { $0.id < $1.id }

        let oldSchemas = old.schemas
        let newSchemas = new.schemas
        schemasAdded = newSchemas.keys.filter { oldSchemas[$0] == nil }.sorted()
        schemasRemoved = oldSchemas.keys.filter { newSchemas[$0] == nil }.sorted()
        schemasChanged = newSchemas.compactMap { name, schema in
            guard let before = oldSchemas[name],
                  SpecDocument.canonicalJSON(before) != SpecDocument.canonicalJSON(schema)
            else { return nil }
            return name
        }.sorted()
    }

    var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
            && schemasAdded.isEmpty && schemasRemoved.isEmpty && schemasChanged.isEmpty
    }

    func rendered(fromVersion: String, toVersion: String) -> String {
        var lines = ["Drift: vendored \(fromVersion) → downloaded \(toVersion)"]
        if isEmpty {
            lines.append("  no changes")
            return lines.joined(separator: "\n")
        }
        lines.append("  operations: +\(added.count) −\(removed.count) ~\(changed.count)")
        lines.append("  schemas:    +\(schemasAdded.count) −\(schemasRemoved.count) ~\(schemasChanged.count)")
        lines += added.map { "  + \($0.id)  \($0.method) \($0.path)" }
        lines += removed.map { "  − \($0.id)  \($0.method) \($0.path)" }
        lines += changed.map { "  ~ \($0.id)  \($0.method) \($0.path)" }
        return lines.joined(separator: "\n")
    }
}

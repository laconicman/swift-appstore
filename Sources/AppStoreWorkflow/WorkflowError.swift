import Foundation

public enum WorkflowError: Error, CustomStringConvertible {
    case misconfigured(String)
    case notFound(String)
    case ambiguous(String)
    case api(operation: String, detail: String)
    case conflict([String])
    case blocked([String])
    case notEditable([String])
    case invalid([String])
    case usage(String)

    public var description: String {
        switch self {
        case .misconfigured(let what): "misconfigured: \(what)"
        case .notFound(let what): "not found: \(what)"
        case .ambiguous(let what): "ambiguous: \(what)"
        case .api(let operation, let detail): "\(operation) failed: \(detail)"
        case .conflict(let lines): "remote changed since the last pull — re-run `asc pull`, or pass --force:\n  \(lines.joined(separator: "\n  "))"
        case .blocked(let lines): "refusing to clear fields (pass --allow-clear to permit):\n  \(lines.joined(separator: "\n  "))"
        case .notEditable(let lines): "target is not in an editable state:\n  \(lines.joined(separator: "\n  "))"
        case .invalid(let lines): "validation failed:\n  \(lines.joined(separator: "\n  "))"
        case .usage(let what): what
        }
    }
}

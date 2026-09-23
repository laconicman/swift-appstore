#if !canImport(Darwin)
/// Stand-in for `OSLogLoggingMiddleware.BodyLoggingPolicy`, whose module compiles to nothing off
/// Apple platforms (it is `#if canImport(Darwin)`-guarded upstream). Keeps
/// ``AppStoreConnect/init(key:serverURL:retryPolicy:bodyLoggingPolicy:transport:)`` source-compatible
/// on Linux, where no logging middleware is installed and the value is ignored.
public enum BodyLoggingPolicy: Sendable {
    case never
    case upTo(maxBytes: Int)
}
#endif

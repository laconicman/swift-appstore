import Foundation
import OpenAPIRuntime

/// Decodes the `date-time` strings App Store Connect returns, which are ISO-8601 with a numeric
/// UTC offset and sometimes fractional seconds (e.g. `2024-06-25T08:00:00-07:00`,
/// `2024-06-25T15:00:00.000+00:00`). The runtime's `.iso8601` transcoder rejects the fractional
/// form and `.iso8601WithFractionalSeconds` rejects the plain one, so — exactly as
/// `GitLabDateTranscoder` does for GitLab — this one accepts both.
///
/// Claims discipline: the accepted formats are *reasoned* from the spec's `date-time` fields and
/// the formats seen in Apple's documentation samples, not verified against live responses in
/// this repository (CI never calls App Store Connect).
public struct AppStoreConnectDateTranscoder: DateTranscoder {
    public init() {}

    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    public func decode(_ string: String) throws -> Date {
        if let date = try? Self.isoFractional.parse(string) { return date }
        if let date = try? Self.isoPlain.parse(string) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Expected an ISO-8601 date, received '\(string)'.")
        )
    }

    public func encode(_ date: Date) throws -> String {
        Self.isoPlain.format(date)
    }
}

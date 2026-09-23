import Crypto
import Foundation

/// Gets `openapi.oas.json` out of Apple's distribution zip. Foundation has no zip reader on
/// Linux, so this shells out to `unzip -p`, which is present on macOS and on GitHub's
/// `ubuntu-latest` runners alike. A bare `.json` path is accepted as-is for offline runs.
enum SpecArchive {
    static func specData(fromZipData zipData: Data) throws -> Data {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("asc-spec-\(UUID().uuidString).zip")
        try zipData.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try specData(fromZipAt: temporary)
    }

    static func specData(fromFileAt url: URL) throws -> Data {
        url.pathExtension.lowercased() == "zip"
            ? try specData(fromZipAt: url)
            : try Data(contentsOf: url)
    }

    private static func specData(fromZipAt url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["unzip", "-p", url.path, ASCSpecTool.upstreamFileName]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError.unzipFailed(process.terminationStatus) }
        guard !data.isEmpty else { throw ToolError.specNotInArchive(ASCSpecTool.upstreamFileName) }
        return data
    }
}

extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

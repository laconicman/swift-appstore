import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One file staged under `<source>/<locale>/<TYPE>/`.
public struct StagedFile: Sendable, Equatable {
    public var fileName: String
    public var url: URL
    public var fileSize: Int

    /// md5 hex — the checksum the PATCH step reports as `sourceFileChecksum`.
    public func checksum() throws -> String {
        Insecure.MD5.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func read() throws -> Data { try Data(contentsOf: url) }
}

/// One staged `<locale>/<TYPE>/` directory after validation.
public struct StagedSet: Sendable, Equatable {
    public var locale: String
    public var type: MediaSetType
    /// Upload order — `sorted()` by file name; order within a set is display order.
    public var files: [StagedFile]
}

/// The whole `--source` tree, scanned and validated before any network call.
public struct StagedMedia: Sendable {
    /// Locale code → sets, sorted by `MediaSetType.rawValue` for deterministic output.
    public var sets: [String: [StagedSet]]

    public var locales: [String] { sets.keys.sorted() }
    public var isEmpty: Bool { sets.isEmpty }
}

/// Turns a staged directory into ``StagedMedia``. Pure filesystem work — no client,
/// so tests exercise it against a temp directory.
public enum MediaSource {
    /// - Parameters:
    ///   - root: The `--source` directory.
    ///   - locales: Optional `--locale` filters; a filter that matches no directory is a
    ///     usage error (a typo'd locale must not silently push nothing).
    /// - Throws: `WorkflowError.invalid` listing every violation found.
    public static func scan(root: URL, locales: [String] = []) throws -> StagedMedia {
        var violations: [String] = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            throw WorkflowError.invalid(["--source \(root.path): no such directory"])
        }

        var wantedLocales = Set(locales)
        for wanted in wantedLocales where !LocaleCodes.isValid(wanted) {
            violations.append("--locale \(wanted): not an App Store Connect locale")
        }

        var sets: [String: [StagedSet]] = [:]
        let localeDirs = (try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
        for locale in localeDirs {
            let localeURL = root.appendingPathComponent(locale)
            guard fm.isDirectory(atPath: localeURL.path) else { continue }
            guard LocaleCodes.isValid(locale) else {
                violations.append("\(locale)/: not an App Store Connect locale")
                continue
            }
            if !wantedLocales.isEmpty, !wantedLocales.contains(locale) { continue }
            wantedLocales.remove(locale)

            let typeDirs = (try? fm.contentsOfDirectory(atPath: localeURL.path))?.sorted() ?? []
            for typeName in typeDirs {
                let typeURL = localeURL.appendingPathComponent(typeName)
                guard fm.isDirectory(atPath: typeURL.path) else { continue }
                guard let type = MediaSetType(rawValue: typeName) else {
                    violations.append("\(locale)/\(typeName)/: unknown set type — must be a screenshotDisplayType or previewType")
                    continue
                }
                let files = ((try? fm.contentsOfDirectory(atPath: typeURL.path)) ?? [])
                    .sorted()
                    .compactMap { name -> StagedFile? in
                        let fileURL = typeURL.appendingPathComponent(name)
                        guard fm.isDirectory(atPath: fileURL.path) == false else { return nil }
                        guard type.kind.fileExtensions.contains(fileURL.pathExtension.lowercased()) else {
                            violations.append("\(locale)/\(typeName)/\(name): not a \(type.kind.noun) file (\(type.kind.fileExtensions.sorted().joined(separator: ", ")))")
                            return nil
                        }
                        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        return StagedFile(fileName: name, url: fileURL, fileSize: size)
                    }
                if files.isEmpty {
                    violations.append("\(locale)/\(typeName)/: no \(type.kind.noun) files")
                    continue
                }
                // Caps are whole-set refusals, never truncation — port of the Python `sys.exit`.
                if files.count > type.kind.cap {
                    violations.append("\(locale)/\(typeName)/: \(files.count) files, cap is \(type.kind.cap) — refusing the whole set")
                    continue
                }
                sets[locale, default: []].append(StagedSet(locale: locale, type: type, files: files))
            }
        }
        for missing in wantedLocales.sorted() {
            violations.append("--locale \(missing): no directory under --source")
        }
        guard violations.isEmpty else { throw WorkflowError.invalid(violations) }
        for key in sets.keys {
            sets[key]?.sort { $0.type.rawValue < $1.type.rawValue }
        }
        return StagedMedia(sets: sets)
    }
}

private extension FileManager {
    func isDirectory(atPath path: String) -> Bool {
        var isDir = ObjCBool(false)
        return fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

import Foundation

/// The local metadata tree after reading a fastlane-layout `metadata/` directory.
public struct MetadataTree: Sendable {
    public var snapshot: ListingSnapshot
    /// Relative paths of `.txt` files that matched no catalog field — reported, never touched.
    /// A typo'd `desciption.txt` must be visible instead of silently dropped.
    public var unknownFiles: [String]
    /// Relative paths skipped because they carry credentials (`demo_password.txt`).
    public var ignoredFiles: [String]

    public init(snapshot: ListingSnapshot, unknownFiles: [String] = [], ignoredFiles: [String] = []) {
        self.snapshot = snapshot
        self.unknownFiles = unknownFiles
        self.ignoredFiles = ignoredFiles
    }
}

/// Reads and writes the fastlane `metadata/` interchange layout.
///
/// Normalization is exactly one trailing newline, matching `deliver`: files are written with a
/// single `\n` terminator and reads strip a single `\n`. Values compare byte-for-byte beyond
/// that — internal whitespace is preserved and significant.
public enum MetadataStore {
    /// Loads the tree under `root`. A missing root yields an empty tree (first `asc pull`
    /// creates it); unreadable files throw.
    public static func load(root: URL) throws -> MetadataTree {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return MetadataTree(snapshot: ListingSnapshot())
        }
        var snapshot = ListingSnapshot()
        var unknown: [String] = []
        var ignored: [String] = []

        for field in ListingField.sharedFields {
            let url = root.appendingPathComponent(field.filePath)
            if let value = try readFile(url) { snapshot.shared[field] = value }
        }
        // Root-level .txt files that match no shared field are reported too — a typo'd
        // `copywrite.txt` at the root must be as visible as one inside a locale dir.
        try unknownTextFiles(
            in: root, rootPrefix: "",
            known: Set(ListingField.sharedFields.map(\.filePath).filter { !$0.contains("/") }),
            unknown: &unknown, ignored: &ignored
        )

        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        for entry in entries where entry.isDirectory {
            let name = entry.lastPathComponent
            if name == "review_information" {
                try scanReviewDir(entry, rootName: name, snapshot: &snapshot, unknown: &unknown, ignored: &ignored)
            } else {
                var values: FieldValues = [:]
                for field in ListingField.localizedFields {
                    if let value = try readFile(entry.appendingPathComponent(field.filePath)) {
                        values[field] = value
                    }
                }
                if !values.isEmpty { snapshot.localized[name] = values }
                try unknownTextFiles(in: entry, rootPrefix: name, known: Set(ListingField.localizedFields.map(\.filePath)),
                                     unknown: &unknown, ignored: &ignored)
            }
        }
        return MetadataTree(snapshot: snapshot, unknownFiles: unknown.sorted(), ignoredFiles: ignored.sorted())
    }

    /// Writes every non-nil value in `snapshot` under `root`, one file per field, each ending
    /// in exactly one newline. Returns the relative paths written, sorted.
    @discardableResult
    public static func write(_ snapshot: ListingSnapshot, to root: URL) throws -> [String] {
        var written: [String] = []
        for field in ListingField.sharedFields {
            guard let value = snapshot.shared[field] else { continue }
            try writeFile(root.appendingPathComponent(field.filePath), value: value)
            written.append(field.filePath)
        }
        for (locale, values) in snapshot.localized {
            let dir = root.appendingPathComponent(locale)
            for (field, value) in values {
                try writeFile(dir.appendingPathComponent(field.filePath), value: value)
                written.append("\(locale)/\(field.filePath)")
            }
        }
        return written.sorted()
    }

    /// After `write`, removes catalog files whose field has no value in `snapshot` — the
    /// remote side removed them, so the local tree must converge rather than keep stale
    /// metadata that `diff` would then try to re-upload.
    ///
    /// A file is only deleted when the baseline proves it is untouched: its content digest
    /// equals what the last pull recorded. A locally-edited stale file (or one with no
    /// baseline) is kept and reported so the owner decides. Unknown `.txt` files are never
    /// touched — the catalog doesn't own them.
    ///
    /// Returns the relative paths that were removed and the stale ones that were kept.
    @discardableResult
    public static func reconcile(
        _ snapshot: ListingSnapshot, baseline: Baseline?, at root: URL
    ) throws -> (removed: [String], keptStale: [String]) {
        let fm = FileManager.default
        var removed: [String] = []
        var kept: [String] = []

        func reconcileFile(_ url: URL, path: String, present: Bool) throws {
            guard !present, fm.fileExists(atPath: url.path) else { return }
            let untouched = baseline?.digests[path].map({ expected in
                (try? readFile(url)).map { Baseline.digest(of: $0) == expected } ?? false
            }) ?? false
            if untouched {
                try fm.removeItem(at: url)
                removed.append(path)
            } else {
                kept.append(path)
            }
        }

        for field in ListingField.sharedFields {
            try reconcileFile(root.appendingPathComponent(field.filePath),
                              path: field.filePath,
                              present: snapshot.shared[field] != nil)
        }
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries where entry.isDirectory {
            let locale = entry.lastPathComponent
            guard locale != "review_information" else { continue }
            let liveValues = snapshot.localized[locale] ?? [:]
            for field in ListingField.localizedFields {
                try reconcileFile(entry.appendingPathComponent(field.filePath),
                                  path: "\(locale)/\(field.filePath)",
                                  present: liveValues[field] != nil)
            }
        }
        return (removed.sorted(), kept.sorted())
    }

    /// Reads a file as UTF-8 and strips exactly one trailing newline. Missing file → `nil`.
    public static func readFile(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
    }

    static func writeFile(_ url: URL, value: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (value + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func scanReviewDir(
        _ dir: URL, rootName: String, snapshot: inout ListingSnapshot, unknown: inout [String], ignored: inout [String]
    ) throws {
        let reviewFields = ListingField.sharedFields.filter { $0.filePath.hasPrefix("review_information/") }
        let known = Set(reviewFields.map { String($0.filePath.dropFirst("review_information/".count)) })
        for field in reviewFields {
            if let value = try readFile(dir.appendingPathComponent(String(field.filePath.dropFirst("review_information/".count)))) {
                snapshot.shared[field] = value
            }
        }
        try unknownTextFiles(in: dir, rootPrefix: rootName, known: known, unknown: &unknown, ignored: &ignored)
    }

    private static func unknownTextFiles(
        in dir: URL, rootPrefix: String, known: Set<String>, unknown: inout [String], ignored: inout [String]
    ) throws {
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            guard file.hasSuffix(".txt") else { continue }
            let path = rootPrefix.isEmpty ? file : "\(rootPrefix)/\(file)"
            if ListingField.sensitiveFileNames.contains(file) {
                ignored.append(path)
            } else if !known.contains(file) {
                unknown.append(path)
            }
        }
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

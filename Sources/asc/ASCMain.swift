import Foundation
import AppStoreKit
import AppStoreWorkflow

/// `asc` — App Store Connect metadata workflow over a fastlane-layout `metadata/` tree.
///
/// Commands:
///   asc pull        live ASC state → metadata files + .asc-baseline.json
///   asc diff        three-way diff: local vs live vs last-pull baseline (read-only)
///   asc apply       apply the diff's deltas; prints the plan, writes only with --yes
///   asc validate    offline checks: field limits, locale codes, required fields
///   asc preflight   archive checks: MinimumOSVersion floor, version/build consistency,
///                   PrivacyInfo.xcprivacy per bundle, build-number reuse
///   asc questionnaire  evidence-cited questionnaire answer sheets (local-only, no credentials)
///
/// Credentials come from the config or ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH — by path only.
/// Writes to App Store Connect require `--yes`; submission and release are never touched.
@main
enum ASC {
    static func main() async {
        // Exit, not throw — a thrown error from top-level main is a fatal trap, not a
        // clean non-zero exit.
        do {
            let args = try Arguments.parse(CommandLine.arguments.dropFirst())
            try await run(args)
        } catch is SilentFailure {
            exit(1)
        } catch let error as WorkflowError {
            if case .usage = error {
                FileHandle.standardError.write(Data("\(error)\n\n\(Arguments.help)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("error: \(Redactor.redact("\(error)"))\n".utf8))
            }
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(Redactor.redact("\(error)"))\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: Arguments) async throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        switch args.command {
        case .pull, .diff, .apply:
            let config = try args.requiredConfiguration(relativeTo: cwd)
            let asc = try AppStoreConnect(key: config.resolvedAPIKey())
            let puller = ListingPuller(asc: asc)
            let live = try await puller.pull(
                appID: config.appId, bundleId: config.bundleId,
                platform: config.platformValue, version: args.versionSelector
            )
            let root = try args.metadataRoot(relativeTo: cwd, config: config)
            switch args.command {
            case .pull: try pull(live: live, to: root)
            case .diff: try diff(live: live, root: root)
            case .apply: try await apply(live: live, root: root, asc: asc, options: args.applyOptions, confirmed: args.yes)
            default: break
            }
        case .validate:
            let config = try args.requiredConfiguration(relativeTo: cwd)
            let root = try args.metadataRoot(relativeTo: cwd, config: config)
            try validate(root: root, config: config)
        case .preflight:
            try await preflight(args: args, cwd: cwd)
        case .questionnaire:
            try questionnaire(args: args, cwd: cwd)
        case .submit:
            let config = try args.requiredConfiguration(relativeTo: cwd)
            let asc = try AppStoreConnect(key: config.resolvedAPIKey())
            try await submit(args: args, config: config, asc: asc)
        }
    }

    // MARK: - Commands

    static func pull(live: LiveListing, to root: URL) throws {
        let previousBaseline = try Baseline.load(root: root)
        let written = try MetadataStore.write(live.values, to: root)
        // Converge the tree to live state: files the remote no longer has are removed —
        // unless locally edited since the last pull, which are kept and reported.
        let reconcile = try MetadataStore.reconcile(live.values, baseline: previousBaseline, at: root)
        var newBaseline = live.makeBaseline()
        newBaseline.carryDigests(from: previousBaseline, for: reconcile.keptStale)
        try newBaseline.write(to: root)
        print("pulled \(live.app.bundleId) \(live.version.versionString) (\(live.version.appStoreState))")
        print("  appInfo \(live.appInfo.id) (\(live.appInfo.appStoreState ?? "unknown state"))")
        print("  \(written.count) files → \(root.path)")
        for path in written { print("    \(path)") }
        for path in reconcile.removed { print("    - \(path) (removed — no longer on App Store Connect)") }
        for path in reconcile.keptStale {
            print("    ! \(path) (remote value gone but file has local edits — kept; delete or keep deliberately)")
        }
        print("    \(Baseline.fileName)")
        if live.demoAccountRequired == true {
            print("  note: demo account is set upstream; the password is never exported — manage it in App Store Connect")
        }
    }

    /// Hard-fails when the baseline belongs to a different app, surfaces version/appInfo drift
    /// as notes. The checks live on `Baseline` so the workflow suite covers them.
    static func checkBaseline(_ baseline: Baseline, live: LiveListing) throws {
        if let violation = baseline.identityViolation(against: live) {
            throw WorkflowError.misconfigured(violation)
        }
        for note in baseline.identityNotes(against: live) { print("  note: \(note)") }
    }

    /// Local-only: scans the app project for evidence, renders the four questionnaire
    /// sheets, writes them under `--out` (contained in the working directory). No network,
    /// no credentials — every answer cites the file it came from or stays open.
    static func questionnaire(args: Arguments, cwd: URL) throws {
        let config = try args.configuration(relativeTo: cwd, required: false)
        let sourcePath = args.source ?? config?.appSource
        guard let sourcePath else {
            throw WorkflowError.misconfigured(
                "no app source — pass --source <dir> or set `appSource` in asc.json")
        }
        let source = URL(fileURLWithPath: (sourcePath as NSString).expandingTildeInPath, relativeTo: cwd)
        // Contain first (rejects ../ escapes), then create, then contain again — once the
        // leaf exists, realpath resolves a symlink planted at the output path.
        let candidate = URL(fileURLWithPath: args.out ?? "questionnaires", relativeTo: cwd)
        _ = try ASCConfiguration.contained(candidate, under: cwd)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let outDir = try ASCConfiguration.contained(candidate, under: cwd)
        let evidence = try EvidenceScan.scan(root: source)
        let sheets = Questionnaire.sheets(for: evidence)
        let report = try SheetStore.write(sheets, to: outDir)
        for sheet in sheets {
            let open = sheet.openCount
            print("\(sheet.fileName): \(sheet.items.count - open) answered, \(open) open")
        }
        for f in report.added { print("  + \(f)") }
        for f in report.changed { print("  ~ \(f) — answers changed since the last run") }
        print("  \(evidence.filesScanned.count) evidence files from \(source.path)")
    }

    /// `asc submit` stages a review submission — version upsert, build attach, draft +
    /// items — and stops there: `submitted: true` is never sent. Without `--yes` it is a
    /// read-only preview of exactly what staging would do.
    static func submit(args: Arguments, config: ASCConfiguration, asc: AppStoreConnect) async throws {
        var request = SubmissionRequest(
            buildNumber: args.buildNumber,
            iapVersionIDs: args.iapVersionIDs, subscriptionVersionIDs: args.subscriptionVersionIDs
        )
        switch args.versionSelector {
        case .exact(let v): request.versionString = v
        // `latest`/`live` are listing selectors — on submit they name nothing; fail loudly.
        case .latest, .live:
            if args.versionProvided {
                throw WorkflowError.usage("--version on submit takes an exact version string, e.g. --version 1.3.0")
            }
        }
        let stager = SubmissionStager(asc: asc)
        let plan = try await stager.plan(
            appID: config.appId, bundleId: config.bundleId,
            platform: config.platformValue, minimumOSVersion: config.minimumOSVersion,
            request: request
        )
        print("submission plan — \(config.bundleId ?? config.appId ?? "?") (\(config.platformValue)):")
        for step in plan.steps { print("  \(step)") }
        for warning in plan.warnings { print("  ! \(warning)") }
        for reason in plan.blockedReasons { print("  ! \(reason)") }
        guard args.yes else {
            print("preview only — re-run with --yes to stage; submission itself stays in App Store Connect")
            return
        }
        if !plan.blockedReasons.isEmpty { throw WorkflowError.invalid(plan.blockedReasons) }
        let result = await stager.stage(plan, request: request)
        for s in result.staged { print("  + \(s)") }
        for s in result.skipped { print("  = \(s)") }
        if let failed = result.failed { throw WorkflowError.api(operation: "submit", detail: failed) }
        if let draftID = result.draftID {
            print("staged on draft \(draftID) — review and submit in App Store Connect")
        }
    }

    static func diff(live: LiveListing, root: URL) throws {
        let local = try MetadataStore.load(root: root)
        let baseline = try Baseline.load(root: root)
        if let baseline { try checkBaseline(baseline, live: live) }
        let diff = ListingDiffer.diff(local: local, live: live, baseline: baseline)
        print(header(for: live))
        print(diffReport(diff))
        for file in local.unknownFiles { print("  ? \(file) — not a known metadata field") }
        for file in local.ignoredFiles { print("  ! \(file) — credential file, ignored") }
        if baseline == nil {
            print("  note: no \(Baseline.fileName) — remote drift since the last pull can't be detected; run `asc pull` first")
        }
    }

    static func apply(live: LiveListing, root: URL, asc: AppStoreConnect, options: ApplyOptions, confirmed: Bool) async throws {
        let local = try MetadataStore.load(root: root)
        // A baseline file from a previous pull enables drift detection; without one the diff
        // treats live as the baseline and every difference is a plain change.
        let storedBaseline = try Baseline.load(root: root)
        if let storedBaseline { try checkBaseline(storedBaseline, live: live) }
        var baseline = storedBaseline ?? live.makeBaseline()
        if storedBaseline == nil {
            print("  warning: no \(Baseline.fileName) — drift since the last pull can't be detected; " +
                  "every difference is treated as a plain change. Run `asc pull` first for full protection.")
        }
        let diff = ListingDiffer.diff(local: local, live: live, baseline: storedBaseline)
        let applier = ListingApplier(asc: asc)
        // plan() gates conflicts/clears/creates, the editable-state check, and field
        // validation over the exact write set — it throws before the first mutation.
        let (writes, planned) = try applier.plan(diff, live: live, options: options)

        print(header(for: live))
        print(diffReport(diff))
        for path in planned.skipped { print("  ~ \(path)") }

        guard !writes.isEmpty else {
            print("nothing to apply — local tree matches live state")
            return
        }
        if !confirmed {
            print("\n\(writes.count) write(s) planned — re-run with --yes to apply:")
            for write in writes { print("    \(write.label)") }
            return
        }
        print("\napplying \(writes.count) write(s)…")
        var result = await applier.apply(writes, baseline: &baseline, live: live)
        result.skipped = planned.skipped
        try baseline.write(to: root)
        for line in result.applied { print("  ✓ \(line)") }
        // Apple may normalize a value on write (trim, re-case). The baseline records the
        // response, so the file must too — otherwise every later diff reports phantom drift.
        if !result.normalized.isEmpty {
            var fixed = ListingSnapshot()
            for (field, locale, value) in result.normalized {
                if let locale { fixed.localized[locale, default: [:]][field] = value }
                else { fixed.shared[field] = value }
            }
            try MetadataStore.write(fixed, to: root)
            for (field, locale, _) in result.normalized {
                print("  ~ \(Baseline.digestKey(field: field, locale: locale)) — file updated to the value App Store Connect stored")
            }
        }
        if let failed = result.failed {
            throw WorkflowError.api(operation: "apply", detail: "\(failed) (\(result.applied.count) write(s) applied before the failure; baseline updated)")
        }
        print("done — baseline updated; a second `asc diff` should be empty")
    }

    static func validate(root: URL, config: ASCConfiguration) throws {
        let local = try MetadataStore.load(root: root)
        let issues = ListingValidator.validate(local: local, expectedLocales: config.locales)
        if issues.isEmpty {
            print("\(root.path): valid — \(local.snapshot.locales.count) locale(s), no issues")
            return
        }
        for issue in issues {
            print("\(issue.severity == .error ? "error" : "warning")  \(issue.path): \(issue.message)")
        }
        if issues.contains(where: { $0.severity == .error }) {
            throw SilentFailure()
        }
    }

    static func preflight(args: Arguments, cwd: URL) async throws {
        guard let target = args.app ?? args.archive else {
            throw WorkflowError.usage("asc preflight needs --app <path.app> or --archive <path.xcarchive>")
        }
        let config = try args.configuration(relativeTo: cwd, required: false)
        guard let floor = args.floor ?? config?.minimumOSVersion else {
            throw WorkflowError.usage("asc preflight needs a deployment floor — --floor X.Y or `minimumOSVersion` in asc.json")
        }
        let url = URL(fileURLWithPath: target, relativeTo: cwd)
        var report = try Preflight.inspect(at: url, floor: floor)

        if args.checkReuse {
            guard let config else {
                throw WorkflowError.misconfigured("--check-reuse needs asc.json with credentials")
            }
            guard let appID = config.appId, !appID.isEmpty else {
                throw WorkflowError.misconfigured("--check-reuse needs `appId` in asc.json")
            }
            let asc = try AppStoreConnect(key: config.resolvedAPIKey())
            let app = report.bundles.first(where: { $0.path.hasSuffix(".app") }) ?? report.bundles[0]
            if let version = app.version, let build = app.build {
                let reused = try await Preflight.buildReuse(
                    asc: asc,
                    appID: appID,
                    version: version, build: build
                )
                if reused { report.findings.append(.buildNumberReused(version: version, build: build)) }
            }
        }

        for bundle in report.bundles {
            print("\(bundle.hasPrivacyManifest ? " " : "!") \(bundle.path)")
            print("    \(bundle.bundleId ?? "?")  v\(bundle.version ?? "?") (\(bundle.build ?? "?"))  minOS \(bundle.minOS ?? "?")")
        }
        if report.ok {
            print("preflight clean — \(report.bundles.count) bundle(s), floor \(floor)")
        } else {
            for finding in report.findings { print("error  \(finding)") }
            throw SilentFailure()
        }
    }

    // MARK: - Output

    static func header(for live: LiveListing) -> String {
        "\(live.app.bundleId) — version \(live.version.versionString) [\(live.version.appStoreState)] · appInfo \(live.appInfo.appStoreState ?? "?")"
    }

    static func diffReport(_ diff: ListingDiff) -> String {
        var lines: [String] = []
        for entry in diff.entries where entry.kind != .unchanged {
            let marker: String = switch entry.kind {
            case .converged: "="   // same value, remote drifted — no write needed
            case .change: "~"
            case .conflict: "!"
            case .blocked: "⊘"
            case .create: "+"
            case .unchanged: " "
            }
            var line = "  \(marker) \(entry.path)"
            if entry.kind == .change || entry.kind == .conflict {
                line += "  (live \(entry.live?.count ?? 0) → local \(entry.local?.count ?? 0) chars)"
            }
            if entry.kind == .blocked {
                line += "  (empty file would clear a live value)"
            }
            lines.append(line)
        }
        for locale in diff.remoteOnlyLocales {
            lines.append("  ? \(locale)/ — exists on App Store Connect but not locally; untouched (no delete path)")
        }
        if lines.isEmpty { lines.append("  (no differences)") }
        return lines.joined(separator: "\n")
    }
}

/// Thrown when the output already said everything; `main` exits non-zero without printing
/// a second error line.
struct SilentFailure: Error {}

/// Command-line parsing — same hand-rolled convention as asc-spec-tool.
struct Arguments {
    enum Command: String { case pull, diff, apply, validate, preflight, questionnaire, submit }
    var command: Command
    var configPath: String = "asc.json"
    var metadata: String?
    var versionSelector: VersionSelector = .latest
    /// True only when `--version` was typed — `.latest` is also the default, so the
    /// selector alone can't tell "flag given" from "flag absent".
    var versionProvided = false
    var yes = false
    var force = false
    var allowClear = false
    var createMissing = false
    var app: String?
    var archive: String?
    var floor: String?
    var checkReuse = false
    /// `asc questionnaire`: app project dir to scan (overrides config `appSource`).
    var source: String?
    /// `asc questionnaire`: output dir for answer sheets (default `questionnaires/`).
    var out: String?
    /// `asc submit`: build number (CFBundleVersion) to attach; nil = newest VALID build.
    var buildNumber: String?
    /// `asc submit`: versioned product ids to co-stage (repeatable flags).
    var iapVersionIDs: [String] = []
    var subscriptionVersionIDs: [String] = []

    var applyOptions: ApplyOptions {
        .init(force: force, allowClear: allowClear, createMissing: createMissing)
    }

    func requiredConfiguration(relativeTo cwd: URL) throws -> ASCConfiguration {
        try ASCConfiguration.load(from: URL(fileURLWithPath: configPath, relativeTo: cwd))
    }

    func configuration(relativeTo cwd: URL, required: Bool) throws -> ASCConfiguration? {
        let url = URL(fileURLWithPath: configPath, relativeTo: cwd)
        if required { return try ASCConfiguration.load(from: url) }
        // Optional means the file may be absent — a present-but-broken one still throws.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ASCConfiguration.load(from: url)
    }

    /// Resolves the metadata root and refuses escapes: a crafted `--metadata` or config
    /// `metadataRoot` like `../../somewhere` would make `pull` write the catalog outside the
    /// working directory. The check itself lives on `ASCConfiguration` so tests cover it.
    func metadataRoot(relativeTo cwd: URL, config: ASCConfiguration) throws -> URL {
        if let metadata {
            return try ASCConfiguration.contained(URL(fileURLWithPath: metadata, relativeTo: cwd), under: cwd)
        }
        return try config.metadataRootURL(relativeTo: cwd)
    }

    static func parse(_ args: ArraySlice<String>) throws -> Arguments {
        var iterator = args.makeIterator()
        guard let first = iterator.next(), let command = Command(rawValue: first) else {
            throw WorkflowError.usage("expected a command")
        }
        var parsed = Arguments(command: command)
        while let arg = iterator.next() {
            switch arg {
            case "--config": parsed.configPath = try value(&iterator, for: arg)
            case "--metadata": parsed.metadata = try value(&iterator, for: arg)
            case "--version":
                parsed.versionSelector = VersionSelector(try value(&iterator, for: arg))
                parsed.versionProvided = true
            case "--yes", "-y": parsed.yes = true
            case "--force": parsed.force = true
            case "--allow-clear": parsed.allowClear = true
            case "--create-missing": parsed.createMissing = true
            case "--app": parsed.app = try value(&iterator, for: arg)
            case "--archive": parsed.archive = try value(&iterator, for: arg)
            case "--floor": parsed.floor = try value(&iterator, for: arg)
            case "--check-reuse": parsed.checkReuse = true
            case "--source": parsed.source = try value(&iterator, for: arg)
            case "--out": parsed.out = try value(&iterator, for: arg)
            case "--build": parsed.buildNumber = try value(&iterator, for: arg)
            case "--iap-version": parsed.iapVersionIDs.append(try value(&iterator, for: arg))
            case "--subscription-version": parsed.subscriptionVersionIDs.append(try value(&iterator, for: arg))
            case "--help", "-h": throw WorkflowError.usage("")
            default: throw WorkflowError.usage("unrecognized argument: \(arg)")
            }
        }
        return parsed
    }

    private static func value(_ iterator: inout ArraySlice<String>.Iterator, for flag: String) throws -> String {
        guard let value = iterator.next() else { throw WorkflowError.usage("\(flag) expects a value") }
        return value
    }

    static let help = """
    usage: asc <command> [options]

    commands:
      pull        fetch live metadata → files + .asc-baseline.json
      diff        three-way diff: local vs live vs baseline (read-only)
      apply       apply deltas (prints the plan; writes only with --yes)
      validate    offline field/locale/required checks
      preflight   archive checks (needs --app or --archive)
      questionnaire  evidence-cited answer sheets from the app project (local-only)
      submit      stage a review submission: version + build + items (preview without --yes)

    options:
      --config <path>       asc.json location (default ./asc.json)
      --metadata <dir>      metadata root override
      --version <sel>       latest | live | <versionString>   (default: latest;
                            submit takes only an exact <versionString>)
      --yes, -y             confirm writes (apply, submit)
      --force               apply over remote drift since the last pull
      --allow-clear         permit empty files to clear remote values
      --create-missing      create missing localization rows / review detail
      --floor <X.Y>         MinimumOSVersion floor (preflight)
      --check-reuse         check the build number against ASC (preflight)
      --source <dir>        app project to scan (questionnaire; else config appSource)
      --out <dir>           answer-sheet output dir (default ./questionnaires)
      --build <N>           build number to attach (submit; default: newest VALID)
      --iap-version <id>    inAppPurchaseVersion id to co-stage (repeatable)
      --subscription-version <id>  subscriptionVersion id to co-stage (repeatable)
    """
}

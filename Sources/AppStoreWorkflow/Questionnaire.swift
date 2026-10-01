import Foundation

/// One questionnaire row: either `answer` + `evidence` citations, or open — `guidance`
/// says what the owner must supply. Nothing is ever guessed into `answer`.
public struct SheetItem: Sendable {
    /// The questionnaire question, as Apple phrases it.
    public var question: String
    /// The evidence-backed answer; nil means the item stays open for the owner.
    public var answer: String?
    /// File citations supporting `answer`, or context on an open item.
    public var evidence: [String] = []
    /// What the owner must supply — present on open items.
    public var guidance: String?
    /// No evidence-backed answer — the owner must respond.
    public var isOpen: Bool { answer == nil }

    public init(_ question: String, answer: String? = nil, guidance: String? = nil, evidence: [String] = []) {
        self.question = question
        self.answer = answer
        self.evidence = evidence
        self.guidance = guidance
    }
}

/// A deterministic Markdown answer sheet — regenerated whole on each run, so `git diff`
/// flags exactly the answers a code change touched. No timestamps: determinism is the feature.
public struct AnswerSheet: Sendable {
    /// Sheet heading (e.g. "App Privacy").
    public var title: String
    /// Output file name within the sheets directory.
    public var fileName: String
    /// Answered and open items in stable order.
    public var items: [SheetItem]
    /// Files this sheet's answers derive from — listed at the foot so a reader can see
    /// the basis. Paths, not revisions: a byte change that moves no extracted signal
    /// intentionally does not dirty the sheet.
    public var evidenceBase: [String]

    /// Items still open for the owner.
    public var openCount: Int { items.filter(\.isOpen).count }

    /// Renders the deterministic Markdown body — identical input renders identically.
    public func render() -> String {
        var out = "# \(title) — answer sheet\n\n"
        out += "Answered items carry their evidence; open items are for the owner.\n"
        let answered = items.filter { !$0.isOpen }
        if !answered.isEmpty {
            out += "\n## Answered\n"
            for item in answered {
                out += "\n- **\(item.question)**\n  \(item.answer!)\n"
                if let guidance = item.guidance { out += "  \(guidance)\n" }
                for cite in item.evidence { out += "  - evidence: \(cite)\n" }
            }
        }
        let open = items.filter(\.isOpen)
        if !open.isEmpty {
            out += "\n## Open questions\n"
            for item in open {
                out += "\n- **\(item.question)**\n"
                if let guidance = item.guidance { out += "  \(guidance)\n" }
                for cite in item.evidence { out += "  - context: \(cite)\n" }
            }
        }
        out += "\n## Evidence base\n\n"
        for file in evidenceBase { out += "- `\(file)`\n" }
        return out
    }
}

/// Maps `ProjectEvidence` onto Apple's four questionnaire surfaces, plus a fifth sheet
/// for the publish-readiness steps that live outside the forms — CloudKit schema
/// promotion, the App Privacy web form, screenshots. The questions are Apple's; the
/// answers are the evidence's — a question with no evidence stays open.
public enum Questionnaire {
    /// Builds the answer sheets from scanned evidence — always the same set,
    /// in the same order, for a given `ProjectEvidence`.
    public static func sheets(for e: ProjectEvidence) -> [AnswerSheet] {
        [exportCompliance(e), appPrivacy(e), ageRating(e), accessibilityLabels(e), publishReadiness(e)]
    }

    // MARK: - export compliance

    static func exportCompliance(_ e: ProjectEvidence) -> AnswerSheet {
        var items: [SheetItem] = []
        let decls = e.encryptionDeclarations
        if decls.isEmpty {
            items.append(.init(
                "Does the app use encryption?",
                guidance: "No `ITSAppUsesNonExemptEncryption` key found in any Info.plist — confirm the app uses no encryption beyond Apple's own, or add the key."
            ))
        } else if decls.allSatisfy({ $0.source.contains(".appex/") }) {
            // The app target's plist is authoritative — an extension-only
            // declaration cannot answer the app's export-compliance question.
            items.append(.init(
                "Does the app use encryption?",
                guidance: "Only app-extension Info.plists declare `ITSAppUsesNonExemptEncryption` — the app target's own plist is authoritative for export compliance; add the key there or answer manually.",
                evidence: decls.map { "`\($0.source)`: \($0.value)" }
            ))
        } else {
            let values = Set(e.encryptionDeclarations.map(\.value))
            if values == [false] {
                items.append(.init(
                    "Does the app use non-exempt encryption?",
                    answer: "No — `ITSAppUsesNonExemptEncryption = false` (exempt/Apple-provided crypto only).",
                    evidence: e.encryptionDeclarations.map { "`\($0.source)`: ITSAppUsesNonExemptEncryption = \($0.value)" }
                ))
            } else if values == [true] {
                items.append(.init(
                    "Non-exempt encryption is declared",
                    answer: "Yes — `ITSAppUsesNonExemptEncryption = true`; exemption/category questions still apply.",
                    guidance: "Owner: answer the exemption follow-ups in App Store Connect.",
                    evidence: e.encryptionDeclarations.map { "`\($0.source)`: ITSAppUsesNonExemptEncryption = \($0.value)" }
                ))
            } else {
                items.append(.init(
                    "Encryption declarations disagree across bundles",
                    guidance: "Info.plists declare different `ITSAppUsesNonExemptEncryption` values — reconcile before answering.",
                    evidence: e.encryptionDeclarations.map { "`\($0.source)`: \($0.value)" }
                ))
            }
        }
        items.append(.init(
            "Export-compliance follow-ups (ECCN, France declaration)",
            guidance: "Owner-level legal answers — no code evidence can supply them."
        ))
        return .init(title: "Export compliance", fileName: "export-compliance.md", items: items, evidenceBase: e.plistFiles)
    }

    // MARK: - app privacy

    static func appPrivacy(_ e: ProjectEvidence) -> AnswerSheet {
        var items: [SheetItem] = []

        // Tracking — an answer is provable only when every manifest declares the key.
        // A manifest that omits NSPrivacyTracking says nothing, so partial coverage
        // leaves the question open rather than averaging into "false".
        let declaring = e.trackingDeclarations
        let undeclared = e.privacyManifestFiles.filter { m in !declaring.contains { $0.source == m } }
        if e.privacyManifestFiles.isEmpty {
            items.append(.init(
                "Does the app track users?",
                guidance: "No PrivacyInfo.xcprivacy found — cannot answer from evidence. Add manifests or answer manually."
            ))
        } else if declaring.contains(where: \.value) {
            items.append(.init(
                "Does the app track users (ATT definition)?",
                answer: "Yes — a privacy manifest declares `NSPrivacyTracking = true`.",
                evidence: declaring.filter(\.value).map { "`\($0.source)`: NSPrivacyTracking = true" }
            ))
        } else if undeclared.isEmpty && e.collectedData.contains(where: { $0.tracking == true }) {
            // Genuine contradiction: every manifest declared false while a datum
            // declares tracking use.
            items.append(.init(
                "Does the app track users (ATT definition)?",
                guidance: "Manifests declare `NSPrivacyTracking = false` but a collected-data entry declares tracking use — reconcile the contradiction before answering.",
                evidence: declaring.map { "`\($0.source)`: NSPrivacyTracking = \($0.value)" }
                    + e.collectedData.filter { $0.tracking == true }
                        .map { "`\($0.source)`: \(humanized($0.dataType)) declares tracking" }
            ))
        } else if undeclared.isEmpty {
            var citations = declaring.map { "`\($0.source)`: NSPrivacyTracking = false" }
            let adSignals = ["ATTrackingManager", "ASIdentifierManager", "SKAdNetwork"]
            let absent = adSignals.filter { e.absentSignals.contains($0) }
            let present = e.signals.filter { adSignals.contains($0.name) }
            if !absent.isEmpty {
                citations.append("no \(absent.map { "`\($0)`" }.joined(separator: "/")) referenced in sources")
            }
            citations += present.map { "`\($0.file)` references \($0.name)" }
            items.append(.init(
                "Does the app track users (ATT definition)?",
                answer: "No — every privacy manifest declares `NSPrivacyTracking = false`.",
                evidence: citations
            ))
        } else {
            items.append(.init(
                "Does the app track users (ATT definition)?",
                guidance: "Some manifests omit `NSPrivacyTracking` — declare it or answer manually.",
                evidence: declaring.map { "`\($0.source)`: NSPrivacyTracking = \($0.value)" }
                    + undeclared.map { "`\($0)`: key absent" }
                    + e.collectedData.filter { $0.tracking == true }
                        .map { "`\($0.source)`: \(humanized($0.dataType)) declares tracking" }
            ))
        }

        // Collected data — one item per manifest, per the manifest's own declaration
        for datum in e.collectedData {
            if datum.dataType == "?" {
                items.append(.init(
                    "Collected data entry without a type",
                    guidance: "Manifest entry omits `NSPrivacyCollectedDataType` — the declaration is malformed; fix it before the label can be answered.",
                    evidence: ["`\(datum.source)`"]
                ))
            } else if let linked = datum.linked, let tracking = datum.tracking, let purposes = datum.purposes {
                items.append(.init(
                    "Collected: \(humanized(datum.dataType))",
                    answer: "linked: \(linked ? "yes" : "no"), tracking: \(tracking ? "yes" : "no"), purposes: \(purposes.map(humanized).joined(separator: ", "))",
                    evidence: ["`\(datum.source)`"]
                ))
            } else {
                var missing: [String] = []
                if datum.linked == nil { missing.append("NSPrivacyCollectedDataTypeLinked") }
                if datum.tracking == nil { missing.append("NSPrivacyCollectedDataTypeTracking") }
                if datum.purposes == nil { missing.append("NSPrivacyCollectedDataTypePurposes") }
                items.append(.init(
                    "Collected: \(humanized(datum.dataType))",
                    guidance: "Manifest entry omits \(missing.joined(separator: ", ")) — supply the missing declarations before this label is complete.",
                    evidence: ["`\(datum.source)`"]
                ))
            }
        }
        // No declared collection is not proof of none — the owner must confirm.
        if e.collectedData.isEmpty {
            items.append(.init(
                "Does the app collect user data?",
                guidance: "No manifest declares collected data — confirm the app collects nothing, or add the declarations."
            ))
        }

        if !e.trackingDomains.isEmpty {
            items.append(.init(
                "Tracking domains declared",
                guidance: "Tracking domains are declared — confirm the tracking answer reflects them.",
                evidence: e.trackingDomains.map { "`\($0.source)`: \($0.domain)" }
            ))
        }
        let completeAPIs = e.accessedAPIs.filter { $0.type != "?" && !$0.reasons.isEmpty }
        let partialAPIs = e.accessedAPIs.filter { $0.type == "?" || $0.reasons.isEmpty }
        if !completeAPIs.isEmpty {
            items.append(.init(
                "Required-reason API usage declared",
                answer: completeAPIs.map { "\(humanized($0.type)) — \(sanitizeReasons($0.reasons))" }
                    .joined(separator: "; "),
                evidence: completeAPIs.map { "`\($0.source)`" }
            ))
        }
        for api in partialAPIs {
            items.append(.init(
                "Required-reason API entry incomplete",
                guidance: "Manifest entry is missing its category or reasons — complete the declaration before it can back a label.",
                evidence: ["`\(api.source)`"]
            ))
        }

        // Data leaving the device — entitlements evidence
        let iCloud = e.entitlements.filter { $0.key.hasPrefix("com.apple.developer.icloud") }
        if !iCloud.isEmpty {
            items.append(.init(
                "Data stored off-device",
                guidance: "iCloud capability is configured — confirm which service (CloudKit private DB, iCloud Documents, key-value store) actually carries user data.",
                evidence: iCloud.map { "`\($0.source)`: \($0.key) = \($0.summary)" }
            ))
        }
        let push = e.entitlements.filter { $0.key == "aps-environment" }
        let remoteNotify = e.backgroundModes.filter { $0.mode == "remote-notification" }
        if !push.isEmpty || !remoteNotify.isEmpty {
            items.append(.init(
                "Push notification payloads",
                guidance: "APNs entitlement/background mode present — if payloads carry user data it may need disclosing.",
                evidence: (push.map { "`\($0.source)`: aps-environment = \($0.summary)" }
                    + remoteNotify.map { "`\($0.source)`: UIBackgroundModes = remote-notification" })
            ))
        }

        // Speech — the task doc's flagged unknown. A text scan can show
        // `requiresOnDeviceRecognition = true` exists, but cannot prove it covers every
        // recognition request — so the destination stays open and cites what was found.
        let speechUse = e.usageDescriptions.filter { $0.key == "NSSpeechRecognitionUsageDescription" }
        let speechSignals = e.signals.filter { $0.name == "SFSpeechRecognizer" }
        let pinning = e.signals.filter { $0.name == "requiresOnDeviceRecognition" }
        if !speechUse.isEmpty || !speechSignals.isEmpty {
            var context = speechSignals.map { "`\($0.file)` references SFSpeechRecognizer" }
                + speechUse.map { "`\($0.source)`: \($0.key)" }
            let guidance: String
            if pinning.isEmpty {
                guidance = "`SFSpeechRecognizer` is used and `requiresOnDeviceRecognition` is not set — audio may be processed on Apple's servers. Confirm server-side use or pin on-device."
            } else {
                context += pinning.map { "`\($0.file)`: requiresOnDeviceRecognition = true" }
                guidance = "An on-device pin was found, but a text scan cannot prove it covers every recognition request — confirm no unpinned recognizer ships."
            }
            items.append(.init("Speech recognition destination", guidance: guidance, evidence: context))
        }

        let found = collectorDependencies(in: e)
        if e.projectFiles.isEmpty {
            items.append(.init(
                "Third-party analytics/ads SDKs",
                guidance: "No `project.pbxproj` or `Package.swift` was scanned — there is no dependency inventory to answer from. Point `--source` at the project root or answer manually."
            ))
        } else if found.isEmpty {
            items.append(.init(
                "Third-party analytics/ads SDKs",
                answer: "None found in linked frameworks or SwiftPM dependencies.",
                evidence: e.linkedFrameworks.isEmpty && e.packageDependencies.isEmpty
                    ? ["project file scan found no linked frameworks or packages"]
                    : e.linkedFrameworks.map { "framework: \($0)" } + e.packageDependencies.map { "package: \($0)" }
            ))
        } else {
            items.append(.init(
                "Third-party SDKs that may collect data",
                guidance: "Each SDK's own collection must be reflected in the label — review each one's docs.",
                evidence: found
            ))
        }

        // Other usage descriptions — each is a privacy-relevant capability the owner confirms
        for usage in e.usageDescriptions where usage.key != "NSSpeechRecognitionUsageDescription" {
            items.append(.init(
                "Declares `\(usage.key)`",
                guidance: "Confirm the label reflects what this capability collects.",
                evidence: ["`\(usage.source)`: \(usage.key)"]
            ))
        }

        return .init(
            title: "App Privacy", fileName: "app-privacy.md", items: items,
            evidenceBase: (e.privacyManifestFiles + e.entitlementFiles + e.plistFiles
                + e.projectFiles + e.signalFiles).sorted())
    }

    /// SDKs that commonly collect or advertise — matched against framework names and
    /// package repo URLs alike (`firebase-ios-sdk` is how FirebaseAnalytics ships).
    static let collectorPatterns = [
        "AdSupport", "AppTrackingTransparency", "FirebaseAnalytics", "firebase-ios-sdk",
        "GoogleMobileAds", "google-mobile-ads", "admob", "AppsFlyerLib", "appsflyer",
        "Adjust", "Amplitude", "Mixpanel", "Segment", "Crashlytics", "FBSDK",
        "facebook-ios-sdk", "Flurry", "AppCenter", "Sentry", "Datadog", "Branch",
    ]

    static func collectorDependencies(in e: ProjectEvidence) -> [String] {
        (e.linkedFrameworks + e.packageDependencies).filter { name in
            collectorPatterns.contains { name.localizedCaseInsensitiveContains($0) }
        }
    }

    // MARK: - age rating

    static func ageRating(_ e: ProjectEvidence) -> AnswerSheet {
        var items: [SheetItem] = []
        /// A negative answer is only as good as the coverage behind it: every scanned
        /// symbol absent AND no source file skipped (oversized/unreadable). Anything
        /// less stays open — absence of a signal is not proof of absent content.
        func codeAnswer(_ q: String, absentSignals: [String], text: String) -> SheetItem {
            if e.scannedSourceFiles.isEmpty {
                return .init(q, guidance: "No source files were scanned — absence cannot be established.")
            }
            if !e.skippedSourceFiles.isEmpty {
                return .init(q, guidance: "Source coverage is incomplete — \(e.skippedSourceFiles.count) file(s) went unscanned; absence cannot be established.",
                    evidence: e.skippedSourceFiles.map { "unscanned: `\($0)`" })
            }
            if absentSignals.allSatisfy({ e.absentSignals.contains($0) }) {
                return .init(q, answer: text, evidence: ["no \(absentSignals.joined(separator: "/")) referenced in scanned sources"])
            }
            let found = e.signals.filter { absentSignals.contains($0.name) }.map { "`\($0.file)` references \($0.name)" }
            return .init(q, guidance: "Signals found — verify the actual user-facing content.", evidence: found)
        }
        items.append(codeAnswer(
            "Unrestricted web access",
            absentSignals: ["WKWebView", "SFSafariViewController", "UIWebView"],
            text: "No — no web-view usage found in sources."
        ))
        var ads = codeAnswer(
            "Third-party advertising or ad tracking",
            absentSignals: ["ATTrackingManager", "ASIdentifierManager", "SKAdNetwork"],
            text: "No — no ad/tracking SDKs or frameworks referenced."
        )
        // An ad SDK can serve third-party ads without the app touching ATT/IDFA —
        // the dependency inventory outranks source symbols here.
        let adDeps = collectorDependencies(in: e)
        if ads.answer != nil && !adDeps.isEmpty {
            ads = .init(
                "Third-party advertising or ad tracking",
                guidance: "Collector-capable dependencies are linked — confirm whether any serve ads or collect for tracking.",
                evidence: adDeps.map { "dependency: \($0)" })
        }
        items.append(ads)
        // Medical/treatment is a content question — HealthKit evidence is context,
        // never a code answer.
        items.append(.init(
            "Medical or treatment information",
            guidance: "Content question — owner answers; HealthKit presence is context only.",
            evidence: e.signals.filter { $0.name == "HKHealthStore" }.map { "`\($0.file)` references HKHealthStore" }
        ))
        for q in [
            "Violence, horror, or fear themes",
            "Sexual content or nudity",
            "Profanity or crude humour",
            "Alcohol, tobacco, or drug references",
            "Gambling or contests",
            "User-generated content or messaging",
            "Made for Kids eligibility",
        ] {
            items.append(.init(q, guidance: "Content question — owner answers; code cannot supply evidence."))
        }
        let ageSignals: Set<String> = [
            "WKWebView", "SFSafariViewController", "UIWebView",
            "ATTrackingManager", "ASIdentifierManager", "SKAdNetwork", "HKHealthStore",
        ]
        let ageFiles = e.signalFiles.filter { file in
            e.signals.contains { $0.file == file && ageSignals.contains($0.name) }
        }
        return .init(
            title: "Age rating", fileName: "age-rating.md", items: items,
            evidenceBase: (ageFiles + e.projectFiles).sorted())
    }

    // MARK: - accessibility nutrition labels

    static func accessibilityLabels(_ e: ProjectEvidence) -> AnswerSheet {
        // Apple's label fields. Code cannot prove support — only an audit can — so every
        // item stays open and points at the audit that should answer it.
        let fields = [
            "VoiceOver", "Voice Control", "Larger Text", "Dark Interface",
            "Differentiate Without Color Alone", "Sufficient Contrast",
            "Reduced Motion", "Captions", "Audio Descriptions",
        ]
        let items = fields.map { field in
            SheetItem(
                "Supports \(field)?",
                guidance: "Answer from an `axiom-accessibility` audit of the app, not from intent — attach the audit's finding.",
                evidence: e.signals.filter { $0.name == "accessibilityLabel" }.map { "`\($0.file)`" }
            )
        }
        return .init(
            title: "Accessibility Nutrition Labels", fileName: "accessibility-labels.md",
            items: items, evidenceBase: [])
    }

    // MARK: - publish readiness

    /// The steps a submission needs that no form or metadata file captures — the ones a
    /// first publish tends to discover late (a TestFlight build syncing against an empty
    /// CloudKit production schema is the worked example). Evidence-gated where a scan can
    /// see the trigger; the rest are always listed because they apply to every app.
    static func publishReadiness(_ e: ProjectEvidence) -> AnswerSheet {
        var items: [SheetItem] = []

        let cloudKit = e.entitlements.filter {
            $0.key == "com.apple.developer.icloud-services" && $0.summary.contains("CloudKit")
        }
        if !cloudKit.isEmpty {
            items.append(.init(
                "CloudKit production schema",
                guidance: "Client-created record types live only in the container's development environment — TestFlight and App Store builds hit production, which apps cannot mutate. Promote via CloudKit Dashboard → Schema → Deploy Schema Changes (a development-signed build must have synced at least once for there to be anything to deploy). `xcrun cktool export-schema` with a saved management token verifies each environment's state.",
                evidence: cloudKit.map { "`\($0.source)`: \($0.key) = \($0.summary)" }
            ))
        }

        let push = e.entitlements.filter { $0.key == "aps-environment" }
        let remoteNotify = e.backgroundModes.filter { $0.mode == "remote-notification" }
        if !push.isEmpty || !remoteNotify.isEmpty {
            items.append(.init(
                "Push in production",
                guidance: "Distribution signing flips `aps-environment` to production; confirm the Push Notifications capability is enabled on the App ID (Xcode's capability sync normally does this) if silent pushes — e.g. CloudKit subscriptions — must reach testers.",
                evidence: (push.map { "`\($0.source)`: aps-environment = \($0.summary)" }
                    + remoteNotify.map { "`\($0.source)`: UIBackgroundModes = remote-notification" })
            ))
        }

        for (q, g) in [
            ("App Privacy form",
             "App Store Connect web only — no public API publishes the data-use labels. Answer from `app-privacy.md`."),
            ("Age rating declaration",
             "Answer from `age-rating.md`; set under the app's Age Rating page (`ageRatingDeclarations` exists in the spec but is not wired into asc)."),
            ("Screenshots",
             "Required before a version can enter review — at least one per required device class."),
            ("Review contact and demo material",
             "`metadata/review_information/` fields — contact name/email/phone and, when `demoAccountRequired`, credentials a reviewer can actually use."),
        ] {
            items.append(.init(q, guidance: g))
        }

        return .init(
            title: "Publish readiness", fileName: "publish-readiness.md",
            items: items, evidenceBase: e.entitlementFiles.sorted())
    }

    /// Required-reason codes (`CA92.1`) pass through unchanged — they are the codes
    /// Apple publishes; humanizing them would lose precision.
    static func sanitizeReasons(_ reasons: [String]) -> String {
        reasons.isEmpty ? "no reasons declared" : reasons.joined(separator: ", ")
    }

    /// `NSPrivacyCollectedDataTypeCrashData` → "Crash Data"; unknown keys pass through
    /// with the NSPrivacy prefix stripped.
    static func humanized(_ key: String) -> String {
        var s = key
        for prefix in ["NSPrivacyCollectedDataTypePurpose", "NSPrivacyCollectedDataType", "NSPrivacyAccessedAPICategory"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && ch.isUppercase { out += " " }
            out.append(ch)
        }
        return out
    }
}

/// Writes sheets into the output directory and reports what changed — unchanged sheets
/// are not touched, so a re-run diffs only answers that actually moved.
public enum SheetStore {
    /// Per-file outcome of a write pass.
    public struct WriteReport: Sendable {
        /// Sheets written for the first time.
        public var added: [String] = []
        /// Sheets whose rendered body differed from what was on disk.
        public var changed: [String] = []
        /// Sheets already identical — left untouched.
        public var unchanged: [String] = []
    }

    /// Writes each sheet under `dir` (created if needed) and reports which files
    /// changed — unchanged sheets are not rewritten, keeping `git diff` signal-clean.
    public static func write(_ sheets: [AnswerSheet], to dir: URL) throws -> WriteReport {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var report = WriteReport()
        for sheet in sheets {
            let url = dir.appendingPathComponent(sheet.fileName)
            // A symlink planted at a sheet name must not redirect the write —
            // remove it rather than follow it outside the output directory.
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try fm.removeItem(at: url)
            }
            let body = sheet.render()
            if let existing = try? String(contentsOf: url, encoding: .utf8) {
                if existing == body {
                    report.unchanged.append(sheet.fileName)
                    continue
                }
                report.changed.append(sheet.fileName)
            } else {
                report.added.append(sheet.fileName)
            }
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return report
    }
}

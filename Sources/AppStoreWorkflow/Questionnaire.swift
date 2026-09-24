import Foundation

/// One questionnaire row: either `answer` + `evidence` citations, or open — `guidance`
/// says what the owner must supply. Nothing is ever guessed into `answer`.
public struct SheetItem: Sendable {
    public var question: String
    public var answer: String?
    public var evidence: [String] = []
    public var guidance: String?
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
    public var title: String
    public var fileName: String
    public var items: [SheetItem]
    public var evidenceBase: [String]

    public var openCount: Int { items.filter(\.isOpen).count }

    public func render() -> String {
        var out = "# \(title) — answer sheet\n\n"
        out += "Answered items carry their evidence; open items are for the owner.\n"
        let answered = items.filter { !$0.isOpen }
        if !answered.isEmpty {
            out += "\n## Answered\n"
            for item in answered {
                out += "\n- **\(item.question)**\n  \(item.answer!)\n"
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

/// Maps `ProjectEvidence` onto Apple's four questionnaire surfaces. The questions are
/// Apple's; the answers are the evidence's — a question with no evidence stays open.
public enum Questionnaire {
    public static func sheets(for e: ProjectEvidence) -> [AnswerSheet] {
        [exportCompliance(e), appPrivacy(e), ageRating(e), accessibilityLabels(e)]
    }

    // MARK: - export compliance

    static func exportCompliance(_ e: ProjectEvidence) -> AnswerSheet {
        var items: [SheetItem] = []
        switch e.encryptionDeclarations.count {
        case 0:
            items.append(.init(
                "Does the app use encryption?",
                guidance: "No `ITSAppUsesNonExemptEncryption` key found in any Info.plist — confirm the app uses no encryption beyond Apple's own, or add the key."
            ))
        default:
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

        // Tracking
        switch e.trackingDeclared {
        case .some(false):
            var citations = e.filesScanned.filter { $0.hasSuffix("PrivacyInfo.xcprivacy") }
                .map { "`\($0)`: NSPrivacyTracking = false" }
            if e.absentSignals.contains("ATTrackingManager") {
                citations.append("no `ATTrackingManager`/`ASIdentifierManager`/`SKAdNetwork` referenced in sources")
            }
            items.append(.init(
                "Does the app track users (ATT definition)?",
                answer: "No — every privacy manifest declares `NSPrivacyTracking = false`.",
                evidence: citations
            ))
        case .some(true):
            items.append(.init(
                "Does the app track users (ATT definition)?",
                answer: "Yes — a privacy manifest declares `NSPrivacyTracking = true`.",
                evidence: e.filesScanned.filter { $0.hasSuffix("PrivacyInfo.xcprivacy") }
            ))
        case nil:
            items.append(.init(
                "Does the app track users?",
                guidance: "No PrivacyInfo.xcprivacy found — cannot answer from evidence. Add manifests or answer manually."
            ))
        }

        // Collected data — one item per manifest, per the manifest's own declaration
        for datum in e.collectedData {
            items.append(.init(
                "Collected: \(humanized(datum.dataType))",
                answer: "linked: \(datum.linked ? "yes" : "no"), tracking: \(datum.tracking ? "yes" : "no"), purposes: \(datum.purposes.map(humanized).joined(separator: ", "))",
                evidence: ["`\(datum.source)`"]
            ))
        }

        // Data leaving the device — entitlements evidence
        let iCloud = e.entitlements.filter { $0.key.hasPrefix("com.apple.developer.icloud") }
        if !iCloud.isEmpty {
            items.append(.init(
                "Data stored off-device",
                answer: "App uses iCloud/CloudKit — user data syncs via the user's private iCloud database (Apple-hosted).",
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

        // Speech — the task doc's flagged unknown
        let speechUse = e.usageDescriptions.filter { $0.key == "NSSpeechRecognitionUsageDescription" }
        let speechSignals = e.signals.filter { $0.name == "SFSpeechRecognizer" }
        let onDevice = e.signals.contains { $0.name == "requiresOnDeviceRecognition" }
        if !speechUse.isEmpty || !speechSignals.isEmpty {
            if onDevice {
                items.append(.init(
                    "Speech recognition destination",
                    answer: "On-device — `requiresOnDeviceRecognition` is set.",
                    evidence: e.signals.filter { $0.name == "requiresOnDeviceRecognition" }.map { "`\($0.file)`" }
                ))
            } else if !speechSignals.isEmpty {
                items.append(.init(
                    "Speech recognition destination",
                    guidance: "`SFSpeechRecognizer` is used and `requiresOnDeviceRecognition` is not set — audio may be processed on Apple's servers. Confirm server-side use or pin on-device.",
                    evidence: speechSignals.map { "`\($0.file)` references SFSpeechRecognizer" }
                        + speechUse.map { "`\($0.source)`: \($0.key)" }
                ))
            }
        }

        // Third-party SDKs that commonly collect
        let collectors = ["AdSupport", "AppTrackingTransparency", "FirebaseAnalytics", "GoogleMobileAds", "AppsFlyerLib", "Adjust", "Amplitude", "Mixpanel", "Segment", "Crashlytics", "FBSDK"]
        let found = (e.linkedFrameworks + e.packageDependencies).filter { name in
            collectors.contains { name.localizedCaseInsensitiveContains($0) }
        }
        if found.isEmpty {
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

    // MARK: - age rating

    static func ageRating(_ e: ProjectEvidence) -> AnswerSheet {
        var items: [SheetItem] = []
        func codeAnswer(_ q: String, absentSignals: [String], text: String) -> SheetItem {
            if absentSignals.allSatisfy({ e.absentSignals.contains($0) }) {
                return .init(q, answer: text, evidence: ["no \(absentSignals.joined(separator: "/")) referenced in sources"])
            }
            let found = e.signals.filter { absentSignals.contains($0.name) }.map { "`\($0.file)` references \($0.name)" }
            return .init(q, guidance: "Signals found — verify the actual user-facing content.", evidence: found)
        }
        items.append(codeAnswer(
            "Unrestricted web access",
            absentSignals: ["WKWebView", "SFSafariViewController", "UIWebView"],
            text: "No — no web-view usage found in sources."
        ))
        items.append(codeAnswer(
            "Third-party advertising or ad tracking",
            absentSignals: ["ATTrackingManager", "ASIdentifierManager", "SKAdNetwork"],
            text: "No — no ad/tracking frameworks referenced."
        ))
        items.append(codeAnswer(
            "Medical or treatment information",
            absentSignals: ["HKHealthStore"],
            text: "No — no HealthKit usage found."
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
    public struct WriteReport: Sendable {
        public var added: [String] = []
        public var changed: [String] = []
        public var unchanged: [String] = []
    }

    public static func write(_ sheets: [AnswerSheet], to dir: URL) throws -> WriteReport {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var report = WriteReport()
        for sheet in sheets {
            let url = dir.appendingPathComponent(sheet.fileName)
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

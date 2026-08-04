import Foundation
import Testing

enum FixturePrivacyRule: String {
    case awsCredential = "aws-credential"
    case signedURL = "signed-url"
    case personalAPIKey = "personal-api-key"
    case projectToken = "project-token"
    case nonReservedEmail = "non-reserved-email"
    case nonReservedURL = "non-reserved-url"
    case authorizationHeader = "authorization-header"
    case environmentAssignment = "environment-assignment"
    case captureProvenance = "capture-provenance"
    case nonSyntheticIdentifier = "non-synthetic-identifier"
    case nonSyntheticTimestamp = "non-synthetic-timestamp"
    case nonSyntheticEvent = "non-synthetic-event"
    case nonSyntheticProject = "non-synthetic-project"
    case nonSyntheticProduct = "non-synthetic-product"
    case tenantRoute = "tenant-route"
    case appleSigningIdentifier = "apple-signing-identifier"
    case publicLogInterpolation = "public-log-interpolation"
    case unsafeDiagnosticMetadata = "unsafe-diagnostic-metadata"
    case externalDenylist = "external-denylist"
}

struct FixturePrivacyFinding: Hashable {
    let relativePath: String
    let rule: FixturePrivacyRule
}

enum FixturePrivacyScanner {
    private struct ConfigurationError: Error {}

    private struct Pattern {
        let rule: FixturePrivacyRule
        let expression: NSRegularExpression

        init(_ rule: FixturePrivacyRule, _ pattern: String, options: NSRegularExpression.Options = []) {
            self.rule = rule
            self.expression = try! NSRegularExpression(pattern: pattern, options: options)
        }
    }

    private static let patterns: [Pattern] = [
        Pattern(.awsCredential, #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#),
        Pattern(.personalAPIKey, #"\b(?:phx_|gh[pousr]_|github_pat_|sk-|xox[baprs]-)[A-Za-z0-9_-]{10,}\b"#),
        Pattern(.projectToken, #"\bphc_[A-Za-z0-9_-]{10,}\b"#),
        Pattern(
            .authorizationHeader,
            #"[\"']Authorization[\"']\s*:\s*[\"'](?:Bearer|Basic|Token)\b"#,
            options: .caseInsensitive
        ),
        Pattern(.environmentAssignment, #"\b(?:POSTHOG|AWS|DATABASE|OPENAI|GITHUB|SLACK)_[A-Z0-9_]+\s*="#),
        Pattern(
            .captureProvenance,
            #"\b(?:captured (?:response|payload|fixture|data)|recorded (?:response|payload|fixture|data|value|count)|captured\s+live(?:\s+(?:response|payload|fixture|data))?|recorded\s+live(?:\s+(?:response|payload|fixture|data))?|captured\s+blob_v2|live\s+(?:host|project|responses?)|observed\s+(?:cohort|on\s+the\s+wire)|verified\s+live|measured\s+live|live[-]verified|(?:measured|verified|checked)\s+against\s+(?:the\s+|this\s+)?(?:project|tenant|deployment|live\s+project|live\s+responses?)|measured\s+on\s+this\s+deployment|read\s+(?:from\s+)?live(?:\s+(?:response|responses|data|project))?|key\s+this\s+project\s+develops\s+against|(?:this|the)\s+(?:project|tenant|deployment)\s+(?:returned|reported|contained)\s+(?:no|zero|[0-9]+|data\s+dated)\b|(?:project|deployment)\s+this(?:\s+app)?\s+was\s+(?:built|written|measured)\s+against|current\s+personal\s+api\s+key|available\s+key\s+is\s+read-only|real\s+payload|every\s+observed\s+row|posthog\s+actually\s+sent|from\s+this\s+machine|photographed\s+exactly|sent\s+for\s+real|this\s+deployment|repository\s+recordings|verbatim (?:recording|copy)|live[ -]api|production[ -]data)\b"#,
            options: .caseInsensitive
        ),
        Pattern(.tenantRoute, #"(?:^|[\s\"'])/s/[a-z0-9-]+"#, options: .caseInsensitive),
        Pattern(
            .publicLogInterpolation,
            #"\b(?:log|logger)\.\w+\([\s\S]{0,500}?privacy:\s*\.public"#,
            options: .caseInsensitive
        ),
        Pattern(
            .unsafeDiagnosticMetadata,
            #"\b(?:print|XCTFail)\([^)]{0,500}?(?:\.path\b|deviceUDID|deviceName)"#
        ),
    ]
    private static let emailExpression = try! NSRegularExpression(
        pattern: #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@([A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,63})\b"#,
        options: .caseInsensitive
    )
    private static let urlExpression = try! NSRegularExpression(
        pattern: #"https?://[^\s\"'<>\\]+"#,
        options: .caseInsensitive
    )
    private static let signedURLExpression = try! NSRegularExpression(
        pattern: #"\bX-Amz-(?:Credential|Security-Token|Signature)\b"#,
        options: .caseInsensitive
    )
    private static let uuidExpression = try! NSRegularExpression(
        pattern: #"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
        options: .caseInsensitive
    )
    private static let dateExpression = try! NSRegularExpression(
        pattern: #"\b20\d{2}-\d{2}-\d{2}\b"#
    )
    private static let jsonlDateExpression = try! NSRegularExpression(
        pattern: #"(?<!\d)20\d{2}-\d{2}-\d{2}(?!\d)"#
    )
    private static let projectPathExpression = try! NSRegularExpression(
        pattern: #"/(?:(?:api/)?projects|project)/(\d+)(?:/|\b)"#,
        options: .caseInsensitive
    )
    private static let appleSigningIdentifierExpression = try! NSRegularExpression(
        pattern: #"\b[A-Z0-9]{10}\.app\.gethog(?:\.[A-Za-z0-9.-]+)?\b"#
    )
    private static let contextualTenantIdentifierExpression = try! NSRegularExpression(
        pattern: #"\b(project|user|flag|insight|cohort|dashboard|subscriber|issue|session)(?:[\s_-]*(?:id|identifier))?\s*(?:[:=#]|is\s+|was\s+)?([0-9][0-9_]{4,})\b"#,
        options: .caseInsensitive
    )
    private static let sourceProjectExpression = try! NSRegularExpression(
        pattern: #"\b(?:projectID|projectId|project_id|teamID|teamId|team_id)\s*[:=]\s*([\d_]+)"#
    )
    private static let cacheProjectExpression = try! NSRegularExpression(
        pattern: #"\bcache_(\d+)_"#,
        options: .caseInsensitive
    )
    private static let opaqueIdentifierExpression = try! NSRegularExpression(
        pattern: #"\bcm[a-z0-9]{16,}\b"#,
        options: .caseInsensitive
    )
    private static let explicitSyntheticIdentifierExpression = try! NSRegularExpression(
        pattern: #"^(?=[a-z0-9:_-]{3,128}$)(?=.*(?:example|synthetic|fixture|test|demo|harbor|meteor))[a-z0-9]+(?:[-_:][a-z0-9]+)*$"#,
        options: .caseInsensitive
    )
    private static let explicitSyntheticDisplayIdentifierExpression = try! NSRegularExpression(
        pattern: #"^example distinct ids \d{4}$"#,
        options: .caseInsensitive
    )
    private static let projectKeys: Set<String> = ["project_id", "projectId", "team_id", "teamId"]
    private static let identifierKeys: Set<String> = [
        "$session_id", "session_id", "sessionId", "window_id", "windowId",
        "distinct_id", "distinctId", "distinct_ids", "distinctIds",
    ]
    private static let timestampKeys: Set<String> = [
        "timestamp", "event_timestamp", "session_start_time", "start_time", "end_time",
        "created_at", "updated_at", "last_seen_at", "timeOrigin",
    ]
    private static let canonicalReplayEpochSeconds = 1_767_225_600.0..<1_769_904_000.0
    private static let publicPostHogHosts: Set<String> = ["us.posthog.com", "eu.posthog.com"]
    /// A loopback probe is served by the test process itself, so it names no
    /// tenant and reaches no external host. Signed-URL rules still apply: a
    /// credential-shaped query is a credential wherever it is pointed.
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
    private static let publicDocumentationHosts: Set<String> = [
        "developer.apple.com", "evilmartians.com", "github.com", "posthog.com",
        "registry.npmjs.org", "www.apple.com", "www.contributor-covenant.org",
        "www.npmjs.com", "www.w3.org", "www.w3ctech.com",
    ]
    private static let eventKeys: Set<String> = ["event", "event_name", "eventName"]
    private static let allowedEvents: Set<String> = [
        "$ai_generation", "$autocapture", "$exception", "$feature_flag_called", "$identify",
        "$pageleave", "$pageview", "$screen", "$survey_response", "$survey_sent", "$web_vitals",
        "account_created", "cache_warmed", "checkout_completed", "checkout_submitted",
        "export_completed", "export_started", "feature_used", "setup_hint_viewed", "trial_started",
        "example-survey-dismissed", "example-survey-response-01", "example-survey-response-02",
        "example-survey-response-03", "example-survey-response-04", "example-survey-response-05",
        "example-survey-response-06", "example-survey-response-07",
        "example-survey-event-1", "example-survey-event-2", "example-survey-event-3",
        "example-survey-event-4", "example-survey-event-5", "example-survey-event-6",
        "example-survey-event-7", "example-survey-event-8", "example-survey-event-9",
        "example_filter_applied", "example_nebula_exported", "example_observation_shared",
        "example_orbit_viewed", "example_session_replayed", "example_star_chart_saved",
        "example_telescope_focused",
        "harbor_dashboard_opened", "harbor_filter_changed", "harbor_help_opened",
        "harbor_note_saved", "harbor_report_downloaded",
        "harbor_search_run", "harbor_widget_pinned", "meteor_export_requested",
        "meteor_filter_applied", "meteor_report_opened", "survey abandoned",
        "survey dismissed", "survey sent",
    ]
    private static let positionalEventColumns: Set<String> = ["event", "events"]
    private static let positionalIdentifierColumns: Set<String> = [
        "ai_session_id", "assignee_role_id", "assignee_user_id", "distinct_id",
        "event_distinct_ids", "fingerprint", "first_distinct_id", "id", "parent_span_id",
        "person_id", "session_id", "span_id", "trace_id", "uuid", "window_id",
    ]
    private static let positionalSensitiveColumns: Set<String> = [
        "campaign", "description", "email", "endpoint", "function", "group_name", "key",
        "library", "name", "people", "person", "product", "product_name", "service_name",
        "source", "table_name", "trace_name", "value",
    ]
    /// The nil UUID is part of several public API fallback shapes and carries no tenant identity.
    /// The remaining values are intentionally named aliases used by the deterministic person fixtures.
    private static let allowedIdentifierExceptions: Set<String> = [
        "00000000-0000-0000-0000-000000000000",
        "account-cobalt-labs",
        "browser:indigo-builder-a",
        "browser:indigo-builder-b",
        "device:amber-comet-73",
        "device:indigo-builder-28",
        "device:violet-navigator-51",
        "person:sable:browser",
        "person:sable:primary",
        "person:sable:tablet",
        "visitor-cobalt-7407",
        "visitor-quartz-7401",
        "visitor:amber-comet-73",
        "visitor:violet-navigator-51",
        "workspace:indigo-builder-28",
        "span-health-root",
        "span-widget-cache",
        "span-widget-entry",
        "span-widget-render",
        "trace-event-cache",
        "trace-event-entry",
        "trace-event-health",
        "trace-event-render",
    ]

    /// Exact values stay outside the repository. CI or a local audit can point
    /// this at a newline-delimited file without teaching the scanner the values
    /// it is intended to reject.
    private static var exactDenylist: [String] {
        guard let path = ProcessInfo.processInfo.environment["GETHOG_FIXTURE_DENYLIST_FILE"],
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    private static func validateDenylistConfiguration() throws {
        let environment = ProcessInfo.processInfo.environment
        let requiresDenylist = ["1", "true", "yes"].contains(
            environment["GETHOG_REQUIRE_FIXTURE_DENYLIST"]?.lowercased()
        )
        guard requiresDenylist else { return }
        guard let path = environment["GETHOG_FIXTURE_DENYLIST_FILE"],
              !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              text.split(whereSeparator: \.isNewline).contains(where: {
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })
        else {
            throw ConfigurationError()
        }
    }

    static func findings(in directory: URL, relativeTo repositoryRoot: URL) throws -> [String] {
        try validateDenylistConfiguration()
        return try detailedFindings(in: directory, relativeTo: repositoryRoot)
            .sorted { ($0.relativePath, $0.rule.rawValue) < ($1.relativePath, $1.rule.rawValue) }
            .map { "\($0.relativePath): \($0.rule.rawValue)" }
    }

    private static func detailedFindings(
        in directory: URL,
        relativeTo repositoryRoot: URL
    ) throws -> Set<FixturePrivacyFinding> {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ),
            "Missing fixture directory"
        )
        var findings: Set<FixturePrivacyFinding> = []
        for case let fileURL as URL in enumerator {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            let text = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
            let relativePath = relativePath(for: fileURL, relativeTo: repositoryRoot)
            inspectFixtureText(text, relativePath: relativePath, findings: &findings)
            if fileURL.pathExtension == "json",
               let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                inspectStructuredValue(
                    object,
                    key: nil,
                    relativePath: relativePath,
                    findings: &findings
                )
                try inspectDecodedFixtureText(
                    object,
                    relativePath: relativePath,
                    findings: &findings
                )
            }
            if fileURL.pathExtension == "jsonl" {
                for line in text.split(whereSeparator: \.isNewline) {
                    let object = try JSONSerialization.jsonObject(
                        with: Data(line.utf8),
                        options: [.fragmentsAllowed]
                    )
                    inspectPositionalReplayRecord(
                        object,
                        relativePath: relativePath,
                        findings: &findings
                    )
                    inspectStructuredValue(
                        object,
                        key: nil,
                        relativePath: relativePath,
                        findings: &findings,
                        timestampExpression: jsonlDateExpression
                    )
                    try inspectDecodedFixtureText(
                        object,
                        relativePath: relativePath,
                        findings: &findings
                    )
                }
            }
        }
        return findings
    }

    private static func inspectDecodedFixtureText(
        _ object: Any,
        relativePath: String,
        findings: inout Set<FixturePrivacyFinding>
    ) throws {
        let decoded = try JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        inspectFixtureText(
            String(decoding: decoded, as: UTF8.self),
            relativePath: relativePath,
            findings: &findings
        )
    }

    private static func inspectFixtureText(
        _ text: String,
        relativePath: String,
        findings: inout Set<FixturePrivacyFinding>
    ) {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns where pattern.expression.firstMatch(in: text, range: fullRange) != nil {
            findings.insert(.init(relativePath: relativePath, rule: pattern.rule))
        }
        let normalizedText = text.lowercased()
        if exactDenylist.contains(where: normalizedText.contains) {
            findings.insert(.init(relativePath: relativePath, rule: .externalDenylist))
        }
        for match in emailExpression.matches(in: text, range: fullRange) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            if !isReserved(host: String(text[range]).lowercased()) {
                findings.insert(.init(relativePath: relativePath, rule: .nonReservedEmail))
            }
        }
        for match in urlExpression.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text),
                  let host = URL(string: String(text[range]))?.host?.lowercased()
            else { continue }
            let isReserved = isReserved(host: host)
            if !isReserved,
               signedURLExpression.firstMatch(in: text, range: match.range) != nil {
                findings.insert(.init(relativePath: relativePath, rule: .signedURL))
            }
            if !isReserved,
               !publicPostHogHosts.contains(host),
               !loopbackHosts.contains(host) {
                findings.insert(.init(relativePath: relativePath, rule: .nonReservedURL))
            }
        }
    }

    static func sourceFindings(in files: [URL], relativeTo repositoryRoot: URL) throws -> [String] {
        try validateDenylistConfiguration()
        var findings: Set<FixturePrivacyFinding> = []
        for fileURL in files {
            let text = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let relativePath = relativePath(for: fileURL, relativeTo: repositoryRoot)
            for pattern in patterns where pattern.expression.firstMatch(in: text, range: range) != nil {
                findings.insert(.init(relativePath: relativePath, rule: pattern.rule))
            }
            let normalizedText = text.lowercased()
            if exactDenylist.contains(where: normalizedText.contains) {
                findings.insert(.init(relativePath: relativePath, rule: .externalDenylist))
            }
            for match in urlExpression.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text),
                      let host = URL(string: String(text[matchRange]))?.host?.lowercased()
                else { continue }
                let isReserved = isReserved(host: host)
                if !isReserved,
                   signedURLExpression.firstMatch(in: text, range: match.range) != nil {
                    findings.insert(.init(relativePath: relativePath, rule: .signedURL))
                }
                if !isReserved,
                   !publicPostHogHosts.contains(host),
                   !publicDocumentationHosts.contains(host),
                   !loopbackHosts.contains(host) {
                    findings.insert(.init(relativePath: relativePath, rule: .nonReservedURL))
                }
            }
            for match in emailExpression.matches(in: text, range: range) {
                guard let hostRange = Range(match.range(at: 1), in: text) else { continue }
                if !isReserved(host: String(text[hostRange]).lowercased()) {
                    findings.insert(.init(relativePath: relativePath, rule: .nonReservedEmail))
                }
            }
            for match in uuidExpression.matches(in: text, range: range) {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let identifier = String(text[matchRange]).lowercased()
                if !isManifestOwnedSyntheticUUID(identifier),
                   !allowedIdentifierExceptions.contains(identifier) {
                    findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticIdentifier))
                }
            }
            if appleSigningIdentifierExpression.firstMatch(in: text, range: range) != nil {
                findings.insert(.init(relativePath: relativePath, rule: .appleSigningIdentifier))
            }
            for match in contextualTenantIdentifierExpression.matches(in: text, range: range) {
                guard let kindRange = Range(match.range(at: 1), in: text),
                      let idRange = Range(match.range(at: 2), in: text),
                      !isAllowedContextualTenantIdentifier(
                        kind: String(text[kindRange]),
                        rawValue: String(text[idRange])
                      )
                else { continue }
                let rule: FixturePrivacyRule = String(text[kindRange]).lowercased() == "project"
                    ? .nonSyntheticProject
                    : .nonSyntheticIdentifier
                findings.insert(.init(relativePath: relativePath, rule: rule))
            }
            for match in projectPathExpression.matches(in: text, range: range) {
                guard let idRange = Range(match.range(at: 1), in: text),
                      !isAllowedSourceProjectReference(String(text[idRange]))
                else { continue }
                findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticProject))
            }
            for match in sourceProjectExpression.matches(in: text, range: range) {
                guard let idRange = Range(match.range(at: 1), in: text),
                      !isAllowedSourceProjectReference(String(text[idRange]))
                else { continue }
                findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticProject))
            }
        }
        return findings
            .sorted { ($0.relativePath, $0.rule.rawValue) < ($1.relativePath, $1.rule.rawValue) }
            .map { "\($0.relativePath): \($0.rule.rawValue)" }
    }

    private static func inspectStructuredValue(
        _ value: Any,
        key: String?,
        relativePath: String,
        findings: inout Set<FixturePrivacyFinding>,
        timestampExpression: NSRegularExpression = dateExpression
    ) {
        if let object = value as? [String: Any] {
            inspectColumnarRows(
                object,
                relativePath: relativePath,
                findings: &findings,
                timestampExpression: timestampExpression
            )
            for (childKey, child) in object {
                inspectStructuredValue(
                    child,
                    key: childKey,
                    relativePath: relativePath,
                    findings: &findings,
                    timestampExpression: timestampExpression
                )
            }
            return
        }
        if let array = value as? [Any] {
            for child in array {
                inspectStructuredValue(
                    child,
                    key: key,
                    relativePath: relativePath,
                    findings: &findings,
                    timestampExpression: timestampExpression
                )
            }
            return
        }
        if let number = value as? NSNumber {
            if let key,
               projectKeys.contains(key),
               number.intValue != SyntheticFixtureCatalog.projectID {
                findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticProject))
            }
            if let key,
               timestampKeys.contains(key),
               !isCanonicalReplayEpoch(number.doubleValue) {
                findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticTimestamp))
            }
            if let key, identifierKeys.contains(key) {
                findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticIdentifier))
            }
            if let key,
               isNumericIdentifierKey(key),
               !SyntheticFixtureCatalog.allowedNumericIdentifiers.contains(number.intValue),
               !isDocumentedHarmlessNumericIdentifier(
                   number.intValue,
                   key: key,
                   relativePath: relativePath
               ) {
                findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticIdentifier))
            }
            return
        }
        guard let string = value as? String else { return }
        let fullRange = NSRange(string.startIndex..<string.endIndex, in: string)
        for match in uuidExpression.matches(in: string, range: fullRange) {
            guard let matchRange = Range(match.range, in: string) else { continue }
            let identifier = String(string[matchRange]).lowercased()
            if !isManifestOwnedSyntheticUUID(identifier),
               !allowedIdentifierExceptions.contains(identifier) {
                findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticIdentifier))
            }
        }
        for match in timestampExpression.matches(in: string, range: fullRange) where key != "api_version" {
            guard let matchRange = Range(match.range, in: string) else { continue }
            if !String(string[matchRange]).hasPrefix("2026-01-") {
                findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticTimestamp))
            }
        }
        if opaqueIdentifierExpression.firstMatch(in: string, range: fullRange) != nil {
            findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticIdentifier))
        }
        if let key,
           identifierKeys.contains(key),
           !isExplicitSyntheticIdentifier(string) {
            findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticIdentifier))
        }
        if let key, projectKeys.contains(key), string != String(SyntheticFixtureCatalog.projectID) {
            findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticProject))
        }
        for match in projectPathExpression.matches(in: string, range: fullRange) {
            guard let idRange = Range(match.range(at: 1), in: string),
                  String(string[idRange]) != String(SyntheticFixtureCatalog.projectID)
            else { continue }
            findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticProject))
        }
        for match in cacheProjectExpression.matches(in: string, range: fullRange) {
            guard let idRange = Range(match.range(at: 1), in: string),
                  String(string[idRange]) != String(SyntheticFixtureCatalog.projectID)
            else { continue }
            findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticProject))
        }
        if let key,
           eventKeys.contains(key),
           !allowedEvents.contains(string) {
            findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticEvent))
        }
        if relativePath.hasSuffix("event_definitions.json"),
           key == "name",
           !allowedEvents.contains(string) {
            findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticEvent))
        }
    }

    private static func inspectColumnarRows(
        _ object: [String: Any],
        relativePath: String,
        findings: inout Set<FixturePrivacyFinding>,
        timestampExpression: NSRegularExpression
    ) {
        guard let columns = object["columns"] as? [String],
              let rows = object["results"] as? [Any]
        else { return }

        for case let row as [Any] in rows {
            for (index, rawColumn) in columns.enumerated() where index < row.count {
                let column = rawColumn.lowercased()
                let cell = row[index]
                inspectStructuredValue(
                    cell,
                    key: column,
                    relativePath: relativePath,
                    findings: &findings,
                    timestampExpression: timestampExpression
                )

                if let string = cell as? String,
                   positionalEventColumns.contains(column),
                   !allowedEvents.contains(string) {
                    findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticEvent))
                }
                if let string = cell as? String,
                   positionalIdentifierColumns.contains(column),
                   !isExplicitSyntheticIdentifier(string) {
                    findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticIdentifier))
                }
                if let string = cell as? String,
                   positionalSensitiveColumns.contains(column),
                   !isAllowedSyntheticSensitiveValue(string, column: column) {
                    findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticProduct))
                }
            }
        }
    }

    private static func isNumericIdentifierKey(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        return lowercased == "id"
            || lowercased == "ids"
            || lowercased.hasSuffix("_id")
            || lowercased.hasSuffix("_ids")
            || lowercased.hasSuffix("_integration")
            || [
                "dashboard", "github_issue_number", "insight", "task_number",
                "ticket_number", "usage_dashboard",
            ].contains(lowercased)
    }

    private static func isDocumentedHarmlessNumericIdentifier(
        _ value: Int,
        key: String,
        relativePath: String
    ) -> Bool {
        relativePath.hasSuffix("snapshot_blobs.jsonl")
            && key.lowercased() == "id"
            && (1...11).contains(value)
    }

    private static func isAllowedSyntheticSensitiveValue(_ value: String, column: String) -> Bool {
        if column == "email" {
            guard let separator = value.lastIndex(of: "@"),
                  separator < value.index(before: value.endIndex)
            else { return value.isEmpty }
            return isReserved(host: String(value[value.index(after: separator)...]).lowercased())
        }
        if column == "person" || column == "people" {
            return isExplicitSyntheticIdentifier(value)
                || SyntheticFixtureCatalog.allowedSensitiveColumnValues.contains(value)
        }
        if SyntheticFixtureCatalog.allowedSensitiveColumnValues.contains(value) { return true }
        let lowercased = value.lowercased()
        return ["example", "synthetic", "fictional", "fixture", "harbor", "meteor"]
            .contains(where: lowercased.contains)
    }

    private static func isReserved(host: String) -> Bool {
        SyntheticFixtureCatalog.allowedURLHosts.contains(host)
            || host == "example.net"
            || host == "example.org"
            || host.hasSuffix(".example.com")
            || host.hasSuffix(".example.net")
            || host.hasSuffix(".example.org")
            || host.hasSuffix(".example.invalid")
            || host.hasSuffix(".example")
    }

    private static func inspectPositionalReplayRecord(
        _ value: Any,
        relativePath: String,
        findings: inout Set<FixturePrivacyFinding>
    ) {
        guard let record = value as? [Any],
              record.count == 2,
              let identifier = record[0] as? String,
              let event = record[1] as? [String: Any],
              event["timestamp"] != nil,
              !isExplicitSyntheticIdentifier(identifier)
        else { return }
        findings.insert(.init(relativePath: relativePath, rule: .nonSyntheticIdentifier))
    }

    private static func isCanonicalReplayEpoch(_ rawValue: Double) -> Bool {
        guard rawValue.isFinite else { return false }
        let magnitude = abs(rawValue)
        let seconds: Double
        if magnitude >= 100_000_000_000_000 {
            seconds = rawValue / 1_000_000
        } else if magnitude >= 100_000_000_000 {
            seconds = rawValue / 1_000
        } else {
            seconds = rawValue
        }
        return canonicalReplayEpochSeconds.contains(seconds)
    }

    private static func isExplicitSyntheticIdentifier(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if allowedIdentifierExceptions.contains(lowercased) { return true }
        if let separator = lowercased.lastIndex(of: "@"),
           separator < lowercased.index(before: lowercased.endIndex),
           isReserved(host: String(lowercased[lowercased.index(after: separator)...])) {
            return true
        }
        let fullRange = NSRange(lowercased.startIndex..<lowercased.endIndex, in: lowercased)
        if let match = uuidExpression.firstMatch(in: lowercased, range: fullRange),
           match.range == fullRange {
            return isManifestOwnedSyntheticUUID(lowercased)
        }
        if explicitSyntheticIdentifierExpression.firstMatch(
            in: lowercased,
            range: fullRange
        )?.range == fullRange {
            return true
        }
        return explicitSyntheticDisplayIdentifierExpression.firstMatch(
            in: lowercased,
            range: fullRange
        )?.range == fullRange
    }

    private static func isAllowedSourceProjectReference(_ rawValue: String) -> Bool {
        guard let projectID = Int(rawValue.replacingOccurrences(of: "_", with: "")) else {
            return false
        }
        return SyntheticFixtureCatalog.allowedSourceProjectIDs.contains(projectID)
    }

    private static func isManifestOwnedSyntheticUUID(_ value: String) -> Bool {
        SyntheticFixtureCatalog.allowedUUIDs.contains(value.lowercased())
    }

    private static func isAllowedContextualTenantIdentifier(kind: String, rawValue: String) -> Bool {
        guard let value = Int(rawValue.replacingOccurrences(of: "_", with: "")) else {
            return false
        }
        switch kind.lowercased() {
        case "project":
            return SyntheticFixtureCatalog.allowedSourceProjectIDs.contains(value)
        case "user":
            return (700_000..<710_000).contains(value)
        case "flag":
            return (710_000..<720_000).contains(value)
        case "insight":
            return (720_000..<725_000).contains(value)
        case "dashboard":
            return (725_000..<730_000).contains(value)
        case "cohort":
            return (730_000..<735_000).contains(value)
        case "subscriber":
            return (735_000..<738_000).contains(value)
        case "issue":
            return (738_000..<739_000).contains(value)
        case "session":
            return (739_000..<740_000).contains(value)
        default:
            return false
        }
    }

    private static func relativePath(for fileURL: URL, relativeTo repositoryRoot: URL) -> String {
        let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(rootPrefix) else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(rootPrefix.count))
    }
}

@Suite("Fixture privacy", .serialized)
struct FixturePrivacyTests {
    private struct InventoryError: Error {}

    private let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private let generatedDirectoryNames: Set<String> = [
        ".build", ".git", ".swiftpm", ".worktrees", ".superpowers", "build", "DerivedData",
    ]
    @Test("ordinary fixture inventories are declared and shared copies are exact")
    func fixtureInventoriesAreDeclaredAndCopiesAreExact() throws {
        let packageRoot = repositoryRoot.appending(path: "GetHogKit/Tests/GetHogKitTests/Fixtures")
        let demoRoot = repositoryRoot.appending(path: "GetHog/Resources/DemoData")
        let packageNames = try fixtureNames(in: packageRoot)
        let demoNames = try fixtureNames(in: demoRoot)
        #expect(packageNames == SyntheticFixtureCatalog.packageFixtureNames)
        #expect(
            demoNames == Set(SyntheticFixtureCatalog.demoCopies.keys)
                .union(SyntheticFixtureCatalog.demoOnlyFixtureNames)
        )
        let mismatches: [String] = try SyntheticFixtureCatalog.demoCopies.compactMap { demoName, packageName in
            guard !SyntheticFixtureCatalog.replayFixtureNames.contains(demoName),
                  !SyntheticFixtureCatalog.replayFixtureNames.contains(packageName)
            else { return nil }
            let packageData = try Data(contentsOf: packageRoot.appending(path: packageName))
            let demoData = try Data(contentsOf: demoRoot.appending(path: demoName))
            return packageData == demoData ? nil : "GetHog/Resources/DemoData/\(demoName): exact-copy"
        }.sorted()
        #expect(mismatches.isEmpty, "Fixture catalog violations:\n\(mismatches.joined(separator: "\n"))")
    }

    @Test("ordinary fixtures contain only fictional data")
    func ordinaryFixturesContainOnlyFictionalData() throws {
        let roots = [
            repositoryRoot.appending(path: "GetHogKit/Tests/GetHogKitTests/Fixtures"),
            repositoryRoot.appending(path: "GetHog/Resources/DemoData"),
        ]
        let findings = try roots.flatMap {
            try FixturePrivacyScanner.findings(in: $0, relativeTo: repositoryRoot)
        }.sorted()
        #expect(findings.isEmpty, "Fixture privacy violations:\n\(findings.joined(separator: "\n"))")
    }

    @Test("query response schemas use public column and type tokens")
    func queryResponseSchemasUsePublicTokens() throws {
        let roots = [
            repositoryRoot.appending(path: "GetHogKit/Tests/GetHogKitTests/Fixtures"),
            repositoryRoot.appending(path: "GetHog/Resources/DemoData"),
        ]
        let placeholder = try NSRegularExpression(
            pattern: #"\b(?:Example|Synthetic|Harbor)\b"#,
            options: .caseInsensitive
        )
        var findings: [String] = []

        for root in roots {
            for file in try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) where file.pathExtension == "json"
                && !SyntheticFixtureCatalog.replayFixtureNames.contains(file.lastPathComponent) {
                let data = try Data(contentsOf: file)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let columns = object["columns"] as? [Any],
                      object["results"] is [Any]
                else { continue }

                let schemaTokens = columns + ((object["types"] as? [[Any]])?.flatMap { $0 } ?? [])
                if schemaTokens.compactMap({ $0 as? String }).contains(where: { token in
                    placeholder.firstMatch(
                        in: token,
                        range: NSRange(token.startIndex..., in: token)
                    ) != nil
                }) {
                    findings.append(
                        file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
                    )
                }
            }
        }

        #expect(findings.sorted().isEmpty, "Query schema placeholder files:\n\(findings.sorted().joined(separator: "\n"))")
    }

    @Test("replay and session fixtures receive the ordinary privacy scan")
    func replayFixturesReceivePrivacyScan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-replay-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let externalHost = ["private", "-domain", ".test"].joined()
        let data = Data(
            ("{\"start_url\":\"" + "https://" + externalHost + "\"}").utf8
        )
        try data.write(to: directory.appending(path: "session_recordings_filtered.json"))

        let findings = try FixturePrivacyScanner.findings(
            in: directory,
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == ["session_recordings_filtered.json: non-reserved-url"])
    }

    @Test("columnar query rows inherit privacy rules from their columns")
    func columnarQueryRowsInheritColumnPrivacyRules() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-columnar-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let externalHost = ["tenant", "-internal.test"].joined()
        let payload: [String: Any] = [
            "columns": ["event", "distinct_id", "properties.$current_url", "product_name"],
            "results": [[
                "private_checkout_completed",
                "opaque-person-8492",
                "https://\(externalHost)/account",
                "Internal Billing Console",
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appending(path: "columnar.json"))

        let findings = try FixturePrivacyScanner.findings(
            in: directory,
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(Set(findings) == Set([
            "columnar.json: non-reserved-url",
            "columnar.json: non-synthetic-event",
            "columnar.json: non-synthetic-identifier",
            "columnar.json: non-synthetic-product",
        ]))
    }

    @Test("generic and nested numeric resource IDs require catalog membership")
    func numericResourceIDsRequireCatalogMembership() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-numeric-id-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cases: [(String, Any)] = [
            ("generic.json", ["id": 987_654]),
            ("nested.json", ["created_by": ["id": 987_655]]),
            ("resource.json", ["feature_flag": ["id": 987_656]]),
            ("cataloged.json", ["id": 725_101]),
            ("harmless.json", ["count": 987_654, "status_code": 987_655, "duration_ms": 987_656]),
        ]
        for (name, object) in cases {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: directory.appending(path: name))
        }

        let findings = try FixturePrivacyScanner.findings(
            in: directory,
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == [
            "generic.json: non-synthetic-identifier",
            "nested.json: non-synthetic-identifier",
            "resource.json: non-synthetic-identifier",
        ])
    }

    @Test("JSONL records receive structural and decoded-text privacy scans")
    func jsonlRecordsReceiveStructuralPrivacyScan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-jsonl-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let denylist = directory.appending(path: ".denylist")
        try Data("forbidden-fixture-value-42\n".utf8).write(to: denylist)
        let previousDenylist = getenv("GETHOG_FIXTURE_DENYLIST_FILE").map { String(cString: $0) }
        setenv("GETHOG_FIXTURE_DENYLIST_FILE", denylist.path, 1)
        defer {
            if let previousDenylist {
                setenv("GETHOG_FIXTURE_DENYLIST_FILE", previousDenylist, 1)
            } else {
                unsetenv("GETHOG_FIXTURE_DENYLIST_FILE")
            }
        }

        let projectKey = ["project", "_id"].joined()
        let sessionKey = ["session", "_id"].joined()
        let nonCanonicalSession = [
            "019f0000", "-0000-7000-8000-", "000000000001",
        ].joined()
        let externalHost = ["private", "-domain", ".test"].joined()
        let authorizationKey = ["Author", "ization"].joined()
        let authorizationValue = ["Be", "arer synthetic-token-value"].joined()
        let cloudCredential = ["AK", "IAABCDEFGHIJKLMNOP"].joined()
        let denyValue = ["forbidden-fixture-", "value-42"].joined()
        let records: [[String: Any]] = [
            [
                projectKey: 9_001,
                "event": "private_event",
                sessionKey: nonCanonicalSession,
                "timestamp": "2025-12-01T00:00:00Z",
            ],
            [
                "url": "https://" + externalHost,
                "email": "person@" + externalHost,
                authorizationKey: authorizationValue,
                "credential": cloudCredential,
                "deny": denyValue.uppercased(),
            ],
        ]
        let jsonl = try records.map { record in
            String(
                decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                as: UTF8.self
            )
        }.joined(separator: "\n")
        try Data(jsonl.utf8).write(to: directory.appending(path: "privacy-records.jsonl"))

        let findings = try FixturePrivacyScanner.findings(
            in: directory,
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(Set(findings) == Set([
            "privacy-records.jsonl: authorization-header",
            "privacy-records.jsonl: aws-credential",
            "privacy-records.jsonl: external-denylist",
            "privacy-records.jsonl: non-reserved-email",
            "privacy-records.jsonl: non-reserved-url",
            "privacy-records.jsonl: non-synthetic-event",
            "privacy-records.jsonl: non-synthetic-identifier",
            "privacy-records.jsonl: non-synthetic-project",
            "privacy-records.jsonl: non-synthetic-timestamp",
        ]))
    }

    @Test("numeric replay epochs and opaque IDs require canonical synthetic formats")
    func numericReplayEpochsAndOpaqueIdentifiersAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-jsonl-structure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let canonicalSession = "018f1000-0000-7000-8000-000000000001"
        let opaqueIdentifier = ["Opaque", "Token", "9K4X2M7Q"].joined()
        let januaryEpochMilliseconds = 1_768_478_400_000 as NSNumber
        let outsideJanuaryEpochMilliseconds = 1_800_000_000_000 as NSNumber

        func writeRecord(_ record: Any, named name: String) throws {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: directory.appending(path: name))
        }

        try writeRecord(
            [
                "timestamp": januaryEpochMilliseconds,
                "session_id": canonicalSession,
                "window_id": "window-example-001",
                "distinct_id": "person-example-001",
            ],
            named: "canonical.jsonl"
        )
        try writeRecord(
            [
                "timestamp": outsideJanuaryEpochMilliseconds,
                "session_id": opaqueIdentifier,
                "window_id": opaqueIdentifier,
                "distinct_id": opaqueIdentifier,
            ],
            named: "keyed.jsonl"
        )
        try writeRecord(
            [opaqueIdentifier, ["timestamp": outsideJanuaryEpochMilliseconds]],
            named: "positional.jsonl"
        )
        try writeRecord(
            [
                "timestamp": januaryEpochMilliseconds,
                "data": [
                    "payload": [
                        "requests": [["timeOrigin": outsideJanuaryEpochMilliseconds]],
                    ],
                ],
            ],
            named: "time-origin.jsonl"
        )
        try writeRecord(
            ["distinct_ids": [opaqueIdentifier]],
            named: "distinct-ids.jsonl"
        )
        try writeRecord(
            ["session_id": 987_654],
            named: "numeric-identifier.jsonl"
        )

        let findings = try FixturePrivacyScanner.findings(
            in: directory,
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == [
            "distinct-ids.jsonl: non-synthetic-identifier",
            "keyed.jsonl: non-synthetic-identifier",
            "keyed.jsonl: non-synthetic-timestamp",
            "numeric-identifier.jsonl: non-synthetic-identifier",
            "positional.jsonl: non-synthetic-identifier",
            "positional.jsonl: non-synthetic-timestamp",
            "time-origin.jsonl: non-synthetic-timestamp",
        ])
    }

    @Test("UUIDs require manifest-owned deterministic namespaces, not a shared prefix")
    func uuidRulesRejectPrefixLookalikes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-uuid-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let privateSuffix = ["9a7b", "4c2d", "8e1f"].joined()
        let prefixLookalike = "018faaaa-bbbb-7ccc-8ddd-\(privateSuffix)"
        let unlistedStructured = [
            "018f2000", "-0000-7000-8000-", "999999999998",
        ].joined()
        let canonical = SyntheticFixtureCatalog.primarySessionID
        try Data("\(prefixLookalike)\n\(canonical)\n".utf8)
            .write(to: directory.appending(path: "lookalike.swift"))
        try Data("\(unlistedStructured)\n".utf8)
            .write(to: directory.appending(path: "unlisted.swift"))

        let findings = try FixturePrivacyScanner.sourceFindings(
            in: [
                directory.appending(path: "lookalike.swift"),
                directory.appending(path: "unlisted.swift"),
            ],
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == [
            "lookalike.swift: non-synthetic-identifier",
            "unlisted.swift: non-synthetic-identifier",
        ])
    }

    @Test("signed URL detection permits reserved examples and rejects external hosts")
    func signedURLRulesAreContextual() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-signed-url-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reserved = directory.appending(path: "reserved.swift")
        let external = directory.appending(path: "external.swift")
        let postHog = directory.appending(path: "posthog.swift")
        let signature = ["X-Amz-", "Signature", "=synthetic"].joined()
        let scheme = ["ht", "tps://"].joined()
        let reservedHost = ["cdn", ".example.com"].joined()
        let externalHost = ["private", "-domain.test"].joined()
        let publicHost = ["us", ".posthog.com"].joined()
        func declaration(host: String) -> Data {
            Data(("let url = \"" + scheme + host + "/render?" + signature + "\"").utf8)
        }
        try declaration(host: reservedHost)
            .write(to: reserved)
        try declaration(host: externalHost)
            .write(to: external)
        try declaration(host: publicHost)
            .write(to: postHog)

        let findings = try FixturePrivacyScanner.sourceFindings(
            in: [reserved, external, postHog],
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == [
            "external.swift: non-reserved-url",
            "external.swift: signed-url",
            "posthog.swift: signed-url",
        ])
    }

    /// A loopback probe started by a test names no tenant and reaches no external
    /// host, so it is reserved for host rules — but a credential-shaped query is
    /// still a credential wherever it is pointed.
    @Test("loopback probe URLs are reserved without excusing signed-URL queries")
    func loopbackURLsAreReservedButStillScannedForSignatures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-loopback-url-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let scheme = ["ht", "tp://"].joined()
        let signature = ["X-Amz-", "Signature", "=synthetic"].joined()
        let loopbackHosts = [
            ("ipv4.swift", ["127.", "0.0.1", ":8080"].joined()),
            ("named.swift", ["local", "host", ":9000"].joined()),
            ("ipv6.swift", ["[:", ":1]", ":9000"].joined()),
        ]
        for (name, host) in loopbackHosts {
            try Data(("let url = \"" + scheme + host + "/probe-asset.png\"").utf8)
                .write(to: directory.appending(path: name))
        }
        let signedHost = ["127.", "0.0.1", ":8080"].joined()
        try Data(("let url = \"" + scheme + signedHost + "/render?" + signature + "\"").utf8)
            .write(to: directory.appending(path: "signed.swift"))

        let findings = try FixturePrivacyScanner.sourceFindings(
            in: loopbackHosts.map { directory.appending(path: $0.0) }
                + [directory.appending(path: "signed.swift")],
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == ["signed.swift: signed-url"])
    }

    @Test("escaped JSON URLs receive the decoded text privacy scan")
    func escapedJSONURLsReceiveDecodedTextPrivacyScan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-escaped-json-url-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let escapedSlash = "\\/"
        let scheme = ["ht", "tps:"].joined() + escapedSlash + escapedSlash
        let signature = ["X-Amz-", "Signature", "=synthetic"].joined()
        let cases = [
            ("reserved.json", ["cdn", ".example.com"].joined()),
            ("us.json", ["us", ".posthog.com"].joined()),
            ("eu.json", ["eu", ".posthog.com"].joined()),
            ("external.json", ["private", "-domain.test"].joined()),
        ]
        for (name, host) in cases {
            let escapedURL = "\(scheme)\(host)\\/render?\(signature)"
            let rawJSON = "{\"urls\":[\"\(escapedURL)\",\"\(escapedURL)\"]}"
            #expect(rawJSON.contains("https:\\/\\/"))
            try Data(rawJSON.utf8).write(to: directory.appending(path: name))
        }

        let findings = try FixturePrivacyScanner.findings(
            in: directory,
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == [
            "eu.json: signed-url",
            "external.json: non-reserved-url",
            "external.json: signed-url",
            "us.json: signed-url",
        ])
    }

    /// Catches a broad numeric matcher that makes ordinary endpoint unit tests
    /// fail while still proving tenant-shaped project references cannot pass.
    @Test("source project rules allow test sentinels and reject tenant-shaped values")
    func sourceProjectRulesAreContextual() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-source-project-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectReference = ["project", "ID"].joined()
        try Data("let \(projectReference) = 42\n".utf8)
            .write(to: directory.appending(path: "generic.swift"))
        try Data("let \(projectReference) = 1_001\n".utf8)
            .write(to: directory.appending(path: "canonical.swift"))
        try Data("let \(projectReference) = 987_654\n".utf8)
            .write(to: directory.appending(path: "tenant-shaped.swift"))
        try Data("let \(projectReference) = 43\n".utf8)
            .write(to: directory.appending(path: "unlisted-small.swift"))

        let findings = try FixturePrivacyScanner.sourceFindings(
            in: [
                directory.appending(path: "generic.swift"),
                directory.appending(path: "canonical.swift"),
                directory.appending(path: "tenant-shaped.swift"),
                directory.appending(path: "unlisted-small.swift"),
            ],
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == [
            "tenant-shaped.swift: non-synthetic-project",
            "unlisted-small.swift: non-synthetic-project",
        ])
    }

    @Test("singular console project routes enforce the synthetic project catalog")
    func singularConsoleProjectRoutesAreChecked() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-console-route-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = ["us", ".posthog.com"].joined()
        let consoleRoute = ["/pro", "ject/"].joined()
        try Data("let url = \"https://\(host)\(consoleRoute)987654/insights/42\"\n".utf8)
            .write(to: directory.appending(path: "console.swift"))
        try Data("let url = \"https://\(host)\(consoleRoute)1001/insights/42\"\n".utf8)
            .write(to: directory.appending(path: "synthetic.swift"))

        let findings = try FixturePrivacyScanner.sourceFindings(
            in: [
                directory.appending(path: "console.swift"),
                directory.appending(path: "synthetic.swift"),
            ],
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == ["console.swift: non-synthetic-project"])
    }

    @Test("strict audits reject a missing external denylist")
    func strictAuditsRejectMissingExternalDenylist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-strict-denylist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let previousStrict = getenv("GETHOG_REQUIRE_FIXTURE_DENYLIST").map { String(cString: $0) }
        let previousPath = getenv("GETHOG_FIXTURE_DENYLIST_FILE").map { String(cString: $0) }
        setenv("GETHOG_REQUIRE_FIXTURE_DENYLIST", "1", 1)
        unsetenv("GETHOG_FIXTURE_DENYLIST_FILE")
        defer {
            if let previousStrict {
                setenv("GETHOG_REQUIRE_FIXTURE_DENYLIST", previousStrict, 1)
            } else {
                unsetenv("GETHOG_REQUIRE_FIXTURE_DENYLIST")
            }
            if let previousPath {
                setenv("GETHOG_FIXTURE_DENYLIST_FILE", previousPath, 1)
            } else {
                unsetenv("GETHOG_FIXTURE_DENYLIST_FILE")
            }
        }

        #expect(throws: (any Error).self) {
            try FixturePrivacyScanner.findings(in: directory, relativeTo: directory)
        }
    }

    @Test("source privacy rejects public log payloads and local diagnostic metadata")
    func unsafeDiagnosticsAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-diagnostic-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let publicPrivacy = ["privacy: ", ".public"].joined()
        let publicLog = "log.debug(\"Opened \\(title, \(publicPrivacy))\")"
        let pathMember = ["file", ".path"].joined()
        let simulatorIdentifier = ["device", "UDID"].joined()
        let simulatorName = ["device", "Name"].joined()
        let absolutePathLog = "print(\"FAILED \\(\(pathMember))\")"
        let simulatorLog = "print(\"device \\(\(simulatorIdentifier)) \\(\(simulatorName))\")"
        let multilinePathLog = "print(\"\"\"\nFAILED \\(\(pathMember))\n\"\"\")"
        try Data(publicLog.utf8).write(to: directory.appending(path: "public-log.swift"))
        try Data(absolutePathLog.utf8).write(to: directory.appending(path: "path-log.swift"))
        try Data(multilinePathLog.utf8).write(to: directory.appending(path: "path-log-multiline.swift"))
        try Data(simulatorLog.utf8).write(to: directory.appending(path: "simulator-log.swift"))

        let findings = try FixturePrivacyScanner.sourceFindings(
            in: [
                directory.appending(path: "path-log.swift"),
                directory.appending(path: "path-log-multiline.swift"),
                directory.appending(path: "public-log.swift"),
                directory.appending(path: "simulator-log.swift"),
            ],
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == [
            "path-log-multiline.swift: unsafe-diagnostic-metadata",
            "path-log.swift: unsafe-diagnostic-metadata",
            "public-log.swift: public-log-interpolation",
            "simulator-log.swift: unsafe-diagnostic-metadata",
        ])
    }

    @Test("source privacy rejects signing prefixes and contextual tenant identifiers")
    func sourceSigningAndTenantIdentifiersAreContextual() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-source-identity-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let signingPrefix = ["9Z8Y", "7X6W5V"].joined()
        let privateBase = ["987", "654"].joined()
        let privateKinds = ["project", "user id", "flag", "insight", "cohort", "dashboard"]
        let privateLines = privateKinds.enumerated().map { offset, kind in
            "let note\(offset) = \"\(kind) \((Int(privateBase) ?? 0) + offset)\""
        }.joined(separator: "\n")
        let allowedLines = [
            "let project = \"project \(SyntheticFixtureCatalog.projectID)\"",
            "let user = \"user id \(700_000 + 101)\"",
            "let flag = \"flag \(710_000 + 101)\"",
            "let insight = \"insight \(720_000 + 101)\"",
            "let cohort = \"cohort \(730_000 + 101)\"",
            "let dashboard = \"dashboard \(725_000 + 101)\"",
            "let subscriber = \"subscriber \(735_000 + 101)\"",
            "let issue = \"issue \(738_000 + 101)\"",
            "let session = \"session \(739_000 + 101)\"",
        ].joined(separator: "\n")
        let nearMissLines = [
            "let user = \"user id \(710_000 + 101)\"",
            "let flag = \"flag \(700_000 + 101)\"",
            "let dashboard = \"dashboard \(720_000 + 101)\"",
            "let cohort = \"cohort \(735_000 + 101)\"",
        ].joined(separator: "\n")
        let publicDocs = [
            "https://developer.apple.com/documentation/backgroundtasks",
            "https://posthog.com/docs/api",
            "https://github.com/PostHog/posthog",
        ].map { "let url = \"\($0)\"" }.joined(separator: "\n")

        try Data("let group = \"\(signingPrefix).app.gethog.shared\"\n".utf8)
            .write(to: directory.appending(path: "signing.swift"))
        try Data(privateLines.utf8).write(to: directory.appending(path: "private.swift"))
        try Data(allowedLines.utf8).write(to: directory.appending(path: "allowed.swift"))
        try Data(nearMissLines.utf8).write(to: directory.appending(path: "near-miss.swift"))
        try Data(publicDocs.utf8).write(to: directory.appending(path: "docs.swift"))

        let files = ["allowed.swift", "docs.swift", "near-miss.swift", "private.swift", "signing.swift"]
            .map { directory.appending(path: $0) }
        let findings = try FixturePrivacyScanner.sourceFindings(
            in: files,
            relativeTo: directory.resolvingSymlinksInPath()
        )

        #expect(findings == [
            "near-miss.swift: non-synthetic-identifier",
            "private.swift: non-synthetic-identifier",
            "private.swift: non-synthetic-project",
            "signing.swift: apple-signing-identifier",
        ])
    }

    @Test("source privacy rejects live-derived provenance without blocking UI measurements")
    func sourceCaptureProvenanceIsContextual() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-source-provenance-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let denied: [String] = [
            ["captured ", "li", "ve response"].joined(),
            ["recorded ", "li", "ve response"].joined(),
            ["measured against", " project"].joined(),
            ["sent for", " real"].joined(),
            ["this", " deployment"].joined(),
            ["repository", " recordings"].joined(),
            ["live", " response"].joined(),
            ["live", " responses"].joined(),
            ["verified", " live"].joined(),
            ["live", "-verified"].joined(),
            ["measured on this ", "deployment"].joined(),
            ["measured against live ", "responses"].joined(),
            ["li", "ve project"].joined(),
            ["li", "ve host serves"].joined(),
            ["observed", " cohort"].joined(),
            ["measured against the ", "li", "ve project"].joined(),
            ["photographed", " exactly"].joined(),
            ["verified against the ", "project"].joined(),
            ["checked against this ", "tenant"].joined(),
            ["read li", "ve responses"].joined(),
            ["the key this ", "project develops against"].joined(),
            ["this ", "project returned zero rows"].joined(),
            ["this ", "project returned 17 rows"].joined(),
            ["this ", "project returned data dated 2025-03-04"].joined(),
            ["project this was built ", "against"].joined(),
            ["works with the current personal ", "API key"].joined(),
            ["the available key is read-", "only"].joined(),
            ["a real ", "payload"].joined(),
            ["PostHog actually ", "sent"].joined(),
            ["sent from this ", "machine"].joined(),
            ["project this app was built ", "against"].joined(),
            ["measured ", "live"].joined(),
            ["captured ", "blob_v2"].joined(),
            ["observed on the ", "wire"].joined(),
            ["every observed ", "row"].joined(),
        ]
        for (offset, phrase) in denied.enumerated() {
            try Data("// \(phrase)\n".utf8)
                .write(to: directory.appending(path: "denied-\(offset).swift"))
        }
        try Data("""
        // UI width measured at 390 points for compact layout.
        let emptyState = "This project has no saved insights."
        let supportState = "This project has zero tickets."
        """.utf8)
            .write(to: directory.appending(path: "safe.swift"))

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).sorted { $0.path < $1.path }
        let findings = try FixturePrivacyScanner.sourceFindings(
            in: files,
            relativeTo: directory.resolvingSymlinksInPath()
        )

        let expected = (0..<denied.count)
            .map { "denied-\($0).swift: capture-provenance" }
            .sorted()
        #expect(findings == expected)
    }

    @Test("all test, UI, screenshot and fixture-consuming Swift sources pass the privacy gate")
    func fixtureConsumersContainOnlySyntheticReferences() throws {
        let files = try sourceFilesForPrivacyScan()
        let findings = try FixturePrivacyScanner.sourceFindings(
            in: files,
            relativeTo: repositoryRoot
        )
        #expect(findings.isEmpty, "Fixture source privacy violations:\n\(findings.joined(separator: "\n"))")
    }

    @Test("the source privacy inventory includes its own scanner")
    func sourcePrivacyInventoryIncludesScanner() throws {
        let scanner = repositoryRoot
            .appending(path: "GetHogKit/Tests/GetHogKitTests/FixturePrivacyTests.swift")
            .resolvingSymlinksInPath()

        #expect(try sourceFilesForPrivacyScan().contains(scanner))
    }

    @Test("the privacy inventory includes relevant repository text formats")
    func sourcePrivacyInventoryIncludesRelevantRepositoryText() throws {
        let included = Set(try sourceFilesForPrivacyScan().map { $0.resolvingSymlinksInPath() })
        let representatives = [
            ".editorconfig",
            "README.md",
            "LICENSE",
            "project.yml",
            "scripts/verify-public-tree",
            "GetHogKit/Package.swift",
            "GetHog/Sources/App/GetHogApp.swift",
            "GetHog/Support/GetHog-Info.plist",
            "GetHog/Support/GetHog.entitlements",
            "GetHog/Resources/rrweb-player/rrweb-player.css",
            "GetHog/Resources/rrweb-player/rrweb-player.min.js",
            "GetHogKit/Sources/GetHogKit/Net/PostHogAPI.swift",
            "GetHogWidgets/GetHogWidgetBundle.swift",
        ].map { repositoryRoot.appending(path: $0).resolvingSymlinksInPath() }

        for representative in representatives {
            #expect(included.contains(representative), "missing \(representative.path)")
        }
        #expect(!included.contains(
            repositoryRoot.appending(path: "GetHog/Resources/Assets.xcassets/AppIcon.appiconset/icon-dark.png")
                .resolvingSymlinksInPath()
        ))
        #expect(included.allSatisfy { file in
            let relativePath = file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
            return !relativePath.split(separator: "/")
                .contains(where: { generatedDirectoryNames.contains(String($0)) })
        })
    }

    @Test("a public-tree manifest drives inclusion and relevant-format exclusion")
    func publicTreeManifestDrivesPrivacyInventory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-public-tree-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appending(path: "manifest.txt")
        let paths = [
            "README.md",
            "GetHog/Resources/rrweb-player/rrweb-player.css",
            "GetHog/Resources/Assets.xcassets/AppIcon.appiconset/icon-dark.png",
            "build/generated.swift",
        ]
        try Data(paths.joined(separator: "\n").utf8).write(to: manifest)

        let previous = getenv("GETHOG_PUBLIC_TREE_MANIFEST").map { String(cString: $0) }
        setenv("GETHOG_PUBLIC_TREE_MANIFEST", manifest.path, 1)
        defer {
            if let previous {
                setenv("GETHOG_PUBLIC_TREE_MANIFEST", previous, 1)
            } else {
                unsetenv("GETHOG_PUBLIC_TREE_MANIFEST")
            }
        }

        let included = Set(try sourceFilesForPrivacyScan().map { $0.resolvingSymlinksInPath() })
        #expect(included == Set([
            repositoryRoot.appending(path: "README.md").resolvingSymlinksInPath(),
            repositoryRoot.appending(path: "GetHog/Resources/rrweb-player/rrweb-player.css")
                .resolvingSymlinksInPath(),
        ]))
    }

    @Test("a public-tree manifest rejects paths outside the repository")
    func publicTreeManifestRejectsInvalidPaths() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "gethog-invalid-public-tree-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appending(path: "manifest.txt")
        try Data("../outside.swift\n/absolute/path.swift\n".utf8).write(to: manifest)

        let previous = getenv("GETHOG_PUBLIC_TREE_MANIFEST").map { String(cString: $0) }
        setenv("GETHOG_PUBLIC_TREE_MANIFEST", manifest.path, 1)
        defer {
            if let previous {
                setenv("GETHOG_PUBLIC_TREE_MANIFEST", previous, 1)
            } else {
                unsetenv("GETHOG_PUBLIC_TREE_MANIFEST")
            }
        }

        #expect(throws: (any Error).self) {
            try sourceFilesForPrivacyScan()
        }
    }

    private func sourceFilesForPrivacyScan() throws -> [URL] {
        let candidates: [URL]
        if let manifestPath = ProcessInfo.processInfo.environment["GETHOG_PUBLIC_TREE_MANIFEST"],
           !manifestPath.isEmpty {
            candidates = try filesFromPublicTreeManifest(at: URL(fileURLWithPath: manifestPath))
        } else {
            let enumerator = try #require(
                FileManager.default.enumerator(
                    at: repositoryRoot,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: []
                ),
                "Missing repository root"
            )
            var discovered: [URL] = []
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true,
                   hasGeneratedPathComponent(file) {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isRegularFile == true {
                    discovered.append(file)
                }
            }
            candidates = discovered
        }

        return try Set(candidates.compactMap { file in
            try isRelevantPrivacyTextFile(file) ? file.resolvingSymlinksInPath() : nil
        }).sorted { $0.path < $1.path }
    }

    private func filesFromPublicTreeManifest(at manifest: URL) throws -> [URL] {
        let text = try String(contentsOf: manifest, encoding: .utf8)
        let root = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var files: [URL] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let path = String(rawLine)
            guard !path.isEmpty,
                  path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }),
                  !path.hasPrefix("/"),
                  !path.contains("\\")
            else { throw InventoryError() }

            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { throw InventoryError() }
            if components.contains(where: { generatedDirectoryNames.contains(String($0)) }) {
                continue
            }

            let file = root.appending(path: path)
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPrefix),
                  FileManager.default.fileExists(atPath: resolved.path)
            else { throw InventoryError() }
            files.append(resolved)
        }
        return files
    }

    private func isRelevantPrivacyTextFile(_ file: URL) throws -> Bool {
        if hasGeneratedPathComponent(file) { return false }
        let relativePath = file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
        if (relativePath.hasPrefix("GetHog/Resources/DemoData/")
            || relativePath.hasPrefix("GetHogKit/Tests/GetHogKitTests/Fixtures/")),
           ["json", "jsonl"].contains(file.pathExtension.lowercased()) {
            return false
        }

        let data = try Data(contentsOf: file)
        return String(data: data, encoding: .utf8) != nil
    }

    private func hasGeneratedPathComponent(_ file: URL) -> Bool {
        let relativePath = file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
        return relativePath.split(separator: "/")
            .contains(where: { generatedDirectoryNames.contains(String($0)) })
    }

    private func fixtureNames(in directory: URL) throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            ).filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
                .map(\.lastPathComponent)
        )
    }
}

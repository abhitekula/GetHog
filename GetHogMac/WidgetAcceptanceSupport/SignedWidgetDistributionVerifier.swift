import Foundation

enum SignedWidgetDistributionVerifier {
    enum Status: String, Equatable, Sendable {
        case signatureValid = "signature-valid"
        case signatureInvalid = "signature-invalid"
        case requiredSinglePresent = "required-single-present"
        case requiredSingleMissing = "required-single-missing-key"
        case requiredSingleWrongType = "required-single-wrong-type"
        case requiredSingleEmpty = "required-single-empty"
        case requiredSingleMultiple = "required-single-multiple"
        case matching
        case mismatched
        case requiredPresent = "required-present"
        case requiredMissing = "required-missing"
        case forbiddenAbsent = "forbidden-absent"
        case forbiddenPresent = "forbidden-present"
    }

    struct Result: Equatable, Sendable {
        let isAccepted: Bool
        let report: String
    }

    struct CommandResult: Sendable {
        let status: Int32
        let output: Data
    }

    enum VerificationError: Error, Equatable {
        case builtProductMissing
        case builtProductAmbiguous
        case entitlementsUnreadable
    }

    private static let groupKey = "com.apple.security.application-groups"
    private static let networkKey = "com.apple.security.network.client"
    private static let extensionRelativePath = "Contents/PlugIns/GetHogWidgets.appex"

    /// Finds the exact app product beside an actually loaded UI-test bundle.
    /// No process environment can redirect this lookup to a different build.
    static func applicationURL(
        testBundleURL: URL,
        isDirectory: (URL) -> Bool = {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    ) throws -> URL {
        var directory = testBundleURL.deletingLastPathComponent()
        var candidates: Set<URL> = []

        while directory.path != "/" {
            let app = directory.appending(path: "GetHog.app")
            let widget = app.appending(path: extensionRelativePath)
            if isDirectory(app), isDirectory(widget) {
                candidates.insert(app.standardizedFileURL)
            }
            directory.deleteLastPathComponent()
        }

        guard !candidates.isEmpty else { throw VerificationError.builtProductMissing }
        guard candidates.count == 1, let app = candidates.first else {
            throw VerificationError.builtProductAmbiguous
        }
        return app
    }

    /// Verifies signatures and compares resolved entitlements. Entitlement
    /// values exist only as transient locals; the returned result contains
    /// key names and structural statuses exclusively.
    static func verify(
        testBundleURL: URL,
        isDirectory: (URL) -> Bool = {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        },
        runCommand: ([String]) throws -> CommandResult = {
            try SignedWidgetDistributionVerifier.runCodesign(arguments: $0)
        }
    ) throws -> Result {
        let app = try applicationURL(testBundleURL: testBundleURL, isDirectory: isDirectory)
        let widget = app.appending(path: extensionRelativePath)
        let appSignature = try runCommand(["--verify", "--strict", app.path]).status == 0
        let widgetSignature = try runCommand(["--verify", "--strict", widget.path]).status == 0
        let appEntitlements = try entitlements(at: app, runCommand: runCommand)
        let widgetEntitlements = try entitlements(at: widget, runCommand: runCommand)
        let appGroups = groupState(appEntitlements[groupKey])
        let widgetGroups = groupState(widgetEntitlements[groupKey])
        let parity: Status = appGroups.value != nil && appGroups.value == widgetGroups.value
            ? .matching
            : .mismatched
        let appNetwork: Status = appEntitlements[networkKey] as? Bool == true
            ? .requiredPresent
            : .requiredMissing
        let widgetNetwork: Status = widgetEntitlements[networkKey] == nil
            ? .forbiddenAbsent
            : .forbiddenPresent
        let checks: [(String, String, Status)] = [
            ("app", "signature", appSignature ? .signatureValid : .signatureInvalid),
            ("extension", "signature", widgetSignature ? .signatureValid : .signatureInvalid),
            ("app", groupKey, appGroups.status),
            ("extension", groupKey, widgetGroups.status),
            ("parity", groupKey, parity),
            ("app", networkKey, appNetwork),
            ("extension", networkKey, widgetNetwork),
        ]
        let accepted = appSignature
            && widgetSignature
            && appGroups.status == .requiredSinglePresent
            && widgetGroups.status == .requiredSinglePresent
            && parity == .matching
            && appNetwork == .requiredPresent
            && widgetNetwork == .forbiddenAbsent
        return Result(
            isAccepted: accepted,
            report: checks.map { "\($0.0).\($0.1): \($0.2.rawValue)" }.joined(separator: "; ")
        )
    }

    private static func groupState(_ raw: Any?) -> (status: Status, value: String?) {
        guard let raw else { return (.requiredSingleMissing, nil) }
        guard let groups = raw as? [String] else { return (.requiredSingleWrongType, nil) }
        switch groups.count {
        case 0: return (.requiredSingleEmpty, nil)
        case 1: return (.requiredSinglePresent, groups[0])
        default: return (.requiredSingleMultiple, nil)
        }
    }

    private static func entitlements(
        at url: URL,
        runCommand: ([String]) throws -> CommandResult
    ) throws -> [String: Any] {
        let result = try runCommand(["--display", "--entitlements", ":-", url.path])
        guard result.status == 0 else { throw VerificationError.entitlementsUnreadable }
        do {
            guard let plist = try PropertyListSerialization.propertyList(
                from: result.output,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw VerificationError.entitlementsUnreadable
            }
            return plist
        } catch let error as VerificationError {
            throw error
        } catch {
            throw VerificationError.entitlementsUnreadable
        }
    }

    static func runCodesign(arguments: [String]) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: output.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

import Darwin
import Foundation

/// Reads account quota windows through the official CLI's built-in /usage
/// command. This command does not create a model turn or submit a prompt.
/// Authentication remains owned by Antigravity's shared local keyring.
struct AntigravityProvider: UsageProvider {
    let id: String
    let name: String
    let iconSymbol = "sparkles"
    let dashboardURL: URL? = URL(string: "https://antigravity.google/docs/cli/commands/usage")

    private let executableURL: URL?
    private let timeout: TimeInterval

    init(instanceId: String = "antigravity", label: String = "Antigravity",
         executableURL: URL? = nil, timeout: TimeInterval = 30) {
        self.id = instanceId
        self.name = label
        self.executableURL = executableURL
        self.timeout = timeout
    }

    static var executablePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
    }

    private var resolvedExecutable: URL? {
        if let executableURL { return executableURL }
        return Self.executablePaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map { URL(fileURLWithPath: $0) }
    }

    func isAvailable() async -> Bool { resolvedExecutable != nil }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let executable = resolvedExecutable else {
            throw ProviderError.executionFailed("Install the official Antigravity CLI (agy) to read quota usage")
        }
        let output: String = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try Self.executeUsage(
                        executableURL: executable, timeout: timeout
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return try Self.parseUsage(output, providerID: id)
    }

    /// Output is TSV: model group, window label, remaining % or "disabled",
    /// and an RFC 3339 reset timestamp. Unknown groups remain visible.
    static func parseUsage(_ output: String, providerID: String = "antigravity",
                           capturedAt: Date = Date()) throws -> UsageSnapshot {
        var quotas: [UsageQuota] = []
        let dateParser = ISO8601DateFormatter()
        let fractionalDateParser = ISO8601DateFormatter()
        fractionalDateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in output.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let columns = line.components(separatedBy: "\t")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count == 4, !columns[0].isEmpty, !columns[1].isEmpty else {
                throw ProviderError.parseFailed("Unexpected Antigravity CLI quota format")
            }
            let label = quotaLabel(group: columns[0], window: columns[1])
            if columns[2].lowercased() == "disabled" {
                quotas.append(UsageQuota(percentUsed: -1, label: label,
                                         detailText: "Not currently applicable"))
                continue
            }
            guard columns[2].hasSuffix("%"),
                  let remaining = Double(columns[2].dropLast()), remaining.isFinite,
                  (0...100).contains(remaining) else {
                throw ProviderError.parseFailed("Invalid Antigravity remaining quota")
            }
            let resetsAt: Date?
            if columns[3].isEmpty {
                resetsAt = nil
            } else if let date = dateParser.date(from: columns[3])
                        ?? fractionalDateParser.date(from: columns[3]) {
                resetsAt = date
            } else {
                throw ProviderError.parseFailed("Invalid Antigravity quota reset time")
            }
            quotas.append(UsageQuota(
                percentUsed: 100 - remaining,
                label: label,
                detailText: "\(columns[2]) remaining",
                resetsAt: resetsAt
            ))
        }
        guard quotas.contains(where: { $0.percentUsed >= 0 }) else {
            throw ProviderError.parseFailed("No active Antigravity quota windows returned")
        }
        return UsageSnapshot(providerId: providerID, quotas: quotas,
                             capturedAt: capturedAt, accountTier: nil,
                             hasIndependentQuotaGroups: true)
    }

    private static func quotaLabel(group: String, window: String) -> String {
        let groupName: String
        switch group {
        case "Gemini Models": groupName = "Gemini"
        case "Claude and GPT models": groupName = "Claude/GPT"
        case "Gemini 4 Argon": groupName = "Argon"
        default: groupName = group
        }
        let windowName: String
        let lower = window.lowercased()
        if lower.contains("five hour") { windowName = "5h" }
        else if lower.contains("weekly") { windowName = "Weekly" }
        else { windowName = window }
        return "\(groupName) · \(windowName)"
    }

    /// Both the CLI's own deadline and this process deadline bound polling.
    /// Output goes to a private temporary file, avoiding pipe backpressure or
    /// inherited pipe handles keeping a poll alive after the CLI exits.
    static func executeUsage(executableURL: URL, timeout: TimeInterval) throws -> String {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("TokenBar-antigravity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("usage.tsv")
        guard fm.createFile(atPath: outputURL.path, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else {
            throw ProviderError.executionFailed("Could not capture Antigravity usage")
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-p", "/usage", "--print-timeout", "20s", "--log-file", "/dev/null"]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            throw ProviderError.executionFailed("Antigravity quota check timed out")
        }
        guard process.terminationStatus == 0 else {
            throw ProviderError.executionFailed(
                "Antigravity CLI could not read quota. Open Antigravity and check your sign-in."
            )
        }
        try outputHandle.synchronize()
        let attributes = try fm.attributesOfItem(atPath: outputURL.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 262_144 else {
            throw ProviderError.parseFailed("Antigravity quota response is too large")
        }
        let data = try Data(contentsOf: outputURL)
        guard let output = String(data: data, encoding: .utf8) else {
            throw ProviderError.parseFailed("Antigravity quota response is not UTF-8")
        }
        return output
    }
}

enum AntigravityProviderDef: RegisteredProvider {
    static let typeId = "antigravity"
    static let defaultName = "Antigravity"
    static let iconSymbol = "sparkles"
    static let dashboardURL: URL? = URL(string: "https://antigravity.google/docs/cli/commands/usage")
    static let category: ProviderCategory = .trackable
    static let dataSourceDescription: String? = "Official Antigravity CLI /usage (shared sign-in)"

    private static let appPaths = [
        "/Applications/Antigravity.app",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Antigravity.app").path,
    ]
    static let detection = DetectionSpec(paths: appPaths + AntigravityProvider.executablePaths,
                                         commands: ["agy"])
    static let iconSpec = IconSpec(appBundlePaths: appPaths)

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        AntigravityProvider(instanceId: instanceId, label: label)
    }
}

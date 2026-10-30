import CommonCrypto
import Foundation
import LocalAuthentication
import Security

/// Uses the same read-only billing endpoints as Grok Bot's Usage & Billing page.
/// The app's active account is decrypted with its existing macOS Safe Storage key.
/// Credentials are never written, refreshed, logged, or sent to configurable hosts.
struct GrokBotProvider: UsageProvider {
    let id: String
    let name: String
    let iconSymbol = "sparkles"
    let dashboardURL: URL? = URL(string: "https://cursor.com/dashboard?tab=usage")
    let dataDirectory: URL
    let allowKeychainInteraction: Bool

    static let maximumCacheAge: TimeInterval = 60 * 60
    static let defaultDataDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Grok Bot")

    init(id: String = "grok-bot", name: String = "Grok Bot", dataDirectory: URL = defaultDataDirectory,
         allowKeychainInteraction: Bool = true) {
        self.id = id
        self.name = name
        self.dataDirectory = dataDirectory
        self.allowKeychainInteraction = allowKeychainInteraction
    }

    func isAvailable() async -> Bool {
        FileManager.default.fileExists(atPath: dataDirectory.path)
    }

    func fetchUsage() async throws -> UsageSnapshot {
        do {
            let credentials = try await readCredentials()
            let status = try await request("GetSandUsageStatus", credentials: credentials)
            // Additional spend is optional; a failure must not hide the weekly quota.
            let period = try? await request("GetCurrentPeriodUsage", credentials: credentials)
            return try Self.parseStatus(status, periodData: period, id: id, capturedAt: Date())
        } catch let liveError {
            // Grok Bot keeps a timestamped snapshot for its account menu. Never
            // present this older reading as a successful live refresh.
            do {
                return try cachedUsage(now: Date())
            } catch {
                throw ProviderError.executionFailed("\(Self.liveFailureMessage(liveError)). \(Self.cacheUnavailable.localizedDescription)")
            }
        }
    }

    private static func liveFailureMessage(_ error: Error) -> String {
        switch error {
        case ProviderError.authenticationRequired: return "Grok Bot Keychain access or sign-in is required"
        case ProviderError.sessionExpired: return "Grok Bot session expired; sign in again in Grok Bot"
        case ProviderError.networkError(let message): return message
        case ProviderError.parseFailed: return "Grok Bot returned an unsupported quota response"
        default: return "Grok Bot live usage could not be read"
        }
    }

    private struct Credentials {
        let token: String
        let teamId: String?
    }

    private func readCredentials() async throws -> Credentials {
        let url = dataDirectory.appendingPathComponent("sand-secrets.json")
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountsJSON = store["cursor-accounts"] as? String,
              let accounts = try? JSONSerialization.jsonObject(with: Data(accountsJSON.utf8)) as? [String: Any],
              let active = accounts["active"] as? String, !active.isEmpty,
              let entries = accounts["accounts"] as? [String: [String: String]],
              let entry = entries[active], let encryptedToken = entry["cursor-access-token"] else {
            throw ProviderError.authenticationRequired
        }
        let password = try await GrokBotKeychain.shared.password(allowInteraction: allowKeychainInteraction)
        let token = try Self.decrypt(encryptedToken, password: password)
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else {
            throw ProviderError.authenticationRequired
        }
        let teamId = try entry["cursor-selected-team-id"].map { try Self.decrypt($0, password: password) }
        if let teamId, Int64(teamId).map({ $0 > 0 }) != true {
            throw ProviderError.authenticationRequired
        }
        return Credentials(token: token, teamId: teamId)
    }

    private func request(_ method: String, credentials: Credentials) async throws -> Data {
        // These paths were verified in the installed Grok Bot billing client.
        let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if let teamId = credentials.teamId { request.setValue(teamId, forHTTPHeaderField: "x-cursor-team-id") }
        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Grok Bot returned an invalid response")
            }
            try Self.validateHTTPStatus(http.statusCode)
            return data
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.networkError("Grok Bot usage service could not be reached")
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: GrokBotNoRedirect(), delegateQueue: nil)

    static func validateHTTPStatus(_ status: Int) throws {
        switch status {
        case 200: break
        case 401: throw ProviderError.sessionExpired
        case 403: throw ProviderError.authenticationRequired
        default: throw ProviderError.networkError("Grok Bot usage service returned HTTP \(status)")
        }
    }

    static func parseStatus(_ data: Data, periodData: Data? = nil, id: String = "grok-bot",
                            capturedAt: Date = Date()) throws -> UsageSnapshot {
        let object = try jsonObject(data)
        guard object["usesPooledEnterpriseAllowance"] as? Bool != true else {
            throw ProviderError.parseFailed("Grok Bot uses a shared team allowance; individual quota is unavailable")
        }
        let percent = try usagePercent(object["usagePercent"])
        let reset = try timestamp(object["nextResetTimestampUtc"])
        let trial = (try timestamp(object["sandTrialExpiresAt"])).map { $0 > capturedAt } ?? false
        var quotas = [UsageQuota(percentUsed: percent, label: trial ? "Trial" : "Weekly",
                                detailText: String(format: "%.1f%% used", percent), resetsAt: reset)]
        if let periodData, let period = try? jsonObject(periodData),
           let spend = period["spendLimitUsage"] as? [String: Any],
           let used = number(spend["individualUsed"]), used >= 0 {
            let limit = number(spend["individualLimit"])
            quotas.append(spendQuota(used: used, limit: limit,
                                     reset: milliseconds(period["billingCycleEnd"]), suffix: ""))
        }
        let plan = object["isUnified"] as? Bool == true ? object["cursorPlanName"] as? String : nil
        return UsageSnapshot(providerId: id, quotas: quotas, capturedAt: capturedAt,
                             accountTier: plan ?? object["grokPlanLabel"] as? String)
    }

    func cachedUsage(now: Date) throws -> UsageSnapshot {
        let directory = dataDirectory.appendingPathComponent("sand-client-persistence")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            throw Self.cacheUnavailable
        }
        let keyedFiles = files.compactMap { file -> (String, URL)? in
            guard file.pathExtension == "blob", let key = Self.decodeBase32(file.deletingPathExtension().lastPathComponent) else { return nil }
            return (key.removingPercentEncoding ?? key, file)
        }
        guard let slotURL = keyedFiles.first(where: { $0.0 == "sand.client.slice.client-meta.account-slot" })?.1,
              let slotData = try? Data(contentsOf: slotURL), let slot = try? Self.jsonObject(slotData),
              (slot["schemaVersion"] as? Int) == 1,
              let account = slot["value"] as? String, !account.isEmpty,
              let cacheURL = keyedFiles.first(where: { $0.0 == "sand.client.slice.account.\(account).weekly-usage.cache" })?.1,
              let data = try? Data(contentsOf: cacheURL) else { throw Self.cacheUnavailable }
        return try Self.parseCache(data, id: id, now: now)
    }

    static func parseCache(_ data: Data, id: String = "grok-bot", now: Date = Date()) throws -> UsageSnapshot {
        let object = try jsonObject(data)
        guard (object["schemaVersion"] as? Int) == 2,
              let value = object["value"] as? [String: Any], value["kind"] as? String == "present",
              let reading = value["reading"] as? [String: Any],
              let usage = reading["usage"] as? [String: Any],
              let capturedAt = milliseconds(reading["readAtMs"]),
              let expiresAt = milliseconds(value["expiresAtMs"]), expiresAt > now,
              capturedAt <= now.addingTimeInterval(60),
              now.timeIntervalSince(capturedAt) <= maximumCacheAge else {
            throw cacheUnavailable
        }
        let percent = try usagePercent(usage["percentUsed"])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        let suffix = " · cached \(formatter.string(from: capturedAt)) (max 1h; live unavailable)"
        var quotas = [UsageQuota(percentUsed: percent, label: usage["isSandTrial"] as? Bool == true ? "Trial" : "Weekly",
                                detailText: String(format: "%.1f%% used", percent) + suffix,
                                resetsAt: milliseconds(usage["nextResetMs"]))]
        if let spend = usage["onDemand"] as? [String: Any],
           let used = number(spend["usedCents"]), used >= 0 {
            quotas.append(spendQuota(used: used, limit: number(spend["limitCents"]), reset: nil, suffix: suffix))
        }
        return UsageSnapshot(providerId: id, quotas: quotas, capturedAt: capturedAt,
                             accountTier: usage["unifiedPlanName"] as? String ?? usage["grokPlanLabel"] as? String)
    }

    private static var cacheUnavailable: ProviderError {
        .executionFailed("Live Grok Bot usage is unavailable and no recent account snapshot exists. Allow TokenBar's Grok Bot Keychain request, or open Grok Bot → Usage & Billing to refresh its cache (maximum age: 1 hour).")
    }

    private static func spendQuota(used: Double, limit: Double?, reset: Date?, suffix: String) -> UsageQuota {
        let validLimit = limit.flatMap { $0 > 0 && $0 < 1e9 ? $0 : nil }
        let detail = validLimit.map { String(format: "$%.2f / $%.2f", used / 100, $0 / 100) }
            ?? String(format: "$%.2f spent", used / 100)
        return UsageQuota(percentUsed: validLimit.map { min(100, used / $0 * 100) } ?? -1,
                          label: "On-Demand", detailText: detail + suffix, resetsAt: reset)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parseFailed("Invalid Grok Bot usage data")
        }
        return object
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func usagePercent(_ value: Any?) throws -> Double {
        guard let value = number(value), value >= 0 else { throw ProviderError.parseFailed("Grok Bot usage percentage is unavailable") }
        return min(100, value)
    }

    private static func milliseconds(_ value: Any?) -> Date? {
        let ms = number(value) ?? (value as? String).flatMap(Double.init)
        guard let ms, ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func timestamp(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw ProviderError.parseFailed("Invalid Grok Bot reset time") }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: text) else { throw ProviderError.parseFailed("Invalid Grok Bot reset time") }
        return date
    }

    static func decodeBase32(_ string: String) -> String? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var bits: UInt32 = 0, count = 0
        var bytes: [UInt8] = []
        for character in string.lowercased().utf8 {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            bits = (bits << 5) | UInt32(index)
            count += 5
            if count >= 8 { count -= 8; bytes.append(UInt8((bits >> count) & 255)) }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func decrypt(_ value: String, password: Data) throws -> String {
        var encoded = value
        if value.hasPrefix("scoped:v1:") {
            let pieces = value.split(separator: ":", maxSplits: 3)
            guard pieces.count == 4, pieces[2].count == 64,
                  pieces[2].allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw ProviderError.authenticationRequired
            }
            encoded = String(pieces[3])
        }
        guard let bytes = Data(base64Encoded: encoded), bytes.starts(with: Data("v10".utf8)) else {
            throw ProviderError.authenticationRequired
        }
        var key = [UInt8](repeating: 0, count: 16)
        let salt = [UInt8]("saltysalt".utf8)
        let result = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBufferPointer { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: CChar.self).baseAddress,
                                    password.count, saltBytes.baseAddress, salt.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, 16)
            }
        }
        guard result == kCCSuccess else { throw ProviderError.authenticationRequired }
        let ciphertext = Array(bytes.dropFirst(3))
        let iv = [UInt8](repeating: 32, count: 16)
        var output = [UInt8](repeating: 0, count: ciphertext.count + 16)
        var outputLength = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, ciphertext, ciphertext.count, &output, output.count, &outputLength)
        guard status == kCCSuccess, let plaintext = String(bytes: output.prefix(outputLength), encoding: .utf8) else {
            throw ProviderError.authenticationRequired
        }
        return plaintext
    }
}

private actor GrokBotKeychain {
    static let shared = GrokBotKeychain()
    private var requestedInteraction = false
    private var cachedPassword: Data?

    func password(allowInteraction: Bool) throws -> Data {
        if let cachedPassword { return cachedPassword }
        let mayPrompt = allowInteraction && !requestedInteraction
        if mayPrompt { requestedInteraction = true }
        let context = LAContext()
        context.interactionNotAllowed = !mayPrompt
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Grok Bot Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let password = result as? Data else {
            throw ProviderError.authenticationRequired
        }
        cachedPassword = password
        return password
    }
}

private final class GrokBotNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Provider registration

enum GrokBotProviderDef: RegisteredProvider {
    static let typeId = "grok-bot"
    static let defaultName = "Grok Bot"
    static let iconSymbol = "sparkles"
    static let dashboardURL: URL? = URL(string: "https://cursor.com/dashboard?tab=usage")
    static let category: ProviderCategory = .trackable
    static let dataSourceDescription: String? = "Grok Bot billing API · macOS Keychain; timestamped cache fallback (up to 1h)"

    private static let appPaths = [
        "/Applications/Grok Bot.app",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Grok Bot.app").path,
    ]
    static let detection = DetectionSpec(paths: appPaths)
    static let iconSpec = IconSpec(appBundlePaths: appPaths)

    static func create(instanceId: String, label: String, config: ProviderConfig) -> any UsageProvider {
        GrokBotProvider(id: instanceId, name: label)
    }
}

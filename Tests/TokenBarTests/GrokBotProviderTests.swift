import XCTest
@testable import TokenBarLib

final class GrokBotProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func cache(percent: Any = 27.25, age: TimeInterval = 300,
                       expiryOffset: TimeInterval = 3600) throws -> Data {
        try json([
            "schemaVersion": 2,
            "value": [
                "kind": "present",
                "reading": [
                    "usage": ["percentUsed": percent, "nextResetMs": (now.timeIntervalSince1970 + 86_400) * 1000,
                              "unifiedPlanName": "Premium", "isSandTrial": false,
                              "onDemand": ["usedCents": 125.0, "limitCents": 500.0]],
                    "readAtMs": (now.timeIntervalSince1970 - age) * 1000,
                ],
                "expiresAtMs": (now.timeIntervalSince1970 + expiryOffset) * 1000,
            ],
        ])
    }

    func testLiveWeeklyAndSpendUseActualUnitsAndInstanceID() throws {
        let status = try json(["usagePercent": 26.69556, "nextResetTimestampUtc": "2027-01-20T08:15:00.123Z",
                               "isUnified": true, "cursorPlanName": "Premium", "grokPlanLabel": "Grok Bot Plan"])
        let period = try json(["spendLimitUsage": ["individualUsed": 125, "individualLimit": 500],
                               "billingCycleEnd": "1800000000000"])
        let snapshot = try GrokBotProvider.parseStatus(status, periodData: period, id: "grok-work", capturedAt: now)
        XCTAssertEqual(snapshot.providerId, "grok-work")
        XCTAssertEqual(snapshot.accountTier, "Premium")
        XCTAssertEqual(snapshot.capturedAt, now)
        XCTAssertEqual(snapshot.quotas[0].percentUsed, 26.69556, accuracy: 0.00001)
        XCTAssertEqual(snapshot.quotas[0].label, "Weekly")
        XCTAssertNotNil(snapshot.quotas[0].resetsAt)
        XCTAssertFalse(snapshot.quotas[0].detailText?.contains("cached") ?? true)
        XCTAssertEqual(snapshot.quotas[1].percentUsed, 25)
        XCTAssertEqual(snapshot.quotas[1].detailText, "$1.25 / $5.00")
    }

    func testRejectsMissingInvalidOrTeamOnlyLiveQuota() throws {
        for object: [String: Any] in [[:], ["usagePercent": -1], ["usagePercent": "27"],
                                    ["usagePercent": true], ["usagePercent": NSNull()],
                                    ["usagePercent": 27, "usesPooledEnterpriseAllowance": true],
                                    ["usagePercent": 27, "nextResetTimestampUtc": "bad date"]] {
            XCTAssertThrowsError(try GrokBotProvider.parseStatus(json(object)))
        }
        XCTAssertThrowsError(try GrokBotProvider.parseStatus(Data("not JSON".utf8)))
        XCTAssertThrowsError(try GrokBotProvider.parseStatus(Data("[]".utf8)))
    }

    func testCapsExhaustedQuotaAndAcceptsZero() throws {
        XCTAssertEqual(try GrokBotProvider.parseStatus(json(["usagePercent": 120])).quotas[0].percentUsed, 100)
        XCTAssertEqual(try GrokBotProvider.parseStatus(json(["usagePercent": 0])).quotas[0].percentUsed, 0)
    }

    func testCachePreservesOriginalTimestampAndMarksStaleness() throws {
        let snapshot = try GrokBotProvider.parseCache(cache(), id: "grok-personal", now: now)
        XCTAssertEqual(snapshot.providerId, "grok-personal")
        XCTAssertEqual(snapshot.capturedAt, now.addingTimeInterval(-300))
        XCTAssertEqual(snapshot.accountTier, "Premium")
        XCTAssertEqual(snapshot.quotas[0].percentUsed, 27.25)
        for quota in snapshot.quotas {
            XCTAssertTrue(quota.detailText?.contains("cached") ?? false)
            XCTAssertTrue(quota.detailText?.contains("max 1h") ?? false)
        }
    }

    func testRejectsExpiredOldFutureAndMalformedCache() throws {
        XCTAssertThrowsError(try GrokBotProvider.parseCache(cache(age: 3601), now: now))
        XCTAssertThrowsError(try GrokBotProvider.parseCache(cache(expiryOffset: -1), now: now))
        XCTAssertThrowsError(try GrokBotProvider.parseCache(cache(age: -61), now: now))
        XCTAssertThrowsError(try GrokBotProvider.parseCache(cache(percent: "NaN"), now: now))
        XCTAssertThrowsError(try GrokBotProvider.parseCache(json([:]), now: now))
    }

    func testHTTPAuthFailuresAreSanitized() throws {
        try GrokBotProvider.validateHTTPStatus(200)
        XCTAssertThrowsError(try GrokBotProvider.validateHTTPStatus(401)) { error in
            guard case ProviderError.sessionExpired = error else { return XCTFail("Expected expired session") }
        }
        XCTAssertThrowsError(try GrokBotProvider.validateHTTPStatus(403)) { error in
            guard case ProviderError.authenticationRequired = error else { return XCTFail("Expected authentication required") }
        }
        XCTAssertThrowsError(try GrokBotProvider.validateHTTPStatus(302))
        XCTAssertThrowsError(try GrokBotProvider.validateHTTPStatus(500))
    }

    func testUnreadableCredentialFailsWithoutEchoingCiphertext() {
        for encoded in ["invalid", "scoped:v1:broken", "djExYmFk", "djEwYmFk"] {
            XCTAssertThrowsError(try GrokBotProvider.decrypt(encoded, password: Data("test-password".utf8))) { error in
                XCTAssertEqual(error.localizedDescription, "Authentication required")
            }
        }
    }

    func testDecryptsElectronSafeStorageAndScopedEnvelope() throws {
        let ciphertext = "djEwlQsFjVoFTQXWS2KuThvV7ka/Chk9a1JBevghARA7kKM="
        let password = Data("test-password".utf8)
        XCTAssertEqual(try GrokBotProvider.decrypt(ciphertext, password: password), "fixture-session-token")
        let scoped = "scoped:v1:" + String(repeating: "a", count: 64) + ":" + ciphertext
        XCTAssertEqual(try GrokBotProvider.decrypt(scoped, password: password), "fixture-session-token")
        XCTAssertThrowsError(try GrokBotProvider.decrypt("scoped:v1:invalid:" + ciphertext, password: password))
    }

    func testBase32DecoderRejectsNonAlphabetCharacters() {
        XCTAssertEqual(GrokBotProvider.decodeBase32("nbswy3dp"), "hello")
        XCTAssertNil(GrokBotProvider.decodeBase32("bad!"))
    }

    func testCacheReaderUsesActiveAccountOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("sand-client-persistence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = directory.appendingPathComponent("onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob")
        try json(["schemaVersion": 1, "value": "account-one"]).write(to: slot)
        try cache(percent: 10).write(to: directory.appendingPathComponent("onqw4zbomnwgszlooqxhg3djmnss4yldmnxxk3tufzqwgy3povxhillpnzss453fmvvwy6jnovzwcz3ffzrwcy3imu.blob"))
        try cache(percent: 90).write(to: directory.appendingPathComponent("onqw4zbomnwgszlooqxhg3djmnss4yldmnxxk3tufzqwgy3povxhilluo5xs453fmvvwy6jnovzwcz3ffzrwcy3imu.blob"))
        let provider = GrokBotProvider(dataDirectory: root, allowKeychainInteraction: false)
        XCTAssertEqual(try provider.cachedUsage(now: now).quotas[0].percentUsed, 10)
        try json(["schemaVersion": 1, "value": "account-two"]).write(to: slot)
        XCTAssertEqual(try provider.cachedUsage(now: now).quotas[0].percentUsed, 90)
        try json(["schemaVersion": 1, "value": "missing-account"]).write(to: slot)
        XCTAssertThrowsError(try provider.cachedUsage(now: now))
    }

    func testInstalledCacheSmokeWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENBAR_GROK_CACHE_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in installed-app cache check")
        }
        let snapshot = try GrokBotProvider().cachedUsage(now: Date())
        print("Grok Bot CACHE quota=\(snapshot.quotas[0].percentUsed) capturedAt=\(snapshot.capturedAt) plan=\(snapshot.accountTier ?? "unknown")")
    }

    func testLiveSmokeWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["TOKENBAR_GROK_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in live request; never prompts for Keychain from a test runner")
        }
        let snapshot = try await GrokBotProvider(allowKeychainInteraction: false).fetchUsage()
        XCTAssertFalse(snapshot.quotas.contains { $0.detailText?.contains("cached") ?? false }, "Live request fell back to cached data")
        print("Grok Bot LIVE quota=\(snapshot.quotas[0].percentUsed) capturedAt=\(snapshot.capturedAt) plan=\(snapshot.accountTier ?? "unknown")")
    }
}

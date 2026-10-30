import XCTest
@testable import TokenBarLib

final class AntigravityProviderTests: XCTestCase {
    private let quotaReport = """
    Gemini Models\tWeekly Limit Remaining\t94%\t2026-11-02T03:32:33Z
    Gemini Models\tFive Hour Limit Remaining\t93%\t2026-10-30T06:11:58Z
    Claude and GPT models\tWeekly Limit Remaining\t0%\t2026-11-02T04:23:50Z
    Claude and GPT models\tFive Hour Limit Remaining\tdisabled\t
    Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t1%\t2026-11-02T03:35:56Z
    """

    func testParsesIndependentWindowsAndDisabledQuota() throws {
        let snapshot = try AntigravityProvider.parseUsage(quotaReport)
        XCTAssertTrue(snapshot.hasIndependentQuotaGroups)
        XCTAssertEqual(snapshot.quotas.map(\.percentUsed), [6, 7, 100, -1, 99])
        XCTAssertEqual(snapshot.quotas.map(\.label), [
            "Gemini · Weekly", "Gemini · 5h", "Claude/GPT · Weekly",
            "Claude/GPT · 5h", "Argon · Weekly",
        ])
        XCTAssertEqual(snapshot.quotas[0].detailText, "94% remaining")
        XCTAssertEqual(snapshot.quotas[0].resetsAt,
                       ISO8601DateFormatter().date(from: "2026-11-02T03:32:33Z"))
        XCTAssertNil(snapshot.quotas[3].resetsAt)
        XCTAssertNil(snapshot.accountTier, "CLI output does not report the account plan")
    }

    func testSupportsNewGroupsDecimalsAndFractionalTimestamps() throws {
        let snapshot = try AntigravityProvider.parseUsage(
            "New model\tDaily\t72.5%\t2026-11-02T03:32:33.125Z\r\n"
        )
        XCTAssertEqual(snapshot.quotas[0].label, "New model · Daily")
        XCTAssertEqual(snapshot.quotas[0].percentUsed, 27.5)
        XCTAssertNotNil(snapshot.quotas[0].resetsAt)
    }

    func testRejectsMissingInvalidAndMisleadingData() {
        for output in [
            "", "Please sign in", "x\tWeekly\t101%\t", "x\tWeekly\t-1%\t",
            "x\tWeekly\tnan%\t", "x\tWeekly\t50%\tnot-a-date",
            "x\tWeekly\tdisabled\t", "x\tWeekly\t5%",
        ] {
            XCTAssertThrowsError(try AntigravityProvider.parseUsage(output))
        }
    }

    func testTimeoutStopsAnUnresponsiveCLI() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBar-agy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("agy")
        try "#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 10\n".write(
            to: executable, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = Date()
        XCTAssertThrowsError(try AntigravityProvider.executeUsage(executableURL: executable, timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    /// Opt-in live smoke check: never prints account identifiers or credentials.
    func testLiveQuotaWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["TOKENBAR_TEST_ANTIGRAVITY_LIVE"] == "1" else {
            throw XCTSkip("Set TOKENBAR_TEST_ANTIGRAVITY_LIVE=1 to query the official /usage command")
        }
        let snapshot = try await AntigravityProvider().fetchUsage()
        XCTAssertTrue(snapshot.hasIndependentQuotaGroups)
        XCTAssertFalse(snapshot.quotas.isEmpty)
        for quota in snapshot.quotas {
            let reset = quota.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
            print("Antigravity quota: \(quota.label), used=\(quota.percentUsed), reset=\(reset)")
        }
        print("Antigravity account tier: \(snapshot.accountTier ?? "not reported by CLI")")
    }
}

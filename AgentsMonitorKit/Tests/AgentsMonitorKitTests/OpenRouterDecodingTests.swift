import XCTest
@testable import AgentsMonitorKit

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

final class OpenRouterDecodingTests: XCTestCase {
    func testKeyList() throws {
        let keys = try OpenRouterClient.decodeKeyList(try fixture("openrouter_keys"), now: utc("2026-11-03T10:00:00Z"))
        XCTAssertEqual(keys.map { $0.name }, ["prod-agent", "research", "ci-runner"])
        XCTAssertEqual(keys[0].id.count, 64)
        XCTAssertEqual(keys[0].capPercent, 60)
        XCTAssertEqual(keys[0].capSeverity, .normal)
        XCTAssertEqual(keys[0].usageDaily, 3.2, accuracy: 0.001)
        XCTAssertNil(keys[1].capPercent)
        XCTAssertEqual(keys[2].capPercent, 0)
        XCTAssertEqual(keys[2].expiresAt, utc("2030-01-01T00:00:00Z"))
        XCTAssertEqual(keys[0].capResetsAt(now: utc("2026-11-03T10:00:00Z")), utc("2026-11-04T00:00:00Z"))
    }

    func testExpiredExpiryTreatedAsAbsent() throws {
        let keys = try OpenRouterClient.decodeKeyList(try fixture("openrouter_keys"), now: utc("2031-01-01T00:00:00Z"))
        XCTAssertNil(keys[2].expiresAt)
    }

    func testSingleKeyWithBudget() throws {
        let key = try OpenRouterClient.decodeKey(try fixture("openrouter_key"), id: "pasted:X")
        XCTAssertEqual(key.id, "pasted:X")
        XCTAssertNil(key.limit)
        XCTAssertEqual(key.budget?.limitUSD, 50)
        XCTAssertEqual(key.capPercent, 25)
        XCTAssertEqual(key.capRemaining ?? 0, 37.5, accuracy: 0.001)
        XCTAssertEqual(key.capResetsAt(now: utc("2026-11-03T10:00:00Z")), utc("2026-12-01T00:00:00Z"))
    }

    func testCredits() throws {
        let b = try OpenRouterClient.decodeCredits(try fixture("openrouter_credits"))
        XCTAssertEqual(b.usd, 42.17, accuracy: 0.001)
    }

    func testBadPayloads() throws {
        XCTAssertThrowsError(try OpenRouterClient.decodeKeyList(Data(#"{"data":{}}"#.utf8))) {
            guard case UsageError.decode = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try OpenRouterClient.decodeCredits(Data("[]".utf8)))
        let skipped = try OpenRouterClient.decodeKeyList(Data(#"{"data":[{"label":"x"},{"hash":"h","label":"y"}]}"#.utf8))
        XCTAssertEqual(skipped.map(\.id), ["h"])
        let viaKeys = try OpenRouterClient.decodeKeyList(Data(#"{"keys":[{"hash":"h","label":"y"}]}"#.utf8))
        XCTAssertEqual(viaKeys.count, 1)
    }

    func testConfigLenientDecode() throws {
        let c = try JSONDecoder().decode(OpenRouterKeyConfig.self, from: Data(#"{"id":"x","source":"managed"}"#.utf8))
        XCTAssertEqual(c.placement, .more)
        XCTAssertEqual(c.displayName, "OpenRouter key")
    }

    func testFormatting() {
        XCTAssertEqual(OpenRouter.formatUSD(3.2), "$3.20")
        XCTAssertEqual(OpenRouter.formatUSDCompact(123.4), "$123")
        XCTAssertEqual(OpenRouter.formatUSDCompact(99.994), "$99.99")
    }

    func testResets() {
        let wed = utc("2026-11-04T12:00:00Z")   // Wednesday
        XCTAssertEqual(OpenRouter.nextUTCReset("daily", now: utc("2026-11-03T10:00:00Z")), utc("2026-11-04T00:00:00Z"))
        XCTAssertEqual(OpenRouter.nextUTCReset("weekly", now: wed), utc("2026-11-09T00:00:00Z"))
        XCTAssertEqual(OpenRouter.nextUTCReset("monthly", now: wed), utc("2026-12-01T00:00:00Z"))
        XCTAssertNil(OpenRouter.nextUTCReset(nil, now: wed))
        XCTAssertNil(OpenRouter.nextUTCReset("hourly", now: wed))
        XCTAssertEqual(OpenRouter.utcWindowStart("weekly", now: utc("2026-11-08T23:59:00Z")), utc("2026-11-02T00:00:00Z"))
    }

    func testPastedIds() {
        let u = UUID()
        XCTAssertEqual(OpenRouter.pastedUUID(from: OpenRouter.pastedId(u)), u)
        XCTAssertNil(OpenRouter.pastedUUID(from: "abc"))
    }
}

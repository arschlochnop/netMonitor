import XCTest
@testable import NetMonitorCore

final class RuleEngineTests: XCTestCase {
    let hk = GeoInfo(ip: "203.0.113.24", countryCode: "HK", region: "Hong Kong", asn: 4760, org: "HKT", raw: "{\"org\":\"HKT\"}")

    func testCountryIn() {
        let pass = RuleEngine.evaluate(Rule(field: .countryCode, op: .isIn, value: "jp, HK"), geo: hk)
        XCTAssertTrue(pass.passed)
        let fail = RuleEngine.evaluate(Rule(field: .countryCode, op: .isIn, value: "JP"), geo: hk)
        XCTAssertFalse(fail.passed)
        XCTAssertEqual(fail.explanation, "国家码应属于 JP，实际为 HK")
    }

    func testChineseSeparators() {
        XCTAssertTrue(RuleEngine.evaluate(Rule(field: .countryCode, op: .isIn, value: "JP，HK、US"), geo: hk).passed)
    }

    func testNotContainsIsCaseInsensitive() {
        XCTAssertFalse(RuleEngine.evaluate(Rule(field: .org, op: .notContains, value: "hkt"), geo: hk).passed)
        XCTAssertTrue(RuleEngine.evaluate(Rule(field: .org, op: .notContains, value: "China"), geo: hk).passed)
    }

    func testMissingFieldFails() {
        let noOrg = GeoInfo(ip: "203.0.113.1", countryCode: "JP")
        let r = RuleEngine.evaluate(Rule(field: .org, op: .notContains, value: "China"), geo: noOrg)
        XCTAssertFalse(r.passed, "取不到字段时应判为未通过，避免漏报")
    }

    func testRegexAndInvalidRegex() {
        XCTAssertTrue(RuleEngine.evaluate(Rule(field: .ip, op: .matchesRegex, value: #"^203\.0\.113\."#), geo: hk).passed)
        let bad = RuleEngine.evaluate(Rule(field: .ip, op: .matchesRegex, value: "("), geo: hk)
        XCTAssertFalse(bad.passed)
        XCTAssertNotNil(bad.note)
    }

    func testASNEquals() {
        XCTAssertTrue(RuleEngine.evaluate(Rule(field: .asn, op: .equals, value: "4760"), geo: hk).passed)
    }

    func testMatchModes() {
        let rules = [Rule(field: .countryCode, op: .isIn, value: "JP"), Rule(field: .org, op: .contains, value: "HKT")]
        XCTAssertFalse(RuleEngine.evaluate(rules, mode: .all, geo: hk).passed)
        XCTAssertTrue(RuleEngine.evaluate(rules, mode: .any, geo: hk).passed)
        XCTAssertTrue(RuleEngine.evaluate([], mode: .all, geo: hk).passed)
    }
}

final class AlertPolicyTests: XCTestCase {
    let settings = AlertPolicySettings(debounce: 2, notifyRecovery: true, repeatInterval: 600, failureAlertAfter: 3)
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testDebounceThenConfirm() {
        var s = AlertState()
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .ok, ip: "1.1.1.1", now: t0, settings: settings), [])
        let first = AlertPolicy.process(state: &s, raw: .mismatch, ip: "1.1.1.1", now: t0 + 60, settings: settings)
        XCTAssertEqual(first, [])
        XCTAssertEqual(s.displayStatus, .pending)
        let second = AlertPolicy.process(state: &s, raw: .mismatch, ip: "1.1.1.1", now: t0 + 120, settings: settings)
        XCTAssertEqual(second, [.mismatchConfirmed])
        XCTAssertEqual(s.displayStatus, .mismatch)
        // 持续不符合，未到重复间隔不再提醒
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .mismatch, ip: "1.1.1.1", now: t0 + 180, settings: settings), [])
        // 到了重复间隔
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .mismatch, ip: "1.1.1.1", now: t0 + 720, settings: settings),
                       [.mismatchRepeated])
    }

    func testSingleBlipDoesNotAlert() {
        var s = AlertState()
        _ = AlertPolicy.process(state: &s, raw: .ok, ip: "1.1.1.1", now: t0, settings: settings)
        _ = AlertPolicy.process(state: &s, raw: .mismatch, ip: "1.1.1.1", now: t0 + 60, settings: settings)
        let back = AlertPolicy.process(state: &s, raw: .ok, ip: "1.1.1.1", now: t0 + 120, settings: settings)
        XCTAssertEqual(back, [], "未确认的单次不符合恢复后不应发恢复通知")
        XCTAssertEqual(s.displayStatus, .ok)
    }

    func testRecoveryAfterConfirmedMismatch() {
        var s = AlertState()
        _ = AlertPolicy.process(state: &s, raw: .mismatch, ip: "1.1.1.1", now: t0, settings: settings)
        _ = AlertPolicy.process(state: &s, raw: .mismatch, ip: "1.1.1.1", now: t0 + 60, settings: settings)
        let events = AlertPolicy.process(state: &s, raw: .ok, ip: "1.1.1.1", now: t0 + 540, settings: settings)
        XCTAssertEqual(events, [.recovered(duration: 480, notify: true)])
    }

    func testFailureAlertsOnceAfterThreshold() {
        var s = AlertState()
        _ = AlertPolicy.process(state: &s, raw: .ok, ip: "1.1.1.1", now: t0, settings: settings)
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .failed, ip: nil, now: t0 + 60, settings: settings), [.failureStarted])
        XCTAssertEqual(s.displayStatus, .failed)
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .failed, ip: nil, now: t0 + 120, settings: settings), [])
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .failed, ip: nil, now: t0 + 180, settings: settings), [.failureAlert])
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .failed, ip: nil, now: t0 + 240, settings: settings), [])
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .ok, ip: "1.1.1.1", now: t0 + 300, settings: settings),
                       [.recovered(duration: 240, notify: true)])
    }

    func testFailureWithoutAlertRecoversSilently() {
        var s = AlertState()
        _ = AlertPolicy.process(state: &s, raw: .failed, ip: nil, now: t0, settings: settings)
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .ok, ip: "1.1.1.1", now: t0 + 60, settings: settings),
                       [.recovered(duration: 60, notify: false)])
    }

    func testIPChange() {
        var s = AlertState()
        _ = AlertPolicy.process(state: &s, raw: .ok, ip: "1.1.1.1", now: t0, settings: settings)
        XCTAssertEqual(AlertPolicy.process(state: &s, raw: .ok, ip: "2.2.2.2", now: t0 + 60, settings: settings),
                       [.ipChanged(from: "1.1.1.1", to: "2.2.2.2")])
    }

    func testFailureKeepsConfirmedMismatch() {
        var s = AlertState()
        _ = AlertPolicy.process(state: &s, raw: .mismatch, ip: "1.1.1.1", now: t0, settings: settings)
        _ = AlertPolicy.process(state: &s, raw: .mismatch, ip: "1.1.1.1", now: t0 + 60, settings: settings)
        _ = AlertPolicy.process(state: &s, raw: .failed, ip: nil, now: t0 + 120, settings: settings)
        XCTAssertEqual(s.displayStatus, .mismatch, "断网不能把已确认的不符合洗成正常")
    }
}

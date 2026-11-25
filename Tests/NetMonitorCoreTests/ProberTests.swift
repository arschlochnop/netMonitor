import XCTest
@testable import NetMonitorCore

/// 按 URL 返回预设响应的假网络层
struct FakeFetcher: HTTPFetching {
    var responses: [String: Result<(String, Int), URLError>]

    func fetch(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int) {
        guard let r = responses[url.absoluteString] else { throw URLError(.cannotFindHost) }
        switch r {
        case .success(let (body, code)): return (Data(body.utf8), code)
        case .failure(let e): throw e
        }
    }
}

final class ProberTests: XCTestCase {
    let endpoints = Dictionary(uniqueKeysWithValues: EndpointCatalog.builtin.map { ($0.id, $0) })
    let cloudflareBody = "ip=203.0.113.88\nloc=JP\n"
    let ipsbBody = #"{"ip":"203.0.113.24","country_code":"HK","asn":4760,"isp":"HKT"}"#

    func testPrimarySuccess() async {
        let fetcher = FakeFetcher(responses: ["https://www.cloudflare.com/cdn-cgi/trace": .success((cloudflareBody, 200))])
        let probe = Probe(name: "日本", endpointID: "cloudflare", rules: [Rule(field: .countryCode, op: .isIn, value: "JP")])
        let outcome = await Prober(fetcher: fetcher).check(probe: probe, endpoints: endpoints, enrichment: nil)
        XCTAssertEqual(outcome.status, .ok)
        XCTAssertEqual(outcome.geo?.ip, "203.0.113.88")
        XCTAssertEqual(outcome.requestHost, "www.cloudflare.com")
    }

    func testFallbackAfterTimeout() async {
        let fetcher = FakeFetcher(responses: [
            "https://www.cloudflare.com/cdn-cgi/trace": .failure(URLError(.timedOut)),
            "https://api.ip.sb/geoip": .success((ipsbBody, 200)),
        ])
        let probe = Probe(name: "日本", endpointID: "cloudflare", fallbackEndpointIDs: ["ip-sb"],
                          rules: [Rule(field: .countryCode, op: .isIn, value: "JP")])
        let outcome = await Prober(fetcher: fetcher).check(probe: probe, endpoints: endpoints, enrichment: nil)
        XCTAssertEqual(outcome.status, .mismatch)
        XCTAssertEqual(outcome.endpointID, "ip-sb")
        XCTAssertEqual(outcome.attempts.first?.failure, .timeout)
        XCTAssertEqual(outcome.evaluation?.failures.first?.actual, "HK")
    }

    func testAllFailed() async {
        let fetcher = FakeFetcher(responses: [
            "https://www.cloudflare.com/cdn-cgi/trace": .success(("oops", 503)),
            "https://api.ip.sb/geoip": .success(("<html>login</html>", 200)),
        ])
        let probe = Probe(name: "日本", endpointID: "cloudflare", fallbackEndpointIDs: ["ip-sb"])
        let outcome = await Prober(fetcher: fetcher).check(probe: probe, endpoints: endpoints, enrichment: nil)
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.attempts.map(\.failure), [.http(503), .parse(.invalidJSON)])
        XCTAssertTrue(outcome.failureSummary.contains("HTTP 503"))
    }

    func testNoIPv6SkipsRequestAndCanCountAsOK() async {
        var alert = ProbeAlertSettings()
        alert.failureIsOK = true
        let probe = Probe(name: "v6", endpointID: "ident-v6", fallbackEndpointIDs: ["icanhazip-v6"], alert: alert)
        let outcome = await Prober(fetcher: FakeFetcher(responses: [:]))
            .check(probe: probe, endpoints: endpoints, enrichment: nil, supportsIPv6: false)
        XCTAssertTrue(outcome.noIPv6)
        XCTAssertEqual(outcome.status, .ok)
    }

    func testIPv6DNSFailureIsNoIPv6() async {
        let probe = Probe(name: "v6", endpointID: "ident-v6")
        let outcome = await Prober(fetcher: FakeFetcher(responses: [:]))
            .check(probe: probe, endpoints: endpoints, enrichment: nil, supportsIPv6: nil)
        XCTAssertTrue(outcome.noIPv6)
        XCTAssertEqual(outcome.status, .failed)
    }

    func testEnrichmentForPlainIP() async {
        let fetcher = FakeFetcher(responses: [
            "https://v6.ident.me": .success(("2001:db8::1", 200)),
            "https://ipwho.is/2001:db8::1": .success((#"{"ip":"2001:db8::1","success":true,"country_code":"CN","connection":{"asn":4134,"isp":"Chinanet"}}"#, 200)),
        ])
        let probe = Probe(name: "v6", endpointID: "ident-v6", rules: [Rule(field: .countryCode, op: .notIn, value: "CN")])
        let outcome = await Prober(fetcher: fetcher)
            .check(probe: probe, endpoints: endpoints, enrichment: EndpointCatalog.enrichment)
        XCTAssertEqual(outcome.geo?.countryCode, "CN")
        XCTAssertEqual(outcome.status, .mismatch, "IPv6 直连泄漏到国内应判为不符合")
    }
}

final class ConfigTests: XCTestCase {
    func testRoundTrip() throws {
        let config = AppConfig.makeDefault()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try ConfigStore.save(config, to: url)
        let loaded = try ConfigStore.load(from: url)
        XCTAssertEqual(loaded, config)
    }

    func testOldConfigMissingFieldsStillLoads() throws {
        let json = #"{"probes":[{"id":"7C1D2B9E-3B0A-4E5C-9F00-000000000001","name":"x","enabled":true,"endpointID":"cloudflare","fallbackEndpointIDs":[],"matchMode":"all","rules":[],"alert":{"debounce":2,"notify":true,"popup":false,"sound":false,"notifyRecovery":true,"failureIsOK":false}}]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.probes.count, 1)
        XCTAssertEqual(config.defaultIntervalSeconds, 60)
    }

    func testEffectiveIntervalRespectsEndpointMinimum() {
        var config = AppConfig()
        config.defaultIntervalSeconds = 60
        let probe = Probe(name: "x", endpointID: "cloudflare", fallbackEndpointIDs: ["ipinfo"])
        XCTAssertEqual(config.effectiveInterval(for: probe), 120)
    }

    func testDefaultProbesReferenceExistingEndpoints() {
        let config = AppConfig.makeDefault()
        let ids = Set(config.allEndpoints.map(\.id))
        for probe in config.probes {
            for id in probe.endpointChain { XCTAssertTrue(ids.contains(id), "\(probe.name) 引用了不存在的接口 \(id)") }
        }
    }

    func testHistoryFileAppendAndPrune() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let file = HistoryFile(url: url)
        let id = UUID()
        let old = HistoryEvent(date: Date(timeIntervalSinceNow: -40 * 86400), probeID: id, probeName: "a", kind: .mismatch)
        let recent = HistoryEvent(date: Date(), probeID: id, probeName: "a", kind: .recovered, after: "x, \"y\"", duration: 60)
        try file.append(old)
        try file.append(recent)
        XCTAssertEqual(file.load().count, 2)
        let kept = try file.prune(olderThan: Date(timeIntervalSinceNow: -30 * 86400))
        XCTAssertEqual(kept.map(\.id), [recent.id])
        XCTAssertTrue(HistoryFile.csv(kept).contains("\"x, \"\"y\"\"\""))
    }
}

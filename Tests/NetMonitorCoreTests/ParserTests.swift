import XCTest
@testable import NetMonitorCore

/// 样例响应取自 docs/endpoints.md 的实测格式，IP 换成了文档保留网段
final class ParserTests: XCTestCase {
    private func endpoint(_ id: String) -> Endpoint {
        EndpointCatalog.builtin.first { $0.id == id }!
    }

    func testIPIP() throws {
        let body = #"{"ret":"ok","data":{"ip":"198.51.100.17","location":["中国","北京","北京","","移动"]}}"#
        let geo = try ResponseParser.parse(text: body, endpoint: endpoint("ipip"))
        XCTAssertEqual(geo.ip, "198.51.100.17")
        XCTAssertEqual(geo.countryCode, "CN")
        XCTAssertEqual(geo.region, "北京")
        XCTAssertEqual(geo.org, "移动")
    }

    func testIPIPHongKongMapsToHK() throws {
        let body = #"{"ret":"ok","data":{"ip":"203.0.113.24","location":["中国","香港","","","hkt.com"]}}"#
        let geo = try ResponseParser.parse(text: body, endpoint: endpoint("ipip"))
        XCTAssertEqual(geo.countryCode, "HK")
    }

    func testIPIPFailureFlag() {
        let body = #"{"ret":"err","data":{}}"#
        XCTAssertThrowsError(try ResponseParser.parse(text: body, endpoint: endpoint("ipip"))) { error in
            XCTAssertEqual(error as? ParseError, .unsuccessful("err"))
        }
    }

    func testIP9LowercaseCountryCode() throws {
        let body = #"{"ret":200,"data":{"ip":"198.51.100.17","country":"中国","country_code":"cn","prov":"北京","city":"北京","isp":"中国移动"},"qt":0.001}"#
        let geo = try ResponseParser.parse(text: body, endpoint: endpoint("ip9"))
        XCTAssertEqual(geo.countryCode, "CN")
        XCTAssertEqual(geo.org, "中国移动")
    }

    func testPconlineLeadingWhitespaceAndImpliedCountry() throws {
        let body = "\r\n\r\n\r\n" + #"{"ip":"198.51.100.17","pro":"北京市","proCode":"110000","city":"北京市","cityCode":"110000","region":"","regionCode":"0","addr":"北京市 移通","regionNames":"","err":""}"# + "\r\n\r\n"
        let geo = try ResponseParser.parse(text: body, endpoint: endpoint("pconline"))
        XCTAssertEqual(geo.ip, "198.51.100.17")
        XCTAssertEqual(geo.countryCode, "CN")
        XCTAssertEqual(geo.region, "北京市")
    }

    func testGBKDecoding() throws {
        // "北京" 的 GBK 编码
        let data = Data(#"{"ip":"198.51.100.17","pro":""#.utf8) + Data([0xB1, 0xB1, 0xBE, 0xA9]) + Data(#"","city":""}"#.utf8)
        let geo = try ResponseParser.parse(data, endpoint: endpoint("pconline"))
        XCTAssertEqual(geo.region, "北京")
    }

    func testCloudflareTrace() throws {
        let body = """
        fl=618f194
        h=www.cloudflare.com
        ip=203.0.113.88
        ts=1795601591.000
        colo=LAX
        loc=JP
        tls=TLSv1.3
        """
        let geo = try ResponseParser.parse(text: body, endpoint: endpoint("cloudflare"))
        XCTAssertEqual(geo.ip, "203.0.113.88")
        XCTAssertEqual(geo.countryCode, "JP")
        XCTAssertEqual(geo.country, CountryNames.displayName(for: "JP"))
    }

    func testIPInfoSplitsASN() throws {
        let body = """
        {
          "ip": "198.51.100.17",
          "city": "Beijing",
          "region": "Beijing",
          "country": "CN",
          "org": "AS56048 China Mobile Communicaitons Corporation"
        }
        """
        let geo = try ResponseParser.parse(text: body, endpoint: endpoint("ipinfo"))
        XCTAssertEqual(geo.asn, 56048)
        XCTAssertEqual(geo.org, "China Mobile Communicaitons Corporation")
        XCTAssertEqual(geo.countryCode, "CN")
    }

    func testIPSB() throws {
        let body = #"{"region":"Tokyo","organization":"KDDI","isp":"KDDI","city":"Tokyo","asn":2516,"ip":"203.0.113.88","country":"Japan","country_code":"JP"}"#
        let geo = try ResponseParser.parse(text: body, endpoint: endpoint("ip-sb"))
        XCTAssertEqual(geo.asn, 2516)
        XCTAssertEqual(geo.org, "KDDI")
        XCTAssertEqual(geo.countryCode, "JP")
        XCTAssertEqual(geo.locationLine, "Tokyo · AS2516 KDDI")
    }

    func testIPWhoIsNestedConnection() throws {
        let body = #"{"ip":"203.0.113.88","success":true,"country":"Japan","country_code":"JP","region":"Tokyo","city":"Tokyo","connection":{"asn":2516,"org":"KDDI","isp":"KDDI Corporation"}}"#
        let geo = try ResponseParser.parse(text: body, endpoint: endpoint("ipwhois"))
        XCTAssertEqual(geo.asn, 2516)
        XCTAssertEqual(geo.org, "KDDI Corporation")
    }

    func testIPWhoIsFailure() {
        let body = #"{"success":false,"message":"Reserved range"}"#
        XCTAssertThrowsError(try ResponseParser.parse(text: body, endpoint: endpoint("ipwhois")))
    }

    func testPlainIPv6() throws {
        let geo = try ResponseParser.parse(text: "2001:db8::1\n", endpoint: endpoint("ident-v6"))
        XCTAssertEqual(geo.ip, "2001:db8::1")
        XCTAssertFalse(geo.hasLocation)
    }

    func testHTMLLoginPageIsInvalidJSON() {
        let body = "<html><title>Wi-Fi 登录</title></html>"
        XCTAssertThrowsError(try ResponseParser.parse(text: body, endpoint: endpoint("ip-sb"))) { error in
            XCTAssertEqual(error as? ParseError, .invalidJSON)
        }
    }

    func testPlainTextGarbageIsInvalidIP() {
        XCTAssertThrowsError(try ResponseParser.parse(text: "<html>", endpoint: endpoint("ident-v6")))
    }

    func testSplitASN() {
        XCTAssertEqual(ResponseParser.splitASN("AS4760 HKT").0, 4760)
        XCTAssertEqual(ResponseParser.splitASN("AS4760 HKT").1, "HKT")
        XCTAssertEqual(ResponseParser.splitASN("2516").0, 2516)
        XCTAssertNil(ResponseParser.splitASN("Asia Pacific Network").0)
        XCTAssertNil(ResponseParser.splitASN("China Mobile").0)
    }

    func testMergeKeepsOriginalIP() {
        let base = GeoInfo(ip: "2001:db8::1", raw: "2001:db8::1")
        let extra = GeoInfo(ip: "2001:db8::1", countryCode: "JP", raw: "{}")
        let merged = ResponseParser.merge(base, enrichment: extra)
        XCTAssertEqual(merged.countryCode, "JP")
        XCTAssertEqual(merged.ip, "2001:db8::1")
    }
}

import Foundation

/// 内置查询接口。来源与实测情况见 docs/endpoints.md。
public enum EndpointCatalog {
    public static let enrichmentID = "ipwhois-lookup"

    public static let builtin: [Endpoint] = [
        // MARK: 境内
        Endpoint(
            id: "ipip", name: "IPIP.net", group: .domestic,
            url: "https://myip.ipip.net/json", kind: .json,
            fields: FieldMap(ip: "data.ip", country: "data.location.0", region: "data.location.1",
                             city: "data.location.2", org: "data.location.4",
                             success: "ret", successValue: "ok"),
            summary: "国家、省、市、运营商（中文）", isBuiltin: true
        ),
        Endpoint(
            id: "ip9", name: "IP9", group: .domestic,
            url: "https://ip9.com.cn/get", kind: .json,
            fields: FieldMap(ip: "data.ip", countryCode: "data.country_code", country: "data.country",
                             region: "data.prov", city: "data.city", org: "data.isp",
                             success: "ret", successValue: "200"),
            summary: "国家码、省、市、运营商；较慢", isBuiltin: true
        ),
        Endpoint(
            id: "pconline", name: "太平洋 IP 库", group: .domestic,
            url: "https://whois.pconline.com.cn/ipJson.jsp?json=true", kind: .json,
            fields: FieldMap(ip: "ip", region: "pro", city: "city", org: "addr"),
            encoding: .gbk, impliedCountryCode: "CN",
            summary: "省、市；无国家字段", isBuiltin: true
        ),

        // MARK: 境外
        Endpoint(
            id: "cloudflare", name: "Cloudflare trace", group: .overseas,
            url: "https://www.cloudflare.com/cdn-cgi/trace", kind: .keyValue,
            fields: FieldMap(ip: "ip", countryCode: "loc"),
            summary: "仅国家码；无配额压力", isBuiltin: true
        ),
        Endpoint(
            id: "ip-sb", name: "IP.SB", group: .overseas,
            url: "https://api.ip.sb/geoip", kind: .json,
            fields: FieldMap(ip: "ip", countryCode: "country_code", country: "country",
                             region: "region", city: "city", asn: "asn", org: "isp"),
            summary: "国家、城市、ASN、运营商", isBuiltin: true
        ),
        Endpoint(
            id: "ipwhois", name: "ipwho.is", group: .overseas,
            url: "https://ipwho.is/", kind: .json,
            fields: FieldMap(ip: "ip", countryCode: "country_code", country: "country",
                             region: "region", city: "city", asn: "connection.asn", org: "connection.isp",
                             success: "success"),
            summary: "国家、城市、ASN、运营商", isBuiltin: true
        ),
        Endpoint(
            id: "ipinfo", name: "ipinfo.io", group: .overseas,
            url: "https://ipinfo.io/json", kind: .json,
            fields: FieldMap(ip: "ip", countryCode: "country", region: "region", city: "city", org: "org"),
            minIntervalSeconds: 120,
            summary: "国家、城市、ASN；免 Token 每日约 1000 次", isBuiltin: true
        ),

        // MARK: IPv6（尚未实测）
        Endpoint(
            id: "ident-v6", name: "ident.me（IPv6）", group: .overseas,
            url: "https://v6.ident.me", kind: .plainIP, ipVersion: .v6,
            summary: "仅 IP，归属地由补全服务查询", isBuiltin: true
        ),
        Endpoint(
            id: "icanhazip-v6", name: "icanhazip（IPv6）", group: .overseas,
            url: "https://ipv6.icanhazip.com", kind: .plainIP, ipVersion: .v6,
            summary: "仅 IP，归属地由补全服务查询", isBuiltin: true
        ),
    ]

    /// 归属地补全服务：只拿到 IP 时用它查询国家与运营商
    public static let enrichment = Endpoint(
        id: enrichmentID, name: "ipwho.is 查询", group: .overseas,
        url: "https://ipwho.is/{ip}", kind: .json,
        fields: FieldMap(ip: "ip", countryCode: "country_code", country: "country",
                         region: "region", city: "city", asn: "connection.asn", org: "connection.isp",
                         success: "success"),
        summary: "按 IP 查询归属地", isBuiltin: true
    )
}

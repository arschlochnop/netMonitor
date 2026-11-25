import Foundation

public enum ParseError: Error, Hashable, Sendable {
    case emptyBody
    case invalidJSON
    case unsuccessful(String)
    case missingIP
    case invalidIP(String)

    public var message: String {
        switch self {
        case .emptyBody: return "响应为空"
        case .invalidJSON: return "响应不是有效的 JSON（可能是登录页或拦截页）"
        case .unsuccessful(let v): return "接口返回失败标志：\(v)"
        case .missingIP: return "响应中找不到 IP"
        case .invalidIP(let v): return "响应中的 IP 无效：\(v.prefix(40))"
        }
    }
}

public enum ResponseParser {

    public static func decode(_ data: Data, encoding: TextEncoding) -> String {
        switch encoding {
        case .utf8:
            return String(decoding: data, as: UTF8.self)
        case .gbk:
            #if canImport(Darwin)
            let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let s = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                return s
            }
            #endif
            return String(decoding: data, as: UTF8.self)
        }
    }

    public static func parse(_ data: Data, endpoint: Endpoint) throws -> GeoInfo {
        try parse(text: decode(data, encoding: endpoint.encoding), endpoint: endpoint)
    }

    public static func parse(text rawText: String, endpoint: Endpoint) throws -> GeoInfo {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.emptyBody }

        var info: GeoInfo
        switch endpoint.kind {
        case .plainIP:
            let ip = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
            info = GeoInfo(ip: ip.trimmingCharacters(in: .whitespaces), raw: text)

        case .keyValue:
            var map: [String: String] = [:]
            for line in text.split(whereSeparator: { $0.isNewline }) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                map[key] = value
            }
            let f = endpoint.fields
            guard let ip = map[f.ip ?? "ip"] else { throw ParseError.missingIP }
            info = GeoInfo(
                ip: ip,
                countryCode: f.countryCode.flatMap { map[$0] },
                country: f.country.flatMap { map[$0] },
                region: f.region.flatMap { map[$0] },
                city: f.city.flatMap { map[$0] },
                org: f.org.flatMap { map[$0] },
                raw: text
            )
            if let asnKey = f.asn, let v = map[asnKey] { applyASN(v, to: &info) }

        case .json:
            guard let data = text.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { throw ParseError.invalidJSON }
            let f = endpoint.fields
            if let successPath = f.success {
                let actual = JSONPath.string(at: successPath, in: root) ?? "nil"
                let expected = f.successValue ?? "true"
                if actual.lowercased() != expected.lowercased() {
                    throw ParseError.unsuccessful(actual)
                }
            }
            guard let ip = JSONPath.string(at: f.ip ?? "ip", in: root) else { throw ParseError.missingIP }
            info = GeoInfo(
                ip: ip,
                countryCode: f.countryCode.flatMap { JSONPath.string(at: $0, in: root) },
                country: f.country.flatMap { JSONPath.string(at: $0, in: root) },
                region: f.region.flatMap { JSONPath.string(at: $0, in: root) },
                city: f.city.flatMap { JSONPath.string(at: $0, in: root) },
                org: f.org.flatMap { JSONPath.string(at: $0, in: root) },
                raw: text
            )
            if let asnPath = f.asn, let v = JSONPath.string(at: asnPath, in: root) { applyASN(v, to: &info) }
        }

        info.ip = info.ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPAddress.isValid(info.ip) else { throw ParseError.invalidIP(info.ip) }
        normalize(&info, endpoint: endpoint)
        return info
    }

    /// 合并归属地补全服务的结果，保留原始 IP
    public static func merge(_ base: GeoInfo, enrichment: GeoInfo) -> GeoInfo {
        var out = base
        out.countryCode = base.countryCode ?? enrichment.countryCode
        out.country = base.country ?? enrichment.country
        out.region = base.region ?? enrichment.region
        out.city = base.city ?? enrichment.city
        out.asn = base.asn ?? enrichment.asn
        out.org = base.org ?? enrichment.org
        out.raw = base.raw + "\n---\n" + enrichment.raw
        return out
    }

    // MARK: - 规范化

    static func normalize(_ info: inout GeoInfo, endpoint: Endpoint) {
        info.countryCode = clean(info.countryCode)?.uppercased()
        info.country = clean(info.country)
        info.region = clean(info.region)
        info.city = clean(info.city)
        info.org = clean(info.org)

        if let org = info.org {
            // 形如 "AS56048 China Mobile ..." 时拆出 ASN
            let (asn, name) = splitASN(org)
            if let asn {
                if info.asn == nil { info.asn = asn }
                info.org = clean(name)
            }
        }

        // 国内接口常把港澳台写成「中国 + 省份」，以省份为准
        if let special = CountryNames.code(country: nil, region: info.region),
           info.countryCode == nil || info.countryCode == "CN" {
            info.countryCode = special
        }
        if info.countryCode == nil {
            info.countryCode = CountryNames.code(country: info.country, region: info.region)
        }
        if info.countryCode == nil, let implied = endpoint.impliedCountryCode, info.region != nil {
            info.countryCode = implied
        }
        if info.country == nil, let code = info.countryCode {
            info.country = CountryNames.displayName(for: code)
        }
    }

    static func applyASN(_ value: String, to info: inout GeoInfo) {
        let (asn, name) = splitASN(value)
        if let asn { info.asn = asn }
        if info.org == nil, let name = clean(name) { info.org = name }
    }

    /// "AS56048 China Mobile" -> (56048, "China Mobile")；"56048" -> (56048, nil)
    static func splitASN(_ value: String) -> (Int?, String?) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        var rest = Substring(trimmed)
        if rest.uppercased().hasPrefix("AS") { rest = rest.dropFirst(2) }
        let digits = rest.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let n = Int(digits) else { return (nil, trimmed) }
        let hadPrefix = trimmed.uppercased().hasPrefix("AS")
        let remainder = rest.dropFirst(digits.count)
        // 纯数字，或 AS 前缀后紧跟空格才认为是 ASN
        guard hadPrefix || remainder.isEmpty else { return (nil, trimmed) }
        guard remainder.isEmpty || remainder.first == " " else { return (nil, trimmed) }
        let name = remainder.trimmingCharacters(in: .whitespaces)
        return (n, name.isEmpty ? nil : name)
    }

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// 点分路径取值：`data.location.0`
public enum JSONPath {
    public static func value(at path: String, in root: Any) -> Any? {
        var current: Any? = root
        for part in path.split(separator: ".") {
            guard let node = current else { return nil }
            if let dict = node as? [String: Any] {
                current = dict[String(part)]
            } else if let array = node as? [Any], let index = Int(part), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        if current is NSNull { return nil }
        return current
    }

    public static func string(at path: String, in root: Any) -> String? {
        guard let v = value(at: path, in: root) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            #if canImport(Darwin)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            #endif
            return n.stringValue
        }
        if let b = v as? Bool { return b ? "true" : "false" }
        return nil
    }
}

public enum IPAddress {
    public static func isValid(_ s: String) -> Bool { isIPv4(s) || isIPv6(s) }

    public static func isIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    public static func isIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return s.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }
}

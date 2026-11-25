import Foundation

public enum IPVersion: String, Codable, CaseIterable, Hashable, Sendable {
    case v4, v6

    public var title: String { self == .v4 ? "IPv4" : "IPv6" }
}

/// 查询接口所在的分组。境内 / 境外只描述服务器位置，实际走哪条出口由用户的分流规则决定。
public enum EndpointGroup: String, Codable, CaseIterable, Hashable, Sendable {
    case domestic, overseas, custom

    public var title: String {
        switch self {
        case .domestic: return "境内"
        case .overseas: return "境外"
        case .custom: return "自定义"
        }
    }
}

public enum ResponseKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// 响应体就是 IP 本身
    case plainIP
    /// 每行 `key=value`，如 Cloudflare 的 cdn-cgi/trace
    case keyValue
    /// JSON，字段用点分路径定位，数组下标写数字，如 `data.location.0`
    case json
    /// 任意文本，字段用正则提取（取第 1 个捕获组）；IP 与国家码留空时自动识别
    case text

    public var title: String {
        switch self {
        case .plainIP: return "纯文本 IP"
        case .keyValue: return "key=value 文本"
        case .json: return "JSON"
        case .text: return "文本（正则提取）"
        }
    }
}

public enum TextEncoding: String, Codable, CaseIterable, Hashable, Sendable {
    case utf8, gbk
}

/// 响应字段到统一结果的映射。keyValue 格式下填键名，json 格式下填点分路径。
public struct FieldMap: Codable, Hashable, Sendable {
    public var ip: String?
    public var countryCode: String?
    public var country: String?
    public var region: String?
    public var city: String?
    public var asn: String?
    public var org: String?
    /// 成功标志所在路径；为空表示不检查
    public var success: String?
    /// 成功标志的期望值（字符串形式），为空时期望 `true`
    public var successValue: String?

    public init(ip: String? = nil, countryCode: String? = nil, country: String? = nil,
                region: String? = nil, city: String? = nil, asn: String? = nil, org: String? = nil,
                success: String? = nil, successValue: String? = nil) {
        self.ip = ip
        self.countryCode = countryCode
        self.country = country
        self.region = region
        self.city = city
        self.asn = asn
        self.org = org
        self.success = success
        self.successValue = successValue
    }
}

public struct Endpoint: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var group: EndpointGroup
    /// 请求地址。用作归属地补全服务时，`{ip}` 会被替换为要查询的 IP。
    public var url: String
    public var kind: ResponseKind
    public var fields: FieldMap
    public var ipVersion: IPVersion
    /// 该接口允许的最小检测间隔（秒），用于避开每日配额
    public var minIntervalSeconds: Int
    public var encoding: TextEncoding
    /// 接口不返回国家、但只服务于某个国家时的隐含国家码（如 pconline 只覆盖中国大陆）
    public var impliedCountryCode: String?
    /// 一句话说明返回哪些信息
    public var summary: String
    public var isBuiltin: Bool

    public init(id: String, name: String, group: EndpointGroup, url: String, kind: ResponseKind,
                fields: FieldMap = FieldMap(), ipVersion: IPVersion = .v4, minIntervalSeconds: Int = 10,
                encoding: TextEncoding = .utf8, impliedCountryCode: String? = nil,
                summary: String = "", isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.group = group
        self.url = url
        self.kind = kind
        self.fields = fields
        self.ipVersion = ipVersion
        self.minIntervalSeconds = minIntervalSeconds
        self.encoding = encoding
        self.impliedCountryCode = impliedCountryCode
        self.summary = summary
        self.isBuiltin = isBuiltin
    }

    /// 请求的域名，用于对照分流规则
    public var host: String? { URL(string: url)?.host }
}

/// 一次查询得到的出口信息
public struct GeoInfo: Codable, Hashable, Sendable {
    public var ip: String
    public var countryCode: String?
    public var country: String?
    public var region: String?
    public var city: String?
    public var asn: Int?
    public var org: String?
    /// 原始响应全文，供关键字规则匹配与排查
    public var raw: String

    public init(ip: String, countryCode: String? = nil, country: String? = nil, region: String? = nil,
                city: String? = nil, asn: Int? = nil, org: String? = nil, raw: String = "") {
        self.ip = ip
        self.countryCode = countryCode
        self.country = country
        self.region = region
        self.city = city
        self.asn = asn
        self.org = org
        self.raw = raw
    }

    public var hasLocation: Bool { countryCode != nil || country != nil }

    /// 用于界面展示的归属描述，如「东京 · AS2516 KDDI」
    public var locationLine: String {
        var parts: [String] = []
        let place = [region, city].compactMap { $0 }.reduce(into: [String]()) { acc, item in
            if !acc.contains(item) { acc.append(item) }
        }
        if !place.isEmpty {
            parts.append(place.joined(separator: " "))
        } else if let country {
            parts.append(country)
        }
        var network = ""
        if let asn { network = "AS\(asn)" }
        if let org { network = network.isEmpty ? org : "\(network) \(org)" }
        if !network.isEmpty { parts.append(network) }
        return parts.joined(separator: " · ")
    }
}

public enum ProbeStatus: String, Codable, Hashable, Sendable {
    /// 拿到 IP 且通过全部规则
    case ok
    /// 拿到 IP 但未通过规则（已过防抖）
    case mismatch
    /// 超时、接口不可用、断网
    case failed
    /// 用户暂停或停用
    case paused
    /// 尚未检测，或不符合但还未达到防抖次数
    case pending

    public var title: String {
        switch self {
        case .ok: return "正常"
        case .mismatch: return "不符合"
        case .failed: return "检测失败"
        case .paused: return "已暂停"
        case .pending: return "待确认"
        }
    }
}

import Foundation

public struct ProbeAlertSettings: Codable, Hashable, Sendable {
    /// 连续多少次不符合才提醒
    public var debounce: Int = 2
    public var notify: Bool = true
    public var popup: Bool = false
    public var sound: Bool = false
    public var notifyRecovery: Bool = true
    /// 检测失败（含本机无 IPv6）时视为正常，用于「IPv6 应当不可达」这类检测点
    public var failureIsOK: Bool = false

    public init() {}
}

/// 检测点 = 查询接口 + 预期规则。查询接口决定请求走哪条出口。
public struct Probe: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var endpointID: String
    /// 主接口失败时依次回退；应与主接口命中同一条分流规则
    public var fallbackEndpointIDs: [String]
    /// 为空时跟随全局间隔
    public var intervalSeconds: Int?
    public var matchMode: MatchMode
    public var rules: [Rule]
    public var alert: ProbeAlertSettings

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, endpointID: String,
                fallbackEndpointIDs: [String] = [], intervalSeconds: Int? = nil,
                matchMode: MatchMode = .all, rules: [Rule] = [], alert: ProbeAlertSettings = ProbeAlertSettings()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.endpointID = endpointID
        self.fallbackEndpointIDs = fallbackEndpointIDs
        self.intervalSeconds = intervalSeconds
        self.matchMode = matchMode
        self.rules = rules
        self.alert = alert
    }

    public var endpointChain: [String] { [endpointID] + fallbackEndpointIDs.filter { $0 != endpointID } }
}

public enum MenuBarText: String, Codable, CaseIterable, Hashable, Sendable {
    case none, countryCode, ip

    public var title: String {
        switch self {
        case .none: return "仅图标"
        case .countryCode: return "国家码"
        case .ip: return "IP"
        }
    }
}

public struct AppConfig: Codable, Hashable, Sendable {
    public var version: Int = 1
    public var defaultIntervalSeconds: Int = 60
    public var timeoutSeconds: Int = 8
    public var checkOnNetworkChange: Bool = true
    /// 唤醒后等待多少秒再检测，期间的失败不计入
    public var wakeGraceSeconds: Int = 10
    /// 持续不符合时的重复提醒间隔（分钟），为空表示不重复
    public var repeatAlertMinutes: Int? = 10
    /// 连续检测失败多少次后提醒，为空表示从不
    public var failureAlertAfter: Int? = 3
    public var menuBarText: MenuBarText = .countryCode
    public var menuBarProbeID: UUID?
    public var historyRetentionDays: Int = 30
    /// 暂停全部检测
    public var allPaused: Bool = false
    public var probes: [Probe] = []
    public var customEndpoints: [Endpoint] = []
    /// 只返回 IP 的接口用它补全归属地
    public var enrichmentEndpointID: String = EndpointCatalog.enrichmentID

    public init() {}

    // 新增字段时保持旧配置可读
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        defaultIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .defaultIntervalSeconds) ?? d.defaultIntervalSeconds
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        checkOnNetworkChange = try c.decodeIfPresent(Bool.self, forKey: .checkOnNetworkChange) ?? d.checkOnNetworkChange
        wakeGraceSeconds = try c.decodeIfPresent(Int.self, forKey: .wakeGraceSeconds) ?? d.wakeGraceSeconds
        repeatAlertMinutes = try c.decodeIfPresent(Int.self, forKey: .repeatAlertMinutes)
        failureAlertAfter = try c.decodeIfPresent(Int.self, forKey: .failureAlertAfter)
        menuBarText = try c.decodeIfPresent(MenuBarText.self, forKey: .menuBarText) ?? d.menuBarText
        menuBarProbeID = try c.decodeIfPresent(UUID.self, forKey: .menuBarProbeID)
        historyRetentionDays = try c.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? d.historyRetentionDays
        allPaused = try c.decodeIfPresent(Bool.self, forKey: .allPaused) ?? d.allPaused
        probes = try c.decodeIfPresent([Probe].self, forKey: .probes) ?? []
        customEndpoints = try c.decodeIfPresent([Endpoint].self, forKey: .customEndpoints) ?? []
        enrichmentEndpointID = try c.decodeIfPresent(String.self, forKey: .enrichmentEndpointID) ?? d.enrichmentEndpointID
    }

    /// 内置接口 + 自定义接口
    public var allEndpoints: [Endpoint] { EndpointCatalog.builtin + customEndpoints }

    public var endpointsByID: [String: Endpoint] {
        Dictionary(allEndpoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 实际检测间隔：检测点设置 / 全局默认，且不低于所用接口的最小间隔
    public func effectiveInterval(for probe: Probe) -> Int {
        let wanted = probe.intervalSeconds ?? defaultIntervalSeconds
        let floor = probe.endpointChain.compactMap { endpointsByID[$0]?.minIntervalSeconds }.max() ?? 0
        return max(wanted, floor, 5)
    }

    public static func makeDefault() -> AppConfig {
        var config = AppConfig()
        let domestic = Probe(
            name: "国内视角",
            endpointID: "ipip",
            fallbackEndpointIDs: ["ip9", "pconline"],
            rules: [Rule(field: .countryCode, op: .isIn, value: "CN")]
        )
        let overseas = Probe(
            name: "海外视角",
            endpointID: "cloudflare",
            fallbackEndpointIDs: ["ip-sb", "ipwhois"],
            rules: [Rule(field: .countryCode, op: .notIn, value: "CN")]
        )
        var v6Alert = ProbeAlertSettings()
        v6Alert.failureIsOK = true
        let v6 = Probe(
            name: "IPv6 泄漏检查",
            endpointID: "ident-v6",
            fallbackEndpointIDs: ["icanhazip-v6"],
            rules: [Rule(field: .countryCode, op: .notIn, value: "CN")],
            alert: v6Alert
        )
        config.probes = [domestic, overseas, v6]
        config.menuBarProbeID = overseas.id
        return config
    }
}

public enum ConfigStore {
    public static func load(from url: URL) throws -> AppConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    public static func save(_ config: AppConfig, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}

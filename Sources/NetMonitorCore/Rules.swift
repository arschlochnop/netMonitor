import Foundation

public enum RuleField: String, Codable, CaseIterable, Hashable, Sendable {
    case countryCode, country, region, city, org, asn, ip, raw

    public var title: String {
        switch self {
        case .countryCode: return "国家码"
        case .country: return "国家名"
        case .region: return "地区"
        case .city: return "城市"
        case .org: return "运营商"
        case .asn: return "ASN"
        case .ip: return "IP"
        case .raw: return "原始响应"
        }
    }

    func value(in geo: GeoInfo) -> String? {
        switch self {
        case .countryCode: return geo.countryCode
        case .country: return geo.country
        case .region: return geo.region
        case .city: return geo.city
        case .org: return geo.org
        case .asn: return geo.asn.map(String.init)
        case .ip: return geo.ip
        case .raw: return geo.raw
        }
    }
}

public enum RuleOperator: String, Codable, CaseIterable, Hashable, Sendable {
    case isIn, notIn, contains, notContains, equals, notEquals, matchesRegex

    public var title: String {
        switch self {
        case .isIn: return "属于"
        case .notIn: return "不属于"
        case .contains: return "包含"
        case .notContains: return "不包含"
        case .equals: return "等于"
        case .notEquals: return "不等于"
        case .matchesRegex: return "匹配正则"
        }
    }

    /// 输入框占位提示
    public var placeholder: String {
        switch self {
        case .isIn, .notIn: return "多个值用逗号分隔，如 JP, US"
        case .matchesRegex: return "正则表达式，不区分大小写"
        default: return "关键字，不区分大小写"
        }
    }
}

public struct Rule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var field: RuleField
    public var op: RuleOperator
    public var value: String

    public init(id: UUID = UUID(), field: RuleField, op: RuleOperator, value: String) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }

    public var summary: String { "\(field.title)\(op.title) \(value)" }
}

public enum MatchMode: String, Codable, CaseIterable, Hashable, Sendable {
    case all, any

    public var title: String { self == .all ? "全部" : "任一" }
}

public struct RuleResult: Hashable, Sendable {
    public var rule: Rule
    public var passed: Bool
    public var actual: String?
    public var note: String?

    /// 如「国家码应属于 JP，实际为 HK」
    public var explanation: String {
        if let note { return "\(rule.summary)：\(note)" }
        let actualText = actual.map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 } ?? "（无）"
        if passed { return rule.summary }
        return "\(rule.field.title)应\(rule.op.title) \(rule.value)，实际为 \(actualText)"
    }
}

public struct Evaluation: Hashable, Sendable {
    public var passed: Bool
    public var results: [RuleResult]

    public var failures: [RuleResult] { results.filter { !$0.passed } }
    public var passedCount: Int { results.filter(\.passed).count }
}

public enum RuleEngine {

    public static func evaluate(_ rules: [Rule], mode: MatchMode, geo: GeoInfo) -> Evaluation {
        let results = rules.map { evaluate($0, geo: geo) }
        guard !results.isEmpty else { return Evaluation(passed: true, results: []) }
        let passed: Bool
        switch mode {
        case .all: passed = results.allSatisfy(\.passed)
        case .any: passed = results.contains(where: \.passed)
        }
        return Evaluation(passed: passed, results: results)
    }

    public static func evaluate(_ rule: Rule, geo: GeoInfo) -> RuleResult {
        let actual = rule.field.value(in: geo)
        // 取不到字段时一律判为未通过：宁可误报，不可漏报
        guard let actual else {
            return RuleResult(rule: rule, passed: false, actual: nil, note: "该接口未返回\(rule.field.title)")
        }
        let target = rule.value.trimmingCharacters(in: .whitespaces)

        switch rule.op {
        case .isIn, .notIn:
            let items = splitList(target)
            let hit = items.contains { $0.caseInsensitiveCompare(actual) == .orderedSame }
            return RuleResult(rule: rule, passed: rule.op == .isIn ? hit : !hit, actual: actual)
        case .contains, .notContains:
            let hit = !target.isEmpty && actual.range(of: target, options: [.caseInsensitive]) != nil
            return RuleResult(rule: rule, passed: rule.op == .contains ? hit : !hit, actual: actual)
        case .equals, .notEquals:
            let hit = actual.caseInsensitiveCompare(target) == .orderedSame
            return RuleResult(rule: rule, passed: rule.op == .equals ? hit : !hit, actual: actual)
        case .matchesRegex:
            guard let regex = try? NSRegularExpression(pattern: target, options: [.caseInsensitive]) else {
                return RuleResult(rule: rule, passed: false, actual: actual, note: "正则表达式无效")
            }
            let range = NSRange(actual.startIndex..., in: actual)
            let hit = regex.firstMatch(in: actual, options: [], range: range) != nil
            return RuleResult(rule: rule, passed: hit, actual: actual)
        }
    }

    static func splitList(_ s: String) -> [String] {
        s.split(whereSeparator: { ",，、;； ".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

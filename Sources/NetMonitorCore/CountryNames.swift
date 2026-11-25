import Foundation

/// 把接口返回的国家名（中文或英文）映射为 ISO 3166-1 二位码。
public enum CountryNames {
    private static let table: [String: String] = [
        "中国": "CN", "中国大陆": "CN", "china": "CN", "people's republic of china": "CN",
        "香港": "HK", "中国香港": "HK", "hong kong": "HK",
        "澳门": "MO", "中国澳门": "MO", "macao": "MO", "macau": "MO",
        "台湾": "TW", "中国台湾": "TW", "taiwan": "TW",
        "日本": "JP", "japan": "JP",
        "美国": "US", "united states": "US", "united states of america": "US", "usa": "US",
        "韩国": "KR", "south korea": "KR", "korea": "KR", "republic of korea": "KR",
        "新加坡": "SG", "singapore": "SG",
        "英国": "GB", "united kingdom": "GB",
        "德国": "DE", "germany": "DE",
        "法国": "FR", "france": "FR",
        "荷兰": "NL", "netherlands": "NL",
        "加拿大": "CA", "canada": "CA",
        "澳大利亚": "AU", "australia": "AU",
        "俄罗斯": "RU", "russia": "RU",
        "印度": "IN", "india": "IN",
        "越南": "VN", "vietnam": "VN", "viet nam": "VN",
        "泰国": "TH", "thailand": "TH",
        "马来西亚": "MY", "malaysia": "MY",
        "菲律宾": "PH", "philippines": "PH",
        "印度尼西亚": "ID", "印尼": "ID", "indonesia": "ID",
        "土耳其": "TR", "turkey": "TR", "türkiye": "TR",
        "巴西": "BR", "brazil": "BR",
        "意大利": "IT", "italy": "IT",
        "西班牙": "ES", "spain": "ES",
        "瑞士": "CH", "switzerland": "CH",
        "瑞典": "SE", "sweden": "SE",
        "阿联酋": "AE", "阿拉伯联合酋长国": "AE", "united arab emirates": "AE",
        "爱尔兰": "IE", "ireland": "IE",
        "波兰": "PL", "poland": "PL",
        "芬兰": "FI", "finland": "FI",
        "挪威": "NO", "norway": "NO",
        "以色列": "IL", "israel": "IL",
        "南非": "ZA", "south africa": "ZA",
        "墨西哥": "MX", "mexico": "MX",
        "阿根廷": "AR", "argentina": "AR",
        "新西兰": "NZ", "new zealand": "NZ",
    ]

    public static func code(for name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return table[key]
    }

    /// 国内接口常把港澳台写成「国家 = 中国，省 = 香港」，此时以省份为准。
    public static func code(country: String?, region: String?) -> String? {
        if let region, let code = specialRegion(region) { return code }
        guard let country else { return nil }
        return code(for: country)
    }

    private static func specialRegion(_ region: String) -> String? {
        let r = region.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.hasPrefix("香港") { return "HK" }
        if r.hasPrefix("澳门") { return "MO" }
        if r.hasPrefix("台湾") { return "TW" }
        return nil
    }

    /// 二位码的中文名，取不到时返回码本身
    public static func displayName(for code: String) -> String {
        Locale(identifier: "zh_CN").localizedString(forRegionCode: code) ?? code
    }
}

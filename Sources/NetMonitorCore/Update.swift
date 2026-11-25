import Foundation

/// 语义化版本：主.次.修订[-预发布]，前缀 v 可有可无
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// 预发布标记，如 "dev"、"beta.1"；为空表示正式版
    public var prerelease: String?

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".").map { Int($0) }
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        major = numbers[0]!
        minor = numbers.count > 1 ? numbers[1]! : 0
        patch = numbers.count > 2 ? numbers[2]! : 0
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // 同一版本号时，预发布版本低于正式版
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (_?, nil): return true
        case (nil, _?): return false
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }
}

/// GitHub Release 中用到的字段
public struct GitHubRelease: Decodable, Hashable, Sendable {
    public struct Asset: Decodable, Hashable, Sendable {
        public var name: String
        public var size: Int
        public var browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var name: String?
    public var body: String?
    public var htmlURL: URL
    public var draft: Bool
    public var prerelease: Bool
    public var publishedAt: Date?
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    public static func decode(_ data: Data) throws -> GitHubRelease {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    public var version: SemanticVersion? { SemanticVersion(tagName) }

    /// 安装包：NetMonitor-<版本>.zip
    public var packageAsset: Asset? {
        assets.first { $0.name.hasPrefix("NetMonitor") && $0.name.hasSuffix(".zip") }
    }

    /// 安装包的校验文件：<安装包名>.sha256
    public var checksumAsset: Asset? {
        guard let package = packageAsset else { return nil }
        return assets.first { $0.name == package.name + ".sha256" }
    }
}

public enum UpdateDecision: Equatable, Sendable {
    case upToDate
    case available(SemanticVersion)
    /// 有新版本但用户选择跳过
    case skipped(SemanticVersion)
    /// Release 不可用（草稿、预发布、版本号无法识别或缺少安装包）
    case unusable(String)
}

public enum UpdatePolicy {
    public static func decide(current: SemanticVersion, release: GitHubRelease, skippedVersion: String?) -> UpdateDecision {
        guard !release.draft, !release.prerelease else { return .unusable("最新 Release 是草稿或预发布版本") }
        guard let latest = release.version else { return .unusable("无法识别版本号 \(release.tagName)") }
        guard current < latest else { return .upToDate }
        guard release.packageAsset != nil else { return .unusable("Release \(release.tagName) 中没有安装包") }
        if let skippedVersion, SemanticVersion(skippedVersion) == latest { return .skipped(latest) }
        return .available(latest)
    }

    /// 解析 `shasum -a 256` 的输出："<64 位十六进制>  文件名"
    public static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let hex = first.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}

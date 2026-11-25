import Foundation

public enum HistoryKind: String, Codable, CaseIterable, Hashable, Sendable {
    case mismatch, recovered, failed, ipChanged

    public var title: String {
        switch self {
        case .mismatch: return "不符合"
        case .recovered: return "恢复"
        case .failed: return "检测失败"
        case .ipChanged: return "IP 变化"
        }
    }

    public var isAbnormal: Bool { self == .mismatch || self == .failed }
}

/// 只记录状态变化与 IP 变化，不记录每次检测
public struct HistoryEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var probeID: UUID
    public var probeName: String
    public var kind: HistoryKind
    public var before: String?
    public var after: String?
    public var detail: String?
    /// 恢复事件记录本次异常持续的秒数
    public var duration: TimeInterval?

    public init(id: UUID = UUID(), date: Date, probeID: UUID, probeName: String, kind: HistoryKind,
                before: String? = nil, after: String? = nil, detail: String? = nil, duration: TimeInterval? = nil) {
        self.id = id
        self.date = date
        self.probeID = probeID
        self.probeName = probeName
        self.kind = kind
        self.before = before
        self.after = after
        self.detail = detail
        self.duration = duration
    }
}

/// JSON Lines 文件存储，一行一个事件
public final class HistoryFile {
    public let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> [HistoryEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(HistoryEvent.self, from: Data($0)) }
    }

    public func append(_ event: HistoryEvent) throws {
        var line = try encoder.encode(event)
        line.append(UInt8(ascii: "\n"))
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// 删除早于保留期限的事件，返回保留下来的事件
    @discardableResult
    public func prune(olderThan cutoff: Date) throws -> [HistoryEvent] {
        let all = load()
        let kept = all.filter { $0.date >= cutoff }
        guard kept.count != all.count else { return all }
        var data = Data()
        for e in kept {
            data.append(try encoder.encode(e))
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url, options: .atomic)
        return kept
    }

    public static func csv(_ events: [HistoryEvent]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        func esc(_ s: String?) -> String {
            let v = s ?? ""
            if v.contains(",") || v.contains("\"") || v.contains("\n") {
                return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return v
        }
        var lines = ["时间,检测点,事件,变化前,变化后,说明"]
        for e in events {
            lines.append([formatter.string(from: e.date), e.probeName, e.kind.title, e.before, e.after, e.detail]
                .map { esc($0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

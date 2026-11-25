import AppKit
import NetMonitorCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct HistoryView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var probeFilter: UUID?
    @State private var range: TimeInterval = 86400
    @State private var abnormalOnly = false

    private var filtered: [HistoryEvent] {
        let cutoff = Date().addingTimeInterval(-range)
        return monitor.history
            .filter { $0.date >= cutoff }
            .filter { probeFilter == nil || $0.probeID == probeFilter }
            .filter { !abnormalOnly || $0.kind.isAbnormal }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("检测点", selection: $probeFilter) {
                    Text("全部检测点").tag(UUID?.none)
                    ForEach(monitor.config.probes) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .frame(width: 220)
                Picker("时间范围", selection: $range) {
                    Text("最近 24 小时").tag(TimeInterval(86400))
                    Text("最近 7 天").tag(TimeInterval(7 * 86400))
                    Text("最近 30 天").tag(TimeInterval(30 * 86400))
                    Text("全部").tag(TimeInterval(3650 * 86400))
                }
                .frame(width: 220)
                Toggle("仅看异常", isOn: $abnormalOnly)
                Spacer()
                Button("导出 CSV…") { exportCSV() }
            }

            HStack(spacing: 12) {
                stat("不符合", filtered.filter { $0.kind == .mismatch }.count.description)
                stat("检测失败", filtered.filter { $0.kind == .failed }.count.description)
                stat("IP 变化", filtered.filter { $0.kind == .ipChanged }.count.description)
                stat("最长一次异常", filtered.compactMap(\.duration).max().map(Format.duration) ?? "—")
            }

            Table(filtered) {
                TableColumn("时间") { e in
                    Text(Format.dateTime.string(from: e.date)).monospacedDigit().foregroundColor(.secondary)
                }
                .width(min: 110, ideal: 120)
                TableColumn("检测点") { e in Text(e.probeName) }
                    .width(min: 80, ideal: 110)
                TableColumn("事件") { e in
                    Text(e.kind.title)
                        .fontWeight(.semibold)
                        .foregroundColor(color(e.kind))
                }
                .width(min: 70, ideal: 80)
                TableColumn("变化前") { e in Text(e.before ?? "").foregroundColor(.secondary).help(e.before ?? "") }
                TableColumn("变化后") { e in Text(e.after ?? "").help(e.after ?? "") }
                TableColumn("说明") { e in Text(e.detail ?? "").foregroundColor(.secondary).help(e.detail ?? "") }
            }

            Text("只记录 IP 变化和状态变化，不记录每次检测；保留期限在“设置 · 通用”中修改。")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 520)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private func color(_ kind: HistoryKind) -> Color {
        switch kind {
        case .mismatch: return ProbeStatus.mismatch.color
        case .recovered: return ProbeStatus.ok.color
        case .failed: return ProbeStatus.failed.color
        case .ipChanged: return .accentColor
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "netmonitor-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 带 BOM，Excel 打开中文不乱码
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(HistoryFile.csv(filtered).utf8)
        try? data.write(to: url)
    }
}

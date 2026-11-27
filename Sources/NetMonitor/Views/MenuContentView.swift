import AppKit
import NetMonitorCore
import SwiftUI

/// 菜单栏下拉面板
///
/// 性能要点：检测状态来自 LiveState（只在内容变化时发布），检测时间由每行自己的
/// TimelineView 按 5 秒刷新，不会因为每秒一次的检测而重排整个面板。
@MainActor
struct MenuContentView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var live: LiveState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            probeList
            Divider()
            footer
        }
        .frame(width: 380)
    }

    // MARK: 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("NetMonitor").font(.system(size: 14, weight: .semibold))
                Text(summary.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(summary.color)
                if monitor.isGloballyMuted, let until = monitor.mutedUntil {
                    Text("提醒已暂停至 \(Format.clock.string(from: until))")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button {
                monitor.checkAll()
            } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("立即检测全部")
            .accessibilityLabel("立即检测全部")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: (text: String, color: Color) {
        if monitor.config.allPaused { return ("已暂停全部检测", Color.secondary) }
        let statuses = monitor.config.probes.compactMap { live.snapshots[$0.id]?.status }
        let mismatch = statuses.filter { $0 == .mismatch }.count
        let failed = statuses.filter { $0 == .failed }.count
        if mismatch == 0 && failed == 0 {
            return monitor.config.probes.isEmpty ? ("还没有检测点", Color.secondary) : ("全部正常", ProbeStatus.ok.color)
        }
        var parts: [String] = []
        if mismatch > 0 { parts.append("\(mismatch) 项不符合") }
        if failed > 0 { parts.append("\(failed) 项检测失败") }
        return (parts.joined(separator: " · "), mismatch > 0 ? ProbeStatus.mismatch.color : ProbeStatus.failed.color)
    }

    // MARK: 列表

    @ViewBuilder
    private var probeList: some View {
        let rows = VStack(spacing: 2) {
            ForEach(monitor.config.probes) { probe in
                ProbeRow(probe: probe, snapshot: live.snapshots[probe.id])
            }
            if monitor.config.probes.isEmpty {
                Button("添加检测点…") { WindowManager.shared.showSettings() }
                    .padding(.vertical, 16)
            }
        }
        .padding(6)

        if monitor.config.probes.count > 6 {
            ScrollView { rows }.frame(height: 440)
        } else {
            rows
        }
    }

    // MARK: 底部

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRowButton(title: "立即检测全部", shortcut: "⌘R") { monitor.checkAll() }
                .keyboardShortcut("r")
            HStack {
                Text("暂停提醒").padding(.leading, 10)
                Spacer()
                Menu(monitor.isGloballyMuted ? "已暂停" : "选择时长") {
                    Button("15 分钟") { monitor.mute(for: 15 * 60) }
                    Button("1 小时") { monitor.mute(for: 3600) }
                    Button("直到明天") { monitor.muteUntilTomorrow() }
                    if monitor.isGloballyMuted {
                        Divider()
                        Button("恢复提醒") { monitor.unmute() }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.trailing, 6)
            }
            .frame(height: 26)
            MenuRowButton(title: monitor.config.allPaused ? "恢复全部检测" : "暂停全部检测") {
                monitor.setAllPaused(!monitor.config.allPaused)
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 10)
            UpdateMenuRow(updater: monitor.updater)
            MenuRowButton(title: "历史记录…", shortcut: "⌘Y") { WindowManager.shared.showHistory() }
                .keyboardShortcut("y")
            MenuRowButton(title: "设置…", shortcut: "⌘,") { WindowManager.shared.showSettings() }
                .keyboardShortcut(",")
            MenuRowButton(title: "退出 NetMonitor", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
            if let error = monitor.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(ProbeStatus.mismatch.color)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .padding(6)
    }
}

/// 检测点一行
@MainActor
struct ProbeRow: View {
    var probe: Probe
    var snapshot: ProbeSnapshot?
    @EnvironmentObject var monitor: Monitor
    @State private var expandedByUser: Bool?

    private var status: ProbeStatus { snapshot?.status ?? (probe.enabled ? .pending : .paused) }
    private var expanded: Bool { expandedByUser ?? (status == .mismatch) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: status).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(probe.name).font(.system(size: 13, weight: .semibold))
                    if let group = monitor.endpoint(for: probe)?.group { Tag(text: group.title) }
                    Spacer()
                    CheckTimeText(probeID: probe.id, paused: status == .paused)
                }
                HStack(spacing: 6) {
                    Text(snapshot?.ipText ?? "—").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    if let cc = snapshot?.countryCode { CountryBadge(code: cc) }
                    if let line = snapshot?.locationLine, !line.isEmpty {
                        Text(line).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                if let note = snapshot?.note {
                    let isMismatch = snapshot?.noteStyle == .mismatch
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundColor(noteColor)
                        .padding(.horizontal, isMismatch ? 6 : 0)
                        .padding(.vertical, isMismatch ? 3 : 0)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(isMismatch ? ProbeStatus.mismatch.color.opacity(0.12) : .clear))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if expanded { actions }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(status == .mismatch ? ProbeStatus.mismatch.color.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { expandedByUser = !expanded }
        .contextMenu { menuItems }
    }

    private var noteColor: Color {
        switch snapshot?.noteStyle {
        case .mismatch?: return ProbeStatus.mismatch.color
        case .warning?: return ProbeStatus.failed.color
        default: return .secondary
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("复制 IP") { copyIP() }.disabled(snapshot?.ip == nil)
            Button("立即检测") { monitor.checkNow(probe.id) }
            Button("静音 1 小时") { monitor.muteProbe(probe.id, for: 3600) }
            Button("编辑…") { WindowManager.shared.showSettings(probeID: probe.id) }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("复制 IP") { copyIP() }.disabled(snapshot?.ip == nil)
        Button("立即检测") { monitor.checkNow(probe.id) }
        Button("静音 1 小时") { monitor.muteProbe(probe.id, for: 3600) }
        Button("编辑…") { WindowManager.shared.showSettings(probeID: probe.id) }
    }

    private func copyIP() {
        guard let ip = snapshot?.ip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }
}

/// “x 秒前”：自己按 5 秒刷新，只重绘这一小段文字
@MainActor
struct CheckTimeText: View {
    var probeID: UUID
    var paused: Bool
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text(text(now: context.date))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }

    private func text(now: Date) -> String {
        if paused { return "已暂停" }
        guard let date = monitor.lastCheckDate(probeID) else { return "等待检测" }
        return Format.ago(date, now: now)
    }
}

/// 有新版本时在菜单里显示一行
@MainActor
struct UpdateMenuRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        switch updater.state {
        case .available(let release):
            MenuRowButton(title: "有新版本 \(release.version?.description ?? release.tagName)，立即更新") {
                if updater.canInstall {
                    Task { await updater.downloadAndInstall(release) }
                } else {
                    NSWorkspace.shared.open(release.htmlURL)
                }
            }
            .foregroundColor(.accentColor)
        case .downloading:
            Text("正在下载更新…").foregroundColor(.secondary).padding(.horizontal, 10).frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .installing:
            Text("正在安装更新，即将重启…").foregroundColor(.secondary).padding(.horizontal, 10).frame(height: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}

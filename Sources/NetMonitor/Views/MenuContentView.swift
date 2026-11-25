import AppKit
import NetMonitorCore
import SwiftUI

/// 菜单栏下拉面板
@MainActor
struct MenuContentView: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(spacing: 0) {
                header
                Divider()
                probeList(now: context.date)
                Divider()
                footer
            }
            .frame(width: 380)
        }
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
        if monitor.config.allPaused { return ("已暂停全部检测", .secondary) }
        let statuses = monitor.config.probes.map(monitor.displayStatus(of:))
        let mismatch = statuses.filter { $0 == .mismatch }.count
        let failed = statuses.filter { $0 == .failed }.count
        if mismatch == 0 && failed == 0 {
            return monitor.config.probes.isEmpty ? ("还没有检测点", .secondary) : ("全部正常", ProbeStatus.ok.color)
        }
        var parts: [String] = []
        if mismatch > 0 { parts.append("\(mismatch) 项不符合") }
        if failed > 0 { parts.append("\(failed) 项检测失败") }
        return (parts.joined(separator: " · "), mismatch > 0 ? ProbeStatus.mismatch.color : ProbeStatus.failed.color)
    }

    // MARK: 列表

    @ViewBuilder
    private func probeList(now: Date) -> some View {
        let rows = VStack(spacing: 2) {
            ForEach(monitor.config.probes) { probe in
                ProbeRow(probe: probe, now: now)
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
    var now: Date
    @EnvironmentObject var monitor: Monitor
    @State private var expandedByUser: Bool?

    private var runtime: ProbeRuntime? { monitor.runtimes[probe.id] }
    private var status: ProbeStatus { monitor.displayStatus(of: probe) }
    private var outcome: CheckOutcome? { runtime?.lastOutcome }
    private var expanded: Bool { expandedByUser ?? (status == .mismatch) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(status: status).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(probe.name).font(.system(size: 13, weight: .semibold))
                    if let group = monitor.endpoint(for: probe)?.group { Tag(text: group.title) }
                    Spacer()
                    Text(timeText).font(.system(size: 11)).foregroundColor(.secondary)
                }
                HStack(spacing: 6) {
                    Text(ipText).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    if let cc = outcome?.geo?.countryCode { CountryBadge(code: cc) }
                    if let line = outcome?.geo?.locationLine, !line.isEmpty {
                        Text(line).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                if let note {
                    Text(note.text)
                        .font(.system(size: 12))
                        .foregroundColor(note.color)
                        .padding(.horizontal, status == .mismatch ? 6 : 0)
                        .padding(.vertical, status == .mismatch ? 3 : 0)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(status == .mismatch ? ProbeStatus.mismatch.color.opacity(0.12) : .clear))
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

    private var actions: some View {
        HStack(spacing: 6) {
            Button("复制 IP") { copyIP() }.disabled(outcome?.geo == nil)
            Button("立即检测") { monitor.checkNow(probe.id) }
            Button("静音 1 小时") { monitor.muteProbe(probe.id, for: 3600) }
            Button("编辑…") { WindowManager.shared.showSettings(probeID: probe.id) }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("复制 IP") { copyIP() }.disabled(outcome?.geo == nil)
        Button("立即检测") { monitor.checkNow(probe.id) }
        Button("静音 1 小时") { monitor.muteProbe(probe.id, for: 3600) }
        Button("编辑…") { WindowManager.shared.showSettings(probeID: probe.id) }
    }

    private func copyIP() {
        guard let ip = outcome?.geo?.ip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }

    private var timeText: String {
        if runtime?.checking == true { return "检测中…" }
        if status == .paused { return "已暂停" }
        guard let date = outcome?.date else { return "等待检测" }
        return Format.ago(date, now: now)
    }

    private var ipText: String {
        if let ip = outcome?.geo?.ip { return ip }
        if outcome?.noIPv6 == true { return "无 IPv6" }
        if let ip = runtime?.alert.lastIP { return "上次 \(ip)" }
        return "—"
    }

    private var note: (text: String, color: Color)? {
        guard let outcome else { return nil }
        switch status {
        case .mismatch:
            let failures = outcome.evaluation?.failures.map(\.explanation).joined(separator: "；")
            if let failures, !failures.isEmpty {
                let count = runtime?.alert.consecutiveMismatch ?? 0
                return ("未通过：\(failures)（连续 \(count) 次）", ProbeStatus.mismatch.color)
            }
            return ("检测失败，上次结果不符合：\(outcome.failureSummary)", ProbeStatus.mismatch.color)
        case .failed:
            return ("检测失败：\(outcome.failureSummary)", ProbeStatus.failed.color)
        case .pending:
            if outcome.status == .mismatch {
                let n = runtime?.alert.consecutiveMismatch ?? 0
                return ("不符合，等待确认（\(n)/\(probe.alert.debounce)）", ProbeStatus.failed.color)
            }
            return nil
        case .ok:
            if outcome.geo == nil {
                return (outcome.noIPv6 ? "本机无 IPv6 出口，按设置视为正常" : "检测失败，按设置视为正常", .secondary)
            }
            return nil
        case .paused:
            return nil
        }
    }
}

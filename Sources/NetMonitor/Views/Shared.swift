import NetMonitorCore
import SwiftUI

extension ProbeStatus {
    var color: Color {
        switch self {
        case .ok: return Color(red: 0.12, green: 0.49, blue: 0.26)
        case .mismatch: return Color(red: 0.78, green: 0.16, blue: 0.16)
        case .failed: return Color(red: 0.70, green: 0.37, blue: 0.0)
        case .paused, .pending: return Color(white: 0.56)
        }
    }

    /// 与颜色配合的形状符号，色弱也能区分
    var glyph: String {
        switch self {
        case .ok: return "✓"
        case .mismatch: return "!"
        case .failed: return "?"
        case .paused: return "‖"
        case .pending: return "…"
        }
    }
}

struct StatusDot: View {
    var status: ProbeStatus
    var size: CGFloat = 20

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .overlay(
                Text(status.glyph)
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundColor(.white)
            )
            .accessibilityLabel(status.title)
    }
}

struct Tag: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
    }
}

struct CountryBadge: View {
    var code: String
    var body: some View {
        Text(code)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.3)))
    }
}

/// 菜单风格的整行按钮，悬停高亮
struct MenuRowButton: View {
    var title: String
    var shortcut: String?
    var action: () -> Void
    @State var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundColor(.secondary) }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor.opacity(0.18) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 检测结果摘要，设置页「测试一次」与接口测试共用
@MainActor
struct OutcomeSummary: View {
    var outcome: CheckOutcome
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let geo = outcome.geo {
                let passed = outcome.evaluation?.passed ?? true
                let total = outcome.evaluation?.results.count ?? 0
                let passCount = outcome.evaluation?.passedCount ?? 0
                Text(passed ? "✓ 通过 \(passCount)/\(total) 条规则" : "✕ 未通过：\(passCount)/\(total) 条规则通过")
                    .fontWeight(.semibold)
                    .foregroundColor(passed ? ProbeStatus.ok.color : ProbeStatus.mismatch.color)
                Text(monitor.describe(geo)).textSelection(.enabled)
                ForEach(outcome.evaluation?.results ?? [], id: \.rule.id) { r in
                    Text((r.passed ? "✓ " : "✕ ") + r.explanation)
                        .font(.caption)
                        .foregroundColor(r.passed ? .secondary : ProbeStatus.mismatch.color)
                }
                Text("经由 \(outcome.endpointName ?? "") · 请求域名 \(outcome.requestHost ?? "—") · \(String(format: "%.1f", outcome.duration)) 秒")
                    .font(.caption).foregroundColor(.secondary)
                Text("若结果出乎意料，对照代理的分流规则检查该域名走哪条出口。")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text(outcome.status == .ok ? "✓ 检测失败，按设置视为正常" : "? 检测失败")
                    .fontWeight(.semibold)
                    .foregroundColor(outcome.status == .ok ? ProbeStatus.ok.color : ProbeStatus.failed.color)
                Text(outcome.failureSummary).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

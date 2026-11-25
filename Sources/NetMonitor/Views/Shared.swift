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

/// 整数输入框：只能输入数字，超出范围时提示并在提交时拉回范围内；右侧带步进按钮
@MainActor
struct IntegerField: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var unit: String
    var step: Int = 1

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    TextField(title, text: $text)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .focused($focused)
                        .onSubmit(commit)
                    Text(unit).foregroundColor(.secondary)
                    Stepper(title, value: Binding(
                        get: { value },
                        set: { newValue in
                            value = Limits.clamp(newValue, range)
                            text = String(value)
                        }
                    ), in: range, step: step)
                    .labelsHidden()
                }
                Text(hint.text)
                    .font(.caption)
                    .foregroundColor(hint.isError ? ProbeStatus.mismatch.color : .secondary)
            }
        } label: {
            Text(title)
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { newValue in
            if !focused { text = String(newValue) }
        }
        .onChange(of: text) { newText in
            // 只保留数字：不允许小数、负号和其他字符
            let digits = newText.filter { $0.isASCII && $0.isNumber }
            if digits != newText {
                text = digits
                return
            }
            if let n = Int(digits), range.contains(n) { value = n }
        }
        .onChange(of: focused) { isFocused in
            if !isFocused { commit() }
        }
    }

    private var hint: (text: String, isError: Bool) {
        let rangeText = "范围 \(range.lowerBound)–\(range.upperBound) \(unit)"
        guard let n = Int(text) else {
            return text.isEmpty ? ("请输入整数，\(rangeText)", true) : ("数值过大，\(rangeText)", true)
        }
        if !range.contains(n) { return ("超出范围，\(rangeText)", true) }
        return (rangeText, false)
    }

    private func commit() {
        let n: Int
        if let parsed = Int(text) {
            n = parsed
        } else {
            // 空输入恢复原值；数字过长溢出视为上限
            n = text.isEmpty ? value : range.upperBound
        }
        value = Limits.clamp(n, range)
        text = String(value)
    }
}

/// 可关闭的整数设置：关闭时为 nil
@MainActor
struct OptionalIntegerField: View {
    var toggleTitle: String
    var title: String
    @Binding var value: Int?
    var defaultValue: Int
    var range: ClosedRange<Int>
    var unit: String
    var step: Int = 1

    var body: some View {
        Toggle(toggleTitle, isOn: Binding(
            get: { value != nil },
            set: { value = $0 ? (value ?? defaultValue) : nil }
        ))
        if value != nil {
            IntegerField(title: title, value: Binding(
                get: { value ?? defaultValue },
                set: { value = $0 }
            ), range: range, unit: unit, step: step)
        }
    }
}

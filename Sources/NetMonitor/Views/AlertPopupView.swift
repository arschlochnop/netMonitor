import NetMonitorCore
import SwiftUI

/// 强提醒弹窗内容
@MainActor
struct AlertPopupView: View {
    @ObservedObject var model: PopupModel
    var onMute: () -> Void
    var onSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundColor(ProbeStatus.mismatch.color)
                    .accessibilityLabel("警告")
                VStack(alignment: .leading, spacing: 4) {
                    Text("出口 IP 不符合预期").font(.system(size: 15, weight: .semibold))
                    Text("\(Format.clock.string(from: model.shownAt)) 检测发现 \(model.items.count) 个检测点异常")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            ForEach(model.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.name).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(item.endpoint).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Text(item.ipLine).font(.system(size: 12)).textSelection(.enabled)
                    ForEach(item.results, id: \.rule.id) { r in
                        Text((r.passed ? "✓ " : "✕ ") + r.explanation)
                            .font(.system(size: 12))
                            .foregroundColor(r.passed ? ProbeStatus.ok.color : ProbeStatus.mismatch.color)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            }
            HStack {
                Spacer()
                Button("静音 1 小时", action: onMute)
                Button("打开设置", action: onSettings)
                Button("知道了", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

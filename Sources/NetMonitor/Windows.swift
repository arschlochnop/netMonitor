import AppKit
import NetMonitorCore
import ServiceManagement
import SwiftUI

// MARK: - 普通窗口（设置、历史）

/// 菜单栏应用没有主窗口，设置与历史窗口自行管理，关闭后保留以便再次打开
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func showSettings(probeID: UUID? = nil) {
        if let probeID { Monitor.shared.selectedProbeID = probeID }
        show(id: "settings", title: "NetMonitor 设置", size: NSSize(width: 880, height: 660)) {
            SettingsView().environmentObject(Monitor.shared)
        }
    }

    func showHistory() {
        show(id: "history", title: "历史记录", size: NSSize(width: 980, height: 620)) {
            HistoryView().environmentObject(Monitor.shared)
        }
    }

    private func show<Content: View>(id: String, title: String, size: NSSize, content: () -> Content) {
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
        } else {
            window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(size)
            window.isReleasedWhenClosed = false
            window.center()
            windows[id] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 强提醒弹窗

struct PopupItem: Identifiable, Hashable {
    var id: UUID
    var name: String
    var endpoint: String
    var ipLine: String
    var results: [RuleResult]
}

@MainActor
final class PopupModel: ObservableObject {
    @Published var items: [PopupItem] = []
    @Published var shownAt = Date()
}

/// 置顶浮动面板：不受专注模式影响，需要手动关闭
@MainActor
final class PopupController {
    private var panel: NSPanel?
    private let model = PopupModel()

    func show(items: [PopupItem], onMute: @escaping () -> Void, onSettings: @escaping () -> Void) {
        guard !items.isEmpty else { return }
        model.items = items
        model.shownAt = Date()
        if panel == nil {
            let view = AlertPopupView(
                model: model,
                onMute: { [weak self] in onMute(); self?.close() },
                onSettings: { [weak self] in self?.close(); onSettings() },
                onDismiss: { [weak self] in self?.close() }
            )
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = [.preferredContentSize]
            let panel = NSPanel(contentViewController: hosting)
            panel.styleMask = [.titled, .closable, .fullSizeContentView]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        guard let panel else { return }
        if !panel.isVisible { panel.center() }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 弹窗打开时同步最新状态；全部恢复后自动关闭
    func update(items: [PopupItem]) {
        guard let panel, panel.isVisible else { return }
        if items.isEmpty {
            close()
        } else {
            model.items = items
        }
    }

    func close() {
        panel?.orderOut(nil)
    }
}

// MARK: - 登录时启动

enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - 菜单栏图标

enum StatusIcon {
    /// 生成模板图：随菜单栏深浅色自动反色。状态靠图形区分，不依赖颜色。
    static func image(status: ProbeStatus, text: String?) -> NSImage {
        let symbolName: String
        switch status {
        case .ok, .pending: symbolName = "globe"
        case .mismatch: symbolName = "exclamationmark.triangle.fill"
        case .failed: symbolName = "questionmark.circle"
        case .paused: symbolName = "pause.circle"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: status.title)?
            .withSymbolConfiguration(config) ?? NSImage()

        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero
        let height: CGFloat = 16
        let iconWidth = max(symbol.size.width, 14)
        let width = ceil(iconWidth + (text == nil ? 0 : 3 + textSize.width))
        let alpha: CGFloat = status == .paused ? 0.5 : 1

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let symbolRect = NSRect(x: (iconWidth - symbol.size.width) / 2,
                                    y: (height - symbol.size.height) / 2,
                                    width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: alpha)
            if let text {
                (text as NSString).draw(at: NSPoint(x: iconWidth + 3, y: (height - textSize.height) / 2),
                                        withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NetMonitor：\(status.title)" + (text.map { "，\($0)" } ?? "")
        return image
    }
}

import AppKit
import SwiftUI

@main
@MainActor
struct NetMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 不订阅 Monitor：否则任何状态变化都会让整个菜单栏场景重算
    private let monitor = Monitor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
                .environmentObject(monitor.live)
        } label: {
            MenuBarLabel(live: monitor.live)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 打包时 Info.plist 已设置 LSUIElement；直接运行可执行文件时也不显示 Dock 图标
        NSApp.setActivationPolicy(.accessory)
        Monitor.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Monitor.shared.saveNow()
    }
}

/// 菜单栏图标：只订阅整体状态和图标旁文字
@MainActor
struct MenuBarLabel: View {
    @ObservedObject var live: LiveState

    var body: some View {
        Image(nsImage: StatusIcon.image(status: live.overall, text: live.menuBarText))
    }
}

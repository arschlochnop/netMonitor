import AppKit
import SwiftUI

@main
@MainActor
struct NetMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = Monitor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
        } label: {
            Image(nsImage: StatusIcon.image(status: monitor.overallStatus, text: monitor.menuBarText))
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

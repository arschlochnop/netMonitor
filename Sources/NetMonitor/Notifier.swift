import AppKit
import Foundation
import UserNotifications

/// 系统通知。只有打包成 .app 运行时才可用；直接 `swift run` 时没有 Bundle ID，系统通知接口会崩溃。
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    var onOpen: ((UUID?) -> Void)?
    var onMute: ((UUID?) -> Void)?
    @Published private(set) var authorized = false
    @Published private(set) var statusText = "未知"

    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func setup() {
        guard isAvailable else {
            statusText = "不可用（未以 .app 方式运行）"
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let view = UNNotificationAction(identifier: "view", title: "查看", options: [.foreground])
        let mute = UNNotificationAction(identifier: "mute1h", title: "静音 1 小时", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "alert", actions: [view, mute], intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in await self?.refreshStatus() }
        }
    }

    func refreshStatus() async {
        guard isAvailable else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
            statusText = "已允许"
        case .denied:
            authorized = false
            statusText = "已拒绝（将改用弹窗提醒）"
        case .notDetermined:
            authorized = false
            statusText = "尚未授权"
        default:
            authorized = settings.authorizationStatus.rawValue >= 2
            statusText = authorized ? "已允许" : "未授权"
        }
    }

    func post(title: String, body: String, probeID: UUID?, sound: Bool, actionable: Bool) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if actionable { content.categoryIdentifier = "alert" }
        if let probeID { content.userInfo = ["probeID": probeID.uuidString] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let idString = response.notification.request.content.userInfo["probeID"] as? String
        completionHandler()
        Task { @MainActor in
            let id = idString.flatMap(UUID.init(uuidString:))
            if action == "mute1h" {
                self.onMute?(id)
            } else {
                self.onOpen?(id)
            }
        }
    }
}

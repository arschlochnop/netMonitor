import Foundation
import NetMonitorCore

/// 菜单栏界面需要展示的检测点状态。
///
/// 只包含用户能看到的内容，不含检测时间、是否正在检测等每秒都在变的字段，
/// 因此检测间隔再短，只要 IP、归属和状态没变，就不会触发界面重新布局。
struct ProbeSnapshot: Equatable {
    enum NoteStyle: Equatable { case mismatch, warning, secondary }

    var status: ProbeStatus
    /// 可复制的 IP；检测失败时为 nil
    var ip: String?
    var ipText: String
    var countryCode: String?
    var locationLine: String
    var note: String?
    var noteStyle: NoteStyle
}

/// 菜单栏界面订阅的状态。只在值真正变化时才发布，避免高频检测拖垮主线程。
@MainActor
final class LiveState: ObservableObject {
    @Published private(set) var snapshots: [UUID: ProbeSnapshot] = [:]
    @Published private(set) var overall: ProbeStatus = .pending
    @Published private(set) var menuBarText: String?

    func update(snapshots new: [UUID: ProbeSnapshot], overall: ProbeStatus, menuBarText: String?) {
        if snapshots != new { snapshots = new }
        if self.overall != overall { self.overall = overall }
        if self.menuBarText != menuBarText { self.menuBarText = menuBarText }
    }
}

/// 历史事件，单独发布，只有历史窗口订阅
@MainActor
final class HistoryStore: ObservableObject {
    @Published var events: [HistoryEvent] = []
}

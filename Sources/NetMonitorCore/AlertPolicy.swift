import Foundation

/// 每个检测点的提醒状态，用于防抖、去重和恢复判断
public struct AlertState: Codable, Hashable, Sendable {
    public var lastRaw: ProbeStatus?
    public var consecutiveMismatch = 0
    public var consecutiveFailure = 0
    /// 不符合已达防抖次数
    public var confirmedMismatch = false
    /// 已就检测失败发出过提醒
    public var failureAlerted = false
    public var abnormalSince: Date?
    public var lastAlertAt: Date?
    public var lastIP: String?
    public var lastLocation: String?

    public init() {}

    /// 界面上展示的状态
    public var displayStatus: ProbeStatus {
        if confirmedMismatch { return .mismatch }
        switch lastRaw {
        case .failed?: return .failed
        case .ok?: return .ok
        default: return .pending
        }
    }
}

public struct AlertPolicySettings: Hashable, Sendable {
    public var debounce: Int
    public var notifyRecovery: Bool
    public var repeatInterval: TimeInterval?
    public var failureAlertAfter: Int?

    public init(debounce: Int, notifyRecovery: Bool, repeatInterval: TimeInterval?, failureAlertAfter: Int?) {
        self.debounce = debounce
        self.notifyRecovery = notifyRecovery
        self.repeatInterval = repeatInterval
        self.failureAlertAfter = failureAlertAfter
    }
}

public enum AlertEvent: Hashable, Sendable {
    /// 不符合达到防抖次数（首次提醒）
    case mismatchConfirmed
    /// 持续不符合，到了重复提醒时间
    case mismatchRepeated
    /// 恢复正常；`notify` 表示之前提醒过、需要通知恢复
    case recovered(duration: TimeInterval, notify: Bool)
    /// 开始检测失败（只记历史）
    case failureStarted
    /// 连续失败达到阈值（需要提醒）
    case failureAlert
    /// 出口 IP 变化（只记历史）
    case ipChanged(from: String, to: String)

    public var shouldNotify: Bool {
        switch self {
        case .mismatchConfirmed, .mismatchRepeated, .failureAlert: return true
        case .recovered(_, let notify): return notify
        case .failureStarted, .ipChanged: return false
        }
    }
}

public enum AlertPolicy {

    /// 处理一次检测结果。`raw` 为本次结果（ok / mismatch / failed），`ip` 为本次拿到的 IP。
    public static func process(state: inout AlertState, raw: ProbeStatus, ip: String?, location: String? = nil,
                               now: Date, settings: AlertPolicySettings) -> [AlertEvent] {
        var events: [AlertEvent] = []
        let previousRaw = state.lastRaw

        if let ip {
            if let last = state.lastIP, last != ip {
                events.append(.ipChanged(from: last, to: ip))
            }
            state.lastIP = ip
            state.lastLocation = location
        }

        switch raw {
        case .ok:
            let wasAlerted = state.confirmedMismatch || state.failureAlerted
            let wasAbnormal = wasAlerted || previousRaw == .failed
            if wasAbnormal {
                let duration = state.abnormalSince.map { now.timeIntervalSince($0) } ?? 0
                events.append(.recovered(duration: duration, notify: wasAlerted && settings.notifyRecovery))
            }
            state.consecutiveMismatch = 0
            state.consecutiveFailure = 0
            state.confirmedMismatch = false
            state.failureAlerted = false
            state.abnormalSince = nil
            state.lastAlertAt = nil

        case .mismatch:
            state.consecutiveFailure = 0
            state.failureAlerted = false
            state.consecutiveMismatch += 1
            if state.consecutiveMismatch >= max(1, settings.debounce) {
                if !state.confirmedMismatch {
                    state.confirmedMismatch = true
                    if state.abnormalSince == nil { state.abnormalSince = now }
                    state.lastAlertAt = now
                    events.append(.mismatchConfirmed)
                } else if let interval = settings.repeatInterval, let last = state.lastAlertAt,
                          now.timeIntervalSince(last) >= interval {
                    state.lastAlertAt = now
                    events.append(.mismatchRepeated)
                }
            }

        case .failed:
            state.consecutiveFailure += 1
            // 失败时无法判断是否仍不符合：保留已确认的不符合，但不再累加
            if previousRaw != .failed {
                events.append(.failureStarted)
                if state.abnormalSince == nil { state.abnormalSince = now }
            }
            if let threshold = settings.failureAlertAfter, !state.failureAlerted,
               state.consecutiveFailure >= max(1, threshold) {
                state.failureAlerted = true
                state.lastAlertAt = now
                events.append(.failureAlert)
            }

        case .paused, .pending:
            return events
        }

        state.lastRaw = raw
        return events
    }
}

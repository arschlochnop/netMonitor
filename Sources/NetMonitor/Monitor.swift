import AppKit
import Combine
import Foundation
import Network
import NetMonitorCore

struct ProbeRuntime {
    var lastOutcome: CheckOutcome?
    var alert = AlertState()
    var checking = false
    var lastRun: Date?
    var mutedUntil: Date?
}

/// 调度检测、维护状态、发出提醒、记录历史
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published var config: AppConfig {
        didSet { configChanged(from: oldValue) }
    }
    @Published private(set) var runtimes: [UUID: ProbeRuntime] = [:]
    @Published private(set) var history: [HistoryEvent] = []
    @Published private(set) var mutedUntil: Date?
    @Published private(set) var supportsIPv6: Bool?
    /// 设置窗口中选中的检测点
    @Published var selectedProbeID: UUID?
    @Published private(set) var lastError: String?

    let notifier: Notifier
    let popup: PopupController
    let configURL: URL
    private let historyFile: HistoryFile
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?
    private var graceUntil: Date?
    private var started = false
    private var lastPrune = Date.distantPast

    init() {
        notifier = Notifier()
        popup = PopupController()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetMonitor", isDirectory: true)
        configURL = support.appendingPathComponent("config.json")
        historyFile = HistoryFile(url: support.appendingPathComponent("history.jsonl"))
        var loadError: String?
        let loaded: AppConfig
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                loaded = try ConfigStore.load(from: configURL)
            } catch {
                // 配置损坏时不覆盖原文件，先备份再用默认配置
                let backup = configURL.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.copyItem(at: configURL, to: backup)
                loaded = AppConfig.makeDefault()
                loadError = "配置文件无法读取，已备份为 \(backup.lastPathComponent) 并恢复默认配置"
            }
        } else {
            loaded = AppConfig.makeDefault()
            try? ConfigStore.save(loaded, to: configURL)
        }
        config = loaded
        lastError = loadError
        selectedProbeID = loaded.probes.first?.id
    }

    // MARK: - 启动

    func start() {
        guard !started else { return }
        started = true

        pruneHistory()

        notifier.onOpen = { [weak self] id in self?.openFromNotification(probeID: id) }
        notifier.onMute = { [weak self] id in
            if let id { self?.muteProbe(id, for: 3600) } else { self?.mute(for: 3600) }
        }
        notifier.setup()

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            let satisfied = path.status == .satisfied
            let v6 = path.supportsIPv6
            Task { @MainActor in self?.pathChanged(signature: signature, satisfied: satisfied, supportsIPv6: v6) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "netmonitor.path"))

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }

        checkAll()
    }

    // MARK: - 调度

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(lastPrune) > 6 * 3600 { pruneHistory() }
        guard !config.allPaused else { return }
        if let graceUntil, now < graceUntil { return }
        for probe in config.probes where probe.enabled {
            let rt = runtimes[probe.id] ?? ProbeRuntime()
            guard !rt.checking else { continue }
            let interval = TimeInterval(config.effectiveInterval(for: probe))
            if let last = rt.lastRun, now.timeIntervalSince(last) < interval { continue }
            run(probe)
        }
    }

    func checkAll() {
        guard !config.allPaused else { return }
        for probe in config.probes where probe.enabled && runtimes[probe.id]?.checking != true {
            run(probe)
        }
    }

    func checkNow(_ id: UUID) {
        guard let probe = config.probes.first(where: { $0.id == id }), runtimes[id]?.checking != true else { return }
        run(probe)
    }

    private func pathChanged(signature: String, satisfied: Bool, supportsIPv6: Bool) {
        self.supportsIPv6 = supportsIPv6
        defer { lastPathSignature = signature }
        guard let previous = lastPathSignature, previous != signature,
              satisfied, config.checkOnNetworkChange else { return }
        // 网络刚切换时路由和代理可能还没就绪，稍等再测
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            Task { @MainActor in self?.checkAll() }
        }
    }

    private func didWake() {
        let grace = TimeInterval(config.wakeGraceSeconds)
        graceUntil = Date().addingTimeInterval(grace)
        DispatchQueue.main.asyncAfter(deadline: .now() + grace + 0.5) { [weak self] in
            Task { @MainActor in self?.checkAll() }
        }
    }

    private func run(_ probe: Probe) {
        var rt = runtimes[probe.id] ?? ProbeRuntime()
        rt.checking = true
        rt.lastRun = Date()
        runtimes[probe.id] = rt

        let prober = Prober(timeout: TimeInterval(config.timeoutSeconds))
        let endpoints = config.endpointsByID
        let enrichment = enrichmentEndpoint
        let v6 = supportsIPv6
        Task {
            let outcome = await prober.check(probe: probe, endpoints: endpoints, enrichment: enrichment, supportsIPv6: v6)
            self.apply(outcome)
        }
    }

    /// 设置页「测试一次」：只返回结果，不影响状态与提醒
    func test(_ probe: Probe) async -> CheckOutcome {
        let prober = Prober(timeout: TimeInterval(config.timeoutSeconds))
        return await prober.check(probe: probe, endpoints: config.endpointsByID,
                                  enrichment: enrichmentEndpoint, supportsIPv6: supportsIPv6)
    }

    func testEndpoint(_ endpoint: Endpoint) async -> Result<GeoInfo, CheckFailure> {
        let prober = Prober(timeout: TimeInterval(config.timeoutSeconds))
        do {
            return .success(try await prober.query(endpoint))
        } catch let e as CheckFailureError {
            return .failure(e.failure)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    var enrichmentEndpoint: Endpoint? {
        if config.enrichmentEndpointID == EndpointCatalog.enrichmentID { return EndpointCatalog.enrichment }
        return config.endpointsByID[config.enrichmentEndpointID]
    }

    // MARK: - 结果处理

    private func apply(_ outcome: CheckOutcome) {
        guard let probe = config.probes.first(where: { $0.id == outcome.probeID }) else { return }
        var rt = runtimes[probe.id] ?? ProbeRuntime()
        rt.checking = false
        rt.lastOutcome = outcome

        // 唤醒宽限期内的失败不计入
        if outcome.status == .failed, let graceUntil, outcome.date < graceUntil {
            runtimes[probe.id] = rt
            return
        }

        let previousDescription = rt.alert.lastIP.map { ip in
            [ip, rt.alert.lastLocation].compactMap { $0 }.joined(separator: " · ")
        }
        let current = outcome.geo.map(describe)
        let settings = AlertPolicySettings(
            debounce: probe.alert.debounce,
            notifyRecovery: probe.alert.notifyRecovery,
            repeatInterval: config.repeatAlertMinutes.map { TimeInterval($0 * 60) },
            failureAlertAfter: config.failureAlertAfter
        )
        let events = AlertPolicy.process(
            state: &rt.alert, raw: outcome.status, ip: outcome.geo?.ip,
            location: outcome.geo.map(locationText), now: outcome.date, settings: settings
        )
        runtimes[probe.id] = rt

        for event in events {
            record(event, probe: probe, outcome: outcome, before: previousDescription, after: current)
            if event.shouldNotify { alert(event, probe: probe, outcome: outcome) }
        }
        refreshPopup()
    }

    private func record(_ event: AlertEvent, probe: Probe, outcome: CheckOutcome, before: String?, after: String?) {
        let failures = outcome.evaluation?.failures.map(\.explanation).joined(separator: "；")
        let item: HistoryEvent?
        switch event {
        case .mismatchConfirmed:
            item = HistoryEvent(date: outcome.date, probeID: probe.id, probeName: probe.name, kind: .mismatch,
                                before: before, after: after, detail: failures)
        case .recovered(let duration, _):
            item = HistoryEvent(date: outcome.date, probeID: probe.id, probeName: probe.name, kind: .recovered,
                                before: nil, after: after ?? "（检测失败视为正常）",
                                detail: "异常持续 \(Format.duration(duration))", duration: duration)
        case .failureStarted:
            item = HistoryEvent(date: outcome.date, probeID: probe.id, probeName: probe.name, kind: .failed,
                                before: before, after: nil, detail: outcome.failureSummary)
        case .ipChanged:
            item = HistoryEvent(date: outcome.date, probeID: probe.id, probeName: probe.name, kind: .ipChanged,
                                before: before, after: after)
        case .mismatchRepeated, .failureAlert:
            item = nil
        }
        guard let item else { return }
        history.append(item)
        do {
            try historyFile.append(item)
        } catch {
            lastError = "历史记录写入失败：\(error.localizedDescription)"
        }
    }

    private func alert(_ event: AlertEvent, probe: Probe, outcome: CheckOutcome) {
        guard !isMuted(probe.id) else { return }
        let settings = probe.alert
        let ipLine = outcome.geo.map(describe) ?? ""

        switch event {
        case .mismatchConfirmed, .mismatchRepeated:
            let failures = outcome.evaluation?.failures.map(\.explanation).joined(separator: "\n") ?? ""
            let title = "\(probe.name)：出口不符合预期"
            let body = [ipLine, failures].filter { !$0.isEmpty }.joined(separator: "\n")
            let canNotify = notifier.isAvailable && notifier.authorized
            if settings.notify && canNotify {
                notifier.post(title: title, body: body, probeID: probe.id, sound: settings.sound, actionable: true)
            }
            // 通知不可用时用弹窗兜底，确保一定看得到
            if settings.popup || (settings.notify && !canNotify) {
                showPopup()
            }
            if settings.sound && !(settings.notify && canNotify) { NSSound.beep() }

        case .recovered(let duration, _):
            guard settings.notify, notifier.isAvailable else { return }
            notifier.post(title: "\(probe.name)：已恢复",
                          body: [ipLine, "异常持续 \(Format.duration(duration))"].filter { !$0.isEmpty }.joined(separator: "\n"),
                          probeID: probe.id, sound: false, actionable: false)

        case .failureAlert:
            guard settings.notify, notifier.isAvailable, notifier.authorized else { return }
            notifier.post(title: "\(probe.name)：检测失败",
                          body: outcome.failureSummary, probeID: probe.id, sound: false, actionable: true)

        case .failureStarted, .ipChanged:
            break
        }
    }

    // MARK: - 弹窗

    private func popupItems() -> [PopupItem] {
        config.probes.compactMap { probe in
            guard displayStatus(of: probe) == .mismatch, let outcome = runtimes[probe.id]?.lastOutcome else { return nil }
            return PopupItem(
                id: probe.id, name: probe.name,
                endpoint: outcome.endpointName ?? "",
                ipLine: outcome.geo.map(describe) ?? "—",
                results: outcome.evaluation?.results ?? []
            )
        }
    }

    func showPopup() {
        popup.show(items: popupItems(),
                   onMute: { [weak self] in self?.mute(for: 3600) },
                   onSettings: { WindowManager.shared.showSettings() })
    }

    private func refreshPopup() {
        popup.update(items: popupItems())
    }

    // MARK: - 静音与暂停

    func isMuted(_ id: UUID) -> Bool {
        let now = Date()
        if let mutedUntil, mutedUntil > now { return true }
        if let until = runtimes[id]?.mutedUntil, until > now { return true }
        return false
    }

    func mute(for seconds: TimeInterval) { mutedUntil = Date().addingTimeInterval(seconds) }

    func muteUntilTomorrow() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        mutedUntil = calendar.date(byAdding: .day, value: 1, to: start)
    }

    func unmute() {
        mutedUntil = nil
        for id in runtimes.keys { runtimes[id]?.mutedUntil = nil }
    }

    func muteProbe(_ id: UUID, for seconds: TimeInterval) {
        var rt = runtimes[id] ?? ProbeRuntime()
        rt.mutedUntil = Date().addingTimeInterval(seconds)
        runtimes[id] = rt
    }

    var isGloballyMuted: Bool { (mutedUntil ?? .distantPast) > Date() }

    func setAllPaused(_ paused: Bool) {
        config.allPaused = paused
        if !paused { checkAll() }
    }

    // MARK: - 派生状态

    func displayStatus(of probe: Probe) -> ProbeStatus {
        if !probe.enabled || config.allPaused { return .paused }
        return runtimes[probe.id]?.alert.displayStatus ?? .pending
    }

    var overallStatus: ProbeStatus {
        let statuses = config.probes.map(displayStatus(of:))
        if statuses.isEmpty || statuses.allSatisfy({ $0 == .paused }) { return .paused }
        if statuses.contains(.mismatch) { return .mismatch }
        if statuses.contains(.failed) { return .failed }
        return .ok
    }

    var menuBarText: String? {
        guard config.menuBarText != .none else { return nil }
        let probe = config.probes.first(where: { $0.id == config.menuBarProbeID }) ?? config.probes.first
        guard let probe, let geo = runtimes[probe.id]?.lastOutcome?.geo else { return nil }
        switch config.menuBarText {
        case .none: return nil
        case .countryCode: return geo.countryCode ?? "?"
        case .ip: return geo.ip
        }
    }

    func endpoint(for probe: Probe) -> Endpoint? { config.endpointsByID[probe.endpointID] }

    func describe(_ geo: GeoInfo) -> String {
        [geo.ip, locationText(geo)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func locationText(_ geo: GeoInfo) -> String {
        [geo.countryCode, geo.locationLine.isEmpty ? nil : geo.locationLine]
            .compactMap { $0 }.joined(separator: " ")
    }

    // MARK: - 配置

    private func configChanged(from old: AppConfig) {
        scheduleSave()
        let oldByID = Dictionary(old.probes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let currentIDs = Set(config.probes.map(\.id))
        for id in runtimes.keys where !currentIDs.contains(id) { runtimes[id] = nil }
        // 接口或规则改了，尽快重测
        for probe in config.probes {
            guard let before = oldByID[probe.id], before != probe else { continue }
            let checkChanged = before.endpointChain != probe.endpointChain || before.rules != probe.rules
                || before.matchMode != probe.matchMode || before.enabled != probe.enabled
            if checkChanged { runtimes[probe.id]?.lastRun = nil }
        }
        if old.historyRetentionDays != config.historyRetentionDays { pruneHistory() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        do {
            try ConfigStore.save(config, to: configURL)
        } catch {
            lastError = "配置保存失败：\(error.localizedDescription)"
        }
    }

    func importConfig(from url: URL) throws {
        let imported = try ConfigStore.load(from: url)
        runtimes = [:]
        config = imported
        selectedProbeID = config.probes.first?.id
        checkAll()
    }

    func exportConfig(to url: URL) throws {
        try ConfigStore.save(config, to: url)
    }

    // MARK: - 历史

    private func pruneHistory() {
        lastPrune = Date()
        let cutoff = Date().addingTimeInterval(-TimeInterval(config.historyRetentionDays) * 86400)
        do {
            history = try historyFile.prune(olderThan: cutoff)
        } catch {
            history = historyFile.load().filter { $0.date >= cutoff }
        }
    }

    private func openFromNotification(probeID: UUID?) {
        if displayStatus(ofID: probeID) == .mismatch {
            showPopup()
        } else {
            WindowManager.shared.showSettings(probeID: probeID)
        }
    }

    private func displayStatus(ofID id: UUID?) -> ProbeStatus? {
        guard let id, let probe = config.probes.first(where: { $0.id == id }) else { return nil }
        return displayStatus(of: probe)
    }
}

enum Format {
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) 秒" }
        if s < 3600 { return "\(s / 60) 分钟" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分钟"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 5 { return "刚刚" }
        if s < 60 { return "\(s) 秒前" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()
}

import AppKit
import NetMonitorCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        TabView {
            ProbesSettingsView()
                .tabItem { Label("检测点", systemImage: "globe") }
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            EndpointsSettingsView()
                .tabItem { Label("查询接口", systemImage: "list.bullet") }
        }
        .padding(12)
        .frame(minWidth: 820, minHeight: 600)
    }
}

// MARK: - 检测点

@MainActor
struct ProbesSettingsView: View {
    @EnvironmentObject var monitor: Monitor

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $monitor.selectedProbeID) {
                    ForEach(monitor.config.probes) { probe in
                        HStack(spacing: 8) {
                            Circle().fill(monitor.displayStatus(of: probe).color).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(probe.name)
                                Text(subtitle(probe)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .tag(probe.id)
                    }
                    .onMove { from, to in monitor.config.probes.move(fromOffsets: from, toOffset: to) }
                }
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        Button("空白检测点") { add(template: .blank) }
                        Divider()
                        Button("国内视角（境内接口，应为 CN）") { add(template: .domestic) }
                        Button("海外视角（境外接口，不应为 CN）") { add(template: .overseas) }
                        Button("IPv6 泄漏检查") { add(template: .ipv6) }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("添加检测点")
                    Button {
                        removeSelected()
                    } label: {
                        Image(systemName: "minus").frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(monitor.selectedProbeID == nil)
                    .help("删除检测点")
                    Button {
                        duplicateSelected()
                    } label: {
                        Image(systemName: "plus.square.on.square").frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(monitor.selectedProbeID == nil)
                    .help("复制检测点")
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 240)

            Divider()

            if let id = monitor.selectedProbeID, let binding = binding(for: id) {
                ProbeEditorView(probe: binding)
                    .id(id)
            } else {
                VStack {
                    Spacer()
                    Text("选择或添加一个检测点").foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func subtitle(_ probe: Probe) -> String {
        let endpoint = monitor.endpoint(for: probe)
        let parts = [endpoint?.group.title, endpoint?.name, probe.enabled ? nil : "已停用"]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private func binding(for id: UUID) -> Binding<Probe>? {
        guard let current = monitor.config.probes.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { monitor.config.probes.first(where: { $0.id == id }) ?? current },
            set: { newValue in
                if let i = monitor.config.probes.firstIndex(where: { $0.id == id }) {
                    monitor.config.probes[i] = newValue
                }
            }
        )
    }

    enum Template { case blank, domestic, overseas, ipv6 }

    private func add(template: Template) {
        var probe: Probe
        switch template {
        case .blank:
            probe = Probe(name: "新检测点", endpointID: "cloudflare", fallbackEndpointIDs: ["ip-sb"])
        case .domestic:
            probe = Probe(name: "国内视角", endpointID: "ipip", fallbackEndpointIDs: ["ip9", "pconline"],
                          rules: [Rule(field: .countryCode, op: .isIn, value: "CN")])
        case .overseas:
            probe = Probe(name: "海外视角", endpointID: "cloudflare", fallbackEndpointIDs: ["ip-sb", "ipwhois"],
                          rules: [Rule(field: .countryCode, op: .notIn, value: "CN")])
        case .ipv6:
            var alert = ProbeAlertSettings()
            alert.failureIsOK = true
            probe = Probe(name: "IPv6 泄漏检查", endpointID: "ident-v6", fallbackEndpointIDs: ["icanhazip-v6"],
                          rules: [Rule(field: .countryCode, op: .notIn, value: "CN")], alert: alert)
        }
        probe.id = UUID()
        monitor.config.probes.append(probe)
        monitor.selectedProbeID = probe.id
    }

    private func removeSelected() {
        guard let id = monitor.selectedProbeID,
              let index = monitor.config.probes.firstIndex(where: { $0.id == id }) else { return }
        let name = monitor.config.probes[index].name
        let alert = NSAlert()
        alert.messageText = "删除检测点「\(name)」？"
        alert.informativeText = "历史记录会保留。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        monitor.config.probes.remove(at: index)
        let next = min(index, monitor.config.probes.count - 1)
        monitor.selectedProbeID = next >= 0 ? monitor.config.probes[next].id : nil
    }

    private func duplicateSelected() {
        guard let id = monitor.selectedProbeID,
              var copy = monitor.config.probes.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.name += " 副本"
        copy.rules = copy.rules.map { Rule(field: $0.field, op: $0.op, value: $0.value) }
        monitor.config.probes.append(copy)
        monitor.selectedProbeID = copy.id
    }
}

@MainActor
struct ProbeEditorView: View {
    @Binding var probe: Probe
    @EnvironmentObject var monitor: Monitor
    @State private var group: EndpointGroup = .overseas
    @State private var testing = false
    @State private var testResult: CheckOutcome?

    private var endpoints: [Endpoint] { monitor.config.allEndpoints }
    private var primary: Endpoint? { monitor.config.endpointsByID[probe.endpointID] }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $probe.name)
                Toggle("启用", isOn: $probe.enabled)
            }

            Section {
                Picker("分组", selection: $group) {
                    ForEach(EndpointGroup.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: group) { newGroup in
                    if primary?.group != newGroup, let first = endpoints.first(where: { $0.group == newGroup }) {
                        probe.endpointID = first.id
                        probe.fallbackEndpointIDs = []
                    }
                }

                Picker("主接口", selection: $probe.endpointID) {
                    ForEach(endpoints.filter { $0.group == group }) { e in
                        Text("\(e.name) — \(e.summary)").tag(e.id)
                    }
                    if primary == nil { Text("（接口不存在）").tag(probe.endpointID) }
                }
                if group == .custom && !endpoints.contains(where: { $0.group == .custom }) {
                    Text("还没有自定义接口，可在“查询接口”页添加。").font(.caption).foregroundColor(.secondary)
                }

                LabeledContent("备用接口") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(Array(probe.fallbackEndpointIDs.enumerated()), id: \.element) { index, id in
                            HStack {
                                Text("\(index + 1). \(monitor.config.endpointsByID[id]?.name ?? id)")
                                Button {
                                    probe.fallbackEndpointIDs.removeAll { $0 == id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("移除 \(monitor.config.endpointsByID[id]?.name ?? id)")
                            }
                        }
                        Menu("添加备用接口") {
                            ForEach(endpoints.filter { !probe.endpointChain.contains($0.id) }) { e in
                                Button("\(e.group.title) · \(e.name)") { probe.fallbackEndpointIDs.append(e.id) }
                            }
                        }
                        .fixedSize()
                    }
                }
                Text("主接口失败时按顺序回退。备用接口应与主接口走同一条出口，否则回退后测到的是另一条路由。")
                    .font(.caption).foregroundColor(.secondary)

                LabeledContent("IP 版本", value: primary?.ipVersion.title ?? "—")
                if let host = primary?.host {
                    LabeledContent("请求域名", value: host)
                }

                Picker("检测间隔", selection: $probe.intervalSeconds) {
                    Text("跟随全局（\(monitor.config.defaultIntervalSeconds) 秒）").tag(Int?.none)
                    ForEach([30, 60, 120, 300, 600], id: \.self) { s in
                        Text(s < 60 ? "\(s) 秒" : "\(s / 60) 分钟").tag(Int?.some(s))
                    }
                }
                let effective = monitor.config.effectiveInterval(for: probe)
                if effective != (probe.intervalSeconds ?? monitor.config.defaultIntervalSeconds) {
                    Text("所选接口有配额限制，实际间隔为 \(effective) 秒。").font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Text("查询接口")
            }

            Section {
                Picker("满足以下", selection: $probe.matchMode) {
                    ForEach(MatchMode.allCases, id: \.self) { Text("\($0.title)条件").tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach($probe.rules) { $rule in
                    HStack {
                        Picker("字段", selection: $rule.field) {
                            ForEach(RuleField.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        Picker("条件", selection: $rule.op) {
                            ForEach(RuleOperator.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        TextField("值", text: $rule.value, prompt: Text(rule.op.placeholder))
                            .labelsHidden()
                        Button {
                            let id = rule.id
                            DispatchQueue.main.async { probe.rules.removeAll { $0.id == id } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除条件")
                    }
                }
                Button("添加条件") {
                    probe.rules.append(Rule(field: .countryCode, op: .isIn, value: ""))
                }
                if probe.rules.isEmpty {
                    Text("没有条件时，只要拿到 IP 就视为正常。").font(.caption).foregroundColor(.secondary)
                }
                Toggle("检测失败视为正常（如“IPv6 应不可达”）", isOn: $probe.alert.failureIsOK)
            } header: {
                Text("预期规则")
            }

            Section {
                Stepper("连续 \(probe.alert.debounce) 次不符合才提醒", value: $probe.alert.debounce, in: 1...10)
                Toggle("系统通知", isOn: $probe.alert.notify)
                Toggle("强提醒弹窗（置顶，需手动关闭）", isOn: $probe.alert.popup)
                Toggle("提示音", isOn: $probe.alert.sound)
                Toggle("恢复时通知", isOn: $probe.alert.notifyRecovery)
            } header: {
                Text("提醒")
            }

            Section {
                HStack {
                    Button("测试一次") {
                        testing = true
                        let snapshot = probe
                        Task {
                            testResult = await monitor.test(snapshot)
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                if let testResult { OutcomeSummary(outcome: testResult) }
            } header: {
                Text("测试")
            }
        }
        .formStyle(.grouped)
        .onAppear { group = primary?.group ?? .overseas }
    }
}

// MARK: - 通用

@MainActor
struct GeneralSettingsView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var message: String?

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { loginEnabled },
                    set: { value in
                        do {
                            try LoginItem.set(value)
                            loginEnabled = LoginItem.isEnabled
                        } catch {
                            message = "设置开机启动失败：\(error.localizedDescription)"
                        }
                    }
                ))
                .disabled(!LoginItem.isAvailable)
                if !LoginItem.isAvailable {
                    Text("需以 .app 方式运行才能设置。").font(.caption).foregroundColor(.secondary)
                }
            }

            Section("检测") {
                Picker("默认检测间隔", selection: $monitor.config.defaultIntervalSeconds) {
                    ForEach([30, 60, 120, 300], id: \.self) { s in
                        Text(s < 60 ? "\(s) 秒" : "\(s / 60) 分钟").tag(s)
                    }
                }
                Picker("请求超时", selection: $monitor.config.timeoutSeconds) {
                    ForEach([5, 8, 15], id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Toggle("网络变化（切换 Wi‑Fi、VPN 上下线）时立即检测", isOn: $monitor.config.checkOnNetworkChange)
                Picker("唤醒后等待网络恢复再判定", selection: $monitor.config.wakeGraceSeconds) {
                    Text("不等待").tag(0)
                    Text("10 秒").tag(10)
                    Text("30 秒").tag(30)
                }
            }

            Section("提醒") {
                Picker("持续异常时重复提醒", selection: $monitor.config.repeatAlertMinutes) {
                    Text("不重复").tag(Int?.none)
                    ForEach([10, 30, 60], id: \.self) { Text("每 \($0) 分钟").tag(Int?.some($0)) }
                }
                Picker("检测失败时提醒", selection: $monitor.config.failureAlertAfter) {
                    Text("从不").tag(Int?.none)
                    ForEach([3, 5, 10], id: \.self) { Text("连续 \($0) 次后").tag(Int?.some($0)) }
                }
                NotificationStatusRow(notifier: monitor.notifier)
            }

            Section("菜单栏") {
                Picker("图标旁显示", selection: $monitor.config.menuBarText) {
                    ForEach(MenuBarText.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("取自检测点", selection: $monitor.config.menuBarProbeID) {
                    ForEach(monitor.config.probes) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .disabled(monitor.config.menuBarText == .none)
            }

            Section("数据") {
                Picker("历史记录保留", selection: $monitor.config.historyRetentionDays) {
                    ForEach([7, 30, 90], id: \.self) { Text("\($0) 天").tag($0) }
                }
                LabeledContent("配置文件（JSON）") {
                    HStack {
                        Button("导入…") { importConfig() }
                        Button("导出…") { exportConfig() }
                        Button("在 Finder 中显示") {
                            monitor.saveNow()
                            NSWorkspace.shared.activateFileViewerSelecting([monitor.configURL])
                        }
                    }
                }
            }

            if let message {
                Text(message).foregroundColor(ProbeStatus.mismatch.color)
            }
        }
        .formStyle(.grouped)
        .task { await monitor.notifier.refreshStatus() }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try monitor.importConfig(from: url)
            message = "已导入 \(url.lastPathComponent)"
        } catch {
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "netmonitor-config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try monitor.exportConfig(to: url)
            message = "已导出到 \(url.path)"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }
}

/// 单独观察 Notifier，授权状态变化时刷新
@MainActor
struct NotificationStatusRow: View {
    @ObservedObject var notifier: Notifier

    var body: some View {
        LabeledContent("通知权限") {
            HStack {
                Text(notifier.statusText)
                Button("打开系统设置") { notifier.openSystemSettings() }
            }
        }
    }
}

// MARK: - 查询接口

@MainActor
struct EndpointsSettingsView: View {
    @EnvironmentObject var monitor: Monitor
    @State private var editing: Endpoint?
    @State private var testResults: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(EndpointGroup.allCases, id: \.self) { group in
                    Section(group.title) {
                        let items = monitor.config.allEndpoints.filter { $0.group == group }
                        if items.isEmpty {
                            Text("暂无").foregroundColor(.secondary)
                        }
                        ForEach(items) { e in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(e.name).fontWeight(.medium)
                                        Tag(text: e.ipVersion.title)
                                        if e.minIntervalSeconds > 10 { Tag(text: "≥\(e.minIntervalSeconds) 秒") }
                                    }
                                    Text(e.url).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                                    Text(e.summary).font(.caption).foregroundColor(.secondary)
                                    if let r = testResults[e.id] {
                                        Text(r).font(.caption)
                                    }
                                }
                                Spacer()
                                Button("测试") { test(e) }
                                if !e.isBuiltin {
                                    Button("编辑") { editing = e }
                                    Button("删除") { delete(e) }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            HStack {
                Button("添加自定义接口…") {
                    editing = Endpoint(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: "",
                                       group: .custom, url: "https://", kind: .json,
                                       fields: FieldMap(ip: "ip", countryCode: "country_code"))
                }
                Spacer()
                Text("测试结果反映的是当前这台 Mac 经由该接口看到的出口。").font(.caption).foregroundColor(.secondary)
            }
        }
        .sheet(item: $editing) { endpoint in
            CustomEndpointEditor(endpoint: endpoint) { saved in
                if let i = monitor.config.customEndpoints.firstIndex(where: { $0.id == saved.id }) {
                    monitor.config.customEndpoints[i] = saved
                } else {
                    monitor.config.customEndpoints.append(saved)
                }
                editing = nil
            } onCancel: {
                editing = nil
            }
            .environmentObject(monitor)
        }
    }

    private func test(_ e: Endpoint) {
        testResults[e.id] = "测试中…"
        Task {
            switch await monitor.testEndpoint(e) {
            case .success(let geo): testResults[e.id] = "✓ " + monitor.describe(geo)
            case .failure(let f): testResults[e.id] = "✕ " + f.message
            }
        }
    }

    private func delete(_ e: Endpoint) {
        let users = monitor.config.probes.filter { $0.endpointChain.contains(e.id) }.map(\.name)
        let alert = NSAlert()
        alert.messageText = "删除接口「\(e.name)」？"
        alert.informativeText = users.isEmpty ? "没有检测点在使用它。" : "以下检测点正在使用它：\(users.joined(separator: "、"))"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        monitor.config.customEndpoints.removeAll { $0.id == e.id }
    }
}

@MainActor
struct CustomEndpointEditor: View {
    @State var endpoint: Endpoint
    var onSave: (Endpoint) -> Void
    var onCancel: () -> Void
    @EnvironmentObject var monitor: Monitor
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(endpoint.name.isEmpty ? "新的自定义接口" : endpoint.name).font(.headline)
            Form {
                TextField("名称", text: $endpoint.name)
                TextField("地址", text: $endpoint.url)
                Picker("IP 版本", selection: $endpoint.ipVersion) {
                    ForEach(IPVersion.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("响应格式", selection: $endpoint.kind) {
                    ForEach(ResponseKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: endpoint.kind) { kind in
                    // 不同格式的字段写法不同，切换时换成该格式的默认值
                    switch kind {
                    case .json: endpoint.fields = FieldMap(ip: "ip", countryCode: "country_code")
                    case .keyValue: endpoint.fields = FieldMap(ip: "ip", countryCode: "loc")
                    case .text, .plainIP: endpoint.fields = FieldMap()
                    }
                }
                Picker("编码", selection: $endpoint.encoding) {
                    Text("UTF-8").tag(TextEncoding.utf8)
                    Text("GBK").tag(TextEncoding.gbk)
                }
                if endpoint.kind != .plainIP {
                    Section {
                        field("IP", \.ip)
                        field("国家码", \.countryCode)
                        field("国家名", \.country)
                        field("地区", \.region)
                        field("城市", \.city)
                        field("ASN", \.asn)
                        field("运营商", \.org)
                        if endpoint.kind == .json {
                            field("成功标志路径", \.success)
                            field("成功标志值", \.successValue)
                        }
                    } header: {
                        Text(fieldsHeader)
                    } footer: {
                        if endpoint.kind == .text {
                            Text("例：响应为 “45.78.60.129 JP” 时全部留空即可；响应为 “ip=1.2.3.4 country=JP” 时，国家码填 country=(\\w+)。")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("取响应第一行的第一段作为 IP；后面若跟着两位国家码（如 “45.78.60.129 JP”）会自动识别。其余归属地用 ipwho.is 按 IP 补全。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            if let result { Text(result).font(.caption).textSelection(.enabled) }
            HStack {
                Button("测试") {
                    result = "测试中…"
                    let snapshot = endpoint
                    Task {
                        switch await monitor.testEndpoint(snapshot) {
                        case .success(let geo): result = "✓ " + monitor.describe(geo)
                        case .failure(let f): result = "✕ " + f.message
                        }
                    }
                }
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") {
                    var saved = endpoint
                    saved.group = .custom
                    saved.isBuiltin = false
                    if saved.name.isEmpty { saved.name = URL(string: saved.url)?.host ?? "自定义接口" }
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: endpoint.url)?.host == nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 620)
    }

    private var fieldsHeader: String {
        switch endpoint.kind {
        case .json: return "字段路径（点分，如 data.ip、data.location.0）"
        case .keyValue: return "键名"
        case .text: return "正则表达式（取第 1 个捕获组；IP 和国家码留空则自动识别）"
        case .plainIP: return ""
        }
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<FieldMap, String?>) -> some View {
        TextField(title, text: Binding(
            get: { endpoint.fields[keyPath: keyPath] ?? "" },
            set: { endpoint.fields[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        ))
    }
}

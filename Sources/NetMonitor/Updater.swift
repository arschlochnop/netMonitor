import AppKit
import CryptoKit
import Foundation
import NetMonitorCore

/// 通过 GitHub Releases 检查更新、下载、校验并替换安装
@MainActor
final class Updater: ObservableObject {
    static let repository = "arschlochnop/netMonitor"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(GitHubRelease)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: GitHubRelease?
    @Published private(set) var lastChecked: Date?

    @Published var autoCheck: Bool {
        didSet { defaults.set(autoCheck, forKey: Keys.autoCheck) }
    }
    @Published var autoInstall: Bool {
        didSet { defaults.set(autoInstall, forKey: Keys.autoInstall) }
    }
    @Published private(set) var skippedVersion: String? {
        didSet { defaults.set(skippedVersion, forKey: Keys.skipped) }
    }

    var onNotify: ((String, String) -> Void)?

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private enum Keys {
        static let autoCheck = "update.autoCheck"
        static let autoInstall = "update.autoInstall"
        static let skipped = "update.skippedVersion"
        static let lastChecked = "update.lastChecked"
    }
    /// 自动检查的间隔
    private let checkInterval: TimeInterval = 6 * 3600

    init() {
        autoCheck = defaults.object(forKey: Keys.autoCheck) as? Bool ?? true
        autoInstall = defaults.object(forKey: Keys.autoInstall) as? Bool ?? false
        skippedVersion = defaults.string(forKey: Keys.skipped)
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    static var currentVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    }

    var currentVersion: SemanticVersion { SemanticVersion(Self.currentVersionString) ?? SemanticVersion("0.0.0")! }

    /// 只有以 .app 方式运行时才能自我替换
    var canInstall: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        // 启动后稍等，避开开机时网络未就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            Task { @MainActor in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard autoCheck else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    // MARK: - 检查

    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("NetMonitor/\(Self.currentVersionString)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.lastChecked)
            guard code == 200 else {
                state = .failed(code == 404 ? "还没有发布任何 Release，或仓库不是公开的" : "GitHub 返回 HTTP \(code)")
                return
            }
            let release = try GitHubRelease.decode(data)
            latest = release
            // 用户手动检查时忽略“跳过此版本”
            switch UpdatePolicy.decide(current: currentVersion, release: release,
                                       skippedVersion: userInitiated ? nil : skippedVersion) {
            case .upToDate, .skipped:
                state = .upToDate
            case .unusable(let reason):
                state = .failed(reason)
            case .available(let version):
                state = .available(release)
                if autoInstall && canInstall && !userInitiated {
                    await downloadAndInstall(release)
                } else if !userInitiated {
                    onNotify?("NetMonitor \(version) 可用", "点菜单栏图标 › 立即更新，或在设置 › 更新中查看。")
                }
            }
        } catch {
            state = .failed("检查更新失败：\(error.localizedDescription)")
        }
    }

    func skip(_ release: GitHubRelease) {
        skippedVersion = release.version?.description
        state = .upToDate
    }

    // MARK: - 下载与安装

    func downloadAndInstall(_ release: GitHubRelease) async {
        guard canInstall else {
            state = .failed("当前不是以 .app 方式运行，无法自动更新")
            return
        }
        guard let package = release.packageAsset else {
            state = .failed("Release 中没有安装包")
            return
        }
        guard let checksumAsset = release.checksumAsset else {
            state = .failed("Release 中没有校验文件 \(package.name).sha256，为安全起见不自动安装")
            return
        }
        state = .downloading
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("NetMonitorUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            // 校验和
            let (sumData, sumResponse) = try await URLSession.shared.data(from: checksumAsset.browserDownloadURL)
            guard (sumResponse as? HTTPURLResponse)?.statusCode == 200,
                  let expected = UpdatePolicy.parseChecksum(String(decoding: sumData, as: UTF8.self)) else {
                throw UpdateError("校验文件无效")
            }

            // 安装包
            let (tempFile, response) = try await URLSession.shared.download(from: package.browserDownloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("安装包下载失败") }
            let zipURL = work.appendingPathComponent(package.name)
            try FileManager.default.moveItem(at: tempFile, to: zipURL)
            let actual = SHA256.hash(data: try Data(contentsOf: zipURL)).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError("安装包校验失败（SHA-256 不一致），已放弃安装") }

            // 解压并检查
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpacked.path])
            guard let newApp = findApp(in: unpacked) else { throw UpdateError("安装包中没有 NetMonitor.app") }
            let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                throw UpdateError("安装包的 Bundle ID 与当前程序不一致")
            }
            if let newVersion = (info?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init),
               let releaseVersion = release.version, newVersion != releaseVersion {
                throw UpdateError("安装包版本 \(newVersion) 与 Release \(releaseVersion) 不一致")
            }
            try run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])

            try install(newApp, workDirectory: work)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? "更新失败：\(error.localizedDescription)")
        }
    }

    /// 写一个小脚本：等当前进程退出后替换 .app，失败时还原，再重新打开
    private func install(_ newApp: URL, workDirectory: URL) throws {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("没有写入 \(parent.path) 的权限，请手动下载安装")
        }
        state = .installing
        let script = """
        #!/bin/bash
        PID="$1"; OLD="$2"; NEW="$3"
        for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        rm -rf "$OLD.updating-old"
        if mv "$OLD" "$OLD.updating-old" && /usr/bin/ditto "$NEW" "$OLD"; then
          rm -rf "$OLD.updating-old"
        else
          rm -rf "$OLD"; mv "$OLD.updating-old" "$OLD"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
        /usr/bin/open "$OLD"
        rm -rf "$(dirname "$0")"
        """
        let scriptURL = workDirectory.appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), current.path, newApp.path]
        try process.run()
        Monitor.shared.saveNow()
        NSApp.terminate(nil)
    }

    private func findApp(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "NetMonitor.app" { return url }
        }
        return nil
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) 执行失败（退出码 \(process.terminationStatus)）")
        }
    }
}

struct UpdateError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

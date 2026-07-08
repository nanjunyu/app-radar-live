import Foundation
import AppKit
import CryptoKit

// MARK: - 更新数据模型

/// releases/latest/download/latest.json 的结构
struct UpdateManifest: Codable {
    let version: String            // 如 "1.1.0"
    let notes: String              // 本次更新说明（Markdown/纯文本）
    let pubDate: String?           // 发布时间 ISO8601
    let platforms: [String: PlatformAsset]

    struct PlatformAsset: Codable {
        let url: String            // zip 下载地址
        let signature: String      // 对 zip 内容的 Ed25519 签名（Base64）
    }
}

/// 更新记录条目（从内置 CHANGELOG.md 解析，遵循 Keep a Changelog 格式）
struct ReleaseHistoryItem: Identifiable {
    var id: String { version }
    let version: String
    let date: String
    let added: [String]
    let changed: [String]
    let fixed: [String]
    let removed: [String]

    var isEmpty: Bool { added.isEmpty && changed.isEmpty && fixed.isEmpty && removed.isEmpty }
}

/// CHANGELOG.md 解析器
enum ChangelogParser {
    /// 解析 Keep a Changelog 格式的 markdown 文本
    static func parse(_ markdown: String) -> [ReleaseHistoryItem] {
        var items: [ReleaseHistoryItem] = []

        var curVersion: String?
        var curDate = ""
        var added: [String] = []
        var changed: [String] = []
        var fixed: [String] = []
        var removed: [String] = []
        var section = "" // added / changed / fixed / removed

        func flush() {
            if let v = curVersion {
                items.append(ReleaseHistoryItem(version: v, date: curDate,
                                                added: added, changed: changed,
                                                fixed: fixed, removed: removed))
            }
            curVersion = nil; curDate = ""
            added = []; changed = []; fixed = []; removed = []
            section = ""
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 版本标题: ## [1.1.0] - 2026-07-08
            if line.hasPrefix("## [") {
                flush()
                if let lb = line.firstIndex(of: "["), let rb = line.firstIndex(of: "]") {
                    curVersion = String(line[line.index(after: lb)..<rb])
                }
                if let dash = line.range(of: " - ") {
                    curDate = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            // 分区标题: ### 新增 / 变更 / 修复 / 移除（兼容中英文）
            if line.hasPrefix("### ") {
                let title = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces).lowercased()
                switch title {
                case "新增", "added": section = "added"
                case "变更", "变化", "changed": section = "changed"
                case "修复", "fixed": section = "fixed"
                case "移除", "删除", "removed": section = "removed"
                default: section = ""
                }
                continue
            }

            // 列表项: - xxx
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard !content.isEmpty else { continue }
                switch section {
                case "added": added.append(content)
                case "changed": changed.append(content)
                case "fixed": fixed.append(content)
                case "removed": removed.append(content)
                default: break
                }
            }
        }
        flush()
        return items
    }
}

// MARK: - 更新状态

enum UpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateManifest)      // 发现新版本
    case downloading(Double)            // 下载中，携带进度 0.0~1.0
    case verifying
    case installing
    case readyToRelaunch
    case failed(String)

    static func == (lhs: UpdatePhase, rhs: UpdatePhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate),
             (.verifying, .verifying), (.installing, .installing), (.readyToRelaunch, .readyToRelaunch):
            return true
        case let (.available(a), .available(b)): return a.version == b.version
        case let (.downloading(a), .downloading(b)): return a == b
        case let (.failed(a), .failed(b)): return a == b
        default: return false
        }
    }
}

// MARK: - AppUpdater

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    // 内置公钥（与 tools/gen_update_key.swift 生成的私钥配对）
    private let publicKeyBase64 = "R1pfwkwUWr86j6bDRoCD6ciicDYk1hxlqMJ2tFdHO9U="

    // 更新源配置
    private let repoOwner = "nanjunyu"
    private let repoName = "app-radar-live"
    private var manifestURL: URL {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest/download/latest.json")!
    }


    @Published var phase: UpdatePhase = .idle
    @Published var latestManifest: UpdateManifest?
    @Published var showUpdateSheet = false      // 控制"发现新版本"弹窗
    @Published var releaseHistory: [ReleaseHistoryItem] = []
    @Published var changelogLoadError: String?

    private var downloadTask: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    private var pendingAsset: UpdateManifest.PlatformAsset?

    // 当前 App 版本（来自 Info.plist CFBundleShortVersionString）
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // 当前架构对应的 platform key
    private var platformKey: String {
        #if arch(arm64)
        return "darwin-arm64"
        #else
        return "darwin-x86_64"
        #endif
    }

    // MARK: 版本比较（语义化，返回 true 表示 remote > local）
    private func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
             .split(separator: ".")
             .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        let n = max(r.count, l.count)
        for i in 0..<n {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    // MARK: - 检查更新

    /// 检查更新。
    /// - silent: true 时不弹"已是最新/失败"提示（用于启动自动检查）
    /// - autoInstall: true 时发现新版本后直接后台下载安装，完成自动重启（"后台自动更新"开关）
    func checkForUpdates(silent: Bool = false, autoInstall: Bool = false) {
        phase = .checking
        var req = URLRequest(url: manifestURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            Task { @MainActor in
                if let error = error {
                    self.phase = silent ? .idle : .failed("检查更新失败：\(error.localizedDescription)")
                    return
                }
                guard let data = data,
                      let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
                    self.phase = silent ? .idle : .failed("无法解析更新信息")
                    return
                }
                self.latestManifest = manifest
                if self.isNewer(manifest.version, than: self.currentVersion) {
                    // 静默检查时，若用户已"跳过此版本"则不打扰
                    let skipped = UserDefaults.standard.string(forKey: "skippedUpdateVersion") ?? ""
                    if silent && skipped == manifest.version {
                        self.phase = .idle
                        return
                    }
                    self.phase = .available(manifest)
                    if autoInstall {
                        // 后台自动更新：直接下载安装，仍弹出弹窗展示进度让用户可见
                        self.showUpdateSheet = true
                        self.startUpdate()
                    } else {
                        self.showUpdateSheet = true
                    }
                } else {
                    self.phase = .upToDate
                }
            }
        }.resume()
    }

    func skipCurrentVersion() {
        if case let .available(m) = phase {
            UserDefaults.standard.set(m.version, forKey: "skippedUpdateVersion")
        }
        showUpdateSheet = false
        phase = .idle
    }

    func dismissUpdateSheet() {
        showUpdateSheet = false
        if case .available = phase { phase = .idle }
    }

    // MARK: - 下载并安装

    func startUpdate() {
        guard case let .available(manifest) = phase else { return }
        guard let asset = manifest.platforms[platformKey],
              let url = URL(string: asset.url) else {
            phase = .failed("未找到适配当前架构（\(platformKey)）的更新包")
            return
        }
        pendingAsset = asset
        phase = .downloading(0)

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self else { return }
            Task { @MainActor in
                if let error = error {
                    self.phase = .failed("下载失败：\(error.localizedDescription)")
                    return
                }
                guard let tempURL = tempURL else {
                    self.phase = .failed("下载失败：未获得文件")
                    return
                }
                self.handleDownloaded(tempURL, asset: asset)
            }
        }
        // 进度回调
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                self?.phase = .downloading(progress.fractionCompleted)
            }
        }
        downloadTask = task
        task.resume()
    }

    private func handleDownloaded(_ tempURL: URL, asset: UpdateManifest.PlatformAsset) {
        phase = .verifying
        do {
            let zipData = try Data(contentsOf: tempURL)
            // Ed25519 验签
            guard verifySignature(data: zipData, signatureBase64: asset.signature) else {
                phase = .failed("安全校验失败：更新包签名无效，已中止安装")
                return
            }
            phase = .installing
            try installUpdate(zipData: zipData)
            phase = .readyToRelaunch
            relaunch()
        } catch {
            phase = .failed("安装失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 签名验证

    private func verifySignature(data: Data, signatureBase64: String) -> Bool {
        guard let pubKeyData = Data(base64Encoded: publicKeyBase64),
              let sigData = Data(base64Encoded: signatureBase64),
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData) else {
            return false
        }
        return pubKey.isValidSignature(sigData, for: data)
    }

    // MARK: - 解压替换

    private func installUpdate(zipData: Data) throws {
        let fm = FileManager.default

        // 解压临时目录（会被下面的替换脚本清理）
        let workDir = fm.temporaryDirectory.appendingPathComponent("appradar_update_\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 保存 zip 并解压（ditto 能正确保留 macOS .app 元数据/权限）
        let zipPath = workDir.appendingPathComponent("update.zip")
        try zipData.write(to: zipPath)
        let unzipDir = workDir.appendingPathComponent("unzipped")
        try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipPath.path, unzipDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw NSError(domain: "AppUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "解压失败"])
        }

        // 找到解压出来的 .app
        let contents = try fm.contentsOfDirectory(atPath: unzipDir.path)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw NSError(domain: "AppUpdater", code: 2, userInfo: [NSLocalizedDescriptionKey: "更新包中未找到应用"])
        }
        let newAppURL = unzipDir.appendingPathComponent(appName)

        // 当前 App 路径
        let currentAppURL = Bundle.main.bundleURL
        guard currentAppURL.pathExtension == "app" else {
            throw NSError(domain: "AppUpdater", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法定位当前应用路径"])
        }

        // 用一个 shell 脚本在 App 真正退出后再完成替换 + 重启。
        // 关键：必须等当前进程 PID 彻底退出，否则 open 只会激活尚未死亡的旧实例，导致卡住。
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptPath = fm.temporaryDirectory.appendingPathComponent("appradar_install_\(UUID().uuidString).sh")
        let script = """
        #!/bin/bash
        # 等待旧进程退出（最多 ~10 秒）
        for i in $(seq 1 50); do
            if ! kill -0 \(pid) 2>/dev/null; then break; fi
            sleep 0.2
        done
        rm -rf "\(currentAppURL.path)"
        ditto "\(newAppURL.path)" "\(currentAppURL.path)"
        xattr -cr "\(currentAppURL.path)"
        open "\(currentAppURL.path)"
        rm -rf "\(workDir.path)"
        rm -f "\(scriptPath.path)"
        """
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        self.pendingInstallScript = scriptPath.path
    }

    private var pendingInstallScript: String?

    // MARK: - 重启

    private func relaunch() {
        guard let scriptPath = pendingInstallScript else { return }
        // 后台脱离启动替换脚本（脚本会等本进程退出后再替换并重启）
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptPath]
        do {
            try task.run()
        } catch {
            phase = .failed("无法启动更新安装脚本：\(error.localizedDescription)")
            return
        }
        // 立即退出当前 App，让脚本接管替换 + 重启
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
            // 兜底：若 terminate 因故未生效，强制退出
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                exit(0)
            }
        }
    }

    // MARK: - 更新记录（GitHub Releases 列表）

    /// 从 App 内置的 CHANGELOG.md 加载更新记录（完全离线，无网络/API 依赖）
    func loadReleaseHistory() {
        changelogLoadError = nil
        guard let path = Bundle.main.path(forResource: "CHANGELOG", ofType: "md"),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            changelogLoadError = "未找到更新记录文件"
            releaseHistory = []
            return
        }
        let items = ChangelogParser.parse(content)
        if items.isEmpty {
            changelogLoadError = "暂无更新记录"
        }
        releaseHistory = items
    }
}

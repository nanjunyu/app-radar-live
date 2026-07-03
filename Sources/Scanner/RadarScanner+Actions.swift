import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    // 将 mas/brew/npm 的一行输出映射成友好的中文进度
    func progressStatus(for line: String) -> String? {
        let lower = line.lowercased()
        if lower.contains("password:") || lower.contains("sorry, try again") { return nil }
        // 优先提取百分比（mas 的进度行如 "###--- 45% downloaded"，含 downloaded 一词，
        // 必须先抓百分比，否则会被误判成"下载完成"）
        if let pct = line.range(of: #"\d+%"#, options: .regularExpression) {
            return "下载中 \(line[pct])"
        }
        if lower.contains("installing") || lower.contains("updating") || lower.contains("upgrading") { return "安装中…" }
        if lower.contains("installed") || lower.contains("updated") || lower.contains("upgraded") { return "✅ 升级完成" }
        if lower.contains("downloaded") { return "下载完成，准备安装…" }
        if lower.contains("downloading") || lower.contains("download") { return "下载中…" }
        return "升级中…"
    }
    
    // App Store 应用：以「当前用户」身份运行 mas（账号上下文正确）。
    // sudo 已启用 pam_tid，内部安装步骤会自动弹系统原生 Touch ID 框，无需密码框。
    func upgradeMasApp(_ app: RadarUpdateApp) {
        if app.isUpgrading { return }
        DispatchQueue.main.async { app.isUpgrading = true; app.upgradeMessage = "准备升级…" }
        DispatchQueue.global(qos: .userInitiated).async {
            // 若 sudo 尚未启用 Touch ID，用系统原生授权框启用一次（不弹自制框）
            if !PrivilegedRunner.isTouchIDSudoEnabled() {
                DispatchQueue.main.async { app.upgradeMessage = "首次需授权启用指纹升级…" }
                let (canceled, success, errMsg) = PrivilegedRunner.enableTouchIDSudo()
                if canceled || !success {
                    DispatchQueue.main.async {
                        app.isUpgrading = false
                        app.upgradeMessage = canceled ? "已取消授权" : "启用指纹失败: \(errMsg.prefix(120))"
                    }
                    return
                }
            }
            // 以当前用户身份升级；内部 sudo 自动走系统原生 Touch ID。
            // 用 `script` 分配伪终端(PTY)，让 mas 以为在终端里运行，从而输出带百分比的进度条。
            DispatchQueue.main.async { app.upgradeMessage = "升级中…（按指纹确认）" }
            var lastLine = ""
            let code = ProcessRunner.runCommandStreaming("script -q /dev/null mas upgrade \(app.appId ?? "") 2>&1") { line in
                lastLine = line
                if let s = self.progressStatus(for: line) {
                    DispatchQueue.main.async { app.upgradeMessage = s }
                }
            }
            let lower = lastLine.lowercased()
            let failed = code != 0 || lower.contains("error") || lower.contains("failed")
                || lower.contains("no downloads") || lower.contains("purchased") || lower.contains("password is required")
            DispatchQueue.main.async {
                app.isUpgrading = false
                if failed {
                    app.upgradeMessage = "升级失败: \(lastLine.prefix(100))"
                } else {
                    app.upgradeMessage = "✅ 升级完成"
                    app.upgraded = true
                    self.refreshDockBadge()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.scanUpdates() }
        }
    }
    
    // Homebrew 应用：以当前用户流式升级（一般无需 sudo）；若提示需要授权则原生提权重试
    func executeAction(action: String, app: RadarUpdateApp) {
        if app.isUpgrading { return }
        DispatchQueue.main.async { app.isUpgrading = true; app.upgradeMessage = "升级中…" }
        DispatchQueue.global(qos: .userInitiated).async {
            var lastLine = ""
            let code = ProcessRunner.runCommandStreaming("brew upgrade \(app.name) 2>&1") { line in
                lastLine = line
                if let s = self.progressStatus(for: line) {
                    DispatchQueue.main.async { app.upgradeMessage = s }
                }
            }
            let lower = lastLine.lowercased()
            let failed = code != 0 || lower.contains("error") || lower.contains("failed")
            DispatchQueue.main.async {
                app.isUpgrading = false
                if failed {
                    app.upgradeMessage = "升级失败: \(lastLine.prefix(100))"
                } else {
                    app.upgradeMessage = "✅ 升级完成"
                    app.upgraded = true
                    self.refreshDockBadge()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.scanUpdates() }
        }
    }
    
    func openInAppStore(app: RadarUpdateApp) {
        if let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // 打开应用：可靠定位真实 .app（App Store 按 adamID、cask 查 artifact），而非简单按显示名
    func launchApp(_ app: RadarUpdateApp) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 1) 已知 .app 路径（独立应用）
            if let path = app.localPath, path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) {
                ProcessRunner.runCommand("open \(self.shellQuote(path))"); return
            }
            // 2) App Store：用 Spotlight 按 App Store ID 定位 .app
            if app.category == .appStore, let id = app.appId, !id.isEmpty {
                let out = ProcessRunner.runCommand("mdfind \"kMDItemAppStoreAdamID == \(id)\" 2>/dev/null")
                if let p = out.components(separatedBy: .newlines).first(where: { $0.hasSuffix(".app") }), !p.isEmpty {
                    ProcessRunner.runCommand("open \(self.shellQuote(p))"); return
                }
            }
            // 3) Homebrew cask：查 cask 的 app artifact 真实名
            if app.category == .brew && app.isCask {
                let json = ProcessRunner.runCommand("brew info --cask \(self.shellQuote(app.name)) --json=v2 2>/dev/null")
                if let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let casks = obj["casks"] as? [[String: Any]], let first = casks.first,
                   let artifacts = first["artifacts"] as? [[String: Any]] {
                    for art in artifacts {
                        if let apps = art["app"] as? [Any], let appName = apps.first as? String {
                            ProcessRunner.runCommand("open -a \(self.shellQuote(appName)) 2>/dev/null"); return
                        }
                    }
                }
            }
            // 4) 兜底：按名称
            ProcessRunner.runCommand("open -a \"\(app.name)\" 2>/dev/null")
        }
    }
    
    // 在「终端」打开项目目录（方便手动 git merge / stash 处理分叉、冲突）
    func openInTerminal(_ app: RadarUpdateApp) {
        guard let path = app.localPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessRunner.runCommand("open -a Terminal \(self.shellQuote(path))")
        }
    }
    
    // 在「访达」中显示项目目录
    func revealInFinder(_ app: RadarUpdateApp) {
        guard let path = app.localPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    
    func quitProcess(pid: Int, force: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let signal = force ? "-9" : "-15"
            ProcessRunner.runCommand("kill \(signal) \(pid)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scanProcesses() }
        }
    }
}

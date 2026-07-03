import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    // 扫描「其他」渠道：CLI 适配器（Claude Code 等）+ Sparkle 独立应用。
    // 探测到才纳入；落后进「待更新」，最新进「已安装」。涉及网络，故独立异步。
    func scanOtherUpdates() {
        DispatchQueue.main.async { self.isScanningOther = true }
        DispatchQueue.global(qos: .utility).async {
            let cliApps = self.scanCLITools()        // 命令行工具（同步：内部并发后等待）
            let sparkleApps = self.scanSparkleApps()  // 独立应用（同步：内部并发后等待）
            let apps = cliApps + sparkleApps
            
            let updates = apps.filter { !$0.upgraded }
            let installed = apps.filter { $0.upgraded }
            DispatchQueue.main.async {
                self.hasOther = !apps.isEmpty
                self.updates = self.updates.filter { $0.category != .other } + updates
                self.installed = self.installed.filter { $0.category != .other } + installed
                self.isScanningOther = false
                self.restoreIgnoreState()
                self.refreshDockBadge()
            }
        }
    }
    
    // MARK: - 命令行工具（适配器注册表）
    private func scanCLITools() -> [RadarUpdateApp] {
        let installedAdapters: [(CLIToolAdapter, String)] = CLIToolAdapter.all.compactMap { ad in
            guard let v = ad.detectInstalled() else { return nil }
            return (ad, v)
        }
        guard !installedAdapters.isEmpty else { return [] }
        let group = DispatchGroup()
        let lock = NSLock()
        var apps: [RadarUpdateApp] = []
        for (ad, localVer) in installedAdapters {
            group.enter()
            ad.fetchLatest { latest in
                let app = RadarUpdateApp(name: ad.displayName, category: .other)
                app.sourceKind = .cliTool
                app.currentVersion = localVer
                app.developer = "命令行工具"
                app.homepage = ad.homepage
                app.upgradeCommand = ad.upgradeCommand
                app.localPath = ad.id            // 用适配器 id 作为稳定忽略标识
                if let latest = latest {
                    app.latestVersion = latest
                    app.upgraded = !cliVersionIsNewer(latest, than: localVer)
                } else {
                    app.latestVersion = localVer
                    app.upgraded = true          // 取不到最新版本，当作已最新，不误报
                }
                lock.lock(); apps.append(app); lock.unlock()
                group.leave()
            }
        }
        group.wait()
        return apps
    }
    
    // MARK: - 独立应用（Sparkle + 无归属的 GUI 应用）
    private func scanSparkleApps() -> [RadarUpdateApp] {
        let candidates = self.discoverSparkleApps()
        guard !candidates.isEmpty else { return [] }
        
        // 分两组：有 feedURL 的可检测更新（需联网），没有的直接列入已安装
        let withFeed = candidates.filter { !$0.feedURL.isEmpty && $0.feedURL.hasPrefix("http") }
        let noFeed = candidates.filter { $0.feedURL.isEmpty || !$0.feedURL.hasPrefix("http") }
        
        // 无 Sparkle 的直接列为已安装（能打开）
        var apps: [RadarUpdateApp] = noFeed.map { c in
            let app = RadarUpdateApp(name: c.displayName, category: .other)
            app.sourceKind = .sparkleApp
            app.currentVersion = c.localVersion
            app.latestVersion = c.localVersion
            app.developer = "独立应用"
            app.localPath = c.bundlePath
            app.localIcon = Self.appIcon(at: c.bundlePath)
            app.upgraded = true
            return app
        }
        
        // 有 Sparkle 的并发拉 appcast 比对版本
        guard !withFeed.isEmpty else { return apps }
        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: 8)
        let lock = NSLock()
        for c in withFeed {
            sem.wait()
            group.enter()
            guard let url = URL(string: c.feedURL) else { sem.signal(); group.leave(); continue }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                defer { sem.signal(); group.leave() }
                guard let data = data, let xml = String(data: data, encoding: .utf8) else {
                    // appcast 拉不到 → 列为已安装（不报错）
                    let app = RadarUpdateApp(name: c.displayName, category: .other)
                    app.sourceKind = .sparkleApp; app.currentVersion = c.localVersion
                    app.latestVersion = c.localVersion; app.developer = "独立应用"
                    app.localPath = c.bundlePath; app.upgraded = true
                    app.localIcon = Self.appIcon(at: c.bundlePath)
                    lock.lock(); apps.append(app); lock.unlock()
                    return
                }
                let (latest, download) = Self.parseAppcastLatest(xml)
                let app = RadarUpdateApp(name: c.displayName, category: .other)
                app.sourceKind = .sparkleApp
                app.currentVersion = c.localVersion
                app.latestVersion = latest ?? c.localVersion
                app.developer = "独立应用"
                app.localPath = c.bundlePath
                app.localIcon = Self.appIcon(at: c.bundlePath)
                if let d = download { app.homepage = URL(string: d) }
                app.upgraded = (latest == nil) || !cliVersionIsNewer(latest!, than: c.localVersion)
                lock.lock(); apps.append(app); lock.unlock()
            }.resume()
        }
        group.wait()
        return apps
    }
    
    // 扫 /Applications、~/Applications 下的 .app：
    // - 有 SUFeedURL → Sparkle 应用，可检测更新
    // - 无 SUFeedURL 但非 App Store / 非 brew cask → 独立安装应用，列入「已安装」，可启动
    private func discoverSparkleApps() -> [(bundlePath: String, displayName: String, localVersion: String, feedURL: String)] {
        let fm = FileManager.default
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        let caskSet = Set(ProcessRunner.runCommand("brew list --cask -1 2>/dev/null")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var result: [(String, String, String, String)] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let bundlePath = dir + "/" + entry
                // 排除 App Store 应用
                if fm.fileExists(atPath: bundlePath + "/Contents/_MASReceipt/receipt") { continue }
                // 排除 brew cask
                let token = entry.replacingOccurrences(of: ".app", with: "")
                    .lowercased().replacingOccurrences(of: " ", with: "-")
                if caskSet.contains(token) || caskSet.contains(token.replacingOccurrences(of: "-", with: "")) { continue }
                // 读 Info.plist
                let plistPath = bundlePath + "/Contents/Info.plist"
                guard let plist = NSDictionary(contentsOfFile: plistPath) else { continue }
                let localVer = (plist["CFBundleShortVersionString"] as? String)
                    ?? (plist["CFBundleVersion"] as? String) ?? "0"
                // 优先用访达显示的本地化名称（中文名如"网易云音乐"），回退到 plist
                var name = fm.displayName(atPath: bundlePath)
                if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
                if name.isEmpty {
                    name = (plist["CFBundleDisplayName"] as? String)
                        ?? (plist["CFBundleName"] as? String)
                        ?? (entry as NSString).deletingPathExtension
                }
                // feedURL 为空字符串表示无 Sparkle（只列出不检测更新）
                let feed = (plist["SUFeedURL"] as? String) ?? ""
                result.append((bundlePath, name, localVer, feed))
            }
        }
        return result
    }
    
    // 取应用图标并缩放到合适尺寸（用于列表卡片）
    static func appIcon(at bundlePath: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        icon.size = NSSize(width: 56, height: 56)
        return icon
    }
    
    // 解析 appcast：返回最高版本 + 对应下载地址。兼容 element 与 attribute 两种写法。
    static func parseAppcastLatest(_ xml: String) -> (version: String?, download: String?) {
        var best: String? = nil
        // sparkle:shortVersionString（元素或属性）
        let patterns = [
            #"<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"#,
            #"sparkle:shortVersionString=\"([^\"]+)\""#,
            #"<sparkle:version>([^<]+)</sparkle:version>"#,
            #"sparkle:version=\"([^\"]+)\""#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = xml as NSString
            re.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m, m.numberOfRanges >= 2 else { return }
                let v = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if best == nil || cliVersionIsNewer(v, than: best!) { best = v }
            }
            if best != nil { break }   // 命中一种写法即可
        }
        // 下载地址（取第一个 enclosure url）
        var download: String? = nil
        if let re = try? NSRegularExpression(pattern: #"<enclosure[^>]*url=\"([^\"]+)\""#) {
            let ns = xml as NSString
            if let m = re.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 2 {
                download = ns.substring(with: m.range(at: 1))
            }
        }
        return (best, download)
    }
    
    // 升级「其他」渠道条目
    func upgradeOther(_ app: RadarUpdateApp) {
        // CLI 工具：执行升级命令（流式进度）
        if app.sourceKind == .cliTool, let cmd = app.upgradeCommand, !app.isUpgrading {
            DispatchQueue.main.async { app.isUpgrading = true; app.upgradeMessage = "正在下载安装（首次较大，可能需 1-2 分钟）…" }
            DispatchQueue.global(qos: .userInitiated).async {
                var lastLine = ""
                let code = ProcessRunner.runCommandStreaming("\(cmd) 2>&1") { line in
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.scanOtherUpdates() }
            }
            return
        }
        // Sparkle 独立应用：打开应用，让其内置 Sparkle 走原生更新流程
        if app.sourceKind == .sparkleApp, let path = app.localPath {
            DispatchQueue.main.async {
                app.upgradeMessage = "已打开应用，请在其内完成更新"
                app.upgraded = true
                self.refreshDockBadge()
            }
            ProcessRunner.runCommand("open \(self.shellQuote(path))")
        }
    }
}

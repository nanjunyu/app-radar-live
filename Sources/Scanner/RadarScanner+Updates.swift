import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    func scanUpdates() {
        if isScanningUpdates { return }
        isScanningUpdates = true
        
        // 用 userInitiated 优先级，避免在繁忙系统上被后台 QoS 限流导致"一直在检查更新"
        DispatchQueue.global(qos: .userInitiated).async {
            // 三个渠道互相独立，并发扫描；整体耗时取决于最慢的一个，而非三者之和
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "radar.updates.scan", attributes: .concurrent)
            var appStore: (updates: [RadarUpdateApp], installed: [RadarUpdateApp]) = ([], [])
            var brew: (updates: [RadarUpdateApp], installed: [RadarUpdateApp]) = ([], [])
            var node: (updates: [RadarUpdateApp], installed: [RadarUpdateApp]) = ([], [])
            let hasNpm = Environment.hasNpm
            
            queue.async(group: group) { appStore = self.scanAppStoreChannel() }
            queue.async(group: group) { brew = self.scanBrewChannel() }
            queue.async(group: group) { if hasNpm { node = self.scanNodeChannel() } }
            group.wait()
            
            let scannedUpdates = appStore.updates + brew.updates + node.updates
            let scannedInstalled = appStore.installed + brew.installed + node.installed
            let allBrewApps = brew.updates + brew.installed
            
            DispatchQueue.main.async {
                self.hasNpm = hasNpm
                // 保留 Git / 其他 渠道结果（它们由各自独立异步扫描填充，避免被覆盖）
                let keepUpdates = self.updates.filter { $0.category == .git || $0.category == .other }
                let keepInstalled = self.installed.filter { $0.category == .git || $0.category == .other }
                self.updates = scannedUpdates + keepUpdates
                self.installed = scannedInstalled + keepInstalled
                self.isScanningUpdates = false
                self.restoreIgnoreState()
                self.refreshDockBadge()
                // 刷新 Node 包运行状态（启停按钮）
                self.refreshNodeServiceStatus()
                // 异步回填 Homebrew 元数据（~2s，不阻塞 UI）
                self.fetchBrewMetadata(for: allBrewApps)
            }
        }
    }
    
    // === App Store 渠道：mas outdated（待更新） + mas list（已安装） ===
    private func scanAppStoreChannel() -> (updates: [RadarUpdateApp], installed: [RadarUpdateApp]) {
        var updates: [RadarUpdateApp] = []
        // mas outdated 输出示例: 682658836  库乐队  (10.4.12 -> 10.4.14)
        let masOutput = ProcessRunner.runCommand("mas outdated")
        for line in masOutput.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }
            let firstSplit = trimmedLine.split(separator: " ", maxSplits: 1).map(String.init)
            guard firstSplit.count == 2, firstSplit[0].allSatisfy({ $0.isNumber }) else { continue }
            let appId = firstSplit[0]
            var remainder = firstSplit[1].trimmingCharacters(in: .whitespaces)
            var currentVer: String? = nil
            var latestVer: String? = nil
            if let openParen = remainder.range(of: "("), let closeParen = remainder.range(of: ")", options: .backwards) {
                let versionPart = String(remainder[openParen.upperBound..<closeParen.lowerBound])
                let verComponents = versionPart.components(separatedBy: "->")
                if verComponents.count == 2 {
                    currentVer = verComponents[0].trimmingCharacters(in: .whitespaces)
                    latestVer = verComponents[1].trimmingCharacters(in: .whitespaces)
                }
                remainder = String(remainder[remainder.startIndex..<openParen.lowerBound])
            }
            let appName = remainder.trimmingCharacters(in: .whitespaces)
            guard !appName.isEmpty else { continue }
            let app = RadarUpdateApp(name: appName, category: .appStore)
            app.appId = appId
            app.currentVersion = currentVer
            app.latestVersion = latestVer
            self.fetchAppStoreMetadata(for: app)
            updates.append(app)
        }
        let updateNames = Set(updates.map { $0.name })
        var installed: [RadarUpdateApp] = []
        let masList = ProcessRunner.runCommand("mas list")
        for line in masList.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].allSatisfy({ $0.isNumber }) else { continue }
            // 格式: "836500024  微信  (4.1.10)"
            var nameAndVer = parts[1].trimmingCharacters(in: .whitespaces)
            var ver: String? = nil
            if let openP = nameAndVer.range(of: "("), let closeP = nameAndVer.range(of: ")", options: .backwards) {
                ver = String(nameAndVer[openP.upperBound..<closeP.lowerBound]).trimmingCharacters(in: .whitespaces)
                nameAndVer = String(nameAndVer[nameAndVer.startIndex..<openP.lowerBound])
            }
            let name = nameAndVer.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || updateNames.contains(name) { continue }
            let app = RadarUpdateApp(name: name, category: .appStore)
            app.appId = parts[0]
            app.currentVersion = ver
            app.latestVersion = ver
            app.upgraded = true
            self.fetchAppStoreMetadata(for: app)
            installed.append(app)
        }
        return (updates, installed)
    }
    
    // === Homebrew 渠道：brew outdated --json（待更新） + brew list（已安装） ===
    private func scanBrewChannel() -> (updates: [RadarUpdateApp], installed: [RadarUpdateApp]) {
        var updates: [RadarUpdateApp] = []
        let brewOutdated = ProcessRunner.runCommand("brew outdated --json 2>/dev/null")
        if let data = brewOutdated.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let formulae = obj["formulae"] as? [[String: Any]] {
                for item in formulae {
                    guard let name = item["name"] as? String else { continue }
                    let app = RadarUpdateApp(name: name, category: .brew)
                    app.currentVersion = (item["installed_versions"] as? [String])?.last
                    app.latestVersion = item["current_version"] as? String
                    updates.append(app)
                }
            }
            if let casks = obj["casks"] as? [[String: Any]] {
                for item in casks {
                    guard let name = item["name"] as? String else { continue }
                    let app = RadarUpdateApp(name: name, category: .brew)
                    app.isCask = true
                    app.currentVersion = (item["installed_versions"] as? [String])?.last ?? item["installed_version"] as? String
                    app.latestVersion = item["current_version"] as? String
                    updates.append(app)
                }
            }
        }
        let updateNames = Set(updates.map { $0.name })
        var installed: [RadarUpdateApp] = []
        // formula（CLI 工具，无 GUI）
        let formulaList = ProcessRunner.runCommand("brew list --formula -1 2>/dev/null")
        for line in formulaList.components(separatedBy: .newlines) {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || updateNames.contains(name) { continue }
            let app = RadarUpdateApp(name: name, category: .brew)
            app.upgraded = true
            installed.append(app)
        }
        // cask（GUI 应用，可"打开"）
        let caskList = ProcessRunner.runCommand("brew list --cask -1 2>/dev/null")
        for line in caskList.components(separatedBy: .newlines) {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || updateNames.contains(name) { continue }
            let app = RadarUpdateApp(name: name, category: .brew)
            app.isCask = true
            app.upgraded = true
            installed.append(app)
        }
        return (updates, installed)
    }
    
    // === Node 渠道：npm outdated -g（待更新） + 直接枚举全局包目录（已安装） ===
    private func scanNodeChannel() -> (updates: [RadarUpdateApp], installed: [RadarUpdateApp]) {
        let updates = self.nodeUpdates()
        let updateNames = Set(updates.map { $0.name })
        var installed: [RadarUpdateApp] = []
        // 直接枚举全局包目录（比 `npm root -g` 稳健：后者受被劫持配置影响会指向空目录）。
        // 目录由 Environment 探测出的「包最多」的 npm prefix 推导，绕开配置劫持。
        let root = Environment.npmGlobalRoot
            ?? ProcessRunner.runCommand("npm root -g \(Environment.npmPrefixArg)2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        guard !root.isEmpty, let entries = try? fm.contentsOfDirectory(atPath: root) else {
            return (updates, installed)
        }
        // 展开：普通包直接用；@scope 目录再列一层得到 @scope/pkg
        var pkgDirs: [(name: String, path: String)] = []
        for e in entries {
            if e.hasPrefix(".") { continue }
            let full = root + "/" + e
            if e.hasPrefix("@") {
                if let subs = try? fm.contentsOfDirectory(atPath: full) {
                    for s in subs where !s.hasPrefix(".") { pkgDirs.append(("\(e)/\(s)", full + "/" + s)) }
                }
            } else {
                pkgDirs.append((e, full))
            }
        }
        for (name, path) in pkgDirs {
            if updateNames.contains(name) { continue }
            if RadarScanner.nodeExcluded.contains(name) { continue }
            let app = RadarUpdateApp(name: name, category: .node)
            // 读版本
            if let data = fm.contents(atPath: path + "/package.json"),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                app.currentVersion = obj["version"] as? String
            }
            app.latestVersion = app.currentVersion
            app.developer = "npm 全局包"
            app.upgraded = true
            self.fetchNpmMetadata(for: app)
            installed.append(app)
        }
        return (updates, installed)
    }
    
    // 统一刷新 Dock 角标：以全部渠道（App Store / Homebrew / Node / Git）当前「未升级且未忽略」的待更新数为准
    func refreshDockBadge() {
        let count = self.updates.filter { !$0.upgraded && !$0.ignored }.count
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
    
    // 忽略状态持久化（跨重启保留），存于 UserDefaults
    private static let ignoredKeysDefaultsKey = "ignoredUpdateKeys"
    private func ignoredKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.ignoredKeysDefaultsKey) ?? [])
    }
    // 设置/取消忽略：写入持久化集合并刷新角标
    func setIgnored(_ app: RadarUpdateApp, _ ignored: Bool) {
        var keys = ignoredKeys()
        if ignored { keys.insert(app.ignoreKey) } else { keys.remove(app.ignoreKey) }
        UserDefaults.standard.set(Array(keys), forKey: Self.ignoredKeysDefaultsKey)
        app.ignored = ignored
        refreshDockBadge()
    }
    // 扫描后按持久化集合恢复每个待更新项的忽略状态
    func restoreIgnoreState() {
        let keys = ignoredKeys()
        for app in updates { app.ignored = keys.contains(app.ignoreKey) }
    }
    
    private func fetchAppStoreMetadata(for app: RadarUpdateApp) {
        guard let appId = app.appId else { return }
        let base = "https://itunes.apple.com/lookup?id=\(appId)&country=cn"
        // mas 给的是 Mac App Store 应用 ID。优先按 macOS 维度查询，
        // 拿到与官方 Mac App Store 一致的体积/分级（不加 entity 默认会返回 iOS 版数据）；
        // 若该 app 无 macOS 版本（结果为空），再回退到默认查询。
        lookup(urlString: base + "&entity=macSoftware", for: app) { [weak self] success in
            if !success {
                self?.lookup(urlString: base, for: app, completion: nil)
            }
        }
    }
    
    private func lookup(urlString: String, for app: RadarUpdateApp, completion: ((Bool) -> Void)?) {
        guard let url = URL(string: urlString) else { completion?(false); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first else {
                completion?(false)
                return
            }
            DispatchQueue.main.async { self.applyMetadata(first, to: app) }
            completion?(true)
        }.resume()
    }
    
    private func applyMetadata(_ first: [String: Any], to app: RadarUpdateApp) {
        if let trackName = first["trackName"] as? String, !trackName.isEmpty {
            app.displayName = trackName
        }
        if let artworkUrl100 = first["artworkUrl512"] as? String ?? first["artworkUrl100"] as? String {
            app.logoUrl = URL(string: artworkUrl100)
        }
        app.developer = first["sellerName"] as? String
        app.releaseNotes = first["releaseNotes"] as? String
        app.descriptionText = first["description"] as? String
        app.averageUserRating = first["averageUserRating"] as? Double
        app.userRatingCount = first["userRatingCount"] as? Int
        app.contentRating = first["trackContentRating"] as? String ?? first["contentAdvisoryRating"] as? String
        app.primaryGenre = (first["genres"] as? [String])?.first ?? first["primaryGenreName"] as? String
        app.price = first["formattedPrice"] as? String
        app.minimumOsVersion = first["minimumOsVersion"] as? String
        // iTunes 返回的 version 即为最新版本，比 mas 的更权威
        if let ver = first["version"] as? String, !ver.isEmpty {
            app.latestVersion = ver
        }
        // 当前版本发布日期，如 2026-06-16T06:56:16Z -> 2026-06-16
        if let dateStr = first["currentVersionReleaseDate"] as? String {
            app.releaseDate = String(dateStr.prefix(10))
        }
        if let lang = first["languageCodesISO2A"] as? [String] { app.languages = lang }
        if let screenshots = first["screenshotUrls"] as? [String] { app.screenshotUrls = screenshots }
        if let size = first["fileSizeBytes"] as? String, let s = Int64(size) {
            let formatter = ByteCountFormatter()
            app.sizeStr = formatter.string(fromByteCount: s)
        }
    }
}

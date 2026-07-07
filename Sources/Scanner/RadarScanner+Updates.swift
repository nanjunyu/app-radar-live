import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    func scanUpdates() {
        if isScanningUpdates { return }
        isScanningUpdates = true
        
        // 在新一轮扫描开始前，清除之前已成功升级的项目（使其能自动归入已安装列表，并同步刷新角标）
        DispatchQueue.main.async {
            self.updates.removeAll(where: { $0.upgraded })
            self.refreshDockBadge()
        }
        
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
                
                // === 关键：合并新扫描结果时保留已有的升级状态 ===
                // mas outdated / brew outdated 在刚执行完升级后可能还未刷新，
                // 导致刚升完的应用仍出现在扫描结果中。如果直接替换，旧对象上的
                // upgraded / upgrading 状态就丢失了，用户看到的是"又变回待更新"。
                // 策略：如果旧列表中已有同一应用且处于 upgraded 或 upgrading 状态，
                // 则保留旧对象（带完整状态），跳过新扫描出的对象。
                let oldByKey: [String: RadarUpdateApp] = {
                    var map: [String: RadarUpdateApp] = [:]
                    for app in self.updates {
                        map[self.stableKey(for: app)] = app
                    }
                    return map
                }()
                var mergedUpdates: [RadarUpdateApp] = []
                for newApp in scannedUpdates {
                    let key = self.stableKey(for: newApp)
                    if let old = oldByKey[key] {
                        // 关键优化：如果旧列表中已有该应用，保留旧对象（保留已加载的描述、图片等富媒体元数据和升级状态），
                        // 仅增量更新版本等必要属性，防止因周扫重建对象导致详情页图片/说明瞬间被重置为空白。
                        old.latestVersion = newApp.latestVersion
                        old.currentVersion = newApp.currentVersion
                        mergedUpdates.append(old)
                    } else {
                        mergedUpdates.append(newApp)
                    }
                }
                
                // 保留那些已经完成升级的旧更新项，使其在 UI 上保持“已完成”状态（不立刻从待更新列表中消失）
                for old in self.updates where old.upgraded {
                    let key = self.stableKey(for: old)
                    if !mergedUpdates.contains(where: { self.stableKey(for: $0) == key }) {
                        mergedUpdates.append(old)
                    }
                }
                
                self.updates = mergedUpdates + keepUpdates
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
        
        // 1. 获取所有 Homebrew 服务状态
        let servicesList = ProcessRunner.runCommand("brew services list 2>/dev/null")
        var runningServices: [String: String] = [:]
        for line in servicesList.components(separatedBy: .newlines) {
            if line.hasPrefix("Name") || line.isEmpty { continue }
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 2 {
                runningServices[parts[0]] = parts[1]
            }
        }
        
        let brewOutdated = ProcessRunner.runCommand("brew outdated --json 2>/dev/null")
        if let data = brewOutdated.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let formulae = obj["formulae"] as? [[String: Any]] {
                for item in formulae {
                    guard let name = item["name"] as? String else { continue }
                    let app = RadarUpdateApp(name: name, category: .brew)
                    app.currentVersion = (item["installed_versions"] as? [String])?.last
                    app.latestVersion = item["current_version"] as? String
                    
                    // 标记服务状态
                    if let status = runningServices[name] {
                        app.isBrewService = true
                        app.isRunning = (status == "started")
                    }
                    
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
                    
                    // 获取 Cask 本地图标
                    Self.loadCaskLocalIcon(app: app)
                    
                    updates.append(app)
                }
            }
        }
        let updateNames = Set(updates.map { $0.name })
        var installed: [RadarUpdateApp] = []
        // formula（仅显示用户主动安装的顶层包，过滤掉自动依赖）
        let formulaList = ProcessRunner.runCommand("brew leaves 2>/dev/null")
        for line in formulaList.components(separatedBy: .newlines) {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || updateNames.contains(name) { continue }
            let app = RadarUpdateApp(name: name, category: .brew)
            app.upgraded = true
            
            // 标记服务状态
            if let status = runningServices[name] {
                app.isBrewService = true
                app.isRunning = (status == "started")
            }
            
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
            
            // 获取 Cask 本地图标
            Self.loadCaskLocalIcon(app: app)
            
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
    
    // 跨扫描周期稳定匹配同一应用的标识键：
    // App Store 用 appId（数字 ID，如 "497799835"），其余渠道用 category + name
    func stableKey(for app: RadarUpdateApp) -> String {
        if app.category == .appStore, let id = app.appId, !id.isEmpty {
            return "appStore|\(id)"
        }
        return "\(app.category.rawValue)|\(app.name)"
    }
    
    // 异步或同步地读取本地 Cask 安装生成的 .app 包图标，从而支持在详情页及列表卡片完美渲染 App Icon
    static func loadCaskLocalIcon(app: RadarUpdateApp) {
        let caskroomDirs = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
        for base in caskroomDirs {
            let dir = "\(base)/\(app.name)"
            if FileManager.default.fileExists(atPath: dir) {
                let enumerator = FileManager.default.enumerator(atPath: dir)
                while let file = enumerator?.nextObject() as? String {
                    if file.hasSuffix(".app") {
                        let appPath = "\(dir)/\(file)"
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: appPath, isDirectory: &isDir), isDir.boolValue {
                            app.localIcon = NSWorkspace.shared.icon(forFile: appPath)
                            app.localPath = appPath
                            return
                        }
                    }
                }
            }
        }
    }
}

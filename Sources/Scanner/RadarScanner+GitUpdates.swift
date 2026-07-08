import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    // 保存和加载启动命令的持久化方法
    private static let gitStartCmdPrefix = "git_start_cmd_"

    private func loadGitStartCmd(forLocalPath path: String) -> String? {
        let key = Self.gitStartCmdPrefix + path
        return UserDefaults.standard.string(forKey: key)
    }

    private func saveGitStartCmd(forLocalPath path: String, cmd: String) {
        let key = Self.gitStartCmdPrefix + path
        UserDefaults.standard.set(cmd, forKey: key)
    }

    // 扫描本机 GitHub 仓库：发现 → 仅保留 origin 为 github.com → fetch 对比是否落后。
    // 落后的进「待更新」，其余进「已安装」。仅在启动/手动刷新时执行（涉及网络，较慢）。
    func scanGitProjects() {
        DispatchQueue.main.async {
            self.isScanningGit = true
            // 开始扫描前，清除已成功升级的旧 Git 项目（使其移入已安装，并扣减角标）
            self.updates.removeAll(where: { $0.category == .git && $0.upgraded })
            self.refreshDockBadge()
        }
        DispatchQueue.global(qos: .utility).async {
            let repos = self.discoverGitHubRepos()
            guard !repos.isEmpty else {
                DispatchQueue.main.async { self.isScanningGit = false }
                return
            }
            
            // 第一阶段：先把发现的仓库立刻显示到「已安装」（无落后信息），不让页面空着
            let placeholders = repos.map { path -> RadarUpdateApp in
                let app = RadarUpdateApp(name: (path as NSString).lastPathComponent, category: .git)
                app.localPath = path
                app.upgraded = true
                app.detectedStartCmd = self.loadGitStartCmd(forLocalPath: path)
                return app
            }
            DispatchQueue.main.async {
                self.installed = self.installed.filter { $0.category != .git } + placeholders
            }
            
            // 第二阶段：高并发评估每个仓库（fetch 走网络、属 I/O 密集，并发度可远超 CPU 核心数）
            var results = [RadarUpdateApp?](repeating: nil, count: repos.count)
            let lock = NSLock()
            let group = DispatchGroup()
            let sem = DispatchSemaphore(value: 16)   // 最多 16 个 git fetch 同时在飞
            let evalQueue = DispatchQueue(label: "git.eval", attributes: .concurrent)
            for i in repos.indices {
                sem.wait()
                group.enter()
                evalQueue.async {
                    let app = self.evaluateRepo(path: repos[i])
                    lock.lock(); results[i] = app; lock.unlock()
                    sem.signal()
                    group.leave()
                }
            }
            group.wait()
            let apps = results.compactMap { $0 }
            let updates = apps.filter { !$0.upgraded }
            let installed = apps.filter { $0.upgraded }
            
            DispatchQueue.main.async {
                // 保留那些已经在本会话完成升级的旧 Git 仓库，以便在 UI 上展示“已完成”而不直接消失
                let oldGitUpgraded = self.updates.filter { $0.category == .git && $0.upgraded }
                var mergedGitUpdates = updates
                for old in oldGitUpgraded {
                    if !mergedGitUpdates.contains(where: { $0.name == old.name }) {
                        mergedGitUpdates.append(old)
                    }
                }
                
                self.updates = self.updates.filter { $0.category != .git } + mergedGitUpdates
                self.installed = self.installed.filter { $0.category != .git } + installed
                self.isScanningGit = false
                self.restoreIgnoreState()
                self.refreshDockBadge()
                
                // 加载完成立即刷新运行状态与端口
                self.refreshGitProjectStatus()
            }
            
            // 第三阶段：受控并发拉取 star/fork（未认证 API 限 60/小时，限并发 4 避免触发滥用检测）
            self.fetchGitStatsBatch(apps)
        }
    }
    
    // 批量拉取 star/fork：信号量限制最多 4 个请求在飞，结果到达即更新对应 app（UI 自动刷新）
    private func fetchGitStatsBatch(_ apps: [RadarUpdateApp]) {
        DispatchQueue.global(qos: .utility).async {
            let sem = DispatchSemaphore(value: 4)
            for app in apps {
                guard app.stars == nil, let hp = app.homepage?.absoluteString,
                      hp.contains("github.com/") else { continue }
                let tail = hp.components(separatedBy: "github.com/").last ?? ""
                let comps = tail.split(separator: "/")
                guard comps.count >= 2 else { continue }
                let owner = String(comps[0])
                let repo = String(comps[1]).replacingOccurrences(of: ".git", with: "")
                guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else { continue }
                sem.wait()
                URLSession.shared.dataTask(with: url) { data, resp, _ in
                    defer { sem.signal() }
                    guard let data = data, let http = resp as? HTTPURLResponse, http.statusCode == 200,
                          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    DispatchQueue.main.async {
                        app.stars = d["stargazers_count"] as? Int
                        app.forks = d["forks_count"] as? Int
                    }
                }.resume()
            }
        }
    }
    
    // 发现 GitHub 仓库：仅扫明确的开发目录（存在才扫）+ 运行中进程反查，去重，仅留 github。
    // 绝不扫家目录根，避免走进 ~/Pictures、~/Documents 等隐私目录触发系统权限申请。
    private func discoverGitHubRepos() -> [String] {
        let home = NSHomeDirectory()
        // 常见开发目录（不含家目录根；不碰照片/文稿/桌面/下载等隐私目录）
        let candidates = ["/Developer", "/Projects", "/projects", "/Code", "/code",
                          "/workspace", "/Workspace", "/git", "/src", "/repos", "/go/src", "/Sites"]
        var roots = Set<String>()
        for sub in candidates {
            let dir = home + sub
            guard FileManager.default.fileExists(atPath: dir) else { continue }
            let out = ProcessRunner.runCommand("find \(shellQuote(dir)) -maxdepth 5 -name .git -type d -not -path '*/node_modules/*' 2>/dev/null")
            for line in out.components(separatedBy: .newlines) where line.hasSuffix("/.git") {
                roots.insert(String(line.dropLast("/.git".count)))
            }
        }
        // 运行中进程反查的活跃项目目录（lsof CWD 向上找 .git），补全不在常见目录下的仓库
        for path in self.runningProjectRoots() { roots.insert(path) }
        
        // 先按规范化真实路径去重（消除符号链接 / /private 前缀 / 末尾斜杠等以及大小写重复）
        var seen = Set<String>()
        var uniqueRepos: [String] = []
        for repo in roots.sorted() {
            let canonical = URL(fileURLWithPath: repo).resolvingSymlinksInPath().path
            let lowercased = canonical.lowercased()
            if seen.insert(lowercased).inserted {
                uniqueRepos.append(canonical)
            }
        }
        // 再检查每个仓库的 origin 是否指向 github（git remote 为本地操作，限并发 8 个避免线程爆炸）
        var isGithub = [Bool](repeating: false, count: uniqueRepos.count)
        let checkSem = DispatchSemaphore(value: 8)
        let checkGroup = DispatchGroup()
        let checkQueue = DispatchQueue(label: "git.origin-check", attributes: .concurrent)
        for i in uniqueRepos.indices {
            checkSem.wait()
            checkGroup.enter()
            checkQueue.async {
                let url = ProcessRunner.runCommand("git -C \(self.shellQuote(uniqueRepos[i])) remote get-url origin 2>/dev/null")
                isGithub[i] = url.lowercased().contains("github.com")
                checkSem.signal()
                checkGroup.leave()
            }
        }
        checkGroup.wait()
        let githubRepos = zip(uniqueRepos, isGithub).filter { $0.1 }.map { $0.0 }
        return githubRepos
    }
    
    // 通过监听端口反查正在运行的项目目录
    private func runningProjectRoots() -> [String] {
        var roots: [String] = []
        let lsof = ProcessRunner.runCommand("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '{print $2}' | sort -u")
        for pidStr in lsof.components(separatedBy: .newlines) {
            guard let _ = Int(pidStr.trimmingCharacters(in: .whitespaces)) else { continue }
            let cwd = ProcessRunner.runCommand("lsof -a -d cwd -p \(pidStr) -Fn 2>/dev/null | grep '^n' | head -1")
            let path = cwd.hasPrefix("n") ? String(cwd.dropFirst()) : ""
            guard !path.isEmpty else { continue }
            // 向上找 3 层 .git
            var dir = path
            for _ in 0..<3 {
                if FileManager.default.fileExists(atPath: dir + "/.git") { roots.append(dir); break }
                dir = (dir as NSString).deletingLastPathComponent
                if dir == "/" || dir.isEmpty { break }
            }
        }
        return roots
    }
    
    // 评估单个仓库：fetch 后对比本地与远程，构建 RadarUpdateApp
    private func evaluateRepo(path: String) -> RadarUpdateApp? {
        let q = shellQuote(path)
        let name = (path as NSString).lastPathComponent
        let url = ProcessRunner.runCommand("git -C \(q) remote get-url origin 2>/dev/null")
        let (owner, repoName) = Self.parseGitHub(url)
        let branch = ProcessRunner.runCommand("git -C \(q) rev-parse --abbrev-ref HEAD 2>/dev/null")
        
        // fetch 最新远程状态（静默，限制只取当前分支）
        _ = ProcessRunner.runCommand("git -C \(q) fetch --quiet 2>/dev/null")
        
        let localSha = ProcessRunner.runCommand("git -C \(q) rev-parse --short HEAD 2>/dev/null")
        let remoteSha = ProcessRunner.runCommand("git -C \(q) rev-parse --short @{u} 2>/dev/null")
        let behindStr = ProcessRunner.runCommand("git -C \(q) rev-list --count HEAD..@{u} 2>/dev/null")
        let behind = Int(behindStr.trimmingCharacters(in: .whitespaces)) ?? 0
        
        let app = RadarUpdateApp(name: name, category: .git)
        app.localPath = path
        app.detectedStartCmd = self.loadGitStartCmd(forLocalPath: path)
        app.developer = owner.isEmpty ? branch : owner
        app.currentVersion = localSha.isEmpty ? nil : localSha
        app.latestVersion = remoteSha.isEmpty ? localSha : remoteSha
        app.descriptionText = "分支 \(branch) · \(url)"
        if !owner.isEmpty {
            app.homepage = URL(string: "https://github.com/\(owner)/\(repoName)")
            app.logoUrl = URL(string: "https://github.com/\(owner).png?size=128")
        }
        
        // 语言：从本地文件扩展名快速统计（最多扫 200 个文件）
        app.language = Self.detectLanguage(at: path)
        
        // 最后更新时间：本地最新 commit 时间 → 转为相对时间
        let dateStr = ProcessRunner.runCommand("git -C \(q) log -1 --format=%ci 2>/dev/null")
        app.lastUpdated = Self.relativeTime(from: dateStr)
        
        if behind > 0 {
            // 落后 → 待更新，拉取提交日志作为「升级说明」
            let log = ProcessRunner.runCommand("git -C \(q) log HEAD..@{u} --oneline -n 15 2>/dev/null")
            app.changelogNotes = "落后远程 \(behind) 个提交：\n" + log
            app.upgraded = false
        } else {
            app.upgraded = true   // 已是最新 → 已安装
        }
        return app
    }
    
    // git pull 更新本地仓库（ff-only 安全模式），流式进度
    func upgradeGitRepo(_ app: RadarUpdateApp) {
        guard let path = app.localPath, !app.isUpgrading else { return }
        DispatchQueue.main.async { app.isUpgrading = true; app.upgradeMessage = "拉取中…" }
        DispatchQueue.global(qos: .userInitiated).async {
            let q = self.shellQuote(path)
            let outputLock = NSLock()
            var fullOutput = ""
            let code = ProcessRunner.runCommandStreaming("git -C \(q) pull --ff-only 2>&1") { line in
                outputLock.lock()
                fullOutput += line + "\n"
                outputLock.unlock()
                DispatchQueue.main.async { app.upgradeMessage = String(line.prefix(40)) }
            }
            outputLock.lock()
            let lower = fullOutput.lowercased()
            outputLock.unlock()
            // ff-only 失败（本地有分叉/改动）→ 给出清晰且易懂的中文解释
            let diverged = lower.contains("not possible to fast-forward") || lower.contains("diverg")
            let localChanges = lower.contains("would be overwritten") || lower.contains("local changes") || lower.contains("unstaged")
            let conflict = lower.contains("conflict")
            let failed = code != 0 || lower.contains("error") || lower.contains("fatal") || conflict || diverged || localChanges
            DispatchQueue.main.async {
                app.isUpgrading = false
                if !failed {
                    app.upgradeMessage = "✅ 已更新到最新"
                    app.upgraded = true
                    self.refreshDockBadge()
                } else {
                    if localChanges {
                        app.upgradeMessage = "⚠️ 本地文件已被修改，为防止您的改动丢失，更新已终止。若不需要修改，可点详情页使用「强制更新」"
                    } else if diverged {
                        app.upgradeMessage = "⚠️ 本地有新提交与远程产生了分叉。可使用「强制更新」覆盖本地，或手动处理"
                    } else if conflict {
                        app.upgradeMessage = "⚠️ 本地修改与远程更新冲突。可使用「强制更新」覆盖本地，或手动解决冲突"
                    } else if lower.contains("could not read from remote") || lower.contains("timed out") || lower.contains("resolve host") {
                        app.upgradeMessage = "⚠️ 无法连接远程仓库，请检查网络连接或 GitHub 权限"
                    } else {
                        app.upgradeMessage = "⚠️ 更新失败，建议您进入详情页使用「强制更新」"
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.scanGitProjects() }
        }
    }
    
    // 强制更新：不顾本地修改和分叉，强制重置到远端最新状态 (@{u}) 并清理未追踪文件
    func forceUpgradeGitRepo(_ app: RadarUpdateApp) {
        guard let path = app.localPath, !app.isUpgrading else { return }
        DispatchQueue.main.async {
            app.isUpgrading = true
            app.upgradeMessage = "正在强制更新 (fetch)..."
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let q = self.shellQuote(path)
            
            // 1. git fetch --all
            _ = ProcessRunner.runCommand("git -C \(q) fetch --all 2>&1")
            
            // 2. git reset --hard @{u}
            DispatchQueue.main.async { app.upgradeMessage = "重置本地代码 (reset)..." }
            let resetResult = ProcessRunner.runCommand("git -C \(q) reset --hard @{u} 2>&1")
            
            // 3. git clean -fd (清理未跟踪的文件和目录)
            DispatchQueue.main.async { app.upgradeMessage = "清理未跟踪文件 (clean)..." }
            _ = ProcessRunner.runCommand("git -C \(q) clean -fd 2>&1")
            
            let lower = resetResult.lowercased()
            let failed = lower.contains("error") || lower.contains("fatal")
            
            DispatchQueue.main.async {
                app.isUpgrading = false
                if !failed {
                    app.upgradeMessage = "✅ 强制更新成功"
                    app.upgraded = true
                    self.refreshDockBadge()
                } else {
                    app.upgradeMessage = "⚠️ 强制更新失败，请手动处理"
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.scanGitProjects() }
        }
    }
    
    // 从 git remote url 解析 (owner, repo)
    private static func parseGitHub(_ url: String) -> (String, String) {
        // 支持 git@github.com:owner/repo.git 和 https://github.com/owner/repo.git
        var s = url
        if let r = s.range(of: "github.com") {
            s = String(s[r.upperBound...])
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
            s = s.replacingOccurrences(of: ".git", with: "")
            let parts = s.split(separator: "/")
            if parts.count >= 2 { return (String(parts[0]), String(parts[1])) }
        }
        return ("", "")
    }
    
    // 快速检测仓库主语言（基于 git ls-files 文件扩展名统计，限 200 文件）
    private static func detectLanguage(at path: String) -> String? {
        let out = ProcessRunner.runCommand("git -C '\(path)' ls-files --cached 2>/dev/null | head -200")
        var counts: [String: Int] = [:]
        let extToLang: [String: String] = [
            "rs": "Rust", "py": "Python", "js": "JavaScript", "ts": "TypeScript",
            "swift": "Swift", "go": "Go", "java": "Java", "kt": "Kotlin",
            "rb": "Ruby", "c": "C", "cpp": "C++", "h": "C", "m": "Objective-C",
            "cs": "C#", "php": "PHP", "vue": "Vue", "dart": "Dart",
            "lua": "Lua", "sh": "Shell", "zig": "Zig", "ex": "Elixir", "html": "HTML", "css": "CSS"
        ]
        for line in out.components(separatedBy: .newlines) {
            let ext = (line as NSString).pathExtension.lowercased()
            if let lang = extToLang[ext] { counts[lang, default: 0] += 1 }
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
    
    // 将 git 日期字符串转为相对时间（如"3 天前"）
    private static func relativeTime(from dateStr: String) -> String? {
        let trimmed = dateStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        guard let date = df.date(from: trimmed) else { return nil }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        if seconds < 2592000 { return "\(seconds / 86400) 天前" }
        if seconds < 31536000 { return "\(seconds / 2592000) 个月前" }
        return "\(seconds / 31536000) 年前"
    }
    
    // 详情页按需拉取单个仓库的 star/fork（仅一次请求，避免列表批量拉超限）
    func fetchGitStats(for app: RadarUpdateApp) {
        guard app.category == .git, app.stars == nil,
              let hp = app.homepage?.absoluteString, hp.contains("github.com/") else { return }
        let parts = hp.components(separatedBy: "github.com/")
        guard parts.count >= 2 else { return }
        let comps = parts[1].split(separator: "/")
        guard comps.count >= 2 else { return }
        Self.fetchGitHubStats(owner: String(comps[0]), repo: String(comps[1]).replacingOccurrences(of: ".git", with: ""), app: app)
    }
    
    // 尝试从 GitHub API 拿 star/fork（限流时静默跳过）
    private static func fetchGitHubStats(owner: String, repo: String, app: RadarUpdateApp) {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else { return }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data, let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                app.stars = d["stargazers_count"] as? Int
                app.forks = d["forks_count"] as? Int
            }
        }.resume()
    }
    
    func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    
    // 读取本地仓库的 README 作为「项目说明」（本地文件，无需联网；详情页打开时按需加载）
    func fetchGitReadme(for app: RadarUpdateApp) {
        guard app.category == .git, let path = app.localPath, !app.readmeLoaded else { return }
        DispatchQueue.global(qos: .utility).async {
            let result = RadarScanner.loadLocalReadme(path: path)
            DispatchQueue.main.async {
                if let (excerpt, images) = result {
                    if app.releaseNotes == nil { app.releaseNotes = excerpt }
                    if app.screenshotUrls.isEmpty { app.screenshotUrls = images }
                }
                app.readmeLoaded = true   // 标记加载完成（即便没有 README），停止 loading
            }
        }
    }
    
    // 读取本地 README 并提取正文摘要 + 图片（同步，调用方负责放到后台线程）
    static func loadLocalReadme(path: String) -> (excerpt: String, images: [String])? {
        let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let zhCandidates = [
            "README.zh-CN.md", "README.zh_CN.md", "README.zh.md", "README.zh-Hans.md",
            "README_zh.md", "readme.zh-cn.md", "readme.zh.md", "README_CN.md", "readme_cn.md"
        ]
        let standardCandidates = ["README.md", "readme.md", "README", "Readme.md",
                                  "README.markdown", "README.rst", "docs/README.md"]
        let candidates = (isChinese ? zhCandidates : []) + standardCandidates
        
        for f in candidates {
            let full = path + "/" + f
            if let md = try? String(contentsOfFile: full, encoding: .utf8), !md.isEmpty {
                let excerpt = readmeExcerpt(md, maxChars: 3000)
                let images = extractReadmeImages(md, repoPath: path, fileSubdir: (f as NSString).deletingLastPathComponent)
                return (excerpt, images)
            }
        }
        return nil
    }
    
    // 从 README 提取图片地址：本地相对路径解析为绝对路径，网络图保留 http；过滤徽章/svg。
    static func extractReadmeImages(_ md: String, repoPath: String, fileSubdir: String) -> [String] {
        var urls: [String] = []
        let patterns = [#"!\[[^\]]*\]\(([^)\s]+)"#, #"<img[^>]+src=[\"']([^\"']+)[\"'][^>]*>"#]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = md as NSString
            re.enumerateMatches(in: md, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m, m.numberOfRanges >= 2 else { return }
                var src = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let low = src.lowercased()
                
                // 1. 过滤徽章 / 状态图标 / 矢量图
                if low.contains("shields.io") || low.contains("badge") || low.hasSuffix(".svg")
                    || low.contains("img.shields") || low.contains("license") || low.contains("licence") { return }
                    
                // 2. 过滤赞助 / 捐赠 / 支付 / 赞赏码
                if low.contains("sponsor") || low.contains("donate") || low.contains("donation")
                    || low.contains("patreon") || low.contains("paypal") || low.contains("alipay")
                    || low.contains("wechatpay") || low.contains("wxpay") || low.contains("pay")
                    || low.contains("赞赏") || low.contains("赏") || low.contains("收款") { return }
                    
                // 3. 过滤二维码 / 关注 / 社交按钮
                if low.contains("qrcode") || low.contains("qr_code") || low.contains("qr") || low.contains("扫码")
                    || low.contains("follow") || low.contains("discord") || low.contains("twitter") || low.contains("facebook") { return }
                
                // 4. 过滤头像 / 贡献者列表
                if low.contains("avatar") || low.contains("contrib") || low.contains("member") { return }
                
                // 5. 过滤 Logo / 横幅 / 星标增长图
                if low.contains("logo") || low.contains("banner") || low.contains("star-history") || low.contains("trending") { return }
                
                // 6. 如果是 HTML img 标签，检查是否指定了微小的高度或宽度（例如 height="60" 或 width="10%" 代表图标/徽章）
                if let range = Range(m.range(at: 0), in: md) {
                    let tagText = String(md[range]).lowercased()
                    if let heightRange = tagText.range(of: #"height\s*=\s*['"]?(\d+)['"]?"#, options: .regularExpression) {
                        let heightStr = tagText[heightRange].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                        if let h = Int(heightStr), h <= 100 {
                            return
                        }
                    }
                    if let widthRange = tagText.range(of: #"width\s*=\s*['"]?(\d+)%?['"]?"#, options: .regularExpression) {
                        let widthStr = tagText[widthRange].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                        if let w = Int(widthStr), w <= 15 {
                            return
                        }
                    }
                }
                
                if src.hasPrefix("http") {
                    // 自动把 github.com 的网页型 blob 图片链接重写为 raw 直链，解决类似 hermes-web-ui 预览图加载失败的问题
                    if src.contains("github.com/") && src.contains("/blob/") {
                        src = src.replacingOccurrences(of: "/blob/", with: "/raw/")
                    }
                    urls.append(src)
                } else if repoPath.hasPrefix("http") {
                    // 远程相对路径（解决 Node/Homebrew 远程获取 README 的相对图片解析）
                    src = src.replacingOccurrences(of: "./", with: "")
                    let base = fileSubdir.isEmpty ? repoPath : repoPath + "/" + fileSubdir
                    let full = src.hasPrefix("/") ? repoPath + src : base + "/" + src
                    urls.append(full)
                } else {
                    // 本地相对路径 → 解析为本地绝对路径，并校验是有效图片
                    src = src.replacingOccurrences(of: "./", with: "")
                    let base = fileSubdir.isEmpty ? repoPath : repoPath + "/" + fileSubdir
                    let full = src.hasPrefix("/") ? repoPath + src : base + "/" + src
                    if FileManager.default.fileExists(atPath: full), NSImage(contentsOfFile: full) != nil {
                        urls.append(full)
                    }
                }
            }
        }
        // 去重并限量
        var seen = Set<String>(); var result: [String] = []
        for u in urls where !seen.contains(u) { seen.insert(u); result.append(u); if result.count >= 6 { break } }
        return result
    }
    
    // 刷新所有 Git 项目的运行状态和端口
    // 逻辑核心：只有在项目目录内监听 TCP 端口的进程，才视为「运行中」。
    // 同时记录该进程的完整命令行，下次启动时可复用。
    func refreshGitProjectStatus() {
        DispatchQueue.global(qos: .utility).async {
            // Step 1: 获取所有进程的 CWD
            var pidToCwd: [Int: String] = [:]
            let lsofCwdOut = ProcessRunner.runCommand("lsof -a -d cwd -Fn 2>/dev/null")
            var currentPid = 0
            for line in lsofCwdOut.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("p") {
                    if let pidVal = Int(trimmed.dropFirst()) { currentPid = pidVal }
                } else if trimmed.hasPrefix("n") && currentPid != 0 {
                    pidToCwd[currentPid] = String(trimmed.dropFirst())
                }
            }

            // Step 2: 获取监听 TCP 端口的 PID → Port 映射
            let lsofPortOut = ProcessRunner.runCommand("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null")
            var pidToPort: [Int: Int] = [:]
            for line in lsofPortOut.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("COMMAND") { continue }
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 9, let pid = Int(parts[1]) {
                    let addr = parts[8]
                    if let c = addr.lastIndex(of: ":"), let port = Int(addr[addr.index(after: c)...]) {
                        if pidToPort[pid] == nil || port < pidToPort[pid]! {
                            pidToPort[pid] = port
                        }
                    }
                }
            }

            // Step 3: 获取进程完整命令行（用于记录学到的启动命令）
            var pidToArgs: [Int: String] = [:]
            let psArgsOut = ProcessRunner.runCommand("ps -ax -o pid=,args=")
            for line in psArgsOut.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let parts = trimmed.components(separatedBy: .whitespaces)
                guard parts.count >= 2, let pid = Int(parts[0]) else { continue }
                // args 去掉 pid 开头
                let args = parts[1...].joined(separator: " ")
                pidToArgs[pid] = args
            }

            // Step 4: 对每个 Git 项目，匹配「有在监听端口的进程且其 CWD 在项目目录内」
            let gitApps = (self.installed + self.updates).filter { $0.category == .git }
            for app in gitApps {
                guard let localPath = app.localPath else { continue }
                let canonicalPath = URL(fileURLWithPath: localPath).resolvingSymlinksInPath().path

                var runningPids: [Int] = []
                var ports: [Int] = []
                var capturedCmd: String? = nil

                for (pid, p) in pidToPort {
                    guard let cwd = pidToCwd[pid] else { continue }
                    let canonicalCwd = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
                    guard canonicalCwd == canonicalPath || canonicalCwd.hasPrefix(canonicalPath + "/") else { continue }
                    runningPids.append(pid)
                    ports.append(p)
                    // 记录启动命令：去掉原始可执行文件路径，保留参数部分即可全局复用
                    if capturedCmd == nil, let args = pidToArgs[pid] {
                        // 将命令行中的绝对路径换成相对命令，也可以直接保存原始形式
                        capturedCmd = args
                    }
                }

                let port = self.selectBestConsolePort(from: ports)
                let isRunning = !runningPids.isEmpty
                let pidsArr = runningPids
                let finalPort = port
                let finalCmd = capturedCmd
                DispatchQueue.main.async {
                    app.runningPids = pidsArr
                    app.isRunning = isRunning
                    app.servicePort = finalPort
                    if isRunning, let cmd = finalCmd {
                        if app.detectedStartCmd != cmd {
                            app.detectedStartCmd = cmd
                            self.saveGitStartCmd(forLocalPath: localPath, cmd: cmd)
                        }
                    }
                }
            }
        }
    }

    // 显示 macOS 原生提示弹窗（确保在主线程执行）
    private func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    // 寻找闲置端口（避免 index.html 静态服务端口冲突）
    private func findFreePort(startingFrom port: Int) -> Int {
        var p = port
        while p < 65535 {
            let out = ProcessRunner.runCommand("lsof -iTCP:\(p) -sTCP:LISTEN 2>/dev/null")
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return p
            }
            p += 1
        }
        return port
    }

    // 后台静默启动 Git 项目（不弹出 Terminal）
    // 逻辑：优先使用已记录的启动命令，如无记录则使用智能推断（如 .command、start.sh、package.json 等）。
    // 若启动超时或失败，直接弹出原生 Alert，决不弹出终端窗口。
    func startGitProject(_ app: RadarUpdateApp) {
        guard app.category == .git, !app.isStartingOrStopping, let localPath = app.localPath else { return }
        
        let startupCmd = self.inferStartupCommand(for: localPath, learnedCmd: app.detectedStartCmd)
        
        guard !startupCmd.isEmpty else {
            // 没有学习过且无法推断启动命令 → 直接展示友好弹窗，让小白用户能够看懂
            self.showAlert(
                title: "无法自动启动项目",
                message: "该项目没有找到常见的启动文件或脚本，且尚未在本地成功运行过。\n\n提示：请先在终端中手动成功运行该服务一次，App 将会自动学习并记住其启动命令与端口。"
            )
            return
        }

        DispatchQueue.main.async { app.isStartingOrStopping = true }
        DispatchQueue.global(qos: .userInitiated).async {
            // 处理脚本文件的执行权限问题 (如以防 `./script.sh` 或 `.command` 没有执行权限)
            let parts = startupCmd.components(separatedBy: " ")
            for part in parts {
                if part.hasPrefix("./") && (part.hasSuffix(".sh") || part.hasSuffix(".command")) {
                    let scriptName = String(part.dropFirst(2))
                    _ = ProcessRunner.runCommand("chmod +x \(self.shellQuote(localPath + "/" + scriptName)) 2>/dev/null")
                }
            }

            // 后台静默启动：Process + nohup，无终端弹窗
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", ProcessRunner.envPath + "nohup \(startupCmd) >/dev/null 2>&1 &"]
            proc.currentDirectoryURL = URL(fileURLWithPath: localPath)
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice

            do {
                try proc.run()
                proc.waitUntilExit()   // 立即退出，由后台接管
            } catch {
                self.showAlert(title: "系统错误", message: "启动进程失败，请检查项目路径或权限是否正确。")
                DispatchQueue.main.async { app.isStartingOrStopping = false }
                return
            }

            // 动态等待服务启动并绑定端口（每 1 秒检测一次，最多等待 15 秒）
            var startSuccess = false
            for _ in 0..<15 {
                Thread.sleep(forTimeInterval: 1.0)
                self.refreshGitProjectStatus()
                
                // 等待主线程更新 UI 状态以核实 app.isRunning
                var isRunning = false
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.main.async {
                    isRunning = app.isRunning
                    group.leave()
                }
                group.wait()
                
                if isRunning {
                    startSuccess = true
                    break
                }
            }
            
            if !startSuccess {
                self.showAlert(
                    title: "服务启动超时或失败",
                    message: "启动命令 [\(startupCmd)] 已在后台尝试执行，但在 15 秒内未检测到任何服务端口处于监听状态。进程可能因为依赖缺失、配置错误或虚拟环境未找到已异常退出。\n\n提示：若服务正常运行但启动较慢，可稍后手动刷新查看。如确有错误，建议在终端中手动运行排查。"
                )
            }

            DispatchQueue.main.async { app.isStartingOrStopping = false }
        }
    }

    // 智能推断当前项目的启动命令
    private func inferStartupCommand(for localPath: String, learnedCmd: String?, checkSubdirs: Bool = true) -> String {
        let fm = FileManager.default

        // 1. 使用之前学到的已持久化的启动命令（优先级最高）
        if let learned = learnedCmd, !learned.isEmpty {
            return learned
        }

        // 2. 精确匹配标准启动脚本（如 kiro-go、Yuque2DingTalk.command、各种 start.sh 等）
        let standardScripts = ["kiro-go", "start.sh", "run.sh", "dev.sh", "serve.sh", "launch.sh", "Yuque2DingTalk.command"]
        for script in standardScripts {
            let path = localPath + "/" + script
            if fm.fileExists(atPath: path) {
                return "./" + script
            }
        }

        // 3. 模糊匹配常见命名的 shell / command 脚本，但排除 setup / install / deploy / build / test / configure 等安装与构建脚本
        if let files = try? fm.contentsOfDirectory(atPath: localPath) {
            for file in files {
                let lower = file.lowercased()
                if file.hasSuffix(".sh") || file.hasSuffix(".command") {
                    if lower.contains("install") || lower.contains("setup") || lower.contains("deploy") || lower.contains("build") || lower.contains("test") || lower.contains("configure") {
                        continue
                    }
                    if lower.contains("start") || lower.contains("run") || lower.contains("dev") || lower.contains("serve") || lower.contains("launch") || lower.contains("yuque") {
                        return "./" + file
                    }
                }
            }
        }

        // 4. docker-compose
        for name in ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"] {
            if fm.fileExists(atPath: localPath + "/" + name) {
                return "docker compose up"
            }
        }

        // 5. package.json — 读取 scripts 字段，按优先级选择
        if fm.fileExists(atPath: localPath + "/package.json"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: localPath + "/package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any] {
            for key in ["dev", "start", "serve", "preview", "run"] {
                if scripts[key] != nil { return "npm run " + key }
            }
            if !scripts.isEmpty { return "npm run dev" }
        }

        // 6. Python
        for entry in ["app.py", "server.py", "main.py", "run.py", "manage.py"] {
            if fm.fileExists(atPath: localPath + "/" + entry) {
                if entry == "manage.py" { return "python3 manage.py runserver" }
                return "python3 " + entry
            }
        }

        // 7. Go
        if fm.fileExists(atPath: localPath + "/go.mod") { return "go run ." }

        // 8. Rust
        if fm.fileExists(atPath: localPath + "/Cargo.toml") { return "cargo run" }

        // 9. 纯静态网页 (动态查找空闲端口)
        if fm.fileExists(atPath: localPath + "/index.html") {
            let freePort = self.findFreePort(startingFrom: 8080)
            return "python3 -m http.server \(freePort)"
        }

        // 10. 单独子目录探测 (解决 monorepo 根目录下没有构建配置的问题，如 finance-tracker/frontend)
        if checkSubdirs {
            if let subdirCmd = self.inferSubdirStartupCommand(localPath: localPath) {
                return subdirCmd
            }
        }

        return ""
    }

    // 递归寻找子目录中的开发配置并推断启动命令 (限深 1 层)
    private func inferSubdirStartupCommand(localPath: String) -> String? {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(atPath: localPath) else { return nil }
        
        var commands: [String] = []
        for sub in subdirs {
            let subPath = localPath + "/" + sub
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            // 跳过无关的目录
            guard !sub.hasPrefix("."), sub != "node_modules", sub != "vendor", sub != "target", sub != "dist", sub != "output" else { continue }
            
            let subCmd = self.inferStartupCommand(for: subPath, learnedCmd: nil, checkSubdirs: false)
            if !subCmd.isEmpty {
                commands.append("cd \(self.shellQuote(sub)) && \(subCmd)")
            }
        }
        
        if commands.isEmpty { return nil }
        if commands.count == 1 {
            return commands[0]
        } else {
            // 并发在后台启动多个子模块 (如 frontend 和 backend)
            return commands.map { "(\($0))" }.joined(separator: " & ")
        }
    }
    
    // 停止 Git 项目：杀死所有属于该项目工作目录下的进程
    func stopGitProject(_ app: RadarUpdateApp) {
        guard app.category == .git, !app.isStartingOrStopping else { return }
        let pids = app.runningPids
        DispatchQueue.main.async { app.isStartingOrStopping = true }
        DispatchQueue.global(qos: .userInitiated).async {
            for pid in pids {
                _ = ProcessRunner.runCommand("kill -9 \(pid) 2>/dev/null")
            }
            Thread.sleep(forTimeInterval: 1.5)
            self.refreshGitProjectStatus()
            DispatchQueue.main.async { app.isStartingOrStopping = false }
        }
    }
    
    // 打开 Git 项目的 Web 控制台
    func openGitProjectUI(_ app: RadarUpdateApp) {
        guard let port = app.servicePort else { return }
        let suffix = self.webPathSuffix(for: app)
        let urlString = "http://localhost:\(port)\(suffix)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    // 扫描本机 GitHub 仓库：发现 → 仅保留 origin 为 github.com → fetch 对比是否落后。
    // 落后的进「待更新」，其余进「已安装」。仅在启动/手动刷新时执行（涉及网络，较慢）。
    func scanGitProjects() {
        DispatchQueue.main.async { self.isScanningGit = true }
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
                self.updates = self.updates.filter { $0.category != .git } + updates
                self.installed = self.installed.filter { $0.category != .git } + installed
                self.isScanningGit = false
                self.restoreIgnoreState()
                self.refreshDockBadge()
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
        
        // 先按规范化真实路径去重（消除符号链接 / /private 前缀 / 末尾斜杠等导致的重复）
        var seen = Set<String>()
        var uniqueRepos: [String] = []
        for repo in roots.sorted() {
            let canonical = URL(fileURLWithPath: repo).resolvingSymlinksInPath().path
            if seen.insert(canonical).inserted { uniqueRepos.append(canonical) }
        }
        // 再并行检查每个仓库的 origin 是否指向 github（git remote 为本地操作，并行后几乎瞬时）
        var isGithub = [Bool](repeating: false, count: uniqueRepos.count)
        DispatchQueue.concurrentPerform(iterations: uniqueRepos.count) { i in
            let url = ProcessRunner.runCommand("git -C \(self.shellQuote(uniqueRepos[i])) remote get-url origin 2>/dev/null")
            isGithub[i] = url.lowercased().contains("github.com")
        }
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
            var lastLine = ""
            let code = ProcessRunner.runCommandStreaming("git -C \(q) pull --ff-only 2>&1") { line in
                lastLine = line
                DispatchQueue.main.async { app.upgradeMessage = String(line.prefix(40)) }
            }
            let lower = lastLine.lowercased()
            // ff-only 失败（本地有分叉/改动）→ 给出清晰中文提示，不强制
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
                } else if diverged {
                    app.upgradeMessage = "⚠️ 本地与远程已分叉，需手动合并"
                } else if localChanges {
                    app.upgradeMessage = "⚠️ 本地有未提交改动，请先提交或暂存"
                } else if conflict {
                    app.upgradeMessage = "⚠️ 存在冲突，需手动解决"
                } else {
                    app.upgradeMessage = "⚠️ 更新失败，需手动处理"
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
        let candidates = ["README.md", "readme.md", "README", "Readme.md",
                          "README.markdown", "README.rst", "docs/README.md"]
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
        let patterns = [#"!\[[^\]]*\]\(([^)\s]+)"#, #"<img[^>]+src=[\"']([^\"']+)[\"']"#]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = md as NSString
            re.enumerateMatches(in: md, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m, m.numberOfRanges >= 2 else { return }
                var src = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let low = src.lowercased()
                // 过滤徽章 / 矢量图标 / 占位
                if low.contains("shields.io") || low.contains("badge") || low.hasSuffix(".svg")
                    || low.contains("img.shields") { return }
                if src.hasPrefix("http") {
                    urls.append(src)
                } else {
                    // 相对路径 → 解析为本地绝对路径，并校验是有效图片
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
}

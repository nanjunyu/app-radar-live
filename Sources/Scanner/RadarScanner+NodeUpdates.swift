import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    // 检测 npm 全局包可升级项。无 npm 时返回空（菜单会被隐藏）。
    // 排除包管理器自身（npm/pnpm/yarn/corepack），这些不应随便升级。
    static let nodeExcluded: Set<String> = ["npm", "pnpm", "yarn", "corepack"]
    private static let excludedPackages = nodeExcluded
    
    func nodeUpdates() -> [RadarUpdateApp] {
        guard Environment.hasNpm else { return [] }
        // npm outdated -g --json：有更新时退出码为 1（正常），仍读取 stdout。
        // 带 --prefix 绕开被劫持的全局配置，对准真正有包的目录。
        let json = ProcessRunner.runCommand("npm outdated -g --json \(Environment.npmPrefixArg)2>/dev/null")
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        // npm 环境异常（如 prefix 目录缺失）时，命令不返回包列表，而是返回顶层错误对象
        // 如 {"error": {"code": "ENOENT", ...}}。必须先识别并跳过，否则会把 "error" 这个键
        // 误当成包名，继而查到 npm registry 上真实存在但毫不相关的同名包（如作者 Raynos 的 error 包）。
        if dict.count == 1, let errObj = dict["error"] as? [String: Any], errObj["code"] != nil {
            return []
        }
        var result: [RadarUpdateApp] = []
        for (pkg, value) in dict {
            guard let info = value as? [String: Any] else { continue }
            // 保险：即便未命中上面的整体判断，逐条也排除明显不是包信息的条目（缺 current/latest）
            guard info["current"] != nil || info["latest"] != nil else { continue }
            // 跳过包管理器自身，避免误升级导致环境崩溃
            if Self.excludedPackages.contains(pkg) { continue }
            let app = RadarUpdateApp(name: pkg, category: .node)
            app.currentVersion = info["current"] as? String
            app.latestVersion = info["latest"] as? String
            app.developer = "npm 全局包"
            fetchNpmMetadata(for: app)   // 异步回填描述/图标/日期/许可证/说明
            result.append(app)
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    // 从 npm registry 回填富信息：描述、主页、仓库主人头像、发布日期、许可证、README 说明。
    func fetchNpmMetadata(for app: RadarUpdateApp) {
        let encoded = app.name.replacingOccurrences(of: "/", with: "%2f")
        guard let url = URL(string: "https://registry.npmjs.org/\(encoded)") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let latest = (json["dist-tags"] as? [String: Any])?["latest"] as? String ?? app.latestVersion
            DispatchQueue.main.async {
                if let desc = json["description"] as? String, !desc.isEmpty {
                    app.descriptionText = desc
                }
                if let lic = json["license"] as? String, !lic.isEmpty { app.license = lic }
                if let hp = json["homepage"] as? String, let u = URL(string: hp) { app.homepage = u }
                if let times = json["time"] as? [String: Any], let lv = latest, let t = times[lv] as? String {
                    app.releaseDate = String(t.prefix(10))
                }
                // 仓库主人头像作为图标；兜底从 scope 或 maintainer 推断
                if let owner = Self.githubOwner(from: json["repository"]) {
                    app.logoUrl = URL(string: "https://github.com/\(owner).png?size=128")
                    app.developer = owner
                } else if let owner = Self.inferOwner(pkg: app.name, json: json) {
                    app.logoUrl = URL(string: "https://github.com/\(owner).png?size=128")
                    app.developer = owner
                }
                // README 作为「说明」内容（无 changelog 时的可靠富文本来源）
                if let readme = json["readme"] as? String, !readme.isEmpty {
                    let excerpt = Self.readmeExcerpt(readme)
                    app.releaseNotes = excerpt
                    
                    // 异步提取 README 中的截图预览图
                    var rawBaseUrl = ""
                    if let owner = Self.githubOwner(from: json["repository"]) ?? Self.inferOwner(pkg: app.name, json: json) {
                        let repoName = app.name.split(separator: "/").last.map(String.init) ?? app.name
                        rawBaseUrl = "https://raw.githubusercontent.com/\(owner)/\(repoName)/HEAD"
                    }
                    let imgs = RadarScanner.extractReadmeImages(readme, repoPath: rawBaseUrl, fileSubdir: "")
                    app.screenshotUrls = imgs
                } else if let desc = json["description"] as? String, !desc.isEmpty {
                    // npm registry readme 为空时，尝试从 GitHub 拉取 README
                    if let owner = Self.githubOwner(from: json["repository"]) ?? Self.inferOwner(pkg: app.name, json: json) {
                        Self.fetchGitHubReadme(owner: owner, pkg: app.name) { excerpt in
                            let text = excerpt ?? desc
                            DispatchQueue.main.async { app.releaseNotes = text }
                        }
                    } else {
                        app.releaseNotes = desc
                    }
                }
            }
        }.resume()
    }
    
    // 从 repository 字段解析 GitHub owner（如 git+https://github.com/pnpm/pnpm.git → pnpm）
    private static func githubOwner(from repo: Any?) -> String? {
        var urlStr: String?
        if let s = repo as? String { urlStr = s }
        else if let d = repo as? [String: Any] { urlStr = d["url"] as? String }
        guard let s = urlStr, let r = s.range(of: "github.com/") else { return nil }
        let tail = s[r.upperBound...]
        let owner = tail.split(separator: "/").first.map(String.init)
        return owner?.replacingOccurrences(of: ".git", with: "")
    }
    
    // 当 repository 为空时，从 scope 名或 maintainer 推断 GitHub 用户名
    private static func inferOwner(pkg: String, json: [String: Any]) -> String? {
        // 1) scope 包名 @scope/pkg → scope 通常就是 GitHub org/user
        if pkg.hasPrefix("@") {
            let scope = pkg.dropFirst().split(separator: "/").first.map(String.init)
            if let s = scope, !s.isEmpty { return s }
        }
        // 2) maintainers 第一位的 name 当 GitHub 用户名试探
        if let maintainers = json["maintainers"] as? [[String: Any]],
           let first = maintainers.first, let name = first["name"] as? String, !name.isEmpty {
            return name
        }
        return nil
    }
    
    // README 取前若干行纯文本摘要：跳过徽章/图片/HTML 行
    static func readmeExcerpt(_ md: String, maxChars: Int = 600) -> String {
        var lines: [String] = []
        for raw in md.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[![") || line.hasPrefix("![") || line.hasPrefix("<") { continue }
            if line.hasPrefix("#") { lines.append(line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)) }
            else { lines.append(line) }
            if lines.joined(separator: "\n").count > maxChars { break }
        }
        let text = lines.joined(separator: "\n")
        return String(text.prefix(maxChars))
    }
    
    // 从 GitHub raw 拉取 README.md（当 npm registry readme 为空时的补充）
    private static func fetchGitHubReadme(owner: String, pkg: String, completion: @escaping (String?) -> Void) {
        // 尝试常见仓库名：owner/pkg（去掉 scope 前缀）
        let repoName = pkg.split(separator: "/").last.map(String.init) ?? pkg
        let urlStr = "https://raw.githubusercontent.com/\(owner)/\(repoName)/HEAD/README.md"
        guard let url = URL(string: urlStr) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data = data, let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
                  let md = String(data: data, encoding: .utf8), !md.isEmpty else {
                completion(nil); return
            }
            completion(readmeExcerpt(md))
        }.resume()
    }
    
    // 从 GitHub Releases 拉取最新版本的升级说明（按需：用户打开详情页时才调用一次）
    func fetchChangelog(for app: RadarUpdateApp) {
        guard app.category == .node, !app.changelogLoaded else { return }
        app.changelogLoaded = true
        // 需要 owner 和 repo 名才能查 releases
        let encoded = app.name.replacingOccurrences(of: "/", with: "%2f")
        guard let regUrl = URL(string: "https://registry.npmjs.org/\(encoded)") else { return }
        URLSession.shared.dataTask(with: regUrl) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard let owner = Self.githubOwner(from: json["repository"]) ?? Self.inferOwner(pkg: app.name, json: json) else { return }
            let repoName = app.name.split(separator: "/").last.map(String.init) ?? app.name
            let apiUrl = "https://api.github.com/repos/\(owner)/\(repoName)/releases/latest"
            guard let url = URL(string: apiUrl) else { return }
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                guard let data = data, let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
                      let rel = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let body = rel["body"] as? String, !body.isEmpty else { return }
                // 清理 markdown：去掉过长的 PR 链接、保留核心内容
                let cleaned = Self.cleanReleaseBody(body)
                DispatchQueue.main.async { app.changelogNotes = cleaned }
            }.resume()
        }.resume()
    }
    
    // 精简 release body：去掉 Full Changelog 链接、@mentions 简化、截断
    static func cleanReleaseBody(_ body: String, maxChars: Int = 800) -> String {
        var lines: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("**full changelog") { continue }
            if line.isEmpty && lines.last?.isEmpty == true { continue } // 去连续空行
            lines.append(line)
            if lines.joined(separator: "\n").count > maxChars { break }
        }
        return String(lines.joined(separator: "\n").prefix(maxChars))
    }
    
    // 升级单个 npm 全局包：npm install -g <pkg>@latest（流式进度）。
    // 全局目录一般用户可写，免 sudo；遇 EACCES 再走系统原生提权（pam_tid Touch ID）。
    func upgradeNodePackage(_ app: RadarUpdateApp) {
        if app.isUpgrading { return }
        DispatchQueue.main.async { app.isUpgrading = true; app.upgradeMessage = "升级中…" }
        DispatchQueue.global(qos: .userInitiated).async {
            // scope 包名（@scope/pkg）整体加单引号，避免 shell 误解析
            let target = "'\(app.name)@latest'"
            var lastLine = ""
            let code = ProcessRunner.runCommandStreaming("npm install -g \(Environment.npmPrefixArg)\(target) 2>&1") { line in
                lastLine = line
                if let s = self.progressStatus(for: line) {
                    DispatchQueue.main.async { app.upgradeMessage = s }
                }
            }
            
            // 权限不足（多见于官方 pkg 装到 /usr/local）→ 用系统原生提权重试
            let lower = lastLine.lowercased()
            if lower.contains("eacces") || lower.contains("permission denied") {
                DispatchQueue.main.async { app.upgradeMessage = "需要授权（指纹）…" }
                var line2 = ""
                let code2 = ProcessRunner.runCommandStreaming("sudo npm install -g \(Environment.npmPrefixArg)\(target) 2>&1") { line in
                    line2 = line
                    if let s = self.progressStatus(for: line) {
                        DispatchQueue.main.async { app.upgradeMessage = s }
                    }
                }
                self.finishNodeUpgrade(app, code: code2, lastLine: line2)
                return
            }
            self.finishNodeUpgrade(app, code: code, lastLine: lastLine)
        }
    }
    
    private func finishNodeUpgrade(_ app: RadarUpdateApp, code: Int32, lastLine: String) {
        let lower = lastLine.lowercased()
        let failed = code != 0 || lower.contains("npm err") || lower.contains("error")
            || lower.contains("eacces") || lower.contains("permission denied")
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

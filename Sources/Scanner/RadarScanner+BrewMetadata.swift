import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    // 批量获取 Homebrew 已安装包的元数据（名称/描述/主页/版本/许可证），回填到 RadarUpdateApp。
    // 用 `brew info --json=v2 --installed` 一次性拉取全部（~2s），不逐个调用。
    func fetchBrewMetadata(for apps: [RadarUpdateApp]) {
        guard !apps.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let json = ProcessRunner.runCommand("brew info --json=v2 --installed 2>/dev/null")
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            
            // 构建 name → metadata 映射
            var metaMap: [String: (desc: String?, homepage: String?, version: String?, license: String?, gitRepoUrl: String?, displayName: String?)] = [:]
            
            if let formulae = obj["formulae"] as? [[String: Any]] {
                for f in formulae {
                    guard let name = f["name"] as? String else { continue }
                    let desc = f["desc"] as? String
                    let homepage = f["homepage"] as? String
                    let version = (f["versions"] as? [String: Any])?["stable"] as? String
                    let license = f["license"] as? String
                    
                    var gitRepo: String? = nil
                    if let urls = f["urls"] as? [String: Any] {
                        if let stable = urls["stable"] as? [String: Any],
                           let u = stable["url"] as? String, u.contains("github.com/") {
                            gitRepo = u
                        } else if let head = urls["head"] as? [String: Any],
                                  let u = head["url"] as? String, u.contains("github.com/") {
                            gitRepo = u
                        }
                    }
                    
                    // formula 是命令行工具，不拉图标（避免 71 个并发请求拖慢界面）
                    metaMap[name] = (desc, homepage, version, license, gitRepo, nil)
                }
            }
            if let casks = obj["casks"] as? [[String: Any]] {
                for c in casks {
                    guard let token = c["token"] as? String else { continue }
                    let desc = c["desc"] as? String
                    let homepage = c["homepage"] as? String
                    let version = c["version"] as? String
                    let displayName = (c["name"] as? [String])?.first
                    metaMap[token] = (desc, homepage, version, nil, nil, displayName)
                }
            }
            
            // 回填到各 app
            for app in apps {
                guard let meta = metaMap[app.name] else { continue }
                // 判断是否是 cask（有 displayName 的就是 cask）
                let isCask = meta.displayName != nil
                DispatchQueue.main.async {
                    if let dn = meta.displayName, !dn.isEmpty { app.displayName = dn }
                    if let desc = meta.desc, !desc.isEmpty { app.descriptionText = desc; app.releaseNotes = desc }
                    if let hp = meta.homepage, let u = URL(string: hp) {
                        app.homepage = u
                        // 只给 cask（GUI 应用）从 GitHub 拉头像，formula 用兜底图标
                        if isCask, hp.contains("github.com/") {
                            let parts = hp.components(separatedBy: "github.com/")
                            if parts.count >= 2 {
                                let owner = parts[1].split(separator: "/").first.map(String.init) ?? ""
                                if !owner.isEmpty {
                                    app.logoUrl = URL(string: "https://github.com/\(owner).png?size=128")
                                    if app.developer == nil { app.developer = owner }
                                }
                            }
                        }
                    }
                    if let gitRepo = meta.gitRepoUrl {
                        app.gitRepoUrl = gitRepo
                        // 若详情页在此之前已打开但因缺少 gitRepoUrl 提前返回，此处在拿到后重新触发异步详情加载
                        if app.changelogNotes == nil && app.releaseNotes == nil {
                            app.changelogLoaded = false
                            self.fetchBrewDetail(for: app)
                        }
                    }
                    if let v = meta.version, app.currentVersion == nil {
                        app.currentVersion = v
                        if app.latestVersion == nil { app.latestVersion = v }
                    }
                    if let lic = meta.license, !lic.isEmpty { app.license = lic }
                }
            }
        }
    }
    
    // 详情页按需加载：从 GitHub 拉 README（功能说明）+ Releases（更新日志），并翻译成中文。
    func fetchBrewDetail(for app: RadarUpdateApp) {
        guard app.category == .brew, !app.changelogLoaded else { return }
        
        var githubPath: String? = nil
        if let hp = app.homepage?.absoluteString, hp.contains("github.com/") {
            githubPath = hp
        } else if let gr = app.gitRepoUrl, gr.contains("github.com/") {
            githubPath = gr
        }
        
        guard let path = githubPath else { return }
        app.changelogLoaded = true
        let parts = path.components(separatedBy: "github.com/")
        guard parts.count >= 2 else { return }
        let comps = parts[1].split(separator: "/")
        guard comps.count >= 2 else { return }
        let owner = String(comps[0])
        let repo = String(comps[1]).replacingOccurrences(of: ".git", with: "")
        
        DispatchQueue.main.async {
            if app.developer == nil || app.developer?.isEmpty == true {
                app.developer = owner
            }
        }
        
        // 不使用翻译器，直接使用原始的简短描述（避免硬翻译导致命令行命令或项目名面目全非）
        
        // README → 功能说明与图片预览提取
        if let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/README.md") {
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                guard let data = data, let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let md = String(data: data, encoding: .utf8), !md.isEmpty else { return }
                let excerpt = RadarScanner.readmeExcerpt(md)
                let rawBaseUrl = "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD"
                let imgs = RadarScanner.extractReadmeImages(md, repoPath: rawBaseUrl, fileSubdir: "")
                DispatchQueue.main.async {
                    app.releaseNotes = excerpt
                    app.screenshotUrls = imgs
                }
            }.resume()
        }
        // Releases → 更新日志与发布日期
        if let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") {
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                guard let data = data, let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let rel = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let body = rel["body"] as? String ?? ""
                let cleaned = body.isEmpty ? "" : RadarScanner.cleanReleaseBody(body)
                let publishedAt = rel["published_at"] as? String
                
                DispatchQueue.main.async {
                    if !cleaned.isEmpty {
                        app.changelogNotes = cleaned
                    }
                    if let pub = publishedAt, pub.count >= 10 {
                        app.releaseDate = String(pub.prefix(10))
                    }
                }
            }.resume()
        }
    }
}

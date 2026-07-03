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
            var metaMap: [String: (desc: String?, homepage: String?, version: String?, license: String?, displayName: String?)] = [:]
            
            if let formulae = obj["formulae"] as? [[String: Any]] {
                for f in formulae {
                    guard let name = f["name"] as? String else { continue }
                    let desc = f["desc"] as? String
                    let homepage = f["homepage"] as? String
                    let version = (f["versions"] as? [String: Any])?["stable"] as? String
                    let license = f["license"] as? String
                    // formula 是命令行工具，不拉图标（避免 71 个并发请求拖慢界面）
                    metaMap[name] = (desc, homepage, version, license, nil)
                }
            }
            if let casks = obj["casks"] as? [[String: Any]] {
                for c in casks {
                    guard let token = c["token"] as? String else { continue }
                    let desc = c["desc"] as? String
                    let homepage = c["homepage"] as? String
                    let version = c["version"] as? String
                    let displayName = (c["name"] as? [String])?.first
                    metaMap[token] = (desc, homepage, version, nil, displayName)
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
        app.changelogLoaded = true
        guard let hp = app.homepage?.absoluteString, hp.contains("github.com/") else { return }
        let parts = hp.components(separatedBy: "github.com/")
        guard parts.count >= 2 else { return }
        let comps = parts[1].split(separator: "/")
        guard comps.count >= 2 else { return }
        let owner = String(comps[0])
        let repo = String(comps[1]).replacingOccurrences(of: ".git", with: "")
        
        // 翻译已有的简短描述
        if let desc = app.descriptionText, !desc.isEmpty {
            Translator.toZh(desc) { zh in DispatchQueue.main.async { app.descriptionText = zh } }
        }
        // README → 功能说明
        if let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/README.md") {
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                guard let data = data, let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let md = String(data: data, encoding: .utf8), !md.isEmpty else { return }
                let excerpt = RadarScanner.readmeExcerpt(md)
                Translator.toZh(excerpt) { zh in DispatchQueue.main.async { app.releaseNotes = zh } }
            }.resume()
        }
        // Releases → 更新日志
        if let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") {
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                guard let data = data, let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let rel = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let body = rel["body"] as? String, !body.isEmpty else { return }
                let cleaned = RadarScanner.cleanReleaseBody(body)
                Translator.toZh(cleaned) { zh in DispatchQueue.main.async { app.changelogNotes = zh } }
            }.resume()
        }
    }
}

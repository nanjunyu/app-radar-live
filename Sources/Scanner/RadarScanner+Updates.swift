import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    func scanUpdates() {
        if isScanningUpdates { return }
        isScanningUpdates = true
        
        DispatchQueue.global(qos: .background).async {
            var scannedUpdates: [RadarUpdateApp] = []
            // mas outdated 输出示例:
            // 682658836  库乐队       (10.4.12    -> 10.4.14)
            let masOutput = ProcessRunner.runCommand("mas outdated")
            for line in masOutput.components(separatedBy: .newlines) {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty { continue }
                // 第一段是 App ID（纯数字），其余是 "名称 (当前版本 -> 最新版本)"
                let firstSplit = trimmedLine.split(separator: " ", maxSplits: 1).map(String.init)
                guard firstSplit.count == 2, firstSplit[0].allSatisfy({ $0.isNumber }) else { continue }
                let appId = firstSplit[0]
                var remainder = firstSplit[1].trimmingCharacters(in: .whitespaces)

                // 解析版本区间 "(current -> latest)"
                var currentVer: String? = nil
                var latestVer: String? = nil
                if let openParen = remainder.range(of: "("), let closeParen = remainder.range(of: ")", options: .backwards) {
                    let versionPart = String(remainder[openParen.upperBound..<closeParen.lowerBound])
                    let verComponents = versionPart.components(separatedBy: "->")
                    if verComponents.count == 2 {
                        currentVer = verComponents[0].trimmingCharacters(in: .whitespaces)
                        latestVer = verComponents[1].trimmingCharacters(in: .whitespaces)
                    }
                    // 名称为括号前的内容
                    remainder = String(remainder[remainder.startIndex..<openParen.lowerBound])
                }
                let appName = remainder.trimmingCharacters(in: .whitespaces)
                guard !appName.isEmpty else { continue }

                let app = RadarUpdateApp(name: appName, category: .appStore)
                app.appId = appId
                app.currentVersion = currentVer
                app.latestVersion = latestVer
                self.fetchAppStoreMetadata(for: app)
                scannedUpdates.append(app)
            }
            
            let brewOutdated = ProcessRunner.runCommand("brew outdated")
            for line in brewOutdated.components(separatedBy: .newlines) where !line.isEmpty && !line.contains("==") && !line.contains("✔") {
                let name = line.trimmingCharacters(in: .whitespaces)
                if name.isEmpty { continue }
                let app = RadarUpdateApp(name: name, category: .brew)
                app.logoUrl = URL(string: "https://logo.clearbit.com/\(name).com")
                scannedUpdates.append(app)
            }
            
            DispatchQueue.main.async {
                self.updates = scannedUpdates
                self.isScanningUpdates = false
                NSApplication.shared.dockTile.badgeLabel = self.updates.count > 0 ? "\(self.updates.count)" : nil
            }
        }
    }
    
    private func fetchAppStoreMetadata(for app: RadarUpdateApp) {
        guard let appId = app.appId, let url = URL(string: "https://itunes.apple.com/lookup?id=\(appId)&country=cn") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]], let first = results.first {
                DispatchQueue.main.async {
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
        }.resume()
    }
}

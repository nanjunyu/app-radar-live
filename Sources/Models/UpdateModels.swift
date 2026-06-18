import SwiftUI
import AppKit
import Foundation

// 2. Update Center (App Store / Brew updates)
enum UpdateCategory: String {
    case appStore = "App Store (待更新)"
    case brew = "Homebrew (待更新)"
}

class RadarUpdateApp: Identifiable, ObservableObject, Hashable {
    let id = UUID()
    let name: String
    let category: UpdateCategory
    
    @Published var displayName: String?
    @Published var appId: String?
    @Published var developer: String?
    @Published var descriptionText: String?
    @Published var releaseNotes: String?
    @Published var logoUrl: URL?
    @Published var sizeStr: String?
    @Published var screenshotUrls: [String] = []
    @Published var averageUserRating: Double?
    @Published var userRatingCount: Int?
    @Published var languages: [String] = []
    @Published var currentVersion: String?
    @Published var latestVersion: String?
    @Published var releaseDate: String?
    @Published var contentRating: String?
    @Published var primaryGenre: String?
    @Published var price: String?
    @Published var minimumOsVersion: String?
    
    init(name: String, category: UpdateCategory) { self.name = name; self.category = category }
    var bestName: String { displayName ?? name }
    // 语言显示：去重，优先中文，效仿官方 "ZH +N种语言"
    var languageDisplay: (primary: String, extraCount: Int)? {
        guard !languages.isEmpty else { return nil }
        var seen = Set<String>()
        var unique: [String] = []
        for l in languages {
            let up = l.uppercased()
            if !seen.contains(up) { seen.insert(up); unique.append(up) }
        }
        guard !unique.isEmpty else { return nil }
        // 优先把中文排在首位
        if let zhIndex = unique.firstIndex(where: { $0 == "ZH" }), zhIndex != 0 {
            let zh = unique.remove(at: zhIndex)
            unique.insert(zh, at: 0)
        }
        return (unique[0], unique.count - 1)
    }
    static func == (lhs: RadarUpdateApp, rhs: RadarUpdateApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

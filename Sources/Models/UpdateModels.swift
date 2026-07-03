import SwiftUI
import AppKit
import Foundation

// 2. Update Center (App Store / Brew updates)
enum UpdateCategory: String {
    case appStore = "App Store (待更新)"
    case brew = "Homebrew (待更新)"
    case node = "Node 全局包 (待更新)"
    case git = "Git 项目 (待更新)"
    case other = "其他 (待更新)"
}

// 「其他」渠道下的子类型：用于列表/详情的来源小标签
enum SourceKind {
    case sparkleApp   // 独立 GUI 应用（Sparkle 自更新）
    case cliTool      // 命令行工具（适配器）
    var label: String { self == .sparkleApp ? "独立应用" : "命令行工具" }
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
    @Published var localIcon: NSImage?     // 本地应用图标（独立应用/cask，用 NSWorkspace 取）
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
    @Published var license: String?       // npm 包许可证
    @Published var homepage: URL?          // npm 包主页
    @Published var changelogNotes: String? // 升级说明（GitHub Release notes）
    @Published var changelogLoaded = false // 是否已尝试加载 changelog
    // 升级操作状态
    @Published var isUpgrading: Bool = false
    @Published var upgradeMessage: String?
    @Published var upgraded: Bool = false   // 升级成功后置真，按钮变为"已是最新版"
    // Git 项目专用：本地仓库路径
    @Published var localPath: String?
    @Published var language: String?       // 主语言（从本地文件统计）
    @Published var lastUpdated: String?    // 最后更新时间（相对时间，如"3天前"）
    @Published var stars: Int?             // GitHub star 数（API 可用时填充）
    @Published var forks: Int?             // GitHub fork 数（API 可用时填充）
    @Published var readmeLoaded = false    // 详情页 README 是否已尝试加载完成（用于显示 loading）
    @Published var ignored = false         // 用户手动忽略本次更新（不计入角标，列表灰显）
    // 「其他」渠道专用
    @Published var sourceKind: SourceKind?     // 子类型（独立应用 / 命令行工具）
    var upgradeCommand: String?                // CLI 工具的升级命令（如 "claude update"）
    // Node 服务管理
    @Published var isRunning: Bool = false     // 当前是否有对应进程在跑
    @Published var servicePort: Int?           // 监听的端口（用于"打开"按钮）
    @Published var isStartingOrStopping = false // 正在启动/停止中
    var serviceBins: [String] = []            // 该包的真实可执行命令名（读自 package.json bin）
    var runningPids: [Int] = []               // 检测到的运行中进程 pid（用于停止）
    var isCask = false                        // Homebrew cask（GUI 应用，可"打开"）；formula 为 CLI 无 GUI
    
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
    // 跨重启稳定的忽略标识：Git 用本地路径，其它渠道用名称
    var ignoreKey: String { "\(category.rawValue)|\(localPath ?? appId ?? name)" }
}

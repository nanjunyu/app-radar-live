import SwiftUI
import AppKit

// MARK: - Update Center (Grid)
struct UpdateCenterView: View {
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    var category: UpdateCategory
    @State private var searchText = ""
    @State private var selectedTab = "installed"  // 默认显示「已安装」
    
    var title: String {
        switch category {
        case .appStore: return "App Store 更新"
        case .brew: return "Homebrew"
        case .node: return "Node 全局包"
        case .git: return "Git 项目"
        case .other: return "其他"
        }
    }
    
    var filteredUpdates: [RadarUpdateApp] {
        var res = scanner.updates.filter { $0.category == category }
        if !searchText.isEmpty { res = res.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
        return res
    }
    
    var filteredInstalled: [RadarUpdateApp] {
        var res = scanner.installed.filter { $0.category == category }
        if !searchText.isEmpty { res = res.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
        return res
    }
    
    // 该渠道是否正在扫描（Git / 其他 用各自专用慢扫描标志）
    var isScanning: Bool {
        switch category {
        case .git: return scanner.isScanningGit
        case .other: return scanner.isScanningOther
        default: return scanner.isScanningUpdates
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(title).font(.system(size: 28, weight: .bold))
                            Spacer()
                            Button(action: { scanner.scanUpdates() }) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }.buttonStyle(PlainButtonStyle()).foregroundColor(accentColor)
                        }
                        
                        // 仿 App Store 胶囊 Tab（一整块灰底，选中项蓝色胶囊浮在上面）
                        HStack(spacing: 0) {
                            tabButton("待更新", tag: "pending")
                            tabButton("已安装", tag: "installed")
                        }
                        .padding(3)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(Capsule())
                    }.padding(.horizontal, 30).padding(.top, 20)
                    
                    if selectedTab == "pending" {
                        if isScanning && filteredUpdates.isEmpty {
                            VStack(spacing: 14) {
                                ProgressView().scaleEffect(1.2)
                                Text(category == .git ? "正在扫描 Git 仓库…" : "正在检查更新…").font(.title3).foregroundColor(.gray)
                            }.frame(maxWidth: .infinity, minHeight: 300)
                        } else if filteredUpdates.isEmpty {
                            VStack {
                                Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundColor(.green.opacity(0.6))
                                Text("已是最新状态").font(.title3).foregroundColor(.gray).padding()
                            }.frame(maxWidth: .infinity, minHeight: 300)
                        } else {
                            // 批量更新按钮
                            HStack {
                                Spacer()
                                Button(action: { upgradeAll() }) {
                                    Label("全部更新", systemImage: "arrow.down.circle.fill")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(accentColor)
                            }.padding(.horizontal, 30)
                            
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 20)], spacing: 20) {
                                ForEach(filteredUpdates) { app in
                                    AppGridCardWithAction(app: app, scanner: scanner, accentColor: accentColor)
                                }
                            }.padding(.horizontal, 30)
                        }
                    } else {
                        // 已安装 tab —— 复用与待更新一样的 AppGridCard 风格
                        if isScanning && filteredInstalled.isEmpty {
                            VStack(spacing: 14) {
                                ProgressView().scaleEffect(1.2)
                                Text(category == .git ? "正在扫描 Git 仓库…" : "正在加载…").font(.title3).foregroundColor(.gray)
                            }.frame(maxWidth: .infinity, minHeight: 300)
                        } else if filteredInstalled.isEmpty {
                            VStack {
                                Image(systemName: "tray.full").font(.system(size: 50)).foregroundColor(.gray.opacity(0.4))
                                Text("暂无已安装项目").font(.title3).foregroundColor(.gray).padding()
                            }.frame(maxWidth: .infinity, minHeight: 300)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 20)], spacing: 20) {
                                ForEach(filteredInstalled) { app in
                                    NavigationLink(value: app) { AppGridCard(app: app, scanner: scanner, accentColor: accentColor) }.buttonStyle(PlainButtonStyle())
                                }
                            }.padding(.horizontal, 30)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索...")
            .navigationDestination(for: RadarUpdateApp.self) { app in AppDetailView(app: app, scanner: scanner, accentColor: accentColor) }
        }
    }
    
    @ViewBuilder
    private func tabButton(_ title: String, tag: String) -> some View {
        let isSelected = selectedTab == tag
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tag } }) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(isSelected ? accentColor : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())   // 让整个胶囊区域可点击，而非仅文字
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private func upgradeAll() {
        for app in filteredUpdates where !app.isUpgrading && !app.upgraded {
            switch app.category {
            case .appStore: scanner.upgradeMasApp(app)
            case .node: scanner.upgradeNodePackage(app)
            case .brew: scanner.executeAction(action: "update_brew", app: app)
            case .git: scanner.upgradeGitRepo(app)
            case .other: scanner.upgradeOther(app)
            }
        }
    }
}

// MARK: - UI Components

// 带「更新」按钮的卡片（用于待更新列表，不用点进详情就能升级）
struct AppGridCardWithAction: View {
    @ObservedObject var app: RadarUpdateApp
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    @State private var isHovered = false
    
    var body: some View {
        NavigationLink(value: app) {
            HStack(alignment: .top, spacing: 12) {
                // Icon
                if let icon = app.localIcon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 56, height: 56).cornerRadius(13)
                } else if let url = app.logoUrl {
                    CachedAsyncImage(url: url) { fallbackIcon }
                        .frame(width: 56, height: 56).cornerRadius(13)
                } else { fallbackIcon }

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.bestName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundColor(.primary)
                    if let date = app.releaseDate {
                        Text(date).font(.system(size: 11)).foregroundColor(.gray)
                    } else {
                        Text(app.developer ?? app.category.rawValue).font(.system(size: 11)).foregroundColor(.gray)
                    }
                    if let cur = app.currentVersion, let latest = app.latestVersion {
                        Text("\(cur) → \(latest)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(accentColor)
                            .lineLimit(1)
                    }
                    Text(app.releaseNotes ?? app.descriptionText ?? "查看更新内容")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    // Git 项目额外信息：语言 / star / fork / 更新时间
                    if app.category == .git {
                        HStack(spacing: 10) {
                            if let lang = app.language {
                                HStack(spacing: 3) { Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9)); Text(lang).font(.system(size: 10)) }
                                    .foregroundColor(.secondary)
                            }
                            if let stars = app.stars, stars > 0 {
                                HStack(spacing: 2) { Image(systemName: "star").font(.system(size: 9)); Text("\(stars)").font(.system(size: 10)) }
                                    .foregroundColor(.secondary)
                            }
                            if let forks = app.forks, forks > 0 {
                                HStack(spacing: 2) { Image(systemName: "tuningfork").font(.system(size: 9)); Text("\(forks)").font(.system(size: 10)) }
                                    .foregroundColor(.secondary)
                            }
                            if let updated = app.lastUpdated {
                                HStack(spacing: 2) { Image(systemName: "clock").font(.system(size: 9)); Text(updated).font(.system(size: 10)) }
                                    .foregroundColor(.secondary)
                            }
                        }.padding(.top, 1)
                    }
                    if app.category == .other, let kind = app.sourceKind {
                        Text(kind.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(accentColor.opacity(0.12)).clipShape(Capsule())
                            .padding(.top, 2)
                    }
                    // Node 包：运行状态
                    if app.category == .node {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(app.isRunning ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 7, height: 7)
                            Text(app.isRunning ? "运行中" : "未运行")
                                .font(.system(size: 10)).foregroundColor(app.isRunning ? .green : .secondary)
                        }.padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                
                // 内联更新按钮
                VStack {
                    Spacer()
                    if app.upgraded {
                        Text("✓").font(.system(size: 14, weight: .bold)).foregroundColor(.green)
                    } else if app.isUpgrading {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Button(action: {
                            switch app.category {
                            case .appStore: scanner.upgradeMasApp(app)
                            case .node: scanner.upgradeNodePackage(app)
                            case .brew: scanner.executeAction(action: "update_brew", app: app)
                            case .git: scanner.upgradeGitRepo(app)
                            case .other: scanner.upgradeOther(app)
                            }
                        }) {
                            Text("更新")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(accentColor).cornerRadius(12)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor).overlay(accentColor.opacity(0.06))).cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(isHovered ? accentColor : Color.gray.opacity(0.15), lineWidth: isHovered ? 2 : 1))
            .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 12 : 6, y: 4)
            .opacity(app.ignored ? 0.45 : 1.0)
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { isHovered = h } }
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    var fallbackIcon: some View {
        let initial = String(app.bestName.prefix(1)).uppercased()
        let hue = Double(abs(app.name.hashValue) % 360) / 360.0
        return RoundedRectangle(cornerRadius: 13)
            .fill(Color(hue: hue, saturation: 0.5, brightness: 0.85).gradient)
            .frame(width: 56, height: 56)
            .overlay(Text(initial).font(.system(size: 24, weight: .bold)).foregroundColor(.white))
    }
}

// 渲染 README 图片：本地文件用 NSImage 直接加载，网络图用 AsyncImage；加载失败则不显示（不裂图）
struct ReadmeImageView: View {
    let src: String
    var body: some View {
        if src.hasPrefix("http"), let u = URL(string: src) {
            CachedAsyncImage(url: u) { EmptyView() }
                .frame(height: 200).cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.15), lineWidth: 1))
        } else if let nsImg = NSImage(contentsOfFile: src) {
            Image(nsImage: nsImg).resizable().scaledToFit()
                .frame(height: 200).cornerRadius(16)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.gray.opacity(0.15), lineWidth: 1))
        } else {
            EmptyView()
        }
    }
}

// MARK: - UI Components (Original)
struct AppGridCard: View {
    @ObservedObject var app: RadarUpdateApp
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    @State private var isHovered = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            if let icon = app.localIcon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 56, height: 56).cornerRadius(13)
            } else if let url = app.logoUrl {
                CachedAsyncImage(url: url) { fallbackIcon }
                    .frame(width: 56, height: 56).cornerRadius(13)
            } else { fallbackIcon }

            // Text block
            VStack(alignment: .leading, spacing: 3) {
                Text(app.bestName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundColor(.primary)
                if let date = app.releaseDate {
                    Text(date).font(.system(size: 11)).foregroundColor(.gray)
                } else {
                    Text(app.developer ?? app.category.rawValue).font(.system(size: 11)).foregroundColor(.gray)
                }
                if let cur = app.currentVersion, let latest = app.latestVersion {
                    Text("\(cur) → \(latest)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(accentColor)
                        .lineLimit(1)
                }
                // 更新说明摘要
                Text(app.releaseNotes ?? "查看更新内容")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                // Git 项目额外信息：语言 / star / fork / 更新时间
                if app.category == .git {
                    HStack(spacing: 10) {
                        if let lang = app.language {
                            HStack(spacing: 3) { Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9)); Text(lang).font(.system(size: 10)) }
                                .foregroundColor(.secondary)
                        }
                        if let stars = app.stars, stars > 0 {
                            HStack(spacing: 2) { Image(systemName: "star").font(.system(size: 9)); Text("\(stars)").font(.system(size: 10)) }
                                .foregroundColor(.secondary)
                        }
                        if let forks = app.forks, forks > 0 {
                            HStack(spacing: 2) { Image(systemName: "tuningfork").font(.system(size: 9)); Text("\(forks)").font(.system(size: 10)) }
                                .foregroundColor(.secondary)
                        }
                        if let updated = app.lastUpdated {
                            HStack(spacing: 2) { Image(systemName: "clock").font(.system(size: 9)); Text(updated).font(.system(size: 10)) }
                                .foregroundColor(.secondary)
                        }
                    }.padding(.top, 1)
                }
                // Node 包：运行状态指示
                if app.category == .node {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(app.isRunning ? Color.green : Color.gray.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(app.isRunning ? "运行中" : "未运行")
                            .font(.system(size: 10)).foregroundColor(app.isRunning ? .green : .secondary)
                        if let port = app.servicePort {
                            Text(":\(port)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }.padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            // Node 包：列表内联启停按钮
            if app.category == .node {
                VStack {
                    Spacer()
                    if app.isStartingOrStopping {
                        ProgressView().scaleEffect(0.7).frame(width: 28, height: 28)
                    } else if app.isRunning {
                        HStack(spacing: 6) {
                            Button(action: { scanner.stopNodeService(app) }) {
                                Text("停止").font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.red.opacity(0.8)).cornerRadius(10)
                            }.buttonStyle(PlainButtonStyle())
                            if app.servicePort != nil {
                                Button(action: { scanner.openNodeServiceUI(app) }) {
                                    Text("打开").font(.system(size: 12, weight: .medium))
                                        .foregroundColor(accentColor)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(accentColor.opacity(0.12)).cornerRadius(10)
                                }.buttonStyle(PlainButtonStyle())
                            }
                        }
                    } else {
                        Button(action: { scanner.startNodeService(app) }) {
                            Text("启动").font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.green).cornerRadius(10)
                        }.buttonStyle(PlainButtonStyle())
                    }
                    Spacer()
                }
            }
            // Git 项目：打开访达
            if app.category == .git {
                VStack {
                    Spacer()
                    Button(action: { scanner.revealInFinder(app) }) {
                        Text("打开").font(.system(size: 12, weight: .medium))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(accentColor.opacity(0.12)).cornerRadius(10)
                    }.buttonStyle(PlainButtonStyle())
                    Spacer()
                }
            }
            // App Store / Homebrew cask / 其他独立应用：打开应用（formula 是 CLI 无 GUI，不显示）
            if ((app.category == .appStore) || (app.category == .brew && app.isCask) || (app.category == .other && app.sourceKind == .sparkleApp)) && app.upgraded {
                VStack {
                    Spacer()
                    Button(action: { scanner.launchApp(app) }) {
                        Text("打开").font(.system(size: 12, weight: .medium))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(accentColor.opacity(0.12)).cornerRadius(10)
                    }.buttonStyle(PlainButtonStyle())
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).overlay(accentColor.opacity(0.06))).cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isHovered ? accentColor : Color.gray.opacity(0.15), lineWidth: isHovered ? 2 : 1))
        .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 12 : 6, y: 4)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { isHovered = h } }
    }
    var fallbackIcon: some View {
        // 彩色首字母头像（类似微信群没头像时的字母方块），零网络请求
        let initial = String(app.bestName.prefix(1)).uppercased()
        let hue = Double(abs(app.name.hashValue) % 360) / 360.0
        return RoundedRectangle(cornerRadius: 13)
            .fill(Color(hue: hue, saturation: 0.5, brightness: 0.85).gradient)
            .frame(width: 56, height: 56)
            .overlay(Text(initial).font(.system(size: 24, weight: .bold)).foregroundColor(.white))
    }
}

struct AppDetailView: View {
    @ObservedObject var app: RadarUpdateApp
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top, spacing: 24) {
                    if let icon = app.localIcon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 120).cornerRadius(26) }
                    else if let url = app.logoUrl { CachedAsyncImage(url: url) { fallbackIcon }.frame(width: 120, height: 120).cornerRadius(26) } else { fallbackIcon }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(app.bestName).font(.system(size: 32, weight: .bold))
                        Text(app.developer ?? app.category.rawValue).font(.title3).foregroundColor(.gray)
                        HStack(spacing: 12) {
                            if app.upgraded {
                                if app.category == .node || app.category == .git || (app.category == .other && app.sourceKind == .cliTool) {
                                    // 命令行工具 / Git 仓库
                                    Text("✅ 已是最新").font(.headline).foregroundColor(.green)
                                        .padding(.horizontal, 24).padding(.vertical, 10)
                                    // Node 包：启动/停止按钮
                                    if app.category == .node {
                                        if app.isStartingOrStopping {
                                            ProgressView().scaleEffect(0.7).frame(width: 24, height: 24)
                                        } else if app.isRunning {
                                            Button(action: { scanner.stopNodeService(app) }) {
                                                Label("停止", systemImage: "stop.circle")
                                                    .font(.subheadline).foregroundColor(.white)
                                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                                    .background(Color.red.opacity(0.85)).cornerRadius(18)
                                            }.buttonStyle(PlainButtonStyle())
                                            if app.servicePort != nil {
                                                Button(action: { scanner.openNodeServiceUI(app) }) {
                                                    Label("打开", systemImage: "globe")
                                                        .font(.subheadline).foregroundColor(accentColor)
                                                        .padding(.horizontal, 16).padding(.vertical, 9)
                                                        .background(accentColor.opacity(0.12)).cornerRadius(18)
                                                }.buttonStyle(PlainButtonStyle())
                                            }
                                        } else {
                                            Button(action: { scanner.startNodeService(app) }) {
                                                Label("启动", systemImage: "play.circle")
                                                    .font(.subheadline).foregroundColor(.white)
                                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                                    .background(Color.green).cornerRadius(18)
                                            }.buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                } else {
                                    // App Store / Homebrew / 独立应用，有 GUI，显示「打开」
                                    Button(action: { scanner.launchApp(app) }) {
                                        Text("打开")
                                            .font(.headline).foregroundColor(.white)
                                            .padding(.horizontal, 28).padding(.vertical, 10)
                                            .background(accentColor).cornerRadius(20)
                                    }.buttonStyle(PlainButtonStyle())
                                }
                            } else {
                                Button(action: {
                                    switch app.category {
                                    case .appStore: scanner.upgradeMasApp(app)
                                    case .node: scanner.upgradeNodePackage(app)
                                    case .brew: scanner.executeAction(action: "update_brew", app: app)
                                    case .git: scanner.upgradeGitRepo(app)
                                    case .other: scanner.upgradeOther(app)
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        if app.isUpgrading { ProgressView().scaleEffect(0.6).frame(width: 14, height: 14) }
                                        Text(app.isUpgrading ? "升级中…" : (app.category == .git ? "拉取更新 (git pull)" : (app.sourceKind == .sparkleApp ? "打开并更新" : "升级到最新版")))
                                            .font(.headline).foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 24).padding(.vertical, 10)
                                    .background(accentColor).cornerRadius(20).opacity(app.isUpgrading ? 0.7 : 1.0)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(app.isUpgrading)
                                
                                if app.category == .appStore {
                                    Button(action: { scanner.openInAppStore(app: app) }) {
                                        Text("在 App Store 中打开").font(.subheadline).foregroundColor(accentColor)
                                    }.buttonStyle(PlainButtonStyle())
                                }
                            }
                            
                            // Git 项目：手动处理入口（更新失败/分叉时可在终端 merge，或在访达中查看）
                            if app.category == .git {
                                Button(action: { scanner.openInTerminal(app) }) {
                                    Label("终端", systemImage: "terminal")
                                        .font(.subheadline).foregroundColor(accentColor)
                                        .padding(.horizontal, 16).padding(.vertical, 9)
                                        .background(accentColor.opacity(0.12)).cornerRadius(18)
                                }.buttonStyle(PlainButtonStyle()).help("在终端打开项目目录")
                                Button(action: { scanner.revealInFinder(app) }) {
                                    Label("访达", systemImage: "folder")
                                        .font(.subheadline).foregroundColor(accentColor)
                                        .padding(.horizontal, 16).padding(.vertical, 9)
                                        .background(accentColor.opacity(0.12)).cornerRadius(18)
                                }.buttonStyle(PlainButtonStyle()).help("在访达中显示项目目录")
                            }
                            
                            // 忽略按钮：本次不再提示更新，不计入角标
                            if !app.upgraded && !app.ignored {
                                Button(action: { scanner.setIgnored(app, true) }) {
                                    Label("忽略更新", systemImage: "eye.slash")
                                        .font(.subheadline).foregroundColor(accentColor)
                                        .padding(.horizontal, 16).padding(.vertical, 9)
                                        .background(accentColor.opacity(0.12)).cornerRadius(18)
                                }.buttonStyle(PlainButtonStyle()).help("忽略本次更新，不再计入角标")
                            }
                            if app.ignored {
                                Button(action: { scanner.setIgnored(app, false) }) {
                                    Label("取消忽略", systemImage: "eye")
                                        .font(.subheadline).foregroundColor(accentColor)
                                        .padding(.horizontal, 16).padding(.vertical, 9)
                                        .background(accentColor.opacity(0.12)).cornerRadius(18)
                                }.buttonStyle(PlainButtonStyle()).help("恢复提醒")
                            }
                            
                            if let msg = app.upgradeMessage {
                                Text(msg).font(.subheadline)
                                    .foregroundColor(
                                        msg.contains("失败") || msg.contains("错误") ? .red :
                                        (msg.contains("⚠️") || msg.contains("手动") || msg.contains("取消") ? .orange : .green)
                                    )
                            }
                        }.padding(.top, 4)
                    }
                    Spacer()
                }
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(statItems.enumerated()), id: \.offset) { idx, item in
                        if idx > 0 { statDivider }
                        statItem(title: item.title, subtitle: item.subtitle, icon: item.icon)
                    }
                }.padding(.vertical, 10)
                Divider()
                if app.category == .node || app.category == .brew, let desc = app.descriptionText, !desc.isEmpty {
                    Text(desc).font(.body).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if app.category == .node || app.category == .brew || app.category == .git, let hp = app.homepage {
                    Link(destination: hp) {
                        Label(hp.absoluteString, systemImage: "link")
                            .font(.system(size: 14))
                            .padding(.vertical, 4)
                    }.foregroundColor(accentColor)
                }
                // 升级说明（GitHub Release notes / Git 提交日志，按需加载）
                if (app.category == .node || app.category == .brew || app.category == .git), let changelog = app.changelogNotes {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(app.category == .git ? "待拉取的提交" : "升级说明").font(.title2).bold()
                        if app.category != .git, let ver = app.latestVersion { Text("v\(ver)").font(.subheadline).foregroundColor(.gray) }
                        Text(changelog).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Git 项目：README 加载中的小提示（加载完自动消失）
                if app.category == .git && !app.readmeLoaded {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.7)
                        Text("正在加载项目说明…").font(.subheadline).foregroundColor(.gray)
                    }.padding(.vertical, 8)
                }
                // Git 项目：预览放在「项目说明」上面
                if app.category == .git && !app.screenshotUrls.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("预览").font(.title2).bold()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                ForEach(app.screenshotUrls, id: \.self) { surl in
                                    ReadmeImageView(src: surl)
                                }
                            }
                        }
                    }
                }
                if let notes = app.releaseNotes {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(app.category == .node ? "说明" : (app.category == .git ? "项目说明 (README)" : "新功能")).font(.title2).bold()
                            Spacer()
                            if let date = app.releaseDate { Text(date).font(.subheadline).foregroundColor(.gray) }
                        }
                        if app.category != .node && app.category != .git, let latest = app.latestVersion { Text("版本 \(latest)").font(.subheadline).foregroundColor(.gray) }
                        Text(notes).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // 其它渠道（如 App Store）：预览在「新功能」之后
                if app.category != .git && !app.screenshotUrls.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("预览").font(.title2).bold()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                ForEach(app.screenshotUrls, id: \.self) { surl in
                                    ReadmeImageView(src: surl)
                                }
                            }
                        }
                    }
                }
            }.padding(40)
        }
        .navigationTitle(app.bestName)
        .onAppear {
            // 按需加载富信息（GitHub README / Release notes / 本地 README）
            if app.category == .node { scanner.fetchChangelog(for: app) }
            if app.category == .brew { scanner.fetchBrewDetail(for: app) }
            if app.category == .git { scanner.fetchGitReadme(for: app); scanner.fetchGitStats(for: app) }
        }
    }
    var fallbackIcon: some View {
        let initial = String(app.bestName.prefix(1)).uppercased()
        let hue = Double(abs(app.name.hashValue) % 360) / 360.0
        return RoundedRectangle(cornerRadius: 26)
            .fill(Color(hue: hue, saturation: 0.5, brightness: 0.85).gradient)
            .frame(width: 120, height: 120)
            .overlay(Text(initial).font(.system(size: 52, weight: .bold)).foregroundColor(.white))
    }
    var statDivider: some View { Divider().frame(height: 36).padding(.horizontal, 4) }
    func formatRatingCount(_ count: Int) -> String {
        if count >= 10000 { return String(format: "%.1f万", Double(count) / 10000.0) }
        return "\(count)"
    }
    // 按官方 App Store 那排的列顺序构建可用信息项：评分 / 年龄分级 / 类别 / 开发者 / 语言 / 大小
    // （评分、排行榜仅原生客户端的内部聚合接口才有，公开 API 取不到，无数据时自动省略）
    private var statItems: [(title: String, subtitle: String, icon: String)] {
        // Node 全局包：展示版本/日期/许可证等有意义的信息
        if app.category == .node {
            var items: [(String, String, String)] = []
            if let c = app.currentVersion { items.append((c, "当前版本", "number")) }
            if let l = app.latestVersion { items.append((l, "最新版本", "arrow.up.circle")) }
            if let d = app.releaseDate { items.append((d, "发布日期", "calendar")) }
            if let lic = app.license { items.append((lic, "许可证", "doc.text")) }
            if let dev = app.developer, !dev.isEmpty, dev != "npm 全局包" {
                items.append((dev, "维护者", "person.crop.circle"))
            }
            return items
        }
        // Homebrew 包：展示版本/许可证/维护者
        if app.category == .brew {
            var items: [(String, String, String)] = []
            if let c = app.currentVersion { items.append((c, "当前版本", "number")) }
            if let l = app.latestVersion, l != app.currentVersion { items.append((l, "最新版本", "arrow.up.circle")) }
            if let lic = app.license { items.append((lic, "许可证", "doc.text")) }
            if let dev = app.developer, !dev.isEmpty { items.append((dev, "维护者", "person.crop.circle")) }
            return items
        }
        // Git 项目：本地 commit / 远程 commit / owner
        if app.category == .git {
            var items: [(String, String, String)] = []
            if let c = app.currentVersion { items.append((c, "本地 commit", "number")) }
            if let l = app.latestVersion, l != app.currentVersion { items.append((l, "远程 commit", "arrow.up.circle")) }
            if let dev = app.developer, !dev.isEmpty { items.append((dev, "GitHub", "person.crop.circle")) }
            return items
        }
        var items: [(String, String, String)] = []
        if let rating = app.averageUserRating, rating > 0, let count = app.userRatingCount, count > 0 {
            items.append((String(format: "%.1f", rating), "\(formatRatingCount(count))个评分", "star.fill"))
        }
        if let cr = app.contentRating {
            items.append((cr, "年龄分级", "person.crop.square"))
        }
        if let genre = app.primaryGenre {
            items.append((genre, "类别", "square.grid.2x2"))
        }
        if let dev = app.developer, !dev.isEmpty {
            items.append((dev, "开发者", "person.crop.circle"))
        }
        if let langInfo = app.languageDisplay {
            items.append((langInfo.primary, langInfo.extraCount > 0 ? "+ \(langInfo.extraCount) 种语言" : "语言", "globe"))
        }
        if let size = app.sizeStr {
            items.append((size, "大小", "externaldrive"))
        }
        return items
    }
    func statItem(title: String, subtitle: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title3).bold().lineLimit(1)
            HStack(spacing: 3) {
                Image(systemName: icon).font(.caption2).foregroundColor(.gray)
                Text(subtitle).font(.caption).foregroundColor(.gray).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

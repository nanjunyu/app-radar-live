import SwiftUI
import AppKit

// MARK: - Update Center (Grid)
struct UpdateCenterView: View {
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    @State private var searchText = ""
    @State private var selectedTab = "installed"  // 默认显示「已安装」
    @State private var selectedCategoryTab = "all" // 当前选中的分类 Tab: all, appStore, brew, node, git, other
    
    var title: String { "应用与更新" }
    
    var filteredUpdates: [RadarUpdateApp] {
        var res = scanner.updates
        if let targetCategory = categoryMap(selectedCategoryTab) {
            res = res.filter { $0.category == targetCategory }
        }
        if !searchText.isEmpty { res = res.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
        return res
    }
    
    var filteredInstalled: [RadarUpdateApp] {
        var res = scanner.installed
        if let targetCategory = categoryMap(selectedCategoryTab) {
            res = res.filter { $0.category == targetCategory }
        }
        if !searchText.isEmpty { res = res.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
        return res
    }
    
    // 是否正在扫描
    var isScanning: Bool {
        if selectedCategoryTab == "all" {
            return scanner.isScanningUpdates || scanner.isScanningGit || scanner.isScanningOther
        }
        switch selectedCategoryTab {
        case "git": return scanner.isScanningGit
        case "other": return scanner.isScanningOther
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
                    
                    // 分类 Tab 栏
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            categoryTabButton("全部", tag: "all")
                            categoryTabButton("App Store", tag: "appStore")
                            categoryTabButton("Homebrew", tag: "brew")
                            if scanner.hasNpm {
                                categoryTabButton("Node.js", tag: "node")
                            }
                            if scanner.hasGit {
                                categoryTabButton("Git 项目", tag: "git")
                            }
                            if scanner.hasOther {
                                categoryTabButton("其他", tag: "other")
                            }
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 4)
                    }
                    
                    if selectedTab == "pending" {
                        if isScanning && filteredUpdates.isEmpty {
                            VStack(spacing: 14) {
                                ProgressView().scaleEffect(1.2)
                                Text(selectedCategoryTab == "git" ? "正在扫描 Git 仓库…" : (selectedCategoryTab == "all" ? "正在全局扫描…" : "正在检查更新…")).font(.title3).foregroundColor(.gray)
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
                                Text(selectedCategoryTab == "git" ? "正在扫描 Git 仓库…" : (selectedCategoryTab == "all" ? "正在全局扫描…" : "正在加载…")).font(.title3).foregroundColor(.gray)
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
    
    @ViewBuilder
    private func categoryTabButton(_ title: String, tag: String) -> some View {
        let isSelected = selectedCategoryTab == tag
        let count = getAppCount(for: tag)
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategoryTab = tag
            }
        }) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? accentColor : .primary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isSelected ? .white : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(isSelected ? accentColor : Color.gray.opacity(0.18))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? accentColor.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? accentColor.opacity(0.3) : Color.gray.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    private func getAppCount(for tag: String) -> Int {
        var allApps = (selectedTab == "pending" ? scanner.updates : scanner.installed)
        if selectedTab == "pending" {
            // 只统计真正待更新的（过滤掉已忽略和已升级的项目）
            allApps = allApps.filter { !$0.upgraded && !$0.ignored }
        }
        let filteredByCategory: [RadarUpdateApp]
        if let targetCategory = categoryMap(tag) {
            filteredByCategory = allApps.filter { $0.category == targetCategory }
        } else {
            filteredByCategory = allApps
        }
        
        if searchText.isEmpty {
            return filteredByCategory.count
        } else {
            return filteredByCategory.filter { $0.name.localizedCaseInsensitiveContains(searchText) }.count
        }
    }
    
    private func categoryMap(_ tag: String) -> UpdateCategory? {
        switch tag {
        case "appStore": return .appStore
        case "brew": return .brew
        case "node": return .node
        case "git": return .git
        case "other": return .other
        default: return nil
        }
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
                    HStack(alignment: .center, spacing: 6) {
                        Text(app.bestName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).truncationMode(.tail)
                            .foregroundColor(.primary)
                        Text(app.category.cleanName)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .foregroundColor(.white)
                            .background(app.category.color.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    if let date = app.releaseDate {
                        Text(date).font(.system(size: 11)).foregroundColor(.gray)
                    } else {
                        Text(app.developer ?? app.category.cleanName).font(.system(size: 11)).foregroundColor(.gray)
                    }
                    if let cur = app.currentVersion, let latest = app.latestVersion {
                        Text("\(cur) → \(latest)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(accentColor)
                            .lineLimit(1)
                    }
                    if let msg = app.upgradeMessage {
                        Text(msg)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(
                                msg.contains("失败") || msg.contains("错误") || msg.contains("⚠️") ? .red :
                                (msg.contains("成功") || msg.contains("✅") ? .green : .orange)
                            )
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    } else {
                        Text(app.releaseNotes ?? app.descriptionText ?? "查看更新内容")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
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
            CachedAsyncImage(url: u) {
                // 加载占位符：显示轻量灰色圆角矩形与微型转轮，防止宽度塌陷为 0，符合高级视觉设计
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.08))
                    .frame(width: 320, height: 200)
                    .overlay(ProgressView().scaleEffect(0.8))
            } failure: {
                // 失败占位符：优雅的失效卡片提示，防止一直转圈圈
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.04))
                    .frame(width: 320, height: 200)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title)
                                .foregroundColor(.gray.opacity(0.5))
                            Text("预览图加载失败").font(.caption).foregroundColor(.gray.opacity(0.5))
                        }
                    )
            }
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
                HStack(alignment: .center, spacing: 6) {
                    Text(app.bestName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundColor(.primary)
                    Text(app.category.cleanName)
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .foregroundColor(.white)
                        .background(app.category.color.opacity(0.85))
                        .clipShape(Capsule())
                }
                if let date = app.releaseDate {
                    Text(date).font(.system(size: 11)).foregroundColor(.gray)
                } else {
                    Text(app.developer ?? app.category.cleanName).font(.system(size: 11)).foregroundColor(.gray)
                }
                if let cur = app.currentVersion {
                    let versionText: String = {
                        if let latest = app.latestVersion, latest != cur {
                            return "\(cur) → \(latest)"
                        } else {
                            return "版本 \(cur)"
                        }
                    }()
                    Text(versionText)
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
                // Node 包 & Git 项目 & Brew 服务：运行状态指示
                if app.category == .node || app.category == .git || (app.category == .brew && app.isBrewService) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(app.isRunning ? Color.green : Color.gray.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(app.isRunning ? "运行中" : "已停止")
                            .font(.system(size: 10)).foregroundColor(app.isRunning ? .green : .secondary)
                        if let port = app.servicePort {
                            Text(":\(port)").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }.padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            // Node 包 & Git 项目 & Brew 服务：列表内联启停与打开控制
            if app.category == .node || app.category == .git || (app.category == .brew && app.isBrewService) {
                VStack {
                    Spacer()
                    if app.isStartingOrStopping {
                        ProgressView().scaleEffect(0.7).frame(width: 28, height: 28)
                    } else if app.isRunning {
                        HStack(spacing: 6) {
                            Button(action: {
                                if app.category == .node {
                                    scanner.stopNodeService(app)
                                } else if app.category == .brew {
                                    scanner.stopBrewService(app)
                                } else {
                                    scanner.stopGitProject(app)
                                }
                            }) {
                                Text("停止").font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.red.opacity(0.8)).cornerRadius(10)
                            }.buttonStyle(PlainButtonStyle())
                            if app.servicePort != nil {
                                Button(action: {
                                    if app.category == .node {
                                        scanner.openNodeServiceUI(app)
                                    } else if app.category == .brew {
                                        scanner.openBrewServiceUI(app)
                                    } else {
                                        scanner.openGitProjectUI(app)
                                    }
                                }) {
                                    Text("控制台").font(.system(size: 12, weight: .medium))
                                        .foregroundColor(accentColor)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(accentColor.opacity(0.12)).cornerRadius(10)
                                }.buttonStyle(PlainButtonStyle())
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Button(action: {
                                if app.category == .node {
                                    scanner.startNodeService(app)
                                } else if app.category == .brew {
                                    scanner.startBrewService(app)
                                } else {
                                    scanner.startGitProject(app)
                                }
                            }) {
                                Text("启动").font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.green).cornerRadius(10)
                            }.buttonStyle(PlainButtonStyle())
                            if app.category == .git {
                                Button(action: { scanner.revealInFinder(app) }) {
                                    Text("访达").font(.system(size: 12, weight: .medium))
                                        .foregroundColor(accentColor)
                                        .padding(.horizontal, 10).padding(.vertical, 4)
                                        .background(accentColor.opacity(0.12)).cornerRadius(10)
                                }.buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
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
    
    @State private var showingForceUpdateSheet = false
    @State private var forceUpdateInput = ""
    
    private func confirmForceUpdate() {
        showingForceUpdateSheet = false
        forceUpdateInput = ""
        scanner.forceUpgradeGitRepo(app)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top, spacing: 24) {
                    if let icon = app.localIcon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 120).cornerRadius(26) }
                    else if let url = app.logoUrl { CachedAsyncImage(url: url) { fallbackIcon }.frame(width: 120, height: 120).cornerRadius(26) } else { fallbackIcon }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(app.bestName).font(.system(size: 32, weight: .bold))
                        Text(app.developer ?? app.category.cleanName).font(.title3).foregroundColor(.gray)
                        HStack(spacing: 12) {
                            if app.upgraded {
                                if app.category == .node || app.category == .git || (app.category == .brew && app.isBrewService) || (app.category == .other && app.sourceKind == .cliTool) {
                                    // 命令行工具 / Git 仓库 / Brew 服务
                                    Text("✅ 已是最新").font(.headline).foregroundColor(.green)
                                        .padding(.horizontal, 24).padding(.vertical, 10)
                                    // Node 包 & Git 项目 & Brew 服务：启动/停止与控制台按钮
                                    if app.category == .node || app.category == .git || (app.category == .brew && app.isBrewService) {
                                        if app.isStartingOrStopping {
                                            ProgressView().scaleEffect(0.7).frame(width: 24, height: 24)
                                        } else if app.isRunning {
                                            HStack(spacing: 12) {
                                                Button(action: {
                                                    if app.category == .node {
                                                        scanner.stopNodeService(app)
                                                    } else if app.category == .brew {
                                                        scanner.stopBrewService(app)
                                                    } else {
                                                        scanner.stopGitProject(app)
                                                    }
                                                }) {
                                                    Label("停止", systemImage: "stop.circle")
                                                        .font(.subheadline).foregroundColor(.white)
                                                        .padding(.horizontal, 16).padding(.vertical, 9)
                                                        .background(Color.red.opacity(0.85)).cornerRadius(18)
                                                }.buttonStyle(PlainButtonStyle())
                                                if app.servicePort != nil {
                                                    Button(action: {
                                                        if app.category == .node {
                                                            scanner.openNodeServiceUI(app)
                                                        } else {
                                                            scanner.openGitProjectUI(app)
                                                        }
                                                    }) {
                                                        Label("控制台", systemImage: "globe")
                                                            .font(.subheadline).foregroundColor(accentColor)
                                                            .padding(.horizontal, 16).padding(.vertical, 9)
                                                            .background(accentColor.opacity(0.12)).cornerRadius(18)
                                                    }.buttonStyle(PlainButtonStyle())
                                                }
                                            }
                                        } else {
                                            Button(action: {
                                                if app.category == .node {
                                                    scanner.startNodeService(app)
                                                } else if app.category == .brew {
                                                    scanner.startBrewService(app)
                                                } else {
                                                    scanner.startGitProject(app)
                                                }
                                            }) {
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
                                        Label("打开", systemImage: "arrow.up.forward.app")
                                            .font(.subheadline).foregroundColor(accentColor)
                                            .padding(.horizontal, 16).padding(.vertical, 9)
                                            .background(accentColor.opacity(0.12)).cornerRadius(18)
                                    }.buttonStyle(PlainButtonStyle())
                                }
                                
                                // 取消忽略按钮
                                if app.ignored {
                                    Button(action: { scanner.setIgnored(app, false) }) {
                                        Label("取消忽略", systemImage: "eye")
                                            .font(.subheadline).foregroundColor(accentColor)
                                            .padding(.horizontal, 16).padding(.vertical, 9)
                                            .background(accentColor.opacity(0.12)).cornerRadius(18)
                                    }.buttonStyle(PlainButtonStyle()).help("恢复提醒")
                                }
                                
                                // Git 项目：已是最新状态下的手动处理入口（终端、访达）
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
                            } else {
                                // ===== 未升级状态 =====
                                
                                // 1. 拉取更新 / 升级按钮
                                Button(action: {
                                    switch app.category {
                                    case .appStore: scanner.upgradeMasApp(app)
                                    case .node: scanner.upgradeNodePackage(app)
                                    case .brew: scanner.executeAction(action: "update_brew", app: app)
                                    case .git: scanner.upgradeGitRepo(app)
                                    case .other: scanner.upgradeOther(app)
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        if app.isUpgrading {
                                            ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                                        } else {
                                            Image(systemName: "arrow.down.circle").font(.system(size: 13, weight: .medium))
                                        }
                                        Text(app.isUpgrading ? "升级中…" : (app.category == .git ? "拉取更新" : (app.sourceKind == .sparkleApp ? "打开并更新" : "升级到最新版")))
                                            .font(.subheadline).bold()
                                    }
                                    .foregroundColor(accentColor)
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .background(accentColor.opacity(0.12)).cornerRadius(18)
                                    .opacity(app.isUpgrading ? 0.7 : 1.0)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(app.isUpgrading)
                                
                                // 2. 强制更新 (仅 Git 项目且未升级)
                                if app.category == .git {
                                    Button(action: { showingForceUpdateSheet = true }) {
                                        Label("强制更新", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                            .font(.subheadline).foregroundColor(accentColor)
                                            .padding(.horizontal, 16).padding(.vertical, 9)
                                            .background(accentColor.opacity(0.12)).cornerRadius(18)
                                    }.buttonStyle(PlainButtonStyle()).help("放弃本地修改，强制以远端为准")
                                }
                                
                                // 3. 忽略更新 / 取消忽略按钮
                                if !app.ignored {
                                    Button(action: { scanner.setIgnored(app, true) }) {
                                        Label("忽略更新", systemImage: "eye.slash")
                                            .font(.subheadline).foregroundColor(accentColor)
                                            .padding(.horizontal, 16).padding(.vertical, 9)
                                            .background(accentColor.opacity(0.12)).cornerRadius(18)
                                    }.buttonStyle(PlainButtonStyle()).help("忽略本次更新，不再计入角标")
                                } else {
                                    Button(action: { scanner.setIgnored(app, false) }) {
                                        Label("取消忽略", systemImage: "eye")
                                            .font(.subheadline).foregroundColor(accentColor)
                                            .padding(.horizontal, 16).padding(.vertical, 9)
                                            .background(accentColor.opacity(0.12)).cornerRadius(18)
                                    }.buttonStyle(PlainButtonStyle()).help("恢复提醒")
                                }
                                
                                // 4. 终端 & 访达 (仅 Git 项目)
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
                                
                                if app.category == .appStore {
                                    Button(action: { scanner.openInAppStore(app: app) }) {
                                        Text("在 App Store 中打开").font(.subheadline).foregroundColor(accentColor)
                                    }.buttonStyle(PlainButtonStyle())
                                }
                            }
                            
                        }.padding(.top, 4)
                        
                        if let msg = app.upgradeMessage {
                            let isRedundantSuccess = app.upgraded && msg.contains("✅") && (app.category == .git || app.category == .node || (app.category == .other && app.sourceKind == .cliTool))
                            if !isRedundantSuccess {
                                Text(msg)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(msg.contains("✅") ? .green : .red)
                                    .padding(.top, 4)
                            }
                        }
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
                // 统一预览大图显示：无论渠道，只要有预览图，都统一排列在说明/项目说明之上，保持风格一致
                if !app.screenshotUrls.isEmpty {
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
                        MarkdownRenderer(markdown: notes)
                    }
                }
            }.padding(40)
        }
        .navigationTitle(app.bestName)
        .onAppear {
            // 按需加载富信息（GitHub README / Release notes / 本地 README）
            if app.category == .node { scanner.fetchChangelog(for: app) }
            if app.category == .brew { scanner.fetchBrewDetail(for: app); scanner.refreshBrewServicesStatus() }
            if app.category == .git { scanner.fetchGitReadme(for: app); scanner.fetchGitStats(for: app) }
        }
        .sheet(isPresented: $showingForceUpdateSheet) {
            VStack(alignment: .leading, spacing: 18) {
                // Header Row
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.red)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("强制更新确认")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primary)
                        Text(app.bestName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                
                // Warning Callout Card
                VStack(alignment: .leading, spacing: 8) {
                    Text("⚠️ 高危操作警告")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.red)
                    Text("强制更新将放弃本地所有修改（包括未提交的修改、暂存的改动和分叉提交），本地代码会被完全重置为远程仓库的状态。此操作不可撤销，请务必确认！")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color.red.opacity(0.05))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.red.opacity(0.12), lineWidth: 1)
                )
                
                // Name Copy Panel
                VStack(alignment: .leading, spacing: 8) {
                    Text("请复制或手动输入项目名称以确认：")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text(app.bestName)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.red)
                            .textSelection(.enabled) // Native selectable and copyable text!
                        
                        Spacer()
                        
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(app.bestName, forType: .string)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("点击复制").font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(accentColor.opacity(0.12))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .help("复制项目名称")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.06))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                    )
                }
                
                // Text Field Input
                TextField("在此粘贴或输入项目名称", text: $forceUpdateInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit {
                        if forceUpdateInput == app.bestName {
                            confirmForceUpdate()
                        }
                    }
                
                // Action Buttons Row
                HStack(spacing: 12) {
                    Spacer()
                    
                    Button("取消") {
                        showingForceUpdateSheet = false
                        forceUpdateInput = ""
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    
                    Button(action: confirmForceUpdate) {
                        Text("确认强制更新")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(forceUpdateInput == app.bestName ? Color.red : Color.gray.opacity(0.3))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(forceUpdateInput != app.bestName)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 440)
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
        // Homebrew 包：展示版本/最新版本/发布日期/许可证/维护者，保持与 Node.js 风格完全一致
        if app.category == .brew {
            var items: [(String, String, String)] = []
            if let c = app.currentVersion { items.append((c, "当前版本", "number")) }
            if let l = app.latestVersion { items.append((l, "最新版本", "arrow.up.circle")) }
            if let d = app.releaseDate { items.append((d, "发布日期", "calendar")) }
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

// 智能 Markdown 说明渲染器：支持 H1, H2, H3 标题大小粗细变化、列表符号、代码块灰色圆角容器及行内样式解析
struct MarkdownRenderer: View {
    let markdown: String
    
    var body: some View {
        let lines = markdown.components(separatedBy: .newlines)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseBlocks(lines), id: \.id) { block in
                renderBlock(block)
            }
        }
    }
    
    enum BlockType {
        case h1, h2, h3, paragraph, bullet, codeBlock(String)
    }
    
    struct Block: Identifiable {
        let id = UUID()
        let type: BlockType
        let text: String
    }
    
    private func parseBlocks(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var inCodeBlock = false
        var codeContent = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(Block(type: .codeBlock(codeContent), text: ""))
                    codeContent = ""
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }
            
            if inCodeBlock {
                codeContent += line + "\n"
                continue
            }
            
            if trimmed.isEmpty {
                continue
            }
            
            if trimmed.hasPrefix("# ") {
                blocks.append(Block(type: .h1, text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(Block(type: .h2, text: String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("### ") {
                blocks.append(Block(type: .h3, text: String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("- ") {
                blocks.append(Block(type: .bullet, text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("* ") {
                blocks.append(Block(type: .bullet, text: String(trimmed.dropFirst(2))))
            } else {
                blocks.append(Block(type: .paragraph, text: line))
            }
        }
        
        if inCodeBlock && !codeContent.isEmpty {
            blocks.append(Block(type: .codeBlock(codeContent), text: ""))
        }
        
        return blocks
    }
    
    private func renderBlock(_ block: Block) -> some View {
        Group {
            switch block.type {
            case .h1:
                renderText(block.text)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
            case .h2:
                renderText(block.text)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
            case .h3:
                renderText(block.text)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            case .bullet:
                HStack(alignment: .top, spacing: 6) {
                    Text("•")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                    renderText(block.text)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                }
                .padding(.leading, 8)
            case .paragraph:
                renderText(block.text)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundColor(.primary)
            case .codeBlock(let code):
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(12)
                }
                .background(Color.gray.opacity(0.06))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.12), lineWidth: 1)
                )
                .padding(.vertical, 4)
            }
        }
    }
    
    private func renderText(_ text: String) -> Text {
        if let attrStr = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attrStr)
        }
        return Text(text)
    }
}

import SwiftUI
import AppKit

enum SettingsTab: String, CaseIterable {
    case general = "通用"
    case about = "关于"
}

struct SettingsView: View {
    @Binding var themeColorHex: String
    var accentColor: Color
    @ObservedObject var updater: AppUpdater

    @State private var selectedTab: SettingsTab = .general
    @State private var showChangelog = false

    // 通用设置项
    @AppStorage("autoCheckUpdate") private var autoCheckUpdate = true
    @AppStorage("showUpdateBadge") private var showUpdateBadge = true
    @AppStorage("hideDockIcon") private var hideDockIcon = false
    @AppStorage("closeWindowBehavior") private var closeWindowBehavior = "minimize"  // "minimize", "ask", "quit"
    @AppStorage("refreshInterval") private var refreshInterval = 5  // 进程刷新间隔(秒)
    @AppStorage("launchAtLogin") private var launchAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题行
            HStack(alignment: .center) {
                Text("应用设置")
                    .font(.system(size: 26, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 20)

            // Tab 切换栏 — 居中 + 统一胶囊包裹
            HStack {
                Spacer()
                HStack(spacing: 2) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Button(action: { selectedTab = tab }) {
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(selectedTab == tab ? .white : .primary.opacity(0.7))
                                .padding(.horizontal, 20).padding(.vertical, 8)
                                .background(selectedTab == tab ? accentColor : Color.clear)
                                .cornerRadius(8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.15), lineWidth: 1))
                Spacer()
            }
            .padding(.bottom, 24)

            // 小标题：当前 tab
            HStack(spacing: 6) {
                Rectangle().fill(accentColor).frame(width: 3, height: 14).cornerRadius(1.5)
                Text(selectedTab.rawValue).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 12)

            // 内容区
            ScrollView {
                Group {
                    switch selectedTab {
                    case .general: generalTab
                    case .about: aboutTab
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showChangelog) {
            ChangelogSheet(updater: updater, accentColor: accentColor, onClose: { showChangelog = false })
        }
        .onAppear {
            // 以系统实际状态为准，纠正开关显示
            launchAtLogin = SystemPreferences.isLaunchAtLoginEnabled
        }
    }

    // MARK: - 通用 Tab
    private var generalTab: some View {
        VStack(spacing: 0) {
            // 主题色选择区
            settingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Text("外观主题").font(.system(size: 14, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                        ForEach(themes, id: \.hex) { theme in
                            Button(action: { themeColorHex = theme.hex }) {
                                VStack(spacing: 0) {
                                    Rectangle().fill(Color(hex: theme.hex)).frame(height: 44)
                                        .overlay(
                                            Image(systemName: themeColorHex == theme.hex ? "checkmark.circle.fill" : "paintpalette")
                                                .foregroundColor(.white).font(.system(size: 16, weight: .medium))
                                        )
                                    HStack { Text(theme.name).font(.system(size: 12, weight: .medium)); Spacer() }
                                        .padding(.horizontal, 10).padding(.vertical, 8)
                                }
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(themeColorHex == theme.hex ? Color(hex: theme.hex) : Color.gray.opacity(0.15), lineWidth: themeColorHex == theme.hex ? 2 : 1)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }

            // 设置列表项
            settingsSection {
                VStack(spacing: 0) {
                    settingsRow(title: "后台自动更新", subtitle: "检测到 AppRadar Live 新版本时，自动下载安装并重启，无需手动操作") {
                        togglePill(isOn: $autoCheckUpdate)
                    }
                    dividerLine
                    settingsRow(title: "更新提醒", subtitle: "检测到新版本时，提示更新并在侧边栏显示快捷入口") {
                        togglePill(isOn: $showUpdateBadge)
                    }
                    dividerLine
                    settingsRow(title: "是否隐藏 Dock 图标（仅 macOS）", subtitle: "独立控制程序坞图标显示状态，不受窗口最小化行为影响") {
                        dropdownPill(options: ["显示 Dock 图标", "隐藏 Dock 图标"],
                                     selected: hideDockIcon ? "隐藏 Dock 图标" : "显示 Dock 图标") { val in
                            hideDockIcon = val == "隐藏 Dock 图标"
                            SystemPreferences.applyDockIconVisibility(hidden: hideDockIcon)
                        }
                    }
                    dividerLine
                    settingsRow(title: "窗口关闭行为", subtitle: "选择关闭窗口时的默认行为") {
                        dropdownPill(options: ["最小化到托盘", "每次询问", "退出应用"],
                                     selected: closeWindowLabel) { val in
                            switch val {
                            case "最小化到托盘": closeWindowBehavior = "minimize"
                            case "每次询问": closeWindowBehavior = "ask"
                            default: closeWindowBehavior = "quit"
                            }
                        }
                    }
                    dividerLine
                    settingsRow(title: "开机自启动", subtitle: "登录 macOS 后自动启动 AppRadar Live，常驻后台监控") {
                        togglePill(isOn: Binding(
                            get: { launchAtLogin },
                            set: { newVal in
                                let ok = SystemPreferences.setLaunchAtLogin(newVal)
                                // 以系统实际状态为准回写，避免"假开关"
                                launchAtLogin = ok ? newVal : SystemPreferences.isLaunchAtLoginEnabled
                            }
                        ))
                    }
                    dividerLine
                    settingsRow(title: "进程刷新间隔", subtitle: "活动监视器数据刷新频率，值越小越实时，但 CPU 占用略增") {
                        dropdownPill(options: ["3 秒", "5 秒", "10 秒"],
                                     selected: "\(refreshInterval) 秒") { val in
                            refreshInterval = Int(val.replacingOccurrences(of: " 秒", with: "")) ?? 5
                        }
                    }
                }
            }
        }
    }

    // MARK: - 关于 Tab
    private var aboutTab: some View {
        VStack(spacing: 24) {
            // App 图标 + 名称 + 版本 + 操作按钮
            VStack(spacing: 12) {
                if let path = Bundle.main.path(forResource: "logo", ofType: "png"),
                   let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80).cornerRadius(18)
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 44)).foregroundColor(accentColor)
                }
                Text("AppRadar Live").font(.system(size: 20, weight: .bold))

                HStack(spacing: 10) {
                    Text("v\(updater.currentVersion)")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.gray.opacity(0.1)).cornerRadius(6)

                    Button(action: { updater.checkForUpdates(silent: false) }) {
                        HStack(spacing: 4) {
                            if case .checking = updater.phase {
                                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                            }
                            Text(checkButtonLabel).font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(accentColor)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(accentColor.opacity(0.08)).cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    Button(action: { showChangelog = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text").font(.system(size: 10))
                            Text("更新记录").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.gray.opacity(0.08)).cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Text("一站式 macOS 开发者软件更新与资源监控雷达")
                    .font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 2)

                // 检查更新的结果反馈
                if let status = updateStatusText {
                    HStack(spacing: 5) {
                        Image(systemName: status.icon).font(.system(size: 10)).foregroundColor(status.color)
                        Text(status.text).font(.system(size: 11)).foregroundColor(status.color)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            // 信息卡片网格
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                aboutCard(icon: "person.fill", title: "主作者", subtitle: "宇泽 AI",
                          url: "https://github.com/nanjunyu")
                aboutCard(icon: "chevron.left.forwardslash.chevron.right", title: "开源仓库", subtitle: "app-radar-live",
                          url: "https://github.com/nanjunyu/app-radar-live")
                aboutCard(icon: "star.fill", title: "点个 Star", subtitle: "支持项目持续开发",
                          url: "https://github.com/nanjunyu/app-radar-live")
                aboutCard(icon: "bubble.left.and.bubble.right.fill", title: "意见反馈", subtitle: "报告问题或提交建议",
                          url: "https://github.com/nanjunyu/app-radar-live/issues")
            }
        }
    }

    // MARK: - 辅助组件

    private var checkButtonLabel: String {
        switch updater.phase {
        case .checking: return "检查中…"
        case .upToDate: return "已是最新"
        default: return "检查更新"
        }
    }

    private var closeWindowLabel: String {
        switch closeWindowBehavior {
        case "minimize": return "最小化到托盘"
        case "ask": return "每次询问"
        default: return "退出应用"
        }
    }

    // 检查更新的结果反馈（仅在失败时展示；成功/已最新由按钮文案表达）
    private var updateStatusText: (text: String, icon: String, color: Color)? {
        if case .failed(let msg) = updater.phase {
            return (msg, "exclamationmark.triangle.fill", .orange)
        }
        return nil
    }

    struct AppTheme { let name: String; let hex: String }
    let themes = [
        AppTheme(name: "雅致白", hex: "#6B7280"),
        AppTheme(name: "优雅紫", hex: "#8B5CF6"),
        AppTheme(name: "活力绿", hex: "#10B981"),
        AppTheme(name: "科技蓝", hex: "#0EA5E9"),
        AppTheme(name: "日落橙", hex: "#F97316")
    ]

    // 设置区块容器
    private func settingsSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.gray.opacity(0.1), lineWidth: 1))
            .padding(.bottom, 14)
    }

    // 单行设置项
    private func settingsRow<Trailing: View>(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 14)
    }

    private var dividerLine: some View {
        Divider().opacity(0.6)
    }

    // 开关胶囊
    private func togglePill(isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .toggleStyle(.switch)
            .tint(accentColor)
            .scaleEffect(0.8)
            .frame(width: 44)
    }

    // 下拉选择胶囊
    private func dropdownPill(options: [String], selected: String, onChange: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button(action: { onChange(opt) }) {
                    HStack {
                        Text(opt)
                        if opt == selected { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selected).font(.system(size: 11, weight: .medium)).foregroundColor(.primary)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            .cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.gray.opacity(0.2), lineWidth: 1))
        }
    }

    private func aboutCard(icon: String, title: String, subtitle: String, url: String) -> some View {
        Button(action: {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 20)).foregroundColor(accentColor)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.primary)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(HoverCardButtonStyle())
    }
}

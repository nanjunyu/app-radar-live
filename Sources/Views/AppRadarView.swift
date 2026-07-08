import SwiftUI
import AppKit
import UserNotifications

// MARK: - Main View
struct AppRadarView: View {
    @ObservedObject var scanner: RadarScanner
    @ObservedObject private var updater = AppUpdater.shared
    @AppStorage("themeColorHex") private var themeColorHex: String = "#8B5CF6"
    var currentAccent: Color { Color(hex: themeColorHex) }
    
    // 自绘侧边栏行：用 Button（命中可靠、即点即应）+ 主题色圆角背景作为选中高亮
    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem, _ title: String, _ icon: String, badge: Int = 0) -> some View {
        let selected = scanner.selectedSidebarItem == item
        Button(action: { scanner.selectedSidebarItem = item }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(selected ? .white : currentAccent)
                    .frame(width: 20)
                Text(title)
                    .foregroundColor(selected ? .white : .primary)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundColor(selected ? .white : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.25) : Color.gray.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? currentAccent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
    }
    
    var body: some View {
        NavigationSplitView {
            List {
                Section(header: Text("活动监视器").font(.caption).foregroundColor(.gray)) {
                    sidebarRow(.monitorAll, "所有进程", "waveform.path.ecg")
                }
                Section(header: Text("版本更新中心").font(.caption).foregroundColor(.gray)) {
                    sidebarRow(.updateAll, "应用与更新", "square.grid.3x3.fill",
                               badge: scanner.updates.filter { !$0.upgraded && !$0.ignored }.count)
                }
                Section(header: Text("系统").font(.caption).foregroundColor(.gray)) {
                    sidebarRow(.sysSettings, "设置", "gearshape")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            .tint(currentAccent)
            .accentColor(currentAccent)
            
        } detail: {
            ZStack {
                // 主题色调底：单色平铺（比全屏渐变轻很多，避免高频刷新时掉帧）
                Color(NSColor.windowBackgroundColor).ignoresSafeArea()
                currentAccent.opacity(0.05).ignoresSafeArea()
                if scanner.selectedSidebarItem == .monitorAll {
                    ActivityMonitorView(scanner: scanner, live: scanner.live, accentColor: currentAccent)
                } else if scanner.selectedSidebarItem == .updateAll {
                    UpdateCenterView(scanner: scanner, accentColor: currentAccent)
                } else if scanner.selectedSidebarItem == .sysSettings {
                    SettingsView(themeColorHex: $themeColorHex, accentColor: currentAccent, updater: updater)
                } else {
                    Text("请选择左侧菜单")
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .tint(currentAccent)
        .onAppear { scanner.startAutoRefresh() }
        .sheet(isPresented: $updater.showUpdateSheet) {
            UpdateAvailableSheet(updater: updater, accentColor: currentAccent)
        }
    }
}

@main
struct AppRadarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        WindowGroup {
            AppRadarView(scanner: appDelegate.scanner)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
    }
}

// AppDelegate 负责：设置 Dock 图标 + 创建常驻菜单栏状态项（NSStatusItem）
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 由 AppDelegate 持有 scanner，主窗口与菜单栏 popover 共用同一份数据
    let scanner = RadarScanner()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1) Dock 图标（防止临时签名 app 因图标缓存显示空白）
        if let path = Bundle.main.path(forResource: "logo", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            NSApplication.shared.applicationIconImage = img
        }
        
        // 2) 菜单栏常驻图标
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            var icon: NSImage? = nil
            if let path = Bundle.main.path(forResource: "logo_menu", ofType: "png") {
                icon = NSImage(contentsOfFile: path)
                icon?.size = NSSize(width: 18, height: 18) // 关键：指定逻辑尺寸为 18x18 磅，让 36x36 物理像素在高分屏 (Retina) 下完美渲染为超清晰的 2x Retina 资源
            }
            if icon == nil {
                icon = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "AppRadar Live")
            }
            icon?.isTemplate = true   // 跟随菜单栏明暗自适应
            button.image = icon
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item
        
        // 3) 进程启动即开始扫描所有待更新（不依赖主窗口是否显示），并启动后台周期重扫
        scanner.startAutoRefresh()
        
        // 4) 请求通知权限，用于推送版本更新和 CPU/内存资源异常报警
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // 5) 应用已保存的偏好设置
        let defaults = UserDefaults.standard
        // 5.1 Dock 图标显隐
        SystemPreferences.applyDockIconVisibility(hidden: defaults.bool(forKey: "hideDockIcon"))
        // 5.2 开机自启动：首次运行（未设置过）时默认开启一次
        if defaults.object(forKey: "launchAtLogin") == nil {
            SystemPreferences.setLaunchAtLogin(true)
            defaults.set(true, forKey: "launchAtLogin")
        }
        
        // 6) 启动后检查自身版本更新（延迟 2s，避开启动高峰）
        //    autoCheckUpdate 默认开启；开启时若发现新版本，直接后台静默下载安装
        let autoUpdate = defaults.object(forKey: "autoCheckUpdate") == nil ? true : defaults.bool(forKey: "autoCheckUpdate")
        if autoUpdate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                AppUpdater.shared.checkForUpdates(silent: true, autoInstall: true)
            }
        }
    }
    
    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if let pop = popover, pop.isShown {
            pop.performClose(sender)
            return
        }
        let pop = popover ?? makePopover()
        popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        pop.contentViewController?.view.window?.makeKey()
    }
    
    private func makePopover() -> NSPopover {
        let hex = UserDefaults.standard.string(forKey: "themeColorHex") ?? "#8B5CF6"
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(
            rootView: MenuBarContentView(scanner: scanner, live: scanner.live, accentColor: Color(hex: hex))
        )
        return pop
    }
}

// MARK: - 菜单栏快捷面板
struct MenuBarContentView: View {
    @ObservedObject var scanner: RadarScanner
    @ObservedObject var live: LiveMetrics
    var accentColor: Color
    
    private func openMainApp(select tab: SidebarItem) {
        // 关闭 popover 弹窗本身 (可从 window list 找到 popover 进行 close，或者直接让其失去焦点自闭)
        // 并选择标签页、激活主应用
        scanner.selectedSidebarItem = tab
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows {
            if window.canBecomeMain && window.level == .normal {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
    
    var body: some View {
        let cpuVal = live.cpuUser + live.cpuSys
        let cpuColor: Color = {
            if cpuVal < 65.0 {
                return .green
            } else if cpuVal < 85.0 {
                return .orange
            } else {
                return .red
            }
        }()
        
        let usedMem = live.appMem + live.wiredMem + live.compressedMem
        let memRatio = live.physicalMem > 0 ? (usedMem / live.physicalMem) : 0.0
        let memColor: Color = {
            if memRatio < 0.75 {
                return .green
            } else if memRatio < 0.90 {
                return .orange
            } else {
                return .red
            }
        }()
        
        return VStack(alignment: .leading, spacing: 12) {
            // 头部栏：真实 App 标识
            HStack(spacing: 8) {
                if let path = Bundle.main.path(forResource: "logo", ofType: "png"),
                   let nsImg = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .cornerRadius(6)
                        .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("AppRadar Live")
                        .font(.system(size: 13, weight: .bold))
                    Text("系统资源与软件更新")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // 快捷齿轮跳转设置
                Button(action: {
                    openMainApp(select: .sysSettings)
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(5)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)
            
            Divider()
            
            // 卡片 1：系统状态监控（点击进入进程列表）
            Button(action: {
                openMainApp(select: .monitorAll)
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("系统状态", systemImage: "cpu")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    
                    HStack(spacing: 0) {
                        // CPU
                        VStack(alignment: .leading, spacing: 2) {
                            Text("CPU 占用").font(.system(size: 9)).foregroundColor(.secondary)
                            Text(String(format: "%.1f%%", min(100, cpuVal)))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(cpuColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Divider().frame(height: 22).padding(.horizontal, 4)
                        
                        // 内存
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已用内存").font(.system(size: 9)).foregroundColor(.secondary)
                            Text(scanner.formatMemoryGB(usedMem))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(memColor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Divider().frame(height: 22).padding(.horizontal, 4)
                        
                        // 进程
                        VStack(alignment: .leading, spacing: 2) {
                            Text("总进程数").font(.system(size: 9)).foregroundColor(.secondary)
                            Text("\(live.processes.count)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(HoverCardButtonStyle())
            
            // 卡片 2：待更新软件中心（点击进入更新中心）
            let pendingUpdates = scanner.updates.filter { !$0.upgraded && !$0.ignored }
            Button(action: {
                openMainApp(select: .updateAll)
            }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("更新中心", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.gray.opacity(0.5))
                    }
                    
                    HStack(spacing: 8) {
                        if pendingUpdates.count > 0 {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(pendingUpdates.count) 个软件可更新")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.orange)
                                
                                let names = pendingUpdates.prefix(2).map { $0.displayName ?? $0.name }.joined(separator: ", ")
                                let suffix = pendingUpdates.count > 2 ? " 等" : ""
                                Text("\(names)\(suffix)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("所有软件已是最新")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.green)
                                Text("AppRadar 后台持续监视中")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.12), lineWidth: 1)
                )
            }
            .buttonStyle(HoverCardButtonStyle())
            
            Divider()
            
            // 底部操作区
            HStack(spacing: 8) {
                Button(action: {
                    openMainApp(select: .monitorAll)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 10))
                        Text("打开主面板")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(PlainHoverButtonStyle())
                
                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 10))
                        Text("退出 AppRadar")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))
                    .foregroundColor(.red)
                    .cornerRadius(6)
                }
                .buttonStyle(PlainHoverButtonStyle())
            }
        }
        .padding(12)
        .frame(width: 250)
    }
}

// MARK: - 自定义按钮动效样式
struct HoverCardButtonStyle: ButtonStyle {
    @State private var isHovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(isHovered ? Color.gray.opacity(0.08) : Color.clear)
            .cornerRadius(8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .onHover { hover in
                isHovered = hover
            }
    }
}

struct PlainHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(isHovered ? 0.8 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hover in
                isHovered = hover
            }
    }
}

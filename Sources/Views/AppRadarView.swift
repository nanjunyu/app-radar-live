import SwiftUI
import AppKit

// MARK: - Main View
struct AppRadarView: View {
    @ObservedObject var scanner: RadarScanner
    @State private var selectedSidebarItem: SidebarItem? = .monitorAll
    @AppStorage("themeColorHex") private var themeColorHex: String = "#8B5CF6"
    var currentAccent: Color { Color(hex: themeColorHex) }
    
    // 自绘侧边栏行：用 Button（命中可靠、即点即应）+ 主题色圆角背景作为选中高亮
    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem, _ title: String, _ icon: String, badge: Int = 0) -> some View {
        let selected = selectedSidebarItem == item
        Button(action: { selectedSidebarItem = item }) {
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
                    sidebarRow(.updateAppStore, "App Store 更新", "arrow.down.app",
                               badge: scanner.updates.filter { $0.category == .appStore && !$0.upgraded && !$0.ignored }.count)
                    sidebarRow(.updateBrew, "Homebrew", "mug",
                               badge: scanner.updates.filter { $0.category == .brew && !$0.upgraded && !$0.ignored }.count)
                    if scanner.hasNpm {
                        sidebarRow(.updateNode, "Node 全局包", "shippingbox",
                                   badge: scanner.updates.filter { $0.category == .node && !$0.upgraded && !$0.ignored }.count)
                    }
                    if scanner.hasGit {
                        sidebarRow(.updateGit, "Git 项目", "arrow.triangle.branch",
                                   badge: scanner.updates.filter { $0.category == .git && !$0.upgraded && !$0.ignored }.count)
                    }
                    if scanner.hasOther {
                        sidebarRow(.updateOther, "其他", "square.grid.2x2",
                                   badge: scanner.updates.filter { $0.category == .other && !$0.upgraded && !$0.ignored }.count)
                    }
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
                if selectedSidebarItem == .monitorAll {
                    ActivityMonitorView(scanner: scanner, live: scanner.live, accentColor: currentAccent)
                } else if selectedSidebarItem == .updateAppStore {
                    UpdateCenterView(scanner: scanner, accentColor: currentAccent, category: .appStore)
                } else if selectedSidebarItem == .updateBrew {
                    UpdateCenterView(scanner: scanner, accentColor: currentAccent, category: .brew)
                } else if selectedSidebarItem == .updateNode {
                    UpdateCenterView(scanner: scanner, accentColor: currentAccent, category: .node)
                } else if selectedSidebarItem == .updateGit {
                    UpdateCenterView(scanner: scanner, accentColor: currentAccent, category: .git)
                } else if selectedSidebarItem == .updateOther {
                    UpdateCenterView(scanner: scanner, accentColor: currentAccent, category: .other)
                } else if selectedSidebarItem == .sysSettings {
                    SettingsView(themeColorHex: $themeColorHex, accentColor: currentAccent)
                } else {
                    Text("请选择左侧菜单")
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .tint(currentAccent)
        .onAppear { scanner.startAutoRefresh() }
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
            let icon = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "AppRadar Live")
            icon?.isTemplate = true   // 跟随菜单栏明暗自适应
            button.image = icon
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item
        
        // 3) 进程启动即开始扫描所有待更新（不依赖主窗口是否显示），并启动后台周期重扫
        scanner.startAutoRefresh()
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
    
    private func statRow(_ title: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).foregroundColor(color)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundColor(accentColor)
                Text("AppRadar Live").font(.system(size: 14, weight: .bold))
                Spacer()
            }
            Divider()
            statRow("CPU 占用", String(format: "%.1f%%", min(100, live.cpuUser + live.cpuSys)), color: accentColor)
            statRow("已用内存", scanner.formatMemoryGB(live.appMem + live.wiredMem + live.compressedMem))
            statRow("进程数", "\(live.processes.count)")
            statRow("待更新", scanner.updates.count > 0 ? "\(scanner.updates.count) 项" : "已最新",
                    color: scanner.updates.count > 0 ? .orange : .green)
            Divider()
            Button {
                NSApplication.shared.activate(ignoringOtherApps: true)
                for window in NSApplication.shared.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
            } label: {
                Label("打开主面板", systemImage: "macwindow").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 AppRadar", systemImage: "power").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 240)
    }
}

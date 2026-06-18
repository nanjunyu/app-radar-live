import SwiftUI
import AppKit

// MARK: - Main View
struct AppRadarView: View {
    @StateObject private var scanner = RadarScanner()
    @State private var selectedSidebarItem: SidebarItem? = .monitorAll
    @AppStorage("themeColorHex") private var themeColorHex: String = "#8B5CF6"
    var currentAccent: Color { Color(hex: themeColorHex) }
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSidebarItem) {
                Section(header: Text("活动监视器").font(.caption).foregroundColor(.gray)) {
                    NavigationLink(value: SidebarItem.monitorAll) { Label("所有进程", systemImage: "waveform.path.ecg") }
                }
                Section(header: Text("版本更新中心").font(.caption).foregroundColor(.gray)) {
                    NavigationLink(value: SidebarItem.updateAppStore) { Label("App Store 更新", systemImage: "arrow.down.app") }
                    NavigationLink(value: SidebarItem.updateBrew) { Label("依赖库更新", systemImage: "mug") }
                }
                Section(header: Text("系统").font(.caption).foregroundColor(.gray)) {
                    NavigationLink(value: SidebarItem.sysSettings) { Label("设置", systemImage: "gearshape") }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            
        } detail: {
            ZStack {
                Color(NSColor.windowBackgroundColor).ignoresSafeArea()
                if selectedSidebarItem == .monitorAll {
                    ActivityMonitorView(scanner: scanner, accentColor: currentAccent)
                } else if selectedSidebarItem == .updateAppStore {
                    UpdateCenterView(scanner: scanner, accentColor: currentAccent, category: .appStore)
                } else if selectedSidebarItem == .updateBrew {
                    UpdateCenterView(scanner: scanner, accentColor: currentAccent, category: .brew)
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
    var body: some Scene { WindowGroup { AppRadarView() }.windowStyle(HiddenTitleBarWindowStyle()) }
}

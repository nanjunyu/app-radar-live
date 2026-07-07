import SwiftUI
import AppKit
import Foundation
import UserNotifications

// MARK: - Scanner
class RadarScanner: ObservableObject {
    // 高频指标拆到独立对象，避免每 5s 刷新波及侧边栏/更新中心等无关视图
    let live = LiveMetrics()
    
    @Published var updates: [RadarUpdateApp] = []
    @Published var installed: [RadarUpdateApp] = []   // 已安装（各渠道全量，不含待更新项）
    @Published var isScanningUpdates = false
    @Published var isScanningGit = false   // Git 仓库扫描中（涉及网络，较慢）
    @Published var isScanningOther = false // 「其他」渠道扫描中
    @Published var hasNpm = false   // 环境是否有 npm，决定是否显示「Node 全局包」菜单
    @Published var hasGit = false   // 是否有 git，决定是否显示「Git 项目」菜单
    @Published var hasOther = false // 是否探测到「其他」来源（CLI 工具 / 独立应用），决定是否显示菜单
    @Published var selectedSidebarItem: SidebarItem? = .monitorAll
    
    var refreshTimer: Timer?
    var updatesTimer: Timer?         // 后台周期性重扫待更新（各渠道），与进程刷新分开
    private var hasStartedAutoRefresh = false   // 防止启动扫描被多次触发
    var iconCache: [pid_t: NSImage] = [:]
    
    // 通知跟踪状态，防止频繁重复推送
    var lastNotifiedUpdates: Set<String> = []
    private var lastCpuAlertTime: Date?
    private var lastMemAlertTime: Date?
    
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    func checkResourceAlerts(cpu: Double, memRatio: Double) {
        let now = Date()
        let cooldown: TimeInterval = 600 // 10分钟冷却时间，避免打扰用户
        
        if cpu >= 85.0 {
            if lastCpuAlertTime == nil || now.timeIntervalSince(lastCpuAlertTime!) > cooldown {
                lastCpuAlertTime = now
                sendNotification(title: "⚠️ CPU 负载过高", body: String(format: "当前 CPU 占用率达 %.1f%%，系统运行负荷较大。", cpu))
            }
        }
        
        if memRatio >= 0.90 {
            if lastMemAlertTime == nil || now.timeIntervalSince(lastMemAlertTime!) > cooldown {
                lastMemAlertTime = now
                sendNotification(title: "⚠️ 内存压力过载", body: String(format: "当前内存使用率已达 %.1f%%，系统面临内存吃紧压力，建议清理后台应用。", memRatio * 100.0))
            }
        }
    }
    
    // MARK: 扫描内部状态（非 @Published，仅用于调度，避免触发 UI 刷新）
    // 防重入标志：覆盖手动 + 自动刷新，杜绝扫描任务堆叠导致 CPU 飙升
    var scanInFlight = false
    // 原生系统指标采集器（Mach / IOKit / getifaddrs）
    let metrics = SystemMetrics()
    // 扫描周期计数，用于把重型/静态查询降频
    var scanCycle = 0
    
    // Docker 静态信息缓存（版本、引擎配置、VM 磁盘）——不会频繁变化，降频刷新即可
    var cachedDockerDesktopVer = "-"
    var cachedDockerEngineVer = "-"
    var cachedDockerComposeVer = "-"
    var cachedDockerKubeVer = "-"
    var cachedDockerNCpu = 1
    var cachedDockerMemTotal: Double = 0
    var cachedDockerDiskTotal: Double = 0
    var cachedDockerDiskUsed: Double = 0
    var dockerStaticInfoLoaded = false
    
    // Homebrew cask 列表缓存（用于进程来源判断）——brew 启动较慢，缓存后周期性刷新，避免拖慢每次进程扫描
    var cachedBrewCaskList: Set<String> = []
    var brewCaskListLoaded = false
    
    // 上一轮的 Docker 伪进程（容器在「所有进程」里以伪进程显示）。
    // 系统进程先行推送 UI 时用它占位，避免 docker 行在两次刷新间闪烁消失。
    var lastDockerProcs: [SysProcess] = []
    
    // Docker 镜像可更新缓存（image → 是否有新版本）。digest 比对较重，降频刷新。
    var cachedImageUpdatable: [String: Bool] = [:]
    // 正在 docker pull 的镜像集合：让 5s 周期扫描重建容器列表时保留"拉取中"状态，不被冲掉。
    var imagesPulling: Set<String> = []
    
    init() {
        // Don't scan in init - let the view trigger it via onAppear
    }
    
    func startAutoRefresh() {
        // 防重入：启动扫描只跑一次（AppDelegate 与窗口 onAppear 可能都触发）
        if hasStartedAutoRefresh { return }
        hasStartedAutoRefresh = true
        
        refreshTimer?.invalidate()
        // 先做极快的能力探测，立刻点亮侧边栏菜单（不等慢扫描）
        detectCapabilities()
        scanProcesses()
        scanUpdates()        // 启动即一次性检查所有渠道（App Store / Homebrew / Node）待更新
        scanGitProjects()    // 启动即扫描 Git 仓库
        scanOtherUpdates()   // 启动即扫描「其他」（CLI 工具等）
        // 进程指标高频刷新（5s）
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scanProcesses(isAuto: true)
        }
        // 后台周期性重扫待更新（30 分钟），无需用户点击各菜单即可持续发现新更新
        updatesTimer = Timer.scheduledTimer(withTimeInterval: 1800.0, repeats: true) { [weak self] _ in
            self?.scanUpdates()
            self?.scanGitProjects()
            self?.scanOtherUpdates()
        }
    }
    
    // 快速探测环境能力（npm / git 是否存在），让菜单第一时间出现
    private func detectCapabilities() {
        DispatchQueue.global(qos: .userInitiated).async {
            let npm = Environment.hasNpm
            let git = Environment.resolve("git") != nil
            DispatchQueue.main.async {
                self.hasNpm = npm
                self.hasGit = git
            }
        }
    }
}

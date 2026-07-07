import SwiftUI
import AppKit
import Foundation

// 高频刷新（每 5s）的系统/Docker 指标，独立成一个 ObservableObject。
// 只有「活动监视器」和菜单栏面板观察它，避免每次刷新波及侧边栏、更新中心等无关视图。
final class LiveMetrics: ObservableObject {
    @Published var processes: [SysProcess] = []
    @Published var isScanningProcesses = false
    @Published var isDockerFirstLoad = true   // Docker 数据尚未首次加载完成，UI 应展示加载态而非空态
    
    @Published var cpuUser: Double = 0
    @Published var cpuSys: Double = 0
    @Published var cpuIdle: Double = 0
    
    @Published var physicalMem: Double = 0
    @Published var appMem: Double = 0
    @Published var wiredMem: Double = 0
    @Published var compressedMem: Double = 0
    @Published var cachedFiles: Double = 0
    @Published var swapUsed: Double = 0
    
    @Published var networkInBytes: Double = 0
    @Published var networkOutBytes: Double = 0
    @Published var diskReadBytes: Double = 0
    @Published var diskWriteBytes: Double = 0
    
    @Published var dockerContainers: [DockerContainer] = []
    @Published var dockerDesktopVersion: String = "-"
    @Published var dockerEngineVersion: String = "-"
    @Published var dockerComposeVersion: String = "-"
    @Published var dockerKubernetesVersion: String = "-"
    @Published var dockerNCpu: Int = 1
    @Published var dockerMemTotal: Double = 0
    @Published var dockerContainerCpuSum: Double = 0.0
    @Published var dockerContainerMemSum: Double = 0.0
    @Published var dockerRunningCount: Int = 0
    @Published var dockerStoppedCount: Int = 0
    @Published var dockerDiskImages: String = "0 B"
    @Published var dockerDiskContainers: String = "0 B"
    @Published var dockerDiskVolumes: String = "0 B"
    @Published var dockerDiskCache: String = "0 B"
    @Published var dockerDiskTotal: Double = 0
    @Published var dockerDiskUsed: Double = 0
}

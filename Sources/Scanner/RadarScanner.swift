import SwiftUI
import AppKit
import Foundation

// MARK: - Scanner
class RadarScanner: ObservableObject {
    @Published var processes: [SysProcess] = []
    @Published var updates: [RadarUpdateApp] = []
    @Published var isScanningProcesses = false
    @Published var isScanningUpdates = false
    @Published var cpuUser: Double = 0
    @Published var cpuSys: Double = 0
    @Published var cpuIdle: Double = 0
    
    @Published var physicalMem: Double = 0
    @Published var appMem: Double = 0
    @Published var wiredMem: Double = 0
    @Published var compressedMem: Double = 0
    @Published var cachedFiles: Double = 0
    @Published var swapUsed: Double = 0
    
    @Published var networkIn: String = "0"
    @Published var networkOut: String = "0"
    @Published var diskRead: String = "0"
    @Published var diskWrite: String = "0"
    @Published var networkInBytes: Double = 0
    @Published var networkOutBytes: Double = 0
    @Published var dockerContainers: [DockerContainer] = []
    
    // Docker Engine Stats
    @Published var dockerDesktopVersion: String = "-"
    @Published var dockerEngineVersion: String = "-"
    @Published var dockerComposeVersion: String = "-"
    @Published var dockerKubernetesVersion: String = "-"
    @Published var dockerNCpu: Int = 1
    @Published var dockerMemTotal: Double = 0 // in bytes
    @Published var dockerContainerCpuSum: Double = 0.0
    @Published var dockerContainerMemSum: Double = 0.0 // in bytes
    @Published var dockerRunningCount: Int = 0
    @Published var dockerStoppedCount: Int = 0
    
    // Docker Disk Stats from `docker system df`
    @Published var dockerDiskImages: String = "0 B"
    @Published var dockerDiskContainers: String = "0 B"
    @Published var dockerDiskVolumes: String = "0 B"
    @Published var dockerDiskCache: String = "0 B"
    
    // Docker VM Physical Disk Stats
    @Published var dockerDiskTotal: Double = 0 // in bytes
    @Published var dockerDiskUsed: Double = 0 // in bytes
    
    var refreshTimer: Timer?
    var iconCache: [pid_t: NSImage] = [:]
    
    init() {
        // Don't scan in init - let the view trigger it via onAppear
    }
    
    func startAutoRefresh() {
        refreshTimer?.invalidate()
        scanProcesses()
        scanUpdates()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.scanProcesses(isAuto: true)
        }
    }
}

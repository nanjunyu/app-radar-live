import SwiftUI
import AppKit
import Foundation

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue:  Double(b) / 255, opacity: Double(a) / 255)
    }
}

extension NSImage {
    func resized(to targetSize: NSSize) -> NSImage {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: targetSize), from: NSRect(origin: .zero, size: self.size), operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}

// MARK: - Process Runner Utility
struct ProcessRunner {
    static let envPath = "export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:~/.nvm/versions/node/v22.22.2/bin\"; "
    @discardableResult
    static func runCommand(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", envPath + command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        do {
            try process.run()
            // Read data BEFORE waitUntilExit to avoid pipe buffer deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch { print("Command Error: \(error)") }
        return ""
    }
}

// MARK: - Data Models

// 1. Activity Monitor (Processes)
enum ProcessTag: String, Comparable {
    case desktop = "Desktop"
    case node = "Node"
    case docker = "Docker"
    case brew = "Homebrew"
    case system = "System"
    
    var color: Color {
        switch self {
        case .desktop: return .blue; case .node: return .green; case .docker: return .cyan; case .brew: return .orange; case .system: return .gray
        }
    }
    static func < (lhs: ProcessTag, rhs: ProcessTag) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct SysProcess: Identifiable, Equatable {
    let id: Int // PID
    let name: String
    let cpu: Double
    let memKB: Double
    let user: String
    let cpuTime: String
    let threads: Int
    let ports: Int
    var tag: ProcessTag
    var iconImage: NSImage?
    
    var memStr: String {
        let mb = Double(memKB) / 1024.0
        if mb > 1024 { return String(format: "%.2f GB", mb / 1024.0) }
        return String(format: "%.1f MB", mb)
    }
    
    var kindStr: String {
        switch tag {
        case .desktop: return "App"
        case .node: return "Node"
        case .docker: return "Docker"
        case .brew: return "Homebrew"
        case .system: return "System"
        }
    }
    
    static func == (lhs: SysProcess, rhs: SysProcess) -> Bool {
        return lhs.id == rhs.id && lhs.cpu == rhs.cpu && lhs.memKB == rhs.memKB
    }
}

struct DockerContainer: Identifiable, Equatable {
    let id: String // Container ID (12 chars)
    let name: String
    let image: String
    let status: String
    let ports: String
    let cpu: String
    
    var isRunning: Bool {
        status.lowercased().hasPrefix("up")
    }
    
    var formattedPorts: [String] {
        if ports.isEmpty { return [] }
        let rawParts = ports.components(separatedBy: ",")
        var result: [String] = []
        for part in rawParts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("->") {
                let subparts = trimmed.components(separatedBy: "->")
                if subparts.count == 2 {
                    let hostPart = subparts[0].components(separatedBy: ":").last ?? ""
                    let containerPart = subparts[1].components(separatedBy: "/").first ?? ""
                    if !hostPart.isEmpty && !containerPart.isEmpty {
                        let formatted = "\(hostPart):\(containerPart)"
                        if !result.contains(formatted) {
                            result.append(formatted)
                        }
                        continue
                    }
                }
            }
            let clean = trimmed.replacingOccurrences(of: "/tcp", with: "").replacingOccurrences(of: "/udp", with: "")
            if !clean.isEmpty {
                if !result.contains(clean) {
                    result.append(clean)
                }
            }
        }
        return result
    }
}

// 2. Update Center (App Store / Brew updates)
enum UpdateCategory: String {
    case appStore = "App Store (待更新)"
    case brew = "Homebrew (待更新)"
}

class RadarUpdateApp: Identifiable, ObservableObject, Hashable {
    let id = UUID()
    let name: String
    let category: UpdateCategory
    
    @Published var appId: String?
    @Published var developer: String?
    @Published var descriptionText: String?
    @Published var releaseNotes: String?
    @Published var logoUrl: URL?
    @Published var sizeStr: String?
    @Published var screenshotUrls: [String] = []
    @Published var averageUserRating: Double?
    @Published var userRatingCount: Int?
    @Published var languages: [String] = []
    
    init(name: String, category: UpdateCategory) { self.name = name; self.category = category }
    static func == (lhs: RadarUpdateApp, rhs: RadarUpdateApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum SidebarItem: Hashable {
    case monitorAll
    case updateAppStore, updateBrew
    case sysSettings, sysAbout
}

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
    
    private var refreshTimer: Timer?
    private var iconCache: [pid_t: NSImage] = [:]
    
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
    
    func scanProcesses(isAuto: Bool = false) {
        if isScanningProcesses { return }
        if !isAuto { isScanningProcesses = true }
        
        // Debug: write to file since stdout may be buffered
        let logPath = "/tmp/appradar_debug.log"
        func log(_ msg: String) {
            let entry = "\(Date()): \(msg)\n"
            if let data = entry.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logPath) {
                    if let fh = FileHandle(forWritingAtPath: logPath) {
                        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                    }
                } else {
                    FileManager.default.createFile(atPath: logPath, contents: data)
                }
            }
        }
        log("scanProcesses started, isAuto=\(isAuto)")
        
        let existingIconCache = self.iconCache
        
        DispatchQueue.global(qos: .userInitiated).async {
            var scannedProcs: [SysProcess] = []
            var newIconCache: [pid_t: NSImage] = [:]
            
            // Get desktop apps map (PID -> App)
            let runningApps = NSWorkspace.shared.runningApplications
            var desktopApps: [pid_t: NSRunningApplication] = [:]
            for app in runningApps {
                desktopApps[app.processIdentifier] = app
            }
            
            // Get thread counts per PID via shell aggregation (avoids pipe deadlock)
            log("Fetching thread counts...")
            var threadCounts: [Int: Int] = [:]
            let threadOutput = ProcessRunner.runCommand("ps -axM -o pid= | awk '{count[$1]++} END {for(p in count) print p, count[p]}'")
            for line in threadOutput.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if parts.count == 2, let pid = Int(parts[0]), let cnt = Int(parts[1]) {
                    threadCounts[pid] = cnt
                }
            }
            
            // Get MEM and PORTS from top
            log("Fetching top process stats...")
            var topStats: [Int: (memKB: Double, ports: Int)] = [:]
            let topProcOutput = ProcessRunner.runCommand("top -l 1 -stats pid,ports,mem")
            for line in topProcOutput.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 3, let pid = Int(parts[0]) {
                    let ports = Int(parts[1]) ?? 0
                    let memStr = parts[2].uppercased()
                    var multiplier = 1.0
                    var cleanStr = memStr
                    if cleanStr.hasSuffix("K") { multiplier = 1.0; cleanStr.removeLast() }
                    else if cleanStr.hasSuffix("M") { multiplier = 1024.0; cleanStr.removeLast() }
                    else if cleanStr.hasSuffix("G") { multiplier = 1024.0 * 1024.0; cleanStr.removeLast() }
                    let memKB = (Double(cleanStr) ?? 0) * multiplier
                    topStats[pid] = (memKB: memKB, ports: ports)
                }
            }
            
            // Parse ps output (with cputime)
            log("Fetching ps output...")
            let psOutput = ProcessRunner.runCommand("ps -axc -o pid=,pcpu=,rss=,user=,cputime=,comm=")
            let lines = psOutput.components(separatedBy: .newlines)
            log("ps output lines: \(lines.count)")
            for line in lines {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 6 {
                    if let pid = Int(parts[0]), let cpu = Double(parts[1]) {
                        let user = parts[3]
                        let cpuTime = parts[4]
                        let comm = parts[5...].joined(separator: " ")
                        let threads = threadCounts[pid] ?? 1
                        let topInfo = topStats[pid] ?? (memKB: Double(parts[2]) ?? 0.0, ports: 0)
                        
                        var tag: ProcessTag = .system
                        var icon: NSImage? = nil
                        let pidT = pid_t(pid)
                        var localizedName = comm
                        
                        if let app = desktopApps[pidT] {
                            tag = .desktop
                            if let lName = app.localizedName { localizedName = lName }
                            // Reuse cached icon if available
                            if let cached = existingIconCache[pidT] {
                                icon = cached
                                newIconCache[pidT] = cached
                            } else if let appIcon = app.icon {
                                let resized = appIcon.resized(to: NSSize(width: 16, height: 16))
                                icon = resized
                                newIconCache[pidT] = resized
                            }
                        }
                        else if comm.lowercased().contains("node") || comm.lowercased().contains("pm2") { tag = .node }
                        else if comm.lowercased().contains("mysql") || comm.lowercased().contains("redis") || comm.lowercased().contains("nginx") { tag = .brew }
                        
                        scannedProcs.append(SysProcess(id: pid, name: localizedName, cpu: cpu, memKB: topInfo.memKB, user: user, cpuTime: cpuTime, threads: threads, ports: topInfo.ports, tag: tag, iconImage: icon))
                    }
                }
            }
            
            // Parse docker output
            let dockerOutput = ProcessRunner.runCommand("docker ps --format '{{.Names}}\t{{.Status}}'")
            var dockerPidCounter = 900000
            for line in dockerOutput.components(separatedBy: .newlines) where !line.isEmpty {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 2 && parts[1].contains("Up") {
                    scannedProcs.append(SysProcess(id: dockerPidCounter, name: parts[0], cpu: 0.1, memKB: 512000.0, user: "docker_daemon", cpuTime: "0:00.00", threads: 1, ports: 0, tag: .docker, iconImage: nil))
                    dockerPidCounter += 1
                }
            }
            
            // Helpers for parsing Docker sizes inside scanProcesses
            func parseDockerMemSize(_ sizeStr: String) -> Double {
                let lower = sizeStr.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if lower.isEmpty { return 0.0 }
                var numberStr = ""
                var unitStr = ""
                for char in lower {
                    if char.isNumber || char == "." || char == "-" {
                        numberStr.append(char)
                    } else {
                        unitStr.append(char)
                    }
                }
                guard let val = Double(numberStr) else { return 0.0 }
                let unit = unitStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if unit.contains("gib") || unit.contains("gb") {
                    return val * 1024 * 1024 * 1024
                } else if unit.contains("mib") || unit.contains("mb") {
                    return val * 1024 * 1024
                } else if unit.contains("kib") || unit.contains("kb") {
                    return val * 1024
                } else {
                    return val
                }
            }
            
            func parseDfSize(_ line: String) -> String {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for part in parts {
                    let upper = part.uppercased()
                    if upper.hasSuffix("B") || upper.hasSuffix("KB") || upper.hasSuffix("MB") || upper.hasSuffix("GB") || upper.hasSuffix("TB") {
                        if let firstChar = upper.first, firstChar.isNumber {
                            return part
                        }
                    }
                }
                return "0 B"
            }
            
            // 1. Get Docker Engine settings
            let dockerInfoOut = ProcessRunner.runCommand("docker info --format '{{.NCPU}},,,{{.MemTotal}},,,{{.ServerVersion}}'")
            var ncpu = 1
            var memLimit: Double = 0
            var engineVer = "-"
            let infoParts = dockerInfoOut.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",,,")
            if infoParts.count >= 3 {
                ncpu = Int(infoParts[0]) ?? 1
                memLimit = Double(infoParts[1]) ?? 0
                engineVer = infoParts[2]
            }
            
            // Get other Docker component versions
            let desktopVerString = ProcessRunner.runCommand("defaults read /Applications/Docker.app/Contents/Info CFBundleShortVersionString 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
            let desktopBuildString = ProcessRunner.runCommand("defaults read /Applications/Docker.app/Contents/Info CFBundleVersion 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
            let desktopVer = (!desktopVerString.isEmpty && !desktopBuildString.isEmpty) ? "\(desktopVerString) (\(desktopBuildString))" : "-"
            
            let composeOut = ProcessRunner.runCommand("docker compose version 2>/dev/null")
            let composeVer = composeOut.components(separatedBy: "version ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
            
            let kubeOut = ProcessRunner.runCommand("kubectl version --client 2>/dev/null")
            let kubeVer = kubeOut.components(separatedBy: "Client Version: ").last?.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
            
            // 2. Run docker stats
            let dockerStatsOutput = ProcessRunner.runCommand("docker stats --no-stream --format '{{.Name}},,,{{.CPUPerc}},,,{{.MemUsage}}'")
            var dockerCpuMap: [String: String] = [:]
            var cpuSum = 0.0
            var memSum = 0.0
            
            for line in dockerStatsOutput.components(separatedBy: .newlines) where !line.isEmpty {
                let parts = line.components(separatedBy: ",,,")
                if parts.count >= 2 {
                    let cname = parts[0]
                    let cpuPct = parts[1]
                    dockerCpuMap[cname] = cpuPct
                    
                    // Accumulate CPU
                    let cleanCpu = cpuPct.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                    cpuSum += Double(cleanCpu) ?? 0.0
                    
                    // Accumulate Mem
                    if parts.count >= 3 {
                        let memUsage = parts[2].components(separatedBy: "/").first ?? ""
                        memSum += parseDockerMemSize(memUsage)
                    }
                }
            }
            
            // 3. Run docker system df
            let dockerDfOut = ProcessRunner.runCommand("docker system df")
            var diskImages = "0 B"
            var diskContainers = "0 B"
            var diskVolumes = "0 B"
            var diskCache = "0 B"
            for line in dockerDfOut.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.contains("Images") {
                    diskImages = parseDfSize(trimmed)
                } else if trimmed.contains("Containers") {
                    diskContainers = parseDfSize(trimmed)
                } else if trimmed.contains("Local Volumes") {
                    diskVolumes = parseDfSize(trimmed)
                } else if trimmed.contains("Build Cache") {
                    diskCache = parseDfSize(trimmed)
                }
            }
            
            // 3.5 Run docker disk stats inside VM
            let dfOutput = ProcessRunner.runCommand("docker run --rm alpine df -k /")
            var diskTotal: Double = 0
            var diskUsed: Double = 0
            let dfLines = dfOutput.components(separatedBy: .newlines)
            if dfLines.count >= 2 {
                let parts = dfLines[1].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 5 {
                    let kBlocks = Double(parts[1]) ?? 0
                    let kUsed = Double(parts[2]) ?? 0
                    diskTotal = kBlocks * 1024.0
                    diskUsed = kUsed * 1024.0
                }
            }
            
            // 4. Parse docker containers for the Docker Tab
            var scannedContainers: [DockerContainer] = []
            let dockerListOutput = ProcessRunner.runCommand("docker ps -a --format '{{.ID}},,,{{.Names}},,,{{.Image}},,,{{.Status}},,,{{.Ports}}'")
            
            for line in dockerListOutput.components(separatedBy: .newlines) where !line.isEmpty {
                let parts = line.components(separatedBy: ",,,")
                if parts.count >= 4 {
                    let cid = parts[0]
                    let name = parts[1]
                    let img = parts[2]
                    let status = parts[3]
                    let ports = parts.count >= 5 ? parts[4] : ""
                    let cpu = dockerCpuMap[name] ?? "0%"
                    scannedContainers.append(DockerContainer(id: cid, name: name, image: img, status: status, ports: ports, cpu: cpu))
                }
            }
            
            DispatchQueue.main.async {
                self.iconCache = newIconCache
                self.processes = scannedProcs
                self.dockerContainers = scannedContainers
                
                self.dockerDesktopVersion = desktopVer
                self.dockerEngineVersion = engineVer
                self.dockerComposeVersion = composeVer
                self.dockerKubernetesVersion = kubeVer
                self.dockerNCpu = ncpu
                self.dockerMemTotal = memLimit
                self.dockerContainerCpuSum = cpuSum
                self.dockerContainerMemSum = memSum
                self.dockerRunningCount = scannedContainers.filter { $0.isRunning }.count
                self.dockerStoppedCount = scannedContainers.filter { !$0.isRunning }.count
                self.dockerDiskImages = diskImages
                self.dockerDiskContainers = diskContainers
                self.dockerDiskVolumes = diskVolumes
                self.dockerDiskCache = diskCache
                self.dockerDiskTotal = diskTotal
                self.dockerDiskUsed = diskUsed
                
                self.isScanningProcesses = false
                log("Loaded \(scannedProcs.count) processes and \(scannedContainers.count) docker containers")
            }
            
            // Fetch system-level stats
            let sysInfo = ProcessRunner.runCommand("top -l 1 -s 0 | head -15")
            let vmStat = ProcessRunner.runCommand("vm_stat")
            let sysctl = ProcessRunner.runCommand("sysctl hw.memsize vm.swapusage")
            
            // Fetch precise network stats via netstat
            let netstatOutput = ProcessRunner.runCommand("netstat -ib | awk '$3 ~ /<Link/ {ibytes+=$(NF-4); obytes+=$(NF-1)} END {print ibytes, obytes}'")
            var netIn = 0.0
            var netOut = 0.0
            let netParts = netstatOutput.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: " ")
            if netParts.count == 2 {
                netIn = Double(netParts[0]) ?? 0.0
                netOut = Double(netParts[1]) ?? 0.0
            }
            
            let pageSize: Double = 16384.0 / (1024 * 1024 * 1024)
            func parseVmStat(for key: String) -> Double {
                guard let range = vmStat.range(of: key) else { return 0.0 }
                let substring = vmStat[range.upperBound...]
                let trimmed = substring.trimmingCharacters(in: .whitespaces)
                let numberString = trimmed.components(separatedBy: CharacterSet(charactersIn: " .\n")).first ?? "0"
                return (Double(numberString) ?? 0.0) * pageSize
            }
            
            let wMem = parseVmStat(for: "Pages wired down:")
            let aMem = parseVmStat(for: "Anonymous pages:")
            let cMem = parseVmStat(for: "Pages occupied by compressor:")
            let fMem = parseVmStat(for: "File-backed pages:")
            
            var pMem = 0.0
            var sUsed = 0.0
            for line in sysctl.components(separatedBy: .newlines) {
                if line.hasPrefix("hw.memsize:") {
                    if let val = Double(line.replacingOccurrences(of: "hw.memsize:", with: "").trimmingCharacters(in: .whitespaces)) {
                        pMem = val / (1024 * 1024 * 1024)
                    }
                } else if line.hasPrefix("vm.swapusage:") {
                    if let usedRange = line.range(of: "used = ") {
                        let sub = line[usedRange.upperBound...]
                        if let val = sub.components(separatedBy: "M").first {
                            sUsed = (Double(val.trimmingCharacters(in: .whitespaces)) ?? 0) / 1024.0
                        }
                    }
                }
            }
            
            var cU = 0.0, cS = 0.0, cI = 0.0
            var nI = "0", nO = "0", dR = "0", dW = "0"
            for line in sysInfo.components(separatedBy: .newlines) {
                if line.hasPrefix("CPU usage:") {
                    let cleaned = line.replacingOccurrences(of: "CPU usage:", with: "")
                        .replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "user", with: "")
                        .replacingOccurrences(of: "sys", with: "").replacingOccurrences(of: "idle", with: "")
                    let nums = cleaned.components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if nums.count >= 3 { cU = nums[0]; cS = nums[1]; cI = nums[2] }
                } else if line.hasPrefix("Networks:") {
                    let parts = line.replacingOccurrences(of: "Networks:", with: "").components(separatedBy: ",")
                    if parts.count >= 2 {
                        nI = parts[0].components(separatedBy: "/").last?.replacingOccurrences(of: "in", with: "").trimmingCharacters(in: .whitespaces) ?? "0"
                        nO = parts[1].components(separatedBy: "/").last?.replacingOccurrences(of: "out", with: "").replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces) ?? "0"
                    }
                } else if line.hasPrefix("Disks:") {
                    let parts = line.replacingOccurrences(of: "Disks:", with: "").components(separatedBy: ",")
                    if parts.count >= 2 {
                        dR = parts[0].components(separatedBy: "/").last?.replacingOccurrences(of: "read", with: "").trimmingCharacters(in: .whitespaces) ?? "0"
                        dW = parts[1].components(separatedBy: "/").last?.replacingOccurrences(of: "written", with: "").replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces) ?? "0"
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.wiredMem = wMem; self.appMem = aMem; self.compressedMem = cMem; self.cachedFiles = fMem
                self.physicalMem = pMem; self.swapUsed = sUsed
                self.cpuUser = cU; self.cpuSys = cS; self.cpuIdle = cI
                self.networkIn = nI; self.networkOut = nO; self.diskRead = dR; self.diskWrite = dW
                self.networkInBytes = netIn
                self.networkOutBytes = netOut
            }
        }
    }
    
    func scanUpdates() {
        if isScanningUpdates { return }
        isScanningUpdates = true
        
        DispatchQueue.global(qos: .background).async {
            var scannedUpdates: [RadarUpdateApp] = []
            let masOutput = ProcessRunner.runCommand("mas outdated")
            for line in masOutput.components(separatedBy: .newlines) where line.contains("->") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count > 1 {
                    let app = RadarUpdateApp(name: parts[1], category: .appStore)
                    app.appId = parts[0]
                    self.fetchAppStoreMetadata(for: app)
                    scannedUpdates.append(app)
                }
            }
            
            let brewOutdated = ProcessRunner.runCommand("brew outdated")
            for line in brewOutdated.components(separatedBy: .newlines) where !line.isEmpty && !line.contains("==") {
                let app = RadarUpdateApp(name: line, category: .brew)
                app.logoUrl = URL(string: "https://logo.clearbit.com/\(line).com")
                scannedUpdates.append(app)
            }
            
            DispatchQueue.main.async {
                self.updates = scannedUpdates
                self.isScanningUpdates = false
                NSApplication.shared.dockTile.badgeLabel = self.updates.count > 0 ? "\(self.updates.count)" : nil
            }
        }
    }
    
    private func fetchAppStoreMetadata(for app: RadarUpdateApp) {
        guard let appId = app.appId, let url = URL(string: "https://itunes.apple.com/lookup?id=\(appId)&country=cn") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]], let first = results.first {
                DispatchQueue.main.async {
                    if let artworkUrl100 = first["artworkUrl512"] as? String ?? first["artworkUrl100"] as? String {
                        app.logoUrl = URL(string: artworkUrl100)
                    }
                    app.developer = first["sellerName"] as? String
                    app.releaseNotes = first["releaseNotes"] as? String
                    app.descriptionText = first["description"] as? String
                    app.averageUserRating = first["averageUserRating"] as? Double
                    app.userRatingCount = first["userRatingCount"] as? Int
                    if let lang = first["languageCodesISO2A"] as? [String] { app.languages = lang }
                    if let screenshots = first["screenshotUrls"] as? [String] { app.screenshotUrls = screenshots }
                    if let size = first["fileSizeBytes"] as? String, let s = Int64(size) {
                        let formatter = ByteCountFormatter()
                        app.sizeStr = formatter.string(fromByteCount: s)
                    }
                }
            }
        }.resume()
    }
    
    func executeAction(action: String, app: RadarUpdateApp) {
        DispatchQueue.global(qos: .userInitiated).async {
            if action == "update_mas" { ProcessRunner.runCommand("mas upgrade") }
            if action == "update_brew" { ProcessRunner.runCommand("brew upgrade \(app.name)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.scanUpdates() }
        }
    }
    
    func quitProcess(pid: Int, force: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let signal = force ? "-9" : "-15"
            ProcessRunner.runCommand("kill \(signal) \(pid)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scanProcesses() }
        }
    }
    
    func formatBytes(_ bytes: Double) -> String {
        let kb = bytes / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        if gb >= 1.0 { return String(format: "%.2f GB", gb) }
        if mb >= 1.0 { return String(format: "%.2f MB", mb) }
        if kb >= 1.0 { return String(format: "%.2f KB", kb) }
        return "\(Int(bytes)) 字节"
    }
    
    func formatDiskStr(_ str: String) -> String {
        let clean = str.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if clean.isEmpty || clean == "0" { return "0 字节" }
        if clean.hasSuffix("G") { return clean.replacingOccurrences(of: "G", with: " GB") }
        if clean.hasSuffix("M") { return clean.replacingOccurrences(of: "M", with: " MB") }
        if clean.hasSuffix("K") { return clean.replacingOccurrences(of: "K", with: " KB") }
        if clean.hasSuffix("T") { return clean.replacingOccurrences(of: "T", with: " TB") }
        return clean + " Bytes"
    }
    
    func formatMemoryGB(_ gbVal: Double) -> String {
        if gbVal <= 0 { return "0 字节" }
        if gbVal >= 1.0 {
            return String(format: "%.2f GB", gbVal)
        } else {
            let mbVal = gbVal * 1024.0
            if mbVal >= 1.0 {
                return String(format: "%.1f MB", mbVal)
            } else {
                let kbVal = mbVal * 1024.0
                return String(format: "%.1f KB", kbVal)
            }
        }
    }
    
    func formatNumber(_ val: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: val)) ?? "\(val)"
    }
    
    func startContainer(name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessRunner.runCommand("docker start \(name)")
            Thread.sleep(forTimeInterval: 0.5)
            self.scanProcesses(isAuto: true)
        }
    }
    
    func stopContainer(name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessRunner.runCommand("docker stop \(name)")
            Thread.sleep(forTimeInterval: 0.5)
            self.scanProcesses(isAuto: true)
        }
    }
}

struct MemoryConnector: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w = size.width
            let h = size.height
            let spacing: CGFloat = 16 // matches HStack spacing approx
            let midY = h / 2
            
            // Horizontal line from left to center
            path.move(to: CGPoint(x: 0, y: midY))
            path.addLine(to: CGPoint(x: w/2, y: midY))
            
            // Vertical line
            path.move(to: CGPoint(x: w/2, y: midY - spacing))
            path.addLine(to: CGPoint(x: w/2, y: midY + spacing))
            
            // 3 Horizontal lines to right
            path.move(to: CGPoint(x: w/2, y: midY - spacing))
            path.addLine(to: CGPoint(x: w, y: midY - spacing))
            
            path.move(to: CGPoint(x: w/2, y: midY))
            path.addLine(to: CGPoint(x: w, y: midY))
            
            path.move(to: CGPoint(x: w/2, y: midY + spacing))
            path.addLine(to: CGPoint(x: w, y: midY + spacing))
            
            context.stroke(path, with: .color(.gray.opacity(0.6)), lineWidth: 1)
        }
        .frame(width: 14, height: 48) // Cover 3 rows
    }
}

// MARK: - Activity Monitor View (Table)
struct ActivityMonitorView: View {
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    
    @State private var selectedTab = "All"
    @State private var searchText = ""
    @State private var selectedPID: SysProcess.ID?
    @State private var showKillAlert = false
    
    var selectedProcessName: String {
        if let pid = selectedPID, let proc = scanner.processes.first(where: { $0.id == pid }) {
            return proc.name
        }
        return ""
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar Area
            HStack {
                Text(selectedTab == "Docker" ? "Docker 容器" : "所有进程").font(.headline).foregroundColor(.gray)
                
                Spacer()
                
                // Segments Tab
                Picker("", selection: $selectedTab) {
                    Text("所有进程").tag("All")
                    Text("Docker").tag("Docker")
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 180)
                
                Spacer()
                
                // Only show system process kill button when not in Docker tab
                if selectedTab != "Docker" {
                    Button(action: {
                        if selectedPID != nil { showKillAlert = true }
                    }) {
                        Image(systemName: "xmark.circle")
                    }
                    .disabled(selectedPID == nil)
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(selectedPID == nil ? .gray.opacity(0.4) : .primary.opacity(0.75))
                    .font(.title2)
                }
                
                
                TextField(selectedTab == "Docker" ? "搜索容器..." : "搜索进程...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 200)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Grid/Table display toggle
            if selectedTab == "Docker" {
                DockerContainerListView(scanner: scanner, searchText: searchText, accentColor: accentColor)
            } else {
                // Native AppKit Table View
                NativeProcessTableView(processes: scanner.processes, searchText: searchText, selectedPID: $selectedPID)
            }
            
            // Bottom status bar (Redesigned into three main blocks with a clear top divider)
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 1)
                
                if selectedTab == "Docker" {
                    HStack(alignment: .top, spacing: 30) {
                        // Block 1: Docker Desktop & Info
                        VStack(alignment: .leading, spacing: 6) {
                            Text("docker desktop (\(scanner.dockerNCpu)核)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("Desktop：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.dockerDesktopVersion).foregroundColor(.primary).frame(width: 110, alignment: .trailing) }
                                HStack { Text("Engine：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.dockerEngineVersion).foregroundColor(.primary).frame(width: 110, alignment: .trailing) }
                                HStack { Text("Compose：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.dockerComposeVersion).foregroundColor(.primary).frame(width: 110, alignment: .trailing) }
                                HStack { Text("Kubernetes：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.dockerKubernetesVersion).foregroundColor(.primary).frame(width: 110, alignment: .trailing) }
                                HStack { Text("容器 CPU：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(String(format: "%.2f%%", scanner.dockerContainerCpuSum)).foregroundColor(.red).frame(width: 110, alignment: .trailing) }
                            }.font(.system(size: 11))
                        }.frame(width: 190)
                        
                        Divider().frame(height: 80)
                        
                        // Block 2: Docker Memory
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Docker 内存").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            HStack(alignment: .top, spacing: 15) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text("内存上限：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(scanner.dockerMemTotal)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("已用内存：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(scanner.dockerContainerMemSum)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("可用内存：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(max(0, scanner.dockerMemTotal - scanner.dockerContainerMemSum))).frame(width: 65, alignment: .trailing) }
                                    HStack {
                                        Text("内存利用率：").foregroundColor(.secondary).frame(width: 80, alignment: .leading)
                                        let pct = scanner.dockerMemTotal > 0 ? (scanner.dockerContainerMemSum / scanner.dockerMemTotal) * 100.0 : 0.0
                                        Text(String(format: "%.1f%%", pct)).frame(width: 65, alignment: .trailing)
                                    }
                                }.font(.system(size: 11))
                                
                                // Modern progress circle indicator
                                VStack(spacing: 4) {
                                    let pct = scanner.dockerMemTotal > 0 ? (scanner.dockerContainerMemSum / scanner.dockerMemTotal) : 0.0
                                    ZStack {
                                        Circle()
                                            .stroke(Color.gray.opacity(0.15), lineWidth: 5)
                                            .frame(width: 45, height: 45)
                                        Circle()
                                            .trim(from: 0.0, to: CGFloat(min(max(pct, 0.0), 1.0)))
                                            .stroke(
                                                AngularGradient(colors: [.blue, .purple, .blue], center: .center),
                                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                                            )
                                            .rotationEffect(Angle(degrees: -90))
                                            .frame(width: 45, height: 45)
                                            .animation(.linear, value: pct)
                                        Text(String(format: "%.0f%%", pct * 100.0))
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                        
                        Divider().frame(height: 80).padding(.leading, 10)
                        
                        // Block 3: Docker Disk Usage
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Docker 磁盘").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            HStack(alignment: .top, spacing: 15) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text("磁盘限额：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.formatBytes(scanner.dockerDiskTotal)).frame(width: 85, alignment: .trailing) }
                                    HStack { Text("已用空间：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.formatBytes(scanner.dockerDiskUsed)).frame(width: 85, alignment: .trailing) }
                                    HStack { Text("可用空间：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.formatBytes(max(0, scanner.dockerDiskTotal - scanner.dockerDiskUsed))).frame(width: 85, alignment: .trailing) }
                                    HStack {
                                        Text("使用率：").foregroundColor(.secondary).frame(width: 70, alignment: .leading)
                                        let pct = scanner.dockerDiskTotal > 0 ? (scanner.dockerDiskUsed / scanner.dockerDiskTotal) * 100.0 : 0.0
                                        Text(String(format: "%.1f%%", pct)).frame(width: 85, alignment: .trailing)
                                    }
                                }.font(.system(size: 11))
                                
                                // Modern progress circle indicator for Disk
                                VStack(spacing: 4) {
                                    let pct = scanner.dockerDiskTotal > 0 ? (scanner.dockerDiskUsed / scanner.dockerDiskTotal) : 0.0
                                    ZStack {
                                        Circle()
                                            .stroke(Color.gray.opacity(0.15), lineWidth: 5)
                                            .frame(width: 45, height: 45)
                                        Circle()
                                            .trim(from: 0.0, to: CGFloat(min(max(pct, 0.0), 1.0)))
                                            .stroke(
                                                AngularGradient(colors: [.green, .cyan, .green], center: .center),
                                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                                            )
                                            .rotationEffect(Angle(degrees: -90))
                                            .frame(width: 45, height: 45)
                                            .animation(.linear, value: pct)
                                        Text(String(format: "%.0f%%", pct * 100.0))
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                } else {
                    HStack(alignment: .top, spacing: 30) {
                        // Block 1: CPU
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CPU").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("系统：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(String(format: "%.2f%%", scanner.cpuSys)).foregroundColor(.red).frame(width: 55, alignment: .trailing) }
                                HStack { Text("用户：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(String(format: "%.2f%%", scanner.cpuUser)).foregroundColor(.blue).frame(width: 55, alignment: .trailing) }
                                HStack { Text("闲置：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(String(format: "%.2f%%", scanner.cpuIdle)).foregroundColor(.green).frame(width: 55, alignment: .trailing) }
                                HStack { Text("线程：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(scanner.formatNumber(scanner.processes.reduce(0) { $0 + $1.threads })).foregroundColor(.primary).frame(width: 55, alignment: .trailing) }
                                HStack { Text("进程：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(scanner.formatNumber(scanner.processes.count)).foregroundColor(.primary).frame(width: 55, alignment: .trailing) }
                            }.font(.system(size: 11))
                        }.frame(width: 130)
                        
                        Divider().frame(height: 80)
                        
                        // Block 2: Memory
                        VStack(alignment: .leading, spacing: 6) {
                            Text("内存").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text("物理内存：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatMemoryGB(scanner.physicalMem)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("已使用内存：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatMemoryGB(scanner.appMem + scanner.wiredMem + scanner.compressedMem)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("已缓存文件：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatMemoryGB(scanner.cachedFiles)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("已使用的交换：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatMemoryGB(scanner.swapUsed)).frame(width: 65, alignment: .trailing) }
                                }.font(.system(size: 11))
                                
                                // Vertical offset to align the connector with the 2nd row "已使用内存"
                                VStack(spacing: 0) {
                                    Spacer().frame(height: 18) // Push down to match 2nd row
                                    HStack(spacing: 4) {
                                        MemoryConnector()
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack { Text("App 内存：").foregroundColor(.secondary).frame(width: 60, alignment: .leading); Text(scanner.formatMemoryGB(scanner.appMem)).frame(width: 65, alignment: .trailing) }
                                            HStack { Text("联动内存：").foregroundColor(.secondary).frame(width: 60, alignment: .leading); Text(scanner.formatMemoryGB(scanner.wiredMem)).frame(width: 65, alignment: .trailing) }
                                            HStack { Text("被压缩：").foregroundColor(.secondary).frame(width: 60, alignment: .leading); Text(scanner.formatMemoryGB(scanner.compressedMem)).frame(width: 65, alignment: .trailing) }
                                        }.font(.system(size: 11))
                                    }
                                }
                            }
                        }
                        
                        Divider().frame(height: 80).padding(.leading, 10)
                        
                        // Block 3: Network & Disk
                        VStack(alignment: .leading, spacing: 6) {
                            Text("网络与磁盘").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("收到的数据：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(scanner.networkInBytes)).frame(width: 85, alignment: .trailing) }
                                HStack { Text("发出的数据：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(scanner.networkOutBytes)).frame(width: 85, alignment: .trailing) }
                                HStack { Text("磁盘读取：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatDiskStr(scanner.diskRead)).frame(width: 85, alignment: .trailing) }
                                HStack { Text("磁盘写入：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatDiskStr(scanner.diskWrite)).frame(width: 85, alignment: .trailing) }
                            }.font(.system(size: 11))
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
            .frame(height: 130) // Increase height of the bottom area
        }
        .alert("确定要退出此进程吗？", isPresented: $showKillAlert) {
            Button("退出") {
                if let pid = selectedPID { scanner.quitProcess(pid: pid, force: false) }
            }
            Button("强制退出", role: .destructive) {
                if let pid = selectedPID { scanner.quitProcess(pid: pid, force: true) }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("你确定要退出“\(selectedProcessName)”吗？")
        }
    }
}


// MARK: - Update Center (Grid)
struct UpdateCenterView: View {
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    @State private var searchText = ""
    
    var filteredUpdates: [RadarUpdateApp] {
        var res = scanner.updates
        if !searchText.isEmpty { res = res.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
        return res
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("所有更新").font(.system(size: 24, weight: .bold))
                        Spacer()
                        Button(action: { scanner.scanUpdates() }) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }.buttonStyle(PlainButtonStyle()).foregroundColor(accentColor)
                    }.padding(.horizontal, 30).padding(.top, 20)
                    
                    if filteredUpdates.isEmpty {
                        VStack {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundColor(.green.opacity(0.6))
                            Text("系统已是最新状态").font(.title3).foregroundColor(.gray).padding()
                        }.frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 24)], spacing: 24) {
                            ForEach(filteredUpdates) { app in
                                NavigationLink(value: app) { AppGridCard(app: app, accentColor: accentColor) }.buttonStyle(PlainButtonStyle())
                            }
                        }.padding(.horizontal, 30)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索更新...")
            .navigationDestination(for: RadarUpdateApp.self) { app in AppDetailView(app: app, scanner: scanner, accentColor: accentColor) }
        }
    }
}

// MARK: - UI Components
struct AppGridCard: View {
    @ObservedObject var app: RadarUpdateApp
    var accentColor: Color
    @State private var isHovered = false
    var body: some View {
        VStack(spacing: 12) {
            if let url = app.logoUrl {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFit().frame(width: 60, height: 60).cornerRadius(14).shadow(color: Color.black.opacity(0.1), radius: 4) }
                    else { fallbackIcon }
                }
            } else { fallbackIcon }
            VStack(spacing: 4) {
                Text(app.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Text(app.developer ?? app.category.rawValue).font(.system(size: 11)).foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 10).background(Color.white).cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isHovered ? accentColor : Color.gray.opacity(0.15), lineWidth: isHovered ? 2 : 1))
        .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 12 : 6, y: 4)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { isHovered = h } }
    }
    var fallbackIcon: some View { RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.1)).frame(width: 60, height: 60).overlay(Image(systemName: "app.fill").foregroundColor(.gray)) }
}

struct AppDetailView: View {
    @ObservedObject var app: RadarUpdateApp
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top, spacing: 24) {
                    if let url = app.logoUrl { AsyncImage(url: url) { p in if let img = p.image { img.resizable().scaledToFit().frame(width: 120).cornerRadius(26) } else { fallbackIcon } } } else { fallbackIcon }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(app.name).font(.system(size: 32, weight: .bold))
                        Text(app.developer ?? app.category.rawValue).font(.title3).foregroundColor(.gray)
                        Button(action: { scanner.executeAction(action: app.category == .appStore ? "update_mas" : "update_brew", app: app) }) {
                            Text("升级到最新版").font(.headline).foregroundColor(.white).padding(.horizontal, 24).padding(.vertical, 10).background(accentColor).cornerRadius(20)
                        }.buttonStyle(PlainButtonStyle()).padding(.top, 4)
                    }
                    Spacer()
                }
                Divider()
                HStack(spacing: 40) {
                    if let rating = app.averageUserRating, let count = app.userRatingCount { statItem(title: String(format: "%.1f", rating), subtitle: "\(count)个评分", icon: "star.fill") }
                    if let size = app.sizeStr { statItem(title: size, subtitle: "大小", icon: "externaldrive") }
                    if !app.languages.isEmpty { statItem(title: app.languages.first ?? "ZH", subtitle: "支持语言", icon: "globe") }
                }.padding(.vertical, 10)
                Divider()
                if !app.screenshotUrls.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("预览").font(.title2).bold()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                ForEach(app.screenshotUrls, id: \.self) { surl in
                                    if let u = URL(string: surl) { AsyncImage(url: u) { p in p.image?.resizable().scaledToFill().frame(height: 200).cornerRadius(16) } }
                                }
                            }
                        }
                    }
                }
                if let notes = app.releaseNotes { VStack(alignment: .leading, spacing: 16) { Text("新功能").font(.title2).bold(); Text(notes).foregroundColor(.primary) } }
            }.padding(40)
        }.navigationTitle(app.name)
    }
    var fallbackIcon: some View { RoundedRectangle(cornerRadius: 26).fill(Color.gray.opacity(0.1)).frame(width: 120, height: 120) }
    func statItem(title: String, subtitle: String, icon: String) -> some View { VStack(spacing: 6) { Image(systemName: icon).foregroundColor(.gray); Text(title).font(.title2).bold(); Text(subtitle).font(.caption).foregroundColor(.gray) } }
}

struct SettingsView: View {
    @Binding var themeColorHex: String; var accentColor: Color
    struct AppTheme { let name: String; let hex: String }
    let themes = [AppTheme(name: "雅致白", hex: "#6B7280"), AppTheme(name: "优雅紫", hex: "#8B5CF6"), AppTheme(name: "活力绿", hex: "#10B981"), AppTheme(name: "科技蓝", hex: "#0EA5E9"), AppTheme(name: "日落橙", hex: "#F97316")]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("设置").font(.largeTitle).bold()
            VStack(alignment: .leading, spacing: 16) {
                HStack { Rectangle().fill(accentColor).frame(width: 4, height: 16).cornerRadius(2); Text("外观主题").font(.headline) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 16) {
                    ForEach(themes, id: \.hex) { theme in
                        Button(action: { themeColorHex = theme.hex }) {
                            VStack(spacing: 0) {
                                Rectangle().fill(Color(hex: theme.hex)).frame(height: 50).overlay(Image(systemName: themeColorHex == theme.hex ? "checkmark.circle.fill" : "paintpalette").foregroundColor(.white).font(.title2))
                                HStack { Text(theme.name).font(.system(size: 13, weight: .medium)); Spacer() }.padding(12).background(Color.white)
                            }.cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(themeColorHex == theme.hex ? Color(hex: theme.hex) : Color.gray.opacity(0.2), lineWidth: 2))
                        }.buttonStyle(PlainButtonStyle())
                    }
                }
            }.padding(24).background(Color.white).cornerRadius(16).shadow(color: .black.opacity(0.05), radius: 10)
            Spacer()
        }.padding(40)
    }
}

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
                Color(hex: "#F9FAFB").ignoresSafeArea()
                if selectedSidebarItem == .monitorAll {
                    ActivityMonitorView(scanner: scanner, accentColor: currentAccent)
                } else if selectedSidebarItem == .updateAppStore || selectedSidebarItem == .updateBrew {
                    UpdateCenterView(scanner: scanner, accentColor: currentAccent)
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

// MARK: - Docker Views
struct DockerContainerListView: View {
    @ObservedObject var scanner: RadarScanner
    var searchText: String
    var accentColor: Color
    
    @State private var showStopAlert = false
    @State private var containerToStop: DockerContainer? = nil
    
    var filteredContainers: [DockerContainer] {
        if searchText.isEmpty { return scanner.dockerContainers }
        return scanner.dockerContainers.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Table Header
            HStack(spacing: 0) {
                Text("状态").frame(width: 50, alignment: .center)
                Color(NSColor.separatorColor).frame(width: 1, height: 14)
                Text("容器名称").padding(.leading, 8).frame(width: 140, alignment: .leading)
                Color(NSColor.separatorColor).frame(width: 1, height: 14)
                Text("Container ID").padding(.leading, 8).frame(width: 110, alignment: .leading)
                Color(NSColor.separatorColor).frame(width: 1, height: 14)
                Text("镜像").padding(.leading, 8).frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                Color(NSColor.separatorColor).frame(width: 1, height: 14)
                Text("端口映射").padding(.leading, 8).frame(width: 220, alignment: .leading)
                Color(NSColor.separatorColor).frame(width: 1, height: 14)
                Text("CPU (%)").padding(.trailing, 8).frame(width: 80, alignment: .trailing)
                Color(NSColor.separatorColor).frame(width: 1, height: 14)
                Text("操作").frame(width: 80, alignment: .center)
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .padding(.vertical, 4)
            .padding(.horizontal)
            .background(.thinMaterial)
            
            Divider()
            
            if filteredContainers.isEmpty {
                VStack {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 40))
                        .foregroundColor(.gray.opacity(0.5))
                    Text("未发现 Docker 容器")
                        .font(.callout)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredContainers) { container in
                            DockerRowView(container: container, scanner: scanner, containerToStop: $containerToStop, showStopAlert: $showStopAlert)
                            Divider()
                        }
                    }
                }
                .background(Color.white)
            }
        }
        .alert("确定要停止此容器吗？", isPresented: $showStopAlert) {
            Button("停止", role: .destructive) {
                if let container = containerToStop {
                    scanner.stopContainer(name: container.name)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let container = containerToStop {
                Text("你确定要停止“\(container.name)”吗？")
            }
        }
    }
}

struct DockerRowView: View {
    let container: DockerContainer
    @ObservedObject var scanner: RadarScanner
    @Binding var containerToStop: DockerContainer?
    @Binding var showStopAlert: Bool
    @State private var isHovered = false
    @State private var isPlayHovered = false
    @State private var isStopHovered = false
    
    func getHostPort(from portStr: String) -> String? {
        let parts = portStr.components(separatedBy: ":")
        if parts.count == 2 {
            let host = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty, host.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil {
                return host
            }
        }
        return nil
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Status Icon
            Circle()
                .fill(container.isRunning ? Color.green : Color.gray.opacity(0.6))
                .frame(width: 8, height: 8)
                .frame(width: 50, alignment: .center)
            
            Spacer().frame(width: 1)
            
            // Name
            Text(container.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .padding(.leading, 8)
                .frame(width: 140, alignment: .leading)
                
            Spacer().frame(width: 1)
            
            // Container ID + Copy button
            HStack(spacing: 4) {
                Text(container.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(container.id, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.gray)
                .help("复制 ID")
            }
            .padding(.leading, 8)
            .frame(width: 110, alignment: .leading)
            
            Spacer().frame(width: 1)
            
            // Image
            Text(container.image)
                .font(.system(size: 11))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 8)
                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            
            Spacer().frame(width: 1)
            
            // Ports
            VStack(alignment: .leading, spacing: 2) {
                if container.formattedPorts.isEmpty {
                    Text("-")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(container.formattedPorts.enumerated()), id: \.offset) { _, port in
                        HStack(spacing: 4) {
                            Text(port)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            if let hostPort = getHostPort(from: port) {
                                Button(action: {
                                    if let url = URL(string: "http://localhost:\(hostPort)") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .foregroundColor(.blue)
                                .help("在浏览器中打开 http://localhost:\(hostPort)")
                            }
                        }
                    }
                }
            }
            .padding(.leading, 8)
            .frame(width: 220, alignment: .leading)
                
            Spacer().frame(width: 1)
            
            // CPU
            Text(container.cpu)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.trailing, 8)
                .frame(width: 80, alignment: .trailing)
                
            Spacer().frame(width: 1)
            
            // Action buttons
            HStack(spacing: 12) {
                if container.isRunning {
                    Button(action: {
                        containerToStop = container
                        showStopAlert = true
                    }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.blue)
                            .cornerRadius(6)
                            .opacity(isStopHovered ? 0.8 : 1.0)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { h in isStopHovered = h }
                    .help("停止容器")
                } else {
                    Button(action: {
                        scanner.startContainer(name: container.name)
                    }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.green)
                            .cornerRadius(6)
                            .offset(x: 0.5) // play 按钮居中微调
                            .opacity(isPlayHovered ? 0.8 : 1.0)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { h in isPlayHovered = h }
                    .help("启动容器")
                }
            }
            .frame(width: 80, alignment: .center)
        }
        .padding(.vertical, 6)
        .padding(.horizontal)
        .background(isHovered ? Color.gray.opacity(0.08) : Color.clear)
        .onHover { h in isHovered = h }
    }
}

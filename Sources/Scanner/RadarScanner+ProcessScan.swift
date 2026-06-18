import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
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
            var dockerMemMap: [String: String] = [:]
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
                        let memUsage = parts[2].components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces) ?? ""
                        dockerMemMap[cname] = memUsage.isEmpty ? "-" : memUsage
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
                    let mem = dockerMemMap[name] ?? "-"
                    scannedContainers.append(DockerContainer(id: cid, name: name, image: img, status: status, ports: ports, cpu: cpu, mem: mem))
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
}

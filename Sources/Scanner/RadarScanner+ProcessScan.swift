import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    func scanProcesses(isAuto: Bool = false) {
        // 防重入：覆盖手动与自动刷新。一次扫描没跑完，绝不开启下一次，
        // 杜绝扫描任务在后台线程上层层堆叠把 CPU 打满。
        if scanInFlight { return }
        scanInFlight = true
        if !isAuto { live.isScanningProcesses = true }
        
        scanCycle += 1
        // Docker 版本/引擎配置/VM 磁盘等几乎不变的信息：首次加载，之后每 ~60s 才刷新一次
        let refreshDockerStatic = !dockerStaticInfoLoaded || (scanCycle % 12 == 0)
        
        let existingIconCache = self.iconCache
        
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                // 无论从哪条路径结束，最终都要释放防重入标志
                DispatchQueue.main.async { self.scanInFlight = false }
            }
            
            var scannedProcs: [SysProcess] = []
            var newIconCache: [pid_t: NSImage] = [:]
            
            // Get desktop apps map (PID -> App)
            let runningApps = NSWorkspace.shared.runningApplications
            var desktopApps: [pid_t: NSRunningApplication] = [:]
            for app in runningApps {
                desktopApps[app.processIdentifier] = app
            }
            
            // Get thread counts per PID via shell aggregation (avoids pipe deadlock)
            var threadCounts: [Int: Int] = [:]
            let threadOutput = ProcessRunner.runCommand("ps -axM -o pid= | awk '{count[$1]++} END {for(p in count) print p, count[p]}'")
            for line in threadOutput.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if parts.count == 2, let pid = Int(parts[0]), let cnt = Int(parts[1]) {
                    threadCounts[pid] = cnt
                }
            }
            
            // Get full executable paths for source-detection (ps -ax -o pid=,comm= gives full path)
            var pidPaths: [Int: String] = [:]
            let pathOutput = ProcessRunner.runCommand("ps -ax -o pid=,comm=")
            for line in pathOutput.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                if parts.count == 2, let pid = Int(parts[0]) {
                    pidPaths[pid] = String(parts[1])
                }
            }
            
            // Build brew cask set for source detection.
            // brew 启动开销大，缓存后每 ~60s 才刷新一次，避免拖慢每次（含首屏）进程扫描。
            let brewCaskList: Set<String>
            if !self.brewCaskListLoaded || (self.scanCycle % 12 == 0) {
                let fresh = Set(ProcessRunner.runCommand("brew list --cask -1 2>/dev/null")
                    .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                brewCaskList = fresh
                DispatchQueue.main.async { self.cachedBrewCaskList = fresh; self.brewCaskListLoaded = true }
            } else {
                brewCaskList = self.cachedBrewCaskList
            }
            
            // Parse ps output: pid, %cpu, rss(KB), user, cputime, comm
            let currentUser = NSUserName()
            let psOutput = ProcessRunner.runCommand("ps -axc -o pid=,pcpu=,rss=,user=,cputime=,comm=")
            for line in psOutput.components(separatedBy: .newlines) {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 6 {
                    if let pid = Int(parts[0]), let cpu = Double(parts[1]) {
                        let user = parts[3]
                        // 内存：仅对当前用户的进程取 phys_footprint（活动监视器口径），
                        // 其余（系统/root 进程，取 footprint 多半无权限且开销大）回退到 ps 的 rss
                        var memKB = Double(parts[2]) ?? 0.0
                        if user == currentUser {
                            let footprint = self.metrics.processMemoryFootprint(pid: Int32(pid))
                            if footprint > 0 { memKB = footprint / 1024.0 }
                        }
                        let cpuTime = parts[4]
                        let comm = parts[5...].joined(separator: " ")
                        let threads = threadCounts[pid] ?? 1
                        
                        var tag: ProcessTag = .system
                        var icon: NSImage? = nil
                        let pidT = pid_t(pid)
                        var localizedName = comm
                        
                        // 精确判断安装来源（基于可执行文件完整路径）
                        let fullPath = pidPaths[pid] ?? ""
                        
                        if let app = desktopApps[pidT] {
                            // 桌面 App → 进一步判断来源
                            if let lName = app.localizedName { localizedName = lName }
                            if let cached = existingIconCache[pidT] {
                                icon = cached; newIconCache[pidT] = cached
                            } else if let appIcon = app.icon {
                                let resized = appIcon.resized(to: NSSize(width: 16, height: 16))
                                icon = resized; newIconCache[pidT] = resized
                            }
                            // 判断 App Store / Homebrew Cask / 独立安装
                            if let bundlePath = app.bundleURL?.path {
                                if FileManager.default.fileExists(atPath: bundlePath + "/Contents/_MASReceipt/receipt") {
                                    tag = .appStore
                                } else {
                                    // 取 app 名(token 格式)，看是否在 brew cask 列表
                                    let appFileName = (bundlePath as NSString).lastPathComponent
                                        .replacingOccurrences(of: ".app", with: "")
                                        .lowercased().replacingOccurrences(of: " ", with: "-")
                                    if brewCaskList.contains(appFileName) ||
                                       brewCaskList.contains(appFileName.replacingOccurrences(of: "-", with: "")) {
                                        tag = .brewCask
                                    } else {
                                        tag = .desktop
                                    }
                                }
                            } else { tag = .desktop }
                        }
                        else if fullPath.contains("/node_modules/") || fullPath.contains("/.nvm/")
                                    || comm.lowercased().contains("node") || comm.lowercased().contains("pm2") { tag = .node }
                        else if fullPath.contains("/workspace/") || fullPath.contains("/Developer/")
                                    || fullPath.contains("/Projects/") || fullPath.contains("/Code/") {
                            // 检查是否在 git 仓库里
                            tag = .git
                        }
                        else if comm.lowercased().contains("mysql") || comm.lowercased().contains("redis")
                                    || comm.lowercased().contains("nginx") { tag = .brew }
                        
                        scannedProcs.append(SysProcess(id: pid, name: localizedName, cpu: cpu, memKB: memKB, user: user, cpuTime: cpuTime, threads: threads, ports: 0, tag: tag, iconImage: icon))
                    }
                }
            }
            
            // 关键优化：系统进程解析完后立即推送 UI，"所有进程"瞬间出现，
            // 不必等下面 docker stats / docker run 等慢命令（首屏卡顿的真正元凶）。
            // docker 伪进程用上一轮缓存占位，待 docker 数据就绪后再整体替换。
            let systemProcs = scannedProcs
            let systemIcons = newIconCache
            DispatchQueue.main.async {
                self.iconCache = systemIcons
                self.live.processes = systemProcs + self.lastDockerProcs
                self.live.isScanningProcesses = false
            }
            
            // Parse docker output (running containers shown as pseudo-processes)
            let dockerOutput = ProcessRunner.runCommand("docker ps --format '{{.Names}}\t{{.Status}}'")
            var dockerPidCounter = 900000
            for line in dockerOutput.components(separatedBy: .newlines) where !line.isEmpty {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 2 && parts[1].contains("Up") {
                    scannedProcs.append(SysProcess(id: dockerPidCounter, name: parts[0], cpu: 0.1, memKB: 512000.0, user: "docker_daemon", cpuTime: "0:00.00", threads: 1, ports: 0, tag: .docker, iconImage: nil))
                    dockerPidCounter += 1
                }
            }
            
            // Helpers for parsing Docker sizes
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
            
            // === Docker 静态信息（版本/引擎配置/VM 磁盘）：仅首次或每 ~60s 刷新 ===
            // 这些查询里 `docker run --rm alpine df` 会启动一个容器，开销极大，
            // 过去每 5 秒执行一次，是 CPU 飙升的主要元凶之一。
            if refreshDockerStatic {
                let dockerInfoOut = ProcessRunner.runCommand("docker info --format '{{.NCPU}},,,{{.MemTotal}},,,{{.ServerVersion}}'")
                let infoParts = dockerInfoOut.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",,,")
                if infoParts.count >= 3 {
                    self.cachedDockerNCpu = Int(infoParts[0]) ?? 1
                    self.cachedDockerMemTotal = Double(infoParts[1]) ?? 0
                    self.cachedDockerEngineVer = infoParts[2]
                }
                
                let desktopVerString = ProcessRunner.runCommand("defaults read /Applications/Docker.app/Contents/Info CFBundleShortVersionString 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
                let desktopBuildString = ProcessRunner.runCommand("defaults read /Applications/Docker.app/Contents/Info CFBundleVersion 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
                self.cachedDockerDesktopVer = (!desktopVerString.isEmpty && !desktopBuildString.isEmpty) ? "\(desktopVerString) (\(desktopBuildString))" : "-"
                
                let composeOut = ProcessRunner.runCommand("docker compose version 2>/dev/null")
                self.cachedDockerComposeVer = composeOut.components(separatedBy: "version ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
                
                let kubeOut = ProcessRunner.runCommand("kubectl version --client 2>/dev/null")
                self.cachedDockerKubeVer = kubeOut.components(separatedBy: "Client Version: ").last?.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
                
                // VM 物理磁盘用量（启动一次性容器，开销大，故只在此降频路径里执行）
                let dfOutput = ProcessRunner.runCommand("docker run --rm alpine df -k /")
                let dfLines = dfOutput.components(separatedBy: .newlines)
                if dfLines.count >= 2 {
                    let parts = dfLines[1].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if parts.count >= 5 {
                        self.cachedDockerDiskTotal = (Double(parts[1]) ?? 0) * 1024.0
                        self.cachedDockerDiskUsed = (Double(parts[2]) ?? 0) * 1024.0
                    }
                }
                self.dockerStaticInfoLoaded = true
            }
            
            // === Docker 实时统计（每个周期都刷新，保证容器 CPU/内存是最新的）===
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
                    let cleanCpu = cpuPct.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
                    cpuSum += Double(cleanCpu) ?? 0.0
                    if parts.count >= 3 {
                        let memUsage = parts[2].components(separatedBy: "/").first?.trimmingCharacters(in: .whitespaces) ?? ""
                        dockerMemMap[cname] = memUsage.isEmpty ? "-" : memUsage
                        memSum += parseDockerMemSize(memUsage)
                    }
                }
            }
            
            // docker system df（磁盘占用明细）
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
            
            // 容器列表（用于 Docker 标签页表格）
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
            
            // === 镜像更新检测（每 ~60s）：本地 RepoDigest 与远程 Registry API digest 比对 ===
            // 使用 Docker Hub Registry v2 API 查远程 digest（比 buildx imagetools 更稳定）。
            // 网络操作较重，故跟随 docker 静态信息节奏降频；其余周期复用缓存。
            var imageUpdatable = self.cachedImageUpdatable
            if refreshDockerStatic {
                let images = Set(scannedContainers.map { $0.image })
                let igroup = DispatchGroup()
                let isem = DispatchSemaphore(value: 4)
                let ilock = NSLock()
                var fresh: [String: Bool] = [:]
                for img in images {
                    igroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        isem.wait(); defer { isem.signal(); igroup.leave() }
                        let q = self.shellQuote(img)
                        let local = ProcessRunner.runCommand("docker image inspect \(q) --format '{{index .RepoDigests 0}}' 2>/dev/null")
                            .components(separatedBy: "@").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        // 解析 image 为 repo:tag（处理带/不带 tag 的情况）
                        let parts = img.split(separator: ":", maxSplits: 1).map(String.init)
                        let repo = parts[0]
                        let tag = parts.count > 1 ? parts[1] : "latest"
                        // 跳过本地构建（无 registry）的镜像
                        if !repo.contains("/") && !repo.contains(".") { fresh[img] = false; return }
                        // Docker Hub Registry v2 API：先获取 token，再查 manifest digest
                        let tokenJson = ProcessRunner.runCommand("curl -s --max-time 10 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:\(repo):pull'")
                        guard let tData = tokenJson.data(using: .utf8),
                              let tObj = try? JSONSerialization.jsonObject(with: tData) as? [String: Any],
                              let token = tObj["token"] as? String else { fresh[img] = false; return }
                        let header = ProcessRunner.runCommand("curl -s --max-time 10 -I -H 'Authorization: Bearer \(token)' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' 'https://registry-1.docker.io/v2/\(repo)/manifests/\(tag)' 2>/dev/null")
                        // 从 response headers 提取 docker-content-digest
                        var remote = ""
                        for line in header.components(separatedBy: .newlines) {
                            if line.lowercased().hasPrefix("docker-content-digest:") {
                                remote = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                                break
                            }
                        }
                        let updatable = !local.isEmpty && !remote.isEmpty && local != remote
                        ilock.lock(); fresh[img] = updatable; ilock.unlock()
                    }
                }
                igroup.wait()
                imageUpdatable = fresh
            }
            for i in scannedContainers.indices {
                let img = scannedContainers[i].image
                scannedContainers[i].imageUpdatable = imageUpdatable[img] ?? false
                // 保留"拉取中"状态，避免被周期扫描冲掉
                if self.imagesPulling.contains(img) {
                    scannedContainers[i].isPullingImage = true
                    scannedContainers[i].imageUpdatable = false
                }
            }
            
            // === 系统级指标：全部走原生内核 API，零子进程开销 ===
            let cpu = self.metrics.cpuUsage()
            let mem = self.metrics.memoryUsage()
            let physicalMem = self.metrics.physicalMemoryGB
            let swapUsed = self.metrics.swapUsedGB()
            let net = self.metrics.networkBytes()
            let disk = self.metrics.diskIOBytes()
            
            DispatchQueue.main.async {
                self.iconCache = newIconCache
                self.live.processes = scannedProcs
                self.lastDockerProcs = scannedProcs.filter { $0.tag == .docker }
                self.live.dockerContainers = scannedContainers
                self.cachedImageUpdatable = imageUpdatable
                
                self.live.dockerDesktopVersion = self.cachedDockerDesktopVer
                self.live.dockerEngineVersion = self.cachedDockerEngineVer
                self.live.dockerComposeVersion = self.cachedDockerComposeVer
                self.live.dockerKubernetesVersion = self.cachedDockerKubeVer
                self.live.dockerNCpu = self.cachedDockerNCpu
                self.live.dockerMemTotal = self.cachedDockerMemTotal
                self.live.dockerContainerCpuSum = cpuSum
                self.live.dockerContainerMemSum = memSum
                self.live.dockerRunningCount = scannedContainers.filter { $0.isRunning }.count
                self.live.dockerStoppedCount = scannedContainers.filter { !$0.isRunning }.count
                self.live.dockerDiskImages = diskImages
                self.live.dockerDiskContainers = diskContainers
                self.live.dockerDiskVolumes = diskVolumes
                self.live.dockerDiskCache = diskCache
                self.live.dockerDiskTotal = self.cachedDockerDiskTotal
                self.live.dockerDiskUsed = self.cachedDockerDiskUsed
                
                // 系统 CPU（首次采样无基准时保持上一次的值）
                if let cpu = cpu {
                    self.live.cpuUser = cpu.user
                    self.live.cpuSys = cpu.system
                    self.live.cpuIdle = cpu.idle
                }
                if let mem = mem {
                    self.live.appMem = mem.appMem
                    self.live.wiredMem = mem.wired
                    self.live.compressedMem = mem.compressed
                    self.live.cachedFiles = mem.fileBacked
                }
                self.live.physicalMem = physicalMem
                self.live.swapUsed = swapUsed
                self.live.networkInBytes = net.inBytes
                self.live.networkOutBytes = net.outBytes
                self.live.diskReadBytes = disk.read
                self.live.diskWriteBytes = disk.write
                
                self.live.isScanningProcesses = false
            }
        }
    }
}

import Foundation
import AppKit

extension RadarScanner {
    func startBrewService(_ app: RadarUpdateApp) {
        guard app.category == .brew, app.isBrewService, !app.isStartingOrStopping else { return }
        DispatchQueue.main.async { app.isStartingOrStopping = true }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ProcessRunner.runCommand("brew services start \(app.name) 2>&1")
            Thread.sleep(forTimeInterval: 1.5)
            self.refreshBrewServicesStatus()
            DispatchQueue.main.async { app.isStartingOrStopping = false }
        }
    }
    
    func stopBrewService(_ app: RadarUpdateApp) {
        guard app.category == .brew, app.isBrewService, !app.isStartingOrStopping else { return }
        DispatchQueue.main.async { app.isStartingOrStopping = true }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ProcessRunner.runCommand("brew services stop \(app.name) 2>&1")
            Thread.sleep(forTimeInterval: 1.5)
            self.refreshBrewServicesStatus()
            DispatchQueue.main.async { app.isStartingOrStopping = false }
        }
    }
    
    func refreshBrewServicesStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Step 1: 获取 brew services 运行状态
            let servicesList = ProcessRunner.runCommand("brew services list 2>/dev/null")
            var runningServices: [String: Bool] = [:]
            for line in servicesList.components(separatedBy: .newlines) {
                if line.hasPrefix("Name") || line.isEmpty { continue }
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    runningServices[parts[0]] = (parts[1] == "started")
                }
            }
            
            // Step 2: 获取监听 TCP 端口的 PID → Port 映射
            let lsofPortOut = ProcessRunner.runCommand("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null")
            var pidToPort: [Int: Int] = [:]
            for line in lsofPortOut.components(separatedBy: .newlines) {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 9, let pid = Int(parts[1]) {
                    let addr = parts[8]
                    if let c = addr.lastIndex(of: ":"), let port = Int(addr[addr.index(after: c)...]) {
                        if pidToPort[pid] == nil || port < pidToPort[pid]! { pidToPort[pid] = port }
                    }
                }
            }
            
            // Step 3: 对每个 brew 服务，通过 brew services info 或 pgrep 找到 PID，再匹配监听端口
            let allBrewApps = (self.installed + self.updates).filter { $0.category == .brew && $0.isBrewService }
            var results: [(app: RadarUpdateApp, isRunning: Bool, port: Int?)] = []
            for app in allBrewApps {
                guard let isRunning = runningServices[app.name] else { continue }
                var port: Int? = nil
                if isRunning {
                    // 优先：brew services info --json 直接给出 PID
                    var foundPid: Int? = nil
                    let infoOut = ProcessRunner.runCommand("brew services info \(app.name) --json 2>/dev/null")
                    if let data = infoOut.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                       let first = arr.first,
                       let pid = first["pid"] as? Int {
                        foundPid = pid
                    }
                    // 回退：pgrep -x 精确匹配可执行文件名
                    if foundPid == nil {
                        let pgrepOut = ProcessRunner.runCommand("pgrep -x \(app.name) 2>/dev/null")
                        foundPid = Int(pgrepOut.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    // 回退：pgrep -f 子字符串匹配
                    if foundPid == nil {
                        let pgrepOut = ProcessRunner.runCommand("pgrep -f \(app.name) 2>/dev/null")
                        foundPid = pgrepOut.components(separatedBy: .newlines)
                            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.first
                    }
                    // 用找到的 PID 匹配端口（也尝试子进程）
                    if let pid = foundPid {
                        var ports: [Int] = []
                        if let p = pidToPort[pid] {
                            ports.append(p)
                        }
                        let childOut = ProcessRunner.runCommand("pgrep -P \(pid) 2>/dev/null")
                        for childStr in childOut.components(separatedBy: .newlines) {
                            if let child = Int(childStr.trimmingCharacters(in: .whitespacesAndNewlines)),
                               let p = pidToPort[child] {
                                ports.append(p)
                            }
                        }
                        port = self.selectBestConsolePort(from: ports)
                    }
                }
                results.append((app: app, isRunning: isRunning, port: port))
            }
            
            // Step 4: 更新 UI
            DispatchQueue.main.async {
                for r in results {
                    r.app.isRunning = r.isRunning
                    r.app.servicePort = r.isRunning ? r.port : nil
                }
            }
        }
    }
    
    // 打开 Homebrew 服务的 Web 控制台
    func openBrewServiceUI(_ app: RadarUpdateApp) {
        guard let port = app.servicePort else { return }
        let suffix = self.webPathSuffix(for: app)
        if let url = URL(string: "http://localhost:\(port)\(suffix)") {
            NSWorkspace.shared.open(url)
        }
    }
}

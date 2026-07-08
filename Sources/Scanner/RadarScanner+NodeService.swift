import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    // npm 全局 bin 目录（如 /Users/x/.nvm/versions/node/vX/bin）
    private func npmBinDir() -> String {
        // 优先用探测到的正确 prefix（绕开被劫持配置）；prefix/bin 即全局 bin 目录
        if let prefix = Environment.npmPrefix { return prefix + "/bin" }
        let root = ProcessRunner.runCommand("npm root -g 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
        if root.hasSuffix("/lib/node_modules") {
            return String(root.dropLast("/lib/node_modules".count)) + "/bin"
        }
        return (ProcessRunner.runCommand("dirname \"$(command -v node)\" 2>/dev/null")).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // 读取某个包的真实可执行命令名（package.json 的 bin 字段）
    private func binNames(forPackage pkg: String, npmRoot: String) -> [String] {
        let plistPath = npmRoot + "/" + pkg + "/package.json"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let binDict = obj["bin"] as? [String: Any] { return Array(binDict.keys) }
        if obj["bin"] is String {
            return [pkg.split(separator: "/").last.map(String.init) ?? pkg]
        }
        return []
    }
    
    // 递归收集某 pid 的所有后代进程（9router 会 fork next-server 子进程持有端口）
    private func descendantPids(of pid: Int) -> [Int] {
        var result: [Int] = []
        var queue = [pid]
        var depth = 0
        while !queue.isEmpty && depth < 6 {
            let current = queue.removeFirst()
            let out = ProcessRunner.runCommand("pgrep -P \(current) 2>/dev/null")
            for line in out.components(separatedBy: .newlines) {
                if let kid = Int(line.trimmingCharacters(in: .whitespaces)) {
                    result.append(kid); queue.append(kid)
                }
            }
            depth += 1
        }
        return result
    }
    
    // 刷新所有 Node 包的运行状态（真实 bin 名匹配进程 + 监听端口）
    func refreshNodeServiceStatus() {
        DispatchQueue.global(qos: .utility).async {
            let npmRoot = Environment.npmGlobalRoot
                ?? ProcessRunner.runCommand("npm root -g 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
            let binDir = self.npmBinDir()
            // 所有进程命令行（pid + 完整命令）
            let psOut = ProcessRunner.runCommand("ps -ax -o pid=,command=")
            let psLines = psOut.components(separatedBy: .newlines)
            // 监听端口 → pid
            let lsofOut = ProcessRunner.runCommand("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null")
            var pidToPort: [Int: Int] = [:]
            for line in lsofOut.components(separatedBy: .newlines) {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 9, let pid = Int(parts[1]) {
                    let addr = parts[8]
                    if let c = addr.lastIndex(of: ":"), let port = Int(addr[addr.index(after: c)...]) {
                        pidToPort[pid] = port
                    }
                }
            }
            
            let nodeApps = (self.installed + self.updates).filter { $0.category == .node }
            for app in nodeApps {
                let bins = self.binNames(forPackage: app.name, npmRoot: npmRoot)
                var rootPids: [Int] = []
                for line in psLines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    let sp = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
                    guard sp.count == 2, let pid = Int(sp[0]) else { continue }
                    let cmd = sp[1]
                    for b in bins {
                        if cmd.contains("\(binDir)/\(b)") || (cmd.contains("/\(app.name)/") && cmd.contains(b)) {
                            rootPids.append(pid); break
                        }
                    }
                }
                // 收集父进程 + 所有后代（覆盖 fork 出来持有端口的 worker，如 next-server）
                var allPids = Set(rootPids)
                for pid in rootPids { allPids.formUnion(self.descendantPids(of: pid)) }
                // 在父进程及其后代里找监听端口
                var ports: [Int] = []
                for pid in allPids {
                    if let p = pidToPort[pid] {
                        ports.append(p)
                    }
                }
                let port = self.selectBestConsolePort(from: ports)
                let running = !allPids.isEmpty
                let pidsArr = Array(allPids)
                DispatchQueue.main.async {
                    app.serviceBins = bins
                    app.runningPids = pidsArr
                    app.isRunning = running
                    app.servicePort = port
                }
            }
        }
    }
    
    // 启动服务：在「终端」里运行命令（对服务和交互式 CLI 都通用、可见输出）
    func startNodeService(_ app: RadarUpdateApp) {
        guard app.category == .node, !app.isStartingOrStopping else { return }
        let cmd = app.serviceBins.first ?? app.name.split(separator: "/").last.map(String.init) ?? app.name
        DispatchQueue.main.async { app.isStartingOrStopping = true }
        DispatchQueue.global(qos: .userInitiated).async {
            // osascript 让 Terminal 在登录环境下运行命令（PATH 完整）
            let escaped = cmd.replacingOccurrences(of: "\"", with: "\\\"")
            _ = ProcessRunner.runCommand("osascript -e 'tell application \"Terminal\" to do script \"\(escaped)\"' -e 'tell application \"Terminal\" to activate' 2>&1")
            Thread.sleep(forTimeInterval: 2.5)
            self.refreshNodeServiceStatus()
            DispatchQueue.main.async { app.isStartingOrStopping = false }
        }
    }
    
    // 停止服务：kill 检测到的进程 + 其子进程 + 占用该端口的进程（9router 等会 fork 子进程持有端口）
    func stopNodeService(_ app: RadarUpdateApp) {
        guard app.category == .node, !app.isStartingOrStopping else { return }
        let pids = app.runningPids
        let port = app.servicePort
        DispatchQueue.main.async { app.isStartingOrStopping = true }
        DispatchQueue.global(qos: .userInitiated).async {
            var targets = Set(pids)
            // 1) 各进程的子进程（递归一层，覆盖 fork 出来的 worker）
            for pid in pids {
                let kids = ProcessRunner.runCommand("pgrep -P \(pid) 2>/dev/null")
                for k in kids.components(separatedBy: .newlines) {
                    if let kp = Int(k.trimmingCharacters(in: .whitespaces)) { targets.insert(kp) }
                }
            }
            // 2) 占用服务端口的进程（真正的监听者，无论在进程树哪个位置）
            if let port = port {
                let portPids = ProcessRunner.runCommand("lsof -ti tcp:\(port) -sTCP:LISTEN 2>/dev/null")
                for p in portPids.components(separatedBy: .newlines) {
                    if let pp = Int(p.trimmingCharacters(in: .whitespaces)) { targets.insert(pp) }
                }
            }
            guard !targets.isEmpty else {
                self.refreshNodeServiceStatus()
                DispatchQueue.main.async { app.isStartingOrStopping = false }
                return
            }
            // 先优雅终止
            for pid in targets { _ = ProcessRunner.runCommand("kill \(pid) 2>/dev/null") }
            Thread.sleep(forTimeInterval: 1.2)
            // 仍存活则强制
            for pid in targets {
                let alive = ProcessRunner.runCommand("ps -p \(pid) -o pid= 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
                if !alive.isEmpty { _ = ProcessRunner.runCommand("kill -9 \(pid) 2>/dev/null") }
            }
            Thread.sleep(forTimeInterval: 0.5)
            self.refreshNodeServiceStatus()
            DispatchQueue.main.async { app.isStartingOrStopping = false }
        }
    }
    
    // 打开服务 Web UI（浏览器）
    func openNodeServiceUI(_ app: RadarUpdateApp) {
        guard let port = app.servicePort else { return }
        let suffix = self.webPathSuffix(for: app)
        if let url = URL(string: "http://localhost:\(port)\(suffix)") {
            NSWorkspace.shared.open(url)
        }
    }
}

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
            let servicesList = ProcessRunner.runCommand("brew services list 2>/dev/null")
            var runningServices: [String: String] = [:]
            for line in servicesList.components(separatedBy: .newlines) {
                if line.hasPrefix("Name") || line.isEmpty { continue }
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    runningServices[parts[0]] = parts[1]
                }
            }
            
            DispatchQueue.main.async {
                // 更新 updates 中的状态
                for app in self.updates where app.category == .brew && app.isBrewService {
                    if let status = runningServices[app.name] {
                        app.isRunning = (status == "started")
                    }
                }
                // 更新 installed 中的状态
                for app in self.installed where app.category == .brew && app.isBrewService {
                    if let status = runningServices[app.name] {
                        app.isRunning = (status == "started")
                    }
                }
            }
        }
    }
    
    func openBrewServiceUI(_ app: RadarUpdateApp) {
        // Homebrew 服务通常运行在后台，没有自带的 Web 控制台界面
    }
}

import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
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
    
    // 完整更新容器：pull 新镜像 → 停止旧容器并重命名备份 → 用原配置重建新容器 → 启动成功则删除备份，失败则回滚
    func upgradeDockerContainer(_ container: DockerContainer) {
        let image = container.image
        let name = container.name
        DispatchQueue.main.async {
            self.imagesPulling.insert(image)
            for i in self.live.dockerContainers.indices where self.live.dockerContainers[i].id == container.id {
                self.live.dockerContainers[i].isPullingImage = true
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let q = self.shellQuote(name)
            // 1. 拉取最新镜像
            _ = ProcessRunner.runCommand("docker pull \(self.shellQuote(image)) 2>&1")
            
            // 2. 读取旧容器的完整 JSON 配置，使用 JSONSerialization 解析避免 Shell 语法解析错误（解决 Cron 空格/星号等导致的崩溃）
            let jsonStr = ProcessRunner.runCommand("docker inspect \(q) 2>/dev/null")
            guard let data = jsonStr.data(using: .utf8),
                  let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = jsonArray.first else {
                DispatchQueue.main.async {
                    self.imagesPulling.remove(image)
                    for i in self.live.dockerContainers.indices where self.live.dockerContainers[i].id == container.id {
                        self.live.dockerContainers[i].isPullingImage = false
                    }
                }
                return
            }
            
            let hostConfig = first["HostConfig"] as? [String: Any] ?? [:]
            
            // 2.1 重启策略
            let restartPolicy = hostConfig["RestartPolicy"] as? [String: Any] ?? [:]
            let restartPolicyName = restartPolicy["Name"] as? String ?? ""
            let restartFlag = (!restartPolicyName.isEmpty && restartPolicyName != "no") ? "--restart \(restartPolicyName)" : ""
            
            // 2.2 端口绑定
            var portFlags: [String] = []
            if let portBindings = hostConfig["PortBindings"] as? [String: Any] {
                for (containerPort, bindings) in portBindings {
                    if let bindingsArray = bindings as? [[String: Any]] {
                        for binding in bindingsArray {
                            let hostIp = binding["HostIp"] as? String ?? ""
                            let hostPort = binding["HostPort"] as? String ?? ""
                            let ipPart = hostIp.isEmpty ? "" : "\(hostIp):"
                            portFlags.append("-p \(ipPart)\(hostPort):\(containerPort)")
                        }
                    }
                }
            }
            let portsStr = portFlags.map { $0.replacingOccurrences(of: "/tcp", with: "").replacingOccurrences(of: "/udp", with: "") }.joined(separator: " ")
            
            // 2.3 卷绑定
            var volumeFlags: [String] = []
            if let mounts = first["Mounts"] as? [[String: Any]] {
                for mount in mounts {
                    let type = mount["Type"] as? String ?? ""
                    if type == "bind" {
                        let source = mount["Source"] as? String ?? ""
                        let dest = mount["Destination"] as? String ?? ""
                        let mode = mount["Mode"] as? String ?? ""
                        let modePart = mode.isEmpty ? "" : ":\(mode)"
                        volumeFlags.append("-v \(self.shellQuote("\(source):\(dest)\(modePart)"))")
                    }
                }
            }
            let volumesStr = volumeFlags.joined(separator: " ")
            
            // 2.4 环境变量
            var envFlags: [String] = []
            let config = first["Config"] as? [String: Any] ?? [:]
            if let envsArray = config["Env"] as? [String] {
                for env in envsArray {
                    envFlags.append("-e \(self.shellQuote(env))")
                }
            }
            let envsStr = envFlags.joined(separator: " ")
            
            // 3. 停止旧容器并重命名为临时备份名称
            _ = ProcessRunner.runCommand("docker stop \(q) 2>/dev/null")
            let tempName = "\(name)_old_\(Int(Date().timeIntervalSince1970))"
            let tempQ = self.shellQuote(tempName)
            _ = ProcessRunner.runCommand("docker rename \(q) \(tempQ) 2>&1")
            
            // 4. 用原配置 + 新镜像启动新容器
            let runCmd = "docker run -d --name \(q) \(restartFlag) \(portsStr) \(volumesStr) \(envsStr) \(self.shellQuote(image))"
            let runResult = ProcessRunner.runCommand("\(runCmd) 2>&1")
            
            let runResultClean = runResult.trimmingCharacters(in: .whitespacesAndNewlines)
            let runSuccess = runResultClean.count == 64 && runResultClean.allSatisfy({ $0.isHexDigit })
            
            if runSuccess {
                // 成功：删除旧容器备份
                _ = ProcessRunner.runCommand("docker rm \(tempQ) 2>/dev/null")
            } else {
                // 失败：回滚。清理可能创建失败的占位容器，并将旧容器改回原名重新启动
                _ = ProcessRunner.runCommand("docker rm -f \(q) 2>/dev/null")
                _ = ProcessRunner.runCommand("docker rename \(tempQ) \(q) 2>/dev/null")
                _ = ProcessRunner.runCommand("docker start \(q) 2>/dev/null")
            }
            
            // 5. 更新状态
            DispatchQueue.main.async {
                self.imagesPulling.remove(image)
                self.cachedImageUpdatable[image] = false
                for i in self.live.dockerContainers.indices where self.live.dockerContainers[i].image == image {
                    self.live.dockerContainers[i].isPullingImage = false
                    self.live.dockerContainers[i].imageUpdatable = false
                }
            }
            // 刷新容器列表
            Thread.sleep(forTimeInterval: 1.0)
            self.scanProcesses(isAuto: true)
        }
    }
}

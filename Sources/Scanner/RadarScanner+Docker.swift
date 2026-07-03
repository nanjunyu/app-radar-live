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
    
    // 完整更新容器：pull 新镜像 → 停止旧容器 → 用原配置（env/ports/volumes/restart）重建 → 删旧容器
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
            // 2. 读取旧容器的完整配置
            let envs = ProcessRunner.runCommand("docker inspect \(q) --format '{{range .Config.Env}}-e {{.}} {{end}}' 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ports = ProcessRunner.runCommand("docker inspect \(q) --format '{{range $k,$v := .HostConfig.PortBindings}}{{range $v}}-p {{.HostIp}}{{if .HostIp}}:{{end}}{{.HostPort}}:{{$k}} {{end}}{{end}}' 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/tcp", with: "").replacingOccurrences(of: "/udp", with: "")
            let volumes = ProcessRunner.runCommand("docker inspect \(q) --format '{{range .Mounts}}{{if eq .Type \"bind\"}}-v {{.Source}}:{{.Destination}} {{end}}{{end}}' 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let restart = ProcessRunner.runCommand("docker inspect \(q) --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let restartFlag = (!restart.isEmpty && restart != "no") ? "--restart \(restart)" : ""
            // 3. 停止并移除旧容器
            _ = ProcessRunner.runCommand("docker stop \(q) 2>/dev/null")
            _ = ProcessRunner.runCommand("docker rm \(q) 2>/dev/null")
            // 4. 用原配置 + 新镜像启动新容器
            let runCmd = "docker run -d --name \(name) \(restartFlag) \(ports) \(volumes) \(envs) \(self.shellQuote(image))"
            _ = ProcessRunner.runCommand("\(runCmd) 2>&1")
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

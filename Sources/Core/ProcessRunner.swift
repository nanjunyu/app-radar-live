import SwiftUI
import AppKit
import Foundation

// MARK: - Process Runner Utility
struct ProcessRunner {
    // PATH 改为运行时从用户真实登录 shell 动态解析（见 Environment），不再写死 nvm 路径。
    // 若探测到的「真正可用」npm 目录与登录 PATH 里排在最前的 npm 不同（如某工具的独立
    // npm 环境抢占了 PATH 前排、但其全局包目录残缺），把该目录置于 PATH 最前，
    // 确保所有裸 `npm ...` 命令都命中同一个正确、可用的 npm。
    static var envPath: String {
        var path = Environment.loginPath
        if let npmPath = Environment.npmPath {
            let dir = (npmPath as NSString).deletingLastPathComponent
            if !path.hasPrefix(dir + ":") {
                path = dir + ":" + path
            }
        }
        return "export PATH=\"\(path)\"; "
    }
    
    // 直接执行可执行文件（不注入 shell PATH），供 Environment 解析登录 PATH 用，避免循环依赖。
    @discardableResult
    static func runRaw(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // 丢弃 stderr 噪声
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
    
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
    
    // 带 stdin 的执行：把 input 写入标准输入（用于 sudo -S 从 stdin 读密码，避免密码出现在进程列表）
    @discardableResult
    static func runCommand(_ command: String, stdin input: String) -> String {
        let process = Process()
        let outPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        process.standardInput = inPipe
        process.arguments = ["-c", envPath + command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        do {
            try process.run()
            if let d = (input + "\n").data(using: .utf8) {
                inPipe.fileHandleForWriting.write(d)
            }
            inPipe.fileHandleForWriting.closeFile()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
    
    // 流式执行：逐行回调输出（用于升级等长耗时命令的实时进度）。
    // 可选 stdin：把 input 写入标准输入（如把密码喂给 `sudo -S`）。
    // mas/brew 的下载百分比用 \r 刷新、阶段用 \n，这里两者都按行切分。
    // onLine 在后台线程回调，UI 更新需自行切回主线程。返回进程退出码。
    @discardableResult
    static func runCommandStreaming(_ command: String, stdin input: String? = nil, onLine: @escaping (String) -> Void) -> Int32 {
        let process = Process()
        let pipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        if input != nil { process.standardInput = inPipe }
        process.arguments = ["-c", envPath + command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        
        let handle = pipe.fileHandleForReading
        var strBuffer = ""
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            strBuffer += chunk
            let parts = strBuffer.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
            for line in parts.dropLast() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { onLine(t) }
            }
            strBuffer = parts.last ?? ""
        }
        
        do {
            try process.run()
            if let input = input, let d = (input + "\n").data(using: .utf8) {
                inPipe.fileHandleForWriting.write(d)
                inPipe.fileHandleForWriting.closeFile()
            }
            process.waitUntilExit()
        } catch {
            handle.readabilityHandler = nil
            return -1
        }
        handle.readabilityHandler = nil
        let tail = strBuffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { onLine(tail) }
        return process.terminationStatus
    }
}

import Foundation
import AppKit

// 启用 sudo 的 Touch ID（Apple 官方机制 /etc/pam.d/sudo_local + pam_tid）。
// 启用后，mas 以当前用户身份运行时，其内部 sudo 会自动弹系统原生 Touch ID 框，
// 无需 TTY、无需密码框。写入用系统原生授权对话框完成（绝不自制密码框）。
enum PrivilegedRunner {
    
    static let sudoLocalPath = "/etc/pam.d/sudo_local"
    
    static func isTouchIDSudoEnabled() -> Bool {
        guard let content = try? String(contentsOfFile: sudoLocalPath, encoding: .utf8) else { return false }
        return content.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && t.contains("pam_tid.so")
        }
    }
    
    /// 用系统原生授权对话框写入 sudo_local 启用 Touch ID sudo（一次性）。
    /// 用 echo 重定向直接写（不像 cp 复制扩展属性，避免 EPERM）。
    /// 返回 (是否取消, 成功与否, 失败时的真实报错)。
    static func enableTouchIDSudo() -> (canceled: Bool, success: Bool, error: String) {
        let inner = "echo \\\"auth       sufficient     pam_tid.so\\\" > \(sudoLocalPath)"
        let osa = "osascript -e 'do shell script \"\(inner)\" with administrator privileges' 2>&1"
        let out = ProcessRunner.runCommand(osa)
        let lower = out.lowercased()
        if lower.contains("user canceled") || lower.contains("-128") {
            return (true, false, "")
        }
        if isTouchIDSudoEnabled() {
            return (false, true, "")
        }
        return (false, false, out.isEmpty ? "写入后校验失败(无输出)" : out)
    }
}

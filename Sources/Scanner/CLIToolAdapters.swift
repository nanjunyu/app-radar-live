import Foundation

// 命令行工具适配器：每个已知 CLI 工具一条声明式配置。
// 新增工具只需往 `all` 数组里加一条，不改核心扫描逻辑。
struct CLIToolAdapter {
    let id: String                                  // 稳定标识（用于忽略持久化）
    let displayName: String                         // 展示名
    let detectInstalled: () -> String?              // 本地版本（nil = 未安装，跳过）
    let fetchLatest: (@escaping (String?) -> Void) -> Void   // 异步取最新版本
    let upgradeCommand: String                      // 升级命令
    let homepage: URL?

    // 注册表：目前接入 Claude Code，后续可加 Codex / Gemini CLI 等
    static let all: [CLIToolAdapter] = [ .claudeCode ]

    // MARK: - Claude Code
    static let claudeCode = CLIToolAdapter(
        id: "claude-code",
        displayName: "Claude Code",
        detectInstalled: {
            // 优先读 ~/.local/bin/claude 软链指向的版本目录名（如 .../versions/2.1.193）
            let link = NSHomeDirectory() + "/.local/bin/claude"
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link) {
                let ver = (dest as NSString).lastPathComponent
                if ver.range(of: #"^\d+\.\d+"#, options: .regularExpression) != nil { return ver }
            }
            // 兜底：claude --version 解析开头的版本号
            let out = ProcessRunner.runCommand("claude --version 2>/dev/null")
            if let m = out.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                return String(out[m])
            }
            return nil
        },
        fetchLatest: { completion in
            // Claude Code 官方发布频道清单（latest 频道）
            let urlStr = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest"
            guard let url = URL(string: urlStr) else { completion(nil); return }
            URLSession.shared.dataTask(with: url) { data, resp, _ in
                guard let data = data, let http = resp as? HTTPURLResponse, http.statusCode == 200,
                      let s = String(data: data, encoding: .utf8) else { completion(nil); return }
                let ver = s.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(ver.range(of: #"^\d+\.\d+"#, options: .regularExpression) != nil ? ver : nil)
            }.resume()
        },
        upgradeCommand: "claude update",
        homepage: URL(string: "https://docs.anthropic.com/en/docs/claude-code")
    )
}

// 语义化版本比较：按点分段数值比较，非数值段回退字符串比较。
// 返回 true 表示 latest 比 current 新（即有更新）。
func cliVersionIsNewer(_ latest: String, than current: String) -> Bool {
    let l = latest.split(separator: ".").map { String($0) }
    let c = current.split(separator: ".").map { String($0) }
    let count = max(l.count, c.count)
    for i in 0..<count {
        let lv = i < l.count ? l[i] : "0"
        let cv = i < c.count ? c[i] : "0"
        if let ln = Int(lv), let cn = Int(cv) {
            if ln != cn { return ln > cn }
        } else if lv != cv {
            return lv.compare(cv, options: .numeric) == .orderedDescending
        }
    }
    return false
}

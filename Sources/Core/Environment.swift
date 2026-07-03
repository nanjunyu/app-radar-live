import Foundation

// 环境能力探测：解析用户「真实登录 shell」的 PATH，再用 command -v 定位各工具。
// 不写死任何路径，做到跨环境（nvm / fnm / volta / Homebrew / 官方安装包）通用。
enum Environment {
    
    // 默认兜底 PATH（解析失败时使用）
    private static let fallbackPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    
    // 用登录+交互式 shell 解析 PATH（会加载用户的 .zshrc/.bash_profile），只解析一次并缓存。
    // 用 P_S/P_E 哨兵包裹，避免 rc 文件输出的噪声干扰。
    static let loginPath: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let out = ProcessRunner.runRaw(shell, ["-lic", "printf 'P_S%sP_E' \"$PATH\""])
        guard let s = out.range(of: "P_S"), let e = out.range(of: "P_E"), s.upperBound <= e.lowerBound else {
            return fallbackPath
        }
        let path = String(out[s.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? fallbackPath : path
    }()
    
    // 各工具可执行路径（command -v），找不到则为 nil → 对应渠道隐藏
    static let brewPath: String?   = resolve("brew")
    static let masPath: String?    = resolve("mas")
    static let dockerPath: String? = resolve("docker")
    
    // npm 探测结果（二进制 + 正确的全局 prefix）。
    // 你的环境里存在多个 npm（Hermes 的 ~/.local 与 nvm 的），且全局配置把 prefix
    // 劫持到某个几乎空的目录。策略：在所有候选里，选「自身安装目录下全局包最多」的那个，
    // 并记录其 prefix，后续所有全局命令都显式 --prefix，绕开被劫持的配置。
    private struct NpmInfo { let bin: String; let prefix: String?; let root: String? }
    private static let npmInfo: NpmInfo? = {
        let out = ProcessRunner.runRaw("/bin/zsh", ["-lic", "whence -ap npm 2>/dev/null"])
        let candidates = out.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        var best: (bin: String, prefix: String, count: Int)? = nil
        for cand in candidates {
            // cand = <prefix>/bin/npm → prefix = 上两级
            let prefix = ((cand as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            let dir = prefix + "/lib/node_modules"
            let count = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
                .filter { !$0.hasPrefix(".") }.count ?? 0
            if best == nil || count > best!.count { best = (cand, prefix, count) }
        }
        guard let b = best else { return NpmInfo(bin: candidates[0], prefix: nil, root: nil) }
        if b.count > 0 {
            return NpmInfo(bin: b.bin, prefix: b.prefix, root: b.prefix + "/lib/node_modules")
        }
        return NpmInfo(bin: b.bin, prefix: nil, root: nil)
    }()
    
    static var npmPath: String?   { npmInfo?.bin }
    static var npmPrefix: String? { npmInfo?.prefix }        // 正确的全局 prefix
    static var npmGlobalRoot: String? { npmInfo?.root }      // 全局包目录（prefix/lib/node_modules）
    // 拼进全局 npm 命令的 --prefix 参数（含尾部空格；无需时为空串）
    static var npmPrefixArg: String {
        if let p = npmPrefix { return "--prefix '\(p)' " }
        return ""
    }
    
    static var hasNpm: Bool    { npmPath != nil }
    static var hasBrew: Bool   { brewPath != nil }
    static var hasMas: Bool    { masPath != nil }
    static var hasDocker: Bool { dockerPath != nil }
    
    static func resolve(_ tool: String) -> String? {
        let p = ProcessRunner.runCommand("command -v \(tool)").trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : p
    }
}

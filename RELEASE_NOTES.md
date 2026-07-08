### 修复
- **修复 Git 扫描/升级闪退**：解决 runCommandStreaming 中数据竞争导致的 use-after-free 崩溃
- **修复升级卡死**：brew/npm/CLI 升级失败时自动清理残留子进程，避免锁文件导致后续升级永远失败
- **限制并发**：Git 仓库发现时限制并发数为 8，避免线程爆炸
- **优化设置描述**：「后台自动更新」明确指向 AppRadar Live 自身

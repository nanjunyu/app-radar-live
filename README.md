# 📡 AppRadar-Live

**AppRadar-Live** 是一款专为 macOS 开发者设计的**本地实时运行应用检测与更新雷达**。它常驻于您的 Mac 菜单栏，实时帮您看护当前正在运行的开发服务、容器与系统依赖，并提供安全的更新引导和强杀端口功能。

---

## 💡 我们要解决的痛点 (Why AppRadar-Live?)

作为开发者，Mac 本地安装的程序来源极其复杂，例如：
1. **Mac App Store** 里的桌面软件
2. **Homebrew** 安装的系统工具和 Casks 桌面应用
3. 从 GitHub **克隆代码并一键脚本启动** 的各种 AI 开源项目
4. 通过 **npm 全局安装** 或在本地运行的 Node 进程
5. 跑在 **Docker** 容器里的各种数据库和镜像服务

### 痛点问题：
* **难以察觉更新**：除 App Store 外，Git 克隆项目、Docker 容器以及 npm 全局工具是否有更新，用户极难感知。
* **臃肿且过载的检测**：市面上的工具往往采用“全量扫描”，不仅检测极慢，还会列出几十个平时根本不常用的依赖更新，带来严重的信息焦虑。
* **直接升级的高风险**：对于本地的 Git 仓库和 AI 项目，直接静默升级极易导致代码冲突或环境崩塌。
* **端口占用的尴尬**：开发者经常遇到 `Port 3000 is already in use`，却不知道到底是后台哪个 Node 或 Python 进程占用了它，不得不频繁使用命令行排查。

---

## ⚡ V1 核心功能 (当前版本)

AppRadar-Live 的首个版本（V1）立足于**“只检测、给引导、防冲突、可强杀”**的核心理念：

1. **动态雷达监控（仅关注运行中程序）**：
   * **端口逆向追踪**：后台动态扫描 TCP 监听端口，拿到 PID 后逆向提取其工作目录（CWD）。如果该目录包含 `.git` 且在工作区中，则判定其为“活跃项目”。
   * **Docker 状态过滤**：仅对 `Status: Up`（正在运行）的容器镜像进行新版本 Digest 检测。
   * 告别耗时的全量扫描，整机检测在 **3-5 秒**内极速完成。
2. **安全的“复制指令”升级引导**：
   * 发现更新时，**不执行强制/直接升级**，以规避代码冲突风险。
   * 软件以卡片形式提供更新日志，并生成对应的终端更新脚本，支持**一键复制**（例如：`cd path && git pull` 或 `docker compose pull`），引导您手动执行安全更新。
3. **⚡️ 进程强杀 (解决端口占用)**：
   * 每一个运行中的 Git / npm 卡片均配备红色的强杀按钮。点击即可通过 `kill -9` 瞬间终止进程并释放端口。
4. **模拟 macOS 菜单栏 UI**：
   * 采用 **Sleek Dark Mode (深色微光主题)** 和 **Glassmorphism (玻璃纳态)** 的毛玻璃下拉面板设计，完美仿真 macOS 顶部状态栏及雷达弹出泡交互。
   * 界面**自动跟随系统深色/浅色模式**切换，夜间使用不刺眼。

5. **版本更新中心（多渠道升级管理）**：
   * **App Store 更新**：通过 `mas` 命令侦测 Mac App Store 待更新应用，并调用 iTunes 接口回填官方元数据——应用图标、完整名称、开发者、版本号（当前 → 最新）、发布日期、年龄分级、类别、支持语言、大小、更新说明（新功能）与预览截图，力求与官方商店保持一致的呈现。
   * **依赖库更新**：通过 `brew outdated` 侦测 Homebrew 待更新的 formula / cask。
   * 侧边栏分流展示，App Store 与依赖库各自独立列表，点击卡片可查看应用详情。

---

## 🔧 依赖工具

桌面端在运行时会调用以下命令行工具，请确保已安装：

* **`mas`**：用于读取 App Store 更新列表，`brew install mas`
* **`brew`**：用于读取 Homebrew 更新
* **`docker`**：用于读取容器运行状态与统计（可选）

---

## 🚀 极速启动与使用

### 方式一：原生桌面应用（推荐）

AppRadar-Live 的主体是一个 SwiftUI 原生 macOS 应用（Apple Silicon / arm64）。

```bash
cd app-radar-live
./build_app.sh        # 编译并签名生成 app-radar-live.app
open app-radar-live.app
```

启动后：
* 左侧边栏切换「所有进程」「App Store 更新」「依赖库更新」「设置」。
* 进程列表首次加载时会显示扫描中的指示器，数据每 5 秒自动刷新。
* 「版本更新中心」点击应用卡片可查看详情，支持一键升级引导。

### 方式二：本地 Web 雷达（早期形态）

仓库内同时保留了一个 FastAPI Web 版后端，可用于浏览器中的端口逆向追踪演示。

```bash
cd app-radar-live
pip install -r requirements.txt
python main.py
```
*(服务将启动并监听在 `http://127.0.0.1:8045`)*

在浏览器中打开 **`http://localhost:8045`** 即可使用。

---

## 🏗️ 项目结构

桌面端源码按职责分层组织在 `Sources/` 下，便于后续扩展各渠道的更新管理（Node / Docker 等）而无需改动主文件：

```
Sources/
├── Core/                              # 通用工具
│   ├── Extensions.swift               # Color(hex:) / NSImage 等扩展
│   └── ProcessRunner.swift            # shell 命令执行封装
├── Models/                            # 数据模型
│   ├── ProcessModels.swift            # ProcessTag / SysProcess / DockerContainer
│   ├── UpdateModels.swift             # UpdateCategory / RadarUpdateApp
│   └── SidebarItem.swift              # 侧边栏路由枚举
├── Scanner/                           # 核心扫描器（按职责拆成多个 extension）
│   ├── RadarScanner.swift             # 类声明、状态属性、生命周期
│   ├── RadarScanner+ProcessScan.swift # 进程与系统资源扫描
│   ├── RadarScanner+Updates.swift     # 版本更新检测（App Store / Homebrew）
│   ├── RadarScanner+Actions.swift     # 升级 / 强杀进程
│   ├── RadarScanner+Formatting.swift  # 字节 / 内存 / 数字格式化
│   └── RadarScanner+Docker.swift      # 容器启停操作
└── Views/                             # SwiftUI 视图
    ├── AppRadarView.swift             # 主窗口与侧边栏（@main 入口）
    ├── ActivityMonitorView.swift      # 活动监视器
    ├── NativeProcessTableView.swift   # 高性能 AppKit 进程表格
    ├── UpdateCenterView.swift         # 版本更新中心（卡片 / 详情）
    ├── SettingsView.swift             # 设置（主题）
    └── DockerViews.swift              # Docker 容器列表
```

> 提示：Swift 同一 module 内的文件无需互相 import，跨文件类型默认可见。新增更新渠道时，建议新增 `RadarScanner+<渠道>Updates.swift` 与对应视图文件，保持单一职责。

---

## 🗺️ 未来终局路线图 (Roadmap)

本工具致力于在开源社区长线迭代，未来将演进为真正的 Mac 桌面应用（使用 **Tauri + Rust** 框架包装）：

* [ ] **深度运行监测**：除了端口，进一步显示运行程序的 CPU/内存消耗、基本元数据与完整启动路径。
* [ ] **多形态客户端**：常驻顶部 Menu Bar 菜单栏，点击菜单栏小图标直接呼出本地系统面板。
* [ ] **后台自动检测**：支持设定后台检测周期（如 1 小时/次），在有新版本时通过 macOS 系统原生弹窗（Notification）提醒。
* [ ] **可配置白名单**：支持用户排除不需要检测的端口和 Docker 镜像。

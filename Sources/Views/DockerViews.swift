import SwiftUI
import AppKit

// MARK: - Docker Views
struct DockerContainerListView: View {
    @ObservedObject var scanner: RadarScanner
    @ObservedObject var live: LiveMetrics
    var searchText: String
    var accentColor: Color
    
    @State private var showStopAlert = false
    @State private var containerToStop: DockerContainer? = nil
    @State private var showUpdateAlert = false
    @State private var containerToUpdate: DockerContainer? = nil
    
    var filteredContainers: [DockerContainer] {
        if searchText.isEmpty { return live.dockerContainers }
        return live.dockerContainers.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    // 固定列 + 弹性列最小宽度 + 分隔线/内边距的总和。
    // 低于此宽度时横向滚动，而不是去挤压 NavigationSplitView 的侧边栏。
    private let minTableWidth: CGFloat = 940
    
    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Table Header
                    HStack(spacing: 0) {
                        Text("状态").frame(width: 50, alignment: .center)
                        Color(NSColor.separatorColor).frame(width: 1, height: 14)
                        Text("容器名称").padding(.leading, 8).frame(width: 160, alignment: .leading)
                        Color(NSColor.separatorColor).frame(width: 1, height: 14)
                        Text("Container ID").padding(.leading, 8).frame(width: 110, alignment: .leading)
                        Color(NSColor.separatorColor).frame(width: 1, height: 14)
                        Text("镜像").padding(.leading, 8).frame(minWidth: 160, maxWidth: 300, alignment: .leading)
                        Color(NSColor.separatorColor).frame(width: 1, height: 14)
                        Text("端口映射").padding(.leading, 8).frame(width: 200, alignment: .leading)
                        Color(NSColor.separatorColor).frame(width: 1, height: 14)
                        Text("CPU (%)").padding(.trailing, 8).frame(width: 80, alignment: .trailing)
                        Color(NSColor.separatorColor).frame(width: 1, height: 14)
                        Text("内存").padding(.trailing, 8).frame(width: 90, alignment: .trailing)
                        Color(NSColor.separatorColor).frame(width: 1, height: 14)
                        Text("操作").frame(width: 80, alignment: .center)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal)
                    .background(.thinMaterial)
                    
                    Divider()
                    
                    if filteredContainers.isEmpty {
                        if live.isDockerFirstLoad {
                            // 首次加载中：显示扫描指示器
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                Text("正在扫描 Docker 容器…")
                                    .font(.callout)
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(NSColor.controlBackgroundColor))
                        } else {
                            // 数据已加载完成但确实没有容器
                            VStack {
                                Image(systemName: "shippingbox")
                                    .font(.system(size: 40))
                                    .foregroundColor(.gray.opacity(0.5))
                                Text("未发现 Docker 容器")
                                    .font(.callout)
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(NSColor.controlBackgroundColor))
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredContainers) { container in
                                    DockerRowView(container: container, scanner: scanner, containerToStop: $containerToStop, showStopAlert: $showStopAlert, containerToUpdate: $containerToUpdate, showUpdateAlert: $showUpdateAlert)
                                    Divider()
                                }
                            }
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                    }
                }
                .frame(width: max(geo.size.width, minTableWidth), height: geo.size.height, alignment: .topLeading)
            }
        }
        .alert("确定要停止此容器吗？", isPresented: $showStopAlert) {
            Button("停止", role: .destructive) {
                if let container = containerToStop {
                    scanner.stopContainer(name: container.name)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let container = containerToStop {
                Text("你确定要停止“\(container.name)”吗？")
            }
        }
        .alert("更新容器镜像", isPresented: $showUpdateAlert) {
            Button("更新", role: .destructive) {
                if let container = containerToUpdate {
                    scanner.upgradeDockerContainer(container)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let container = containerToUpdate {
                Text("将拉取最新镜像并重建容器「\(container.name)」。⚠️ 容器会短暂停止后重新启动，数据卷和配置保留。")
            }
        }
    }
}

struct DockerRowView: View {
    let container: DockerContainer
    @ObservedObject var scanner: RadarScanner
    @Binding var containerToStop: DockerContainer?
    @Binding var showStopAlert: Bool
    @Binding var containerToUpdate: DockerContainer?
    @Binding var showUpdateAlert: Bool
    @State private var isHovered = false
    @State private var isPlayHovered = false
    @State private var isStopHovered = false
    
    func getHostPort(from portStr: String) -> String? {
        let parts = portStr.components(separatedBy: ":")
        if parts.count == 2 {
            let host = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if !host.isEmpty, host.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil {
                return host
            }
        }
        return nil
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Status Icon
            Circle()
                .fill(container.isRunning ? Color.green : Color.gray.opacity(0.6))
                .frame(width: 8, height: 8)
                .frame(width: 50, alignment: .center)
            
            Spacer().frame(width: 1)
            
            // Name
            Text(container.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 8)
                .frame(width: 160, alignment: .leading)
                
            Spacer().frame(width: 1)
            
            // Container ID + Copy button
            HStack(spacing: 4) {
                Text(container.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(container.id, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.gray)
                .help("复制 ID")
            }
            .padding(.leading, 8)
            .frame(width: 110, alignment: .leading)
            
            Spacer().frame(width: 1)
            
            // Image
            HStack(spacing: 6) {
                Text(container.image)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if container.isPullingImage {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                } else if container.imageUpdatable {
                    Button(action: { containerToUpdate = container; showUpdateAlert = true }) {
                        Text("可更新")
                            .font(.system(size: 9, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.orange).clipShape(Capsule())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("点击更新：拉取新镜像并重建容器")
                }
            }
            .padding(.leading, 8)
            .frame(minWidth: 160, maxWidth: 300, alignment: .leading)
            
            Spacer().frame(width: 1)
            
            // Ports
            VStack(alignment: .leading, spacing: 2) {
                if container.formattedPorts.isEmpty {
                    Text("-")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(container.formattedPorts.enumerated()), id: \.offset) { _, port in
                        HStack(spacing: 4) {
                            Text(port)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            if let hostPort = getHostPort(from: port) {
                                Button(action: {
                                    if let url = URL(string: "http://localhost:\(hostPort)") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .buttonStyle(PlainButtonStyle())
                                .foregroundColor(.blue)
                                .help("在浏览器中打开 http://localhost:\(hostPort)")
                            }
                        }
                    }
                }
            }
            .padding(.leading, 8)
            .frame(width: 200, alignment: .leading)
                
            Spacer().frame(width: 1)
            
            // CPU
            Text(container.cpu)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.trailing, 8)
                .frame(width: 80, alignment: .trailing)
                
            Spacer().frame(width: 1)
            
            // Memory
            Text(container.isRunning ? container.mem : "-")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.trailing, 8)
                .frame(width: 90, alignment: .trailing)
                
            Spacer().frame(width: 1)
            
            // Action buttons
            HStack(spacing: 12) {
                if container.isRunning {
                    Button(action: {
                        containerToStop = container
                        showStopAlert = true
                    }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.blue)
                            .cornerRadius(6)
                            .opacity(isStopHovered ? 0.8 : 1.0)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { h in isStopHovered = h }
                    .help("停止容器")
                } else {
                    Button(action: {
                        scanner.startContainer(name: container.name)
                    }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.green)
                            .cornerRadius(6)
                            .offset(x: 0.5) // play 按钮居中微调
                            .opacity(isPlayHovered ? 0.8 : 1.0)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover { h in isPlayHovered = h }
                    .help("启动容器")
                }
            }
            .frame(width: 80, alignment: .center)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal)
        .background(isHovered ? Color.gray.opacity(0.08) : Color.clear)
        .onHover { h in isHovered = h }
    }
}

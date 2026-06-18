import SwiftUI
import AppKit

struct MemoryConnector: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let w = size.width
            let h = size.height
            let spacing: CGFloat = 16 // matches HStack spacing approx
            let midY = h / 2
            
            // Horizontal line from left to center
            path.move(to: CGPoint(x: 0, y: midY))
            path.addLine(to: CGPoint(x: w/2, y: midY))
            
            // Vertical line
            path.move(to: CGPoint(x: w/2, y: midY - spacing))
            path.addLine(to: CGPoint(x: w/2, y: midY + spacing))
            
            // 3 Horizontal lines to right
            path.move(to: CGPoint(x: w/2, y: midY - spacing))
            path.addLine(to: CGPoint(x: w, y: midY - spacing))
            
            path.move(to: CGPoint(x: w/2, y: midY))
            path.addLine(to: CGPoint(x: w, y: midY))
            
            path.move(to: CGPoint(x: w/2, y: midY + spacing))
            path.addLine(to: CGPoint(x: w, y: midY + spacing))
            
            context.stroke(path, with: .color(.gray.opacity(0.6)), lineWidth: 1)
        }
        .frame(width: 14, height: 48) // Cover 3 rows
    }
}

// MARK: - Activity Monitor View (Table)
struct ActivityMonitorView: View {
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    
    @State private var selectedTab = "All"
    @State private var searchText = ""
    @State private var selectedPID: SysProcess.ID?
    @State private var showKillAlert = false
    
    var selectedProcessName: String {
        if let pid = selectedPID, let proc = scanner.processes.first(where: { $0.id == pid }) {
            return proc.name
        }
        return ""
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar Area
            HStack {
                Text(selectedTab == "Docker" ? "Docker 容器" : "所有进程").font(.headline).foregroundColor(.gray)
                
                Spacer()
                
                // Segments Tab
                Picker("", selection: $selectedTab) {
                    Text("所有进程").tag("All")
                    Text("Docker").tag("Docker")
                }
                .pickerStyle(SegmentedPickerStyle())
                .frame(width: 180)
                
                Spacer()
                
                // Only show system process kill button when not in Docker tab
                if selectedTab != "Docker" {
                    Button(action: {
                        if selectedPID != nil { showKillAlert = true }
                    }) {
                        Image(systemName: "xmark.circle")
                    }
                    .disabled(selectedPID == nil)
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(selectedPID == nil ? .gray.opacity(0.4) : .primary.opacity(0.75))
                    .font(.title2)
                }
                
                
                TextField(selectedTab == "Docker" ? "搜索容器..." : "搜索进程...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 200)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Grid/Table display toggle
            ZStack {
                if selectedTab == "Docker" {
                    DockerContainerListView(scanner: scanner, searchText: searchText, accentColor: accentColor)
                } else {
                    // Native AppKit Table View
                    NativeProcessTableView(processes: scanner.processes, searchText: searchText, selectedPID: $selectedPID)
                }

                // First-load indicator: only while initial scan is running and no data yet
                if scanner.processes.isEmpty && scanner.isScanningProcesses {
                    VStack(spacing: 14) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("正在扫描系统进程…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
            
            // Bottom status bar (Redesigned into three main blocks with a clear top divider)
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 1)
                
                if selectedTab == "Docker" {
                    HStack(alignment: .top, spacing: 30) {
                        // Block 1: Docker Desktop & Info
                        VStack(alignment: .leading, spacing: 6) {
                            Text("docker desktop (\(scanner.dockerNCpu)核)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("Desktop：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.dockerDesktopVersion).foregroundColor(.primary).frame(width: 110, alignment: .trailing) }
                                HStack { Text("Engine：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.dockerEngineVersion).foregroundColor(.primary).frame(width: 110, alignment: .trailing) }
                                HStack { Text("Compose：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.dockerComposeVersion).foregroundColor(.primary).frame(width: 110, alignment: .trailing) }
                                HStack { Text("Kubernetes：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.dockerKubernetesVersion).foregroundColor(.primary).frame(width: 110, alignment: .trailing) }
                                HStack { Text("容器 CPU：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(String(format: "%.2f%%", scanner.dockerContainerCpuSum)).foregroundColor(.red).frame(width: 110, alignment: .trailing) }
                            }.font(.system(size: 11))
                        }.frame(width: 190)
                        
                        Divider().frame(height: 80)
                        
                        // Block 2: Docker Memory
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Docker 内存").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            HStack(alignment: .top, spacing: 15) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text("内存上限：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(scanner.dockerMemTotal)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("已用内存：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(scanner.dockerContainerMemSum)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("可用内存：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(max(0, scanner.dockerMemTotal - scanner.dockerContainerMemSum))).frame(width: 65, alignment: .trailing) }
                                    HStack {
                                        Text("内存利用率：").foregroundColor(.secondary).frame(width: 80, alignment: .leading)
                                        let pct = scanner.dockerMemTotal > 0 ? (scanner.dockerContainerMemSum / scanner.dockerMemTotal) * 100.0 : 0.0
                                        Text(String(format: "%.1f%%", pct)).frame(width: 65, alignment: .trailing)
                                    }
                                }.font(.system(size: 11))
                                
                                // Modern progress circle indicator
                                VStack(spacing: 4) {
                                    let pct = scanner.dockerMemTotal > 0 ? (scanner.dockerContainerMemSum / scanner.dockerMemTotal) : 0.0
                                    ZStack {
                                        Circle()
                                            .stroke(Color.gray.opacity(0.15), lineWidth: 5)
                                            .frame(width: 45, height: 45)
                                        Circle()
                                            .trim(from: 0.0, to: CGFloat(min(max(pct, 0.0), 1.0)))
                                            .stroke(
                                                AngularGradient(colors: [.blue, .purple, .blue], center: .center),
                                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                                            )
                                            .rotationEffect(Angle(degrees: -90))
                                            .frame(width: 45, height: 45)
                                            .animation(.linear, value: pct)
                                        Text(String(format: "%.0f%%", pct * 100.0))
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                        
                        Divider().frame(height: 80).padding(.leading, 10)
                        
                        // Block 3: Docker Disk Usage
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Docker 磁盘").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            HStack(alignment: .top, spacing: 15) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text("磁盘限额：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.formatBytes(scanner.dockerDiskTotal)).frame(width: 85, alignment: .trailing) }
                                    HStack { Text("已用空间：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.formatBytes(scanner.dockerDiskUsed)).frame(width: 85, alignment: .trailing) }
                                    HStack { Text("可用空间：").foregroundColor(.secondary).frame(width: 70, alignment: .leading); Text(scanner.formatBytes(max(0, scanner.dockerDiskTotal - scanner.dockerDiskUsed))).frame(width: 85, alignment: .trailing) }
                                    HStack {
                                        Text("使用率：").foregroundColor(.secondary).frame(width: 70, alignment: .leading)
                                        let pct = scanner.dockerDiskTotal > 0 ? (scanner.dockerDiskUsed / scanner.dockerDiskTotal) * 100.0 : 0.0
                                        Text(String(format: "%.1f%%", pct)).frame(width: 85, alignment: .trailing)
                                    }
                                }.font(.system(size: 11))
                                
                                // Modern progress circle indicator for Disk
                                VStack(spacing: 4) {
                                    let pct = scanner.dockerDiskTotal > 0 ? (scanner.dockerDiskUsed / scanner.dockerDiskTotal) : 0.0
                                    ZStack {
                                        Circle()
                                            .stroke(Color.gray.opacity(0.15), lineWidth: 5)
                                            .frame(width: 45, height: 45)
                                        Circle()
                                            .trim(from: 0.0, to: CGFloat(min(max(pct, 0.0), 1.0)))
                                            .stroke(
                                                AngularGradient(colors: [.green, .cyan, .green], center: .center),
                                                style: StrokeStyle(lineWidth: 5, lineCap: .round)
                                            )
                                            .rotationEffect(Angle(degrees: -90))
                                            .frame(width: 45, height: 45)
                                            .animation(.linear, value: pct)
                                        Text(String(format: "%.0f%%", pct * 100.0))
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                } else {
                    HStack(alignment: .top, spacing: 30) {
                        // Block 1: CPU
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CPU").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("系统：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(String(format: "%.2f%%", scanner.cpuSys)).foregroundColor(.red).frame(width: 55, alignment: .trailing) }
                                HStack { Text("用户：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(String(format: "%.2f%%", scanner.cpuUser)).foregroundColor(.blue).frame(width: 55, alignment: .trailing) }
                                HStack { Text("闲置：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(String(format: "%.2f%%", scanner.cpuIdle)).foregroundColor(.green).frame(width: 55, alignment: .trailing) }
                                HStack { Text("线程：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(scanner.formatNumber(scanner.processes.reduce(0) { $0 + $1.threads })).foregroundColor(.primary).frame(width: 55, alignment: .trailing) }
                                HStack { Text("进程：").foregroundColor(.secondary).frame(width: 40, alignment: .leading); Text(scanner.formatNumber(scanner.processes.count)).foregroundColor(.primary).frame(width: 55, alignment: .trailing) }
                            }.font(.system(size: 11))
                        }.frame(width: 130)
                        
                        Divider().frame(height: 80)
                        
                        // Block 2: Memory
                        VStack(alignment: .leading, spacing: 6) {
                            Text("内存").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack { Text("物理内存：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatMemoryGB(scanner.physicalMem)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("已使用内存：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatMemoryGB(scanner.appMem + scanner.wiredMem + scanner.compressedMem)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("已缓存文件：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatMemoryGB(scanner.cachedFiles)).frame(width: 65, alignment: .trailing) }
                                    HStack { Text("已使用的交换：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatMemoryGB(scanner.swapUsed)).frame(width: 65, alignment: .trailing) }
                                }.font(.system(size: 11))
                                
                                // Vertical offset to align the connector with the 2nd row "已使用内存"
                                VStack(spacing: 0) {
                                    Spacer().frame(height: 18) // Push down to match 2nd row
                                    HStack(spacing: 4) {
                                        MemoryConnector()
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack { Text("App 内存：").foregroundColor(.secondary).frame(width: 60, alignment: .leading); Text(scanner.formatMemoryGB(scanner.appMem)).frame(width: 65, alignment: .trailing) }
                                            HStack { Text("联动内存：").foregroundColor(.secondary).frame(width: 60, alignment: .leading); Text(scanner.formatMemoryGB(scanner.wiredMem)).frame(width: 65, alignment: .trailing) }
                                            HStack { Text("被压缩：").foregroundColor(.secondary).frame(width: 60, alignment: .leading); Text(scanner.formatMemoryGB(scanner.compressedMem)).frame(width: 65, alignment: .trailing) }
                                        }.font(.system(size: 11))
                                    }
                                }
                            }
                        }
                        
                        Divider().frame(height: 80).padding(.leading, 10)
                        
                        // Block 3: Network & Disk
                        VStack(alignment: .leading, spacing: 6) {
                            Text("网络与磁盘").font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text("收到的数据：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(scanner.networkInBytes)).frame(width: 85, alignment: .trailing) }
                                HStack { Text("发出的数据：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatBytes(scanner.networkOutBytes)).frame(width: 85, alignment: .trailing) }
                                HStack { Text("磁盘读取：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatDiskStr(scanner.diskRead)).frame(width: 85, alignment: .trailing) }
                                HStack { Text("磁盘写入：").foregroundColor(.secondary).frame(width: 80, alignment: .leading); Text(scanner.formatDiskStr(scanner.diskWrite)).frame(width: 85, alignment: .trailing) }
                            }.font(.system(size: 11))
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
            .frame(height: 130) // Increase height of the bottom area
        }
        .alert("确定要退出此进程吗？", isPresented: $showKillAlert) {
            Button("退出") {
                if let pid = selectedPID { scanner.quitProcess(pid: pid, force: false) }
            }
            Button("强制退出", role: .destructive) {
                if let pid = selectedPID { scanner.quitProcess(pid: pid, force: true) }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("你确定要退出“\(selectedProcessName)”吗？")
        }
    }
}

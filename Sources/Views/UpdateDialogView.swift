import SwiftUI
import AppKit

// MARK: - 发现新版本弹窗（仿截图1）
struct UpdateAvailableSheet: View {
    @ObservedObject var updater: AppUpdater
    var accentColor: Color

    private var manifest: UpdateManifest? {
        if case let .available(m) = updater.phase { return m }
        return updater.latestManifest
    }

    private var isBusy: Bool {
        switch updater.phase {
        case .downloading, .verifying, .installing, .readyToRelaunch: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient(colors: [accentColor, accentColor.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现新版本").font(.system(size: 16, weight: .bold))
                }
                Spacer()
                Button(action: { updater.dismissUpdateSheet() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
            .padding(20)

            Divider()

            // 版本信息 + 更新内容
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let m = manifest {
                        Text("v\(m.version)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(accentColor)
                        Text("当前版本 v\(updater.currentVersion)，新版本已可用。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Divider().padding(.vertical, 4)

                        Text("更新内容").font(.system(size: 13, weight: .semibold))
                        Text(m.notes.isEmpty ? "本次更新包含若干优化与修复。" : m.notes)
                            .font(.system(size: 12))
                            .foregroundColor(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(maxHeight: 260)

            Divider()

            // 底部操作区
            VStack(spacing: 12) {
                // 进度展示
                switch updater.phase {
                case .downloading(let p):
                    VStack(spacing: 4) {
                        HStack {
                            Text("正在下载更新…").font(.system(size: 11)).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(p * 100))%").font(.system(size: 11, weight: .semibold)).foregroundColor(accentColor)
                        }
                        ProgressView(value: p).tint(accentColor)
                    }
                case .verifying:
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        Text("正在校验安全签名…").font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                    }
                case .installing, .readyToRelaunch:
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        Text("正在安装，应用即将自动重启…").font(.system(size: 11)).foregroundColor(.secondary)
                        Spacer()
                    }
                case .failed(let msg):
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 11))
                        Text(msg).font(.system(size: 11)).foregroundColor(.orange)
                        Spacer()
                    }
                default:
                    EmptyView()
                }

                if !isBusy {
                    HStack(spacing: 10) {
                        Button("取消") { updater.dismissUpdateSheet() }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(7)

                        Button("跳过此版本") { updater.skipCurrentVersion() }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(7)

                        Spacer()

                        Button(action: { updater.startUpdate() }) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 12))
                                Text("立即更新").font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 7)
                            .background(accentColor)
                            .cornerRadius(7)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - 更新记录弹窗（仿截图3，数据来自内置 CHANGELOG.md）
struct ChangelogSheet: View {
    @ObservedObject var updater: AppUpdater
    var accentColor: Color
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("更新记录").font(.system(size: 18, weight: .bold))
                Spacer()
                Button(action: { onClose() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            if updater.releaseHistory.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundColor(.secondary)
                    Text(updater.changelogLoadError ?? "暂无更新记录").font(.system(size: 13)).foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(updater.releaseHistory) { item in
                            ChangelogEntry(item: item, accentColor: accentColor,
                                           isCurrent: item.version == updater.currentVersion)
                        }
                    }
                    .padding(20)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("关闭") { onClose() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Color.gray.opacity(0.12))
                    .cornerRadius(7)
            }
            .padding(16)
        }
        .frame(width: 560, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { updater.loadReleaseHistory() }
    }
}

private struct ChangelogEntry: View {
    let item: ReleaseHistoryItem
    var accentColor: Color
    var isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("v\(item.version)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(isCurrent ? accentColor : Color.gray.opacity(0.6))
                    .cornerRadius(6)
                if isCurrent {
                    Text("当前版本").font(.system(size: 10, weight: .medium)).foregroundColor(accentColor)
                }
                Spacer()
                Text(item.date).font(.system(size: 11)).foregroundColor(.secondary)
            }

            changeGroup(title: "新增", items: item.added, color: .green)
            changeGroup(title: "变更", items: item.changed, color: .orange)
            changeGroup(title: "修复", items: item.fixed, color: .blue)
            changeGroup(title: "移除", items: item.removed, color: .red)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func changeGroup(title: String, items: [String], color: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(color)
                ForEach(items, id: \.self) { text in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(color.opacity(0.6)).frame(width: 4, height: 4).padding(.top, 6)
                        Text(markdownBold(text))
                            .font(.system(size: 12))
                            .foregroundColor(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // 简单处理 **加粗** markdown
    private func markdownBold(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

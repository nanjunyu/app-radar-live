import SwiftUI
import AppKit

// MARK: - Update Center (Grid)
struct UpdateCenterView: View {
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    var category: UpdateCategory
    @State private var searchText = ""
    
    var title: String {
        category == .appStore ? "App Store 更新" : "依赖库更新"
    }
    
    var filteredUpdates: [RadarUpdateApp] {
        var res = scanner.updates.filter { $0.category == category }
        if !searchText.isEmpty { res = res.filter { $0.name.localizedCaseInsensitiveContains(searchText) } }
        return res
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(title).font(.system(size: 24, weight: .bold))
                        Spacer()
                        Button(action: { scanner.scanUpdates() }) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }.buttonStyle(PlainButtonStyle()).foregroundColor(accentColor)
                    }.padding(.horizontal, 30).padding(.top, 20)
                    
                    if scanner.isScanningUpdates && filteredUpdates.isEmpty {
                        VStack(spacing: 14) {
                            ProgressView().scaleEffect(1.2)
                            Text("正在检查更新…").font(.title3).foregroundColor(.gray)
                        }.frame(maxWidth: .infinity, minHeight: 300)
                    } else if filteredUpdates.isEmpty {
                        VStack {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundColor(.green.opacity(0.6))
                            Text("系统已是最新状态").font(.title3).foregroundColor(.gray).padding()
                        }.frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 20)], spacing: 20) {
                            ForEach(filteredUpdates) { app in
                                NavigationLink(value: app) { AppGridCard(app: app, accentColor: accentColor) }.buttonStyle(PlainButtonStyle())
                            }
                        }.padding(.horizontal, 30)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索更新...")
            .navigationDestination(for: RadarUpdateApp.self) { app in AppDetailView(app: app, scanner: scanner, accentColor: accentColor) }
        }
    }
}

// MARK: - UI Components
struct AppGridCard: View {
    @ObservedObject var app: RadarUpdateApp
    var accentColor: Color
    @State private var isHovered = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            if let url = app.logoUrl {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFit().frame(width: 56, height: 56).cornerRadius(13).shadow(color: Color.black.opacity(0.1), radius: 4) }
                    else { fallbackIcon }
                }
            } else { fallbackIcon }

            // Text block
            VStack(alignment: .leading, spacing: 3) {
                Text(app.bestName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundColor(.primary)
                if let date = app.releaseDate {
                    Text(date).font(.system(size: 11)).foregroundColor(.gray)
                } else {
                    Text(app.developer ?? app.category.rawValue).font(.system(size: 11)).foregroundColor(.gray)
                }
                if let cur = app.currentVersion, let latest = app.latestVersion {
                    Text("\(cur) → \(latest)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(accentColor)
                        .lineLimit(1)
                }
                // 更新说明摘要
                Text(app.releaseNotes ?? "查看更新内容")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor)).cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(isHovered ? accentColor : Color.gray.opacity(0.15), lineWidth: isHovered ? 2 : 1))
        .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 12 : 6, y: 4)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { isHovered = h } }
    }
    var fallbackIcon: some View { RoundedRectangle(cornerRadius: 13).fill(Color.gray.opacity(0.1)).frame(width: 56, height: 56).overlay(Image(systemName: "app.fill").foregroundColor(.gray)) }
}

struct AppDetailView: View {
    @ObservedObject var app: RadarUpdateApp
    @ObservedObject var scanner: RadarScanner
    var accentColor: Color
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top, spacing: 24) {
                    if let url = app.logoUrl { AsyncImage(url: url) { p in if let img = p.image { img.resizable().scaledToFit().frame(width: 120).cornerRadius(26) } else { fallbackIcon } } } else { fallbackIcon }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(app.bestName).font(.system(size: 32, weight: .bold))
                        Text(app.developer ?? app.category.rawValue).font(.title3).foregroundColor(.gray)
                        Button(action: { scanner.executeAction(action: app.category == .appStore ? "update_mas" : "update_brew", app: app) }) {
                            Text("升级到最新版").font(.headline).foregroundColor(.white).padding(.horizontal, 24).padding(.vertical, 10).background(accentColor).cornerRadius(20)
                        }.buttonStyle(PlainButtonStyle()).padding(.top, 4)
                    }
                    Spacer()
                }
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    if let latest = app.latestVersion {
                        statItem(title: latest, subtitle: app.currentVersion.map { "当前 \($0)" } ?? "最新版本", icon: "arrow.up.circle.fill")
                        statDivider
                    }
                    if let rating = app.averageUserRating, rating > 0, let count = app.userRatingCount, count > 0 {
                        statItem(title: String(format: "%.1f", rating), subtitle: "\(formatRatingCount(count))个评分", icon: "star.fill")
                        statDivider
                    }
                    if let cr = app.contentRating {
                        statItem(title: cr, subtitle: "年龄分级", icon: "person.crop.square")
                        statDivider
                    }
                    if let genre = app.primaryGenre {
                        statItem(title: genre, subtitle: "类别", icon: "square.grid.2x2")
                        statDivider
                    }
                    if let langInfo = app.languageDisplay {
                        statItem(title: langInfo.primary, subtitle: langInfo.extraCount > 0 ? "+\(langInfo.extraCount)种语言" : "语言", icon: "globe")
                        statDivider
                    }
                    if let size = app.sizeStr {
                        statItem(title: size, subtitle: "大小", icon: "externaldrive")
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 10)
                Divider()
                if !app.screenshotUrls.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("预览").font(.title2).bold()
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                ForEach(app.screenshotUrls, id: \.self) { surl in
                                    if let u = URL(string: surl) { AsyncImage(url: u) { p in p.image?.resizable().scaledToFill().frame(height: 200).cornerRadius(16) } }
                                }
                            }
                        }
                    }
                }
                if let notes = app.releaseNotes {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("新功能").font(.title2).bold()
                            Spacer()
                            if let date = app.releaseDate { Text(date).font(.subheadline).foregroundColor(.gray) }
                        }
                        if let latest = app.latestVersion { Text("版本 \(latest)").font(.subheadline).foregroundColor(.gray) }
                        Text(notes).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(40)
        }.navigationTitle(app.bestName)
    }
    var fallbackIcon: some View { RoundedRectangle(cornerRadius: 26).fill(Color.gray.opacity(0.1)).frame(width: 120, height: 120) }
    var statDivider: some View { Divider().frame(height: 36).padding(.horizontal, 4) }
    func formatRatingCount(_ count: Int) -> String {
        if count >= 10000 { return String(format: "%.1f万", Double(count) / 10000.0) }
        return "\(count)"
    }
    func statItem(title: String, subtitle: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.title3).bold().lineLimit(1)
            HStack(spacing: 3) {
                Image(systemName: icon).font(.caption2).foregroundColor(.gray)
                Text(subtitle).font(.caption).foregroundColor(.gray).lineLimit(1)
            }
        }
        .frame(minWidth: 70)
        .padding(.horizontal, 12)
    }
}

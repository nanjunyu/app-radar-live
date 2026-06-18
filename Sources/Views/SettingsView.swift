import SwiftUI
import AppKit

struct SettingsView: View {
    @Binding var themeColorHex: String; var accentColor: Color
    struct AppTheme { let name: String; let hex: String }
    let themes = [AppTheme(name: "雅致白", hex: "#6B7280"), AppTheme(name: "优雅紫", hex: "#8B5CF6"), AppTheme(name: "活力绿", hex: "#10B981"), AppTheme(name: "科技蓝", hex: "#0EA5E9"), AppTheme(name: "日落橙", hex: "#F97316")]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("设置").font(.largeTitle).bold()
            VStack(alignment: .leading, spacing: 16) {
                HStack { Rectangle().fill(accentColor).frame(width: 4, height: 16).cornerRadius(2); Text("外观主题").font(.headline) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))], spacing: 16) {
                    ForEach(themes, id: \.hex) { theme in
                        Button(action: { themeColorHex = theme.hex }) {
                            VStack(spacing: 0) {
                                Rectangle().fill(Color(hex: theme.hex)).frame(height: 50).overlay(Image(systemName: themeColorHex == theme.hex ? "checkmark.circle.fill" : "paintpalette").foregroundColor(.white).font(.title2))
                                HStack { Text(theme.name).font(.system(size: 13, weight: .medium)); Spacer() }.padding(12).background(Color(NSColor.controlBackgroundColor))
                            }.cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(themeColorHex == theme.hex ? Color(hex: theme.hex) : Color.gray.opacity(0.2), lineWidth: 2))
                        }.buttonStyle(PlainButtonStyle())
                    }
                }
            }.padding(24).background(Color(NSColor.controlBackgroundColor)).cornerRadius(16).shadow(color: .black.opacity(0.05), radius: 10)
            Spacer()
        }.padding(40)
    }
}

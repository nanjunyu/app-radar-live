import Foundation
import AppKit
import ServiceManagement

/// 系统级偏好设置的真实落地（开机自启、Dock 图标显隐）
enum SystemPreferences {

    // MARK: - 开机自启动

    /// 应用当前实际的登录项状态
    static var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// 设置开机自启动，返回是否成功
    @discardableResult
    static func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            NSLog("设置开机自启动失败: \(error)")
            return false
        }
    }

    // MARK: - Dock 图标显隐

    /// 应用 Dock 图标显隐状态。hide=true 时切到 accessory（隐藏 Dock 图标，仅菜单栏常驻）
    static func applyDockIconVisibility(hidden: Bool) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(hidden ? .accessory : .regular)
            if !hidden {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

import SwiftUI
import AppKit
import Foundation

enum SidebarItem: Hashable {
    case monitorAll
    case updateAll
    case updateAppStore, updateBrew, updateNode, updateGit, updateOther
    case sysSettings, sysAbout
}

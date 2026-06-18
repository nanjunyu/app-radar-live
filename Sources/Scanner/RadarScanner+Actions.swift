import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    func executeAction(action: String, app: RadarUpdateApp) {
        DispatchQueue.global(qos: .userInitiated).async {
            if action == "update_mas" { ProcessRunner.runCommand("mas upgrade") }
            if action == "update_brew" { ProcessRunner.runCommand("brew upgrade \(app.name)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.scanUpdates() }
        }
    }
    
    func quitProcess(pid: Int, force: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let signal = force ? "-9" : "-15"
            ProcessRunner.runCommand("kill \(signal) \(pid)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.scanProcesses() }
        }
    }
}

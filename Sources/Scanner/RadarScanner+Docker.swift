import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    func startContainer(name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessRunner.runCommand("docker start \(name)")
            Thread.sleep(forTimeInterval: 0.5)
            self.scanProcesses(isAuto: true)
        }
    }
    
    func stopContainer(name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessRunner.runCommand("docker stop \(name)")
            Thread.sleep(forTimeInterval: 0.5)
            self.scanProcesses(isAuto: true)
        }
    }
}

import SwiftUI
import AppKit
import Foundation

// MARK: - Process Runner Utility
struct ProcessRunner {
    static let envPath = "export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin:~/.nvm/versions/node/v22.22.2/bin\"; "
    @discardableResult
    static func runCommand(_ command: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.arguments = ["-c", envPath + command]
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        do {
            try process.run()
            // Read data BEFORE waitUntilExit to avoid pipe buffer deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch { print("Command Error: \(error)") }
        return ""
    }
}

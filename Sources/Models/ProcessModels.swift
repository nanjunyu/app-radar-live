import SwiftUI
import AppKit
import Foundation

// 1. Activity Monitor (Processes)
enum ProcessTag: String, Comparable {
    case desktop = "Desktop"
    case node = "Node"
    case docker = "Docker"
    case brew = "Homebrew"
    case system = "System"
    
    var color: Color {
        switch self {
        case .desktop: return .blue; case .node: return .green; case .docker: return .cyan; case .brew: return .orange; case .system: return .gray
        }
    }
    static func < (lhs: ProcessTag, rhs: ProcessTag) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct SysProcess: Identifiable, Equatable {
    let id: Int // PID
    let name: String
    let cpu: Double
    let memKB: Double
    let user: String
    let cpuTime: String
    let threads: Int
    let ports: Int
    var tag: ProcessTag
    var iconImage: NSImage?
    
    var memStr: String {
        let mb = Double(memKB) / 1024.0
        if mb > 1024 { return String(format: "%.2f GB", mb / 1024.0) }
        return String(format: "%.1f MB", mb)
    }
    
    var kindStr: String {
        switch tag {
        case .desktop: return "App"
        case .node: return "Node"
        case .docker: return "Docker"
        case .brew: return "Homebrew"
        case .system: return "System"
        }
    }
    
    static func == (lhs: SysProcess, rhs: SysProcess) -> Bool {
        return lhs.id == rhs.id && lhs.cpu == rhs.cpu && lhs.memKB == rhs.memKB
    }
}

struct DockerContainer: Identifiable, Equatable {
    let id: String // Container ID (12 chars)
    let name: String
    let image: String
    let status: String
    let ports: String
    let cpu: String
    var mem: String = "-"
    
    var isRunning: Bool {
        status.lowercased().hasPrefix("up")
    }
    
    var formattedPorts: [String] {
        if ports.isEmpty { return [] }
        let rawParts = ports.components(separatedBy: ",")
        var result: [String] = []
        for part in rawParts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("->") {
                let subparts = trimmed.components(separatedBy: "->")
                if subparts.count == 2 {
                    let hostPart = subparts[0].components(separatedBy: ":").last ?? ""
                    let containerPart = subparts[1].components(separatedBy: "/").first ?? ""
                    if !hostPart.isEmpty && !containerPart.isEmpty {
                        let formatted = "\(hostPart):\(containerPart)"
                        if !result.contains(formatted) {
                            result.append(formatted)
                        }
                        continue
                    }
                }
            }
            let clean = trimmed.replacingOccurrences(of: "/tcp", with: "").replacingOccurrences(of: "/udp", with: "")
            if !clean.isEmpty {
                if !result.contains(clean) {
                    result.append(clean)
                }
            }
        }
        return result
    }
}

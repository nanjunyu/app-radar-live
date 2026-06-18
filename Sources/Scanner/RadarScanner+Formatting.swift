import SwiftUI
import AppKit
import Foundation

extension RadarScanner {
    func formatBytes(_ bytes: Double) -> String {
        let kb = bytes / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        if gb >= 1.0 { return String(format: "%.2f GB", gb) }
        if mb >= 1.0 { return String(format: "%.2f MB", mb) }
        if kb >= 1.0 { return String(format: "%.2f KB", kb) }
        return "\(Int(bytes)) 字节"
    }
    
    func formatDiskStr(_ str: String) -> String {
        let clean = str.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if clean.isEmpty || clean == "0" { return "0 字节" }
        if clean.hasSuffix("G") { return clean.replacingOccurrences(of: "G", with: " GB") }
        if clean.hasSuffix("M") { return clean.replacingOccurrences(of: "M", with: " MB") }
        if clean.hasSuffix("K") { return clean.replacingOccurrences(of: "K", with: " KB") }
        if clean.hasSuffix("T") { return clean.replacingOccurrences(of: "T", with: " TB") }
        return clean + " Bytes"
    }
    
    func formatMemoryGB(_ gbVal: Double) -> String {
        if gbVal <= 0 { return "0 字节" }
        if gbVal >= 1.0 {
            return String(format: "%.2f GB", gbVal)
        } else {
            let mbVal = gbVal * 1024.0
            if mbVal >= 1.0 {
                return String(format: "%.1f MB", mbVal)
            } else {
                let kbVal = mbVal * 1024.0
                return String(format: "%.1f KB", kbVal)
            }
        }
    }
    
    func formatNumber(_ val: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: val)) ?? "\(val)"
    }
}

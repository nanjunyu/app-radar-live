import AppKit
import Foundation

// 生成 AppRadar 新 logo：白底 + 紫粉→蓝渐变圆 + 居中白色鸽子剪影（现代扁平风）
// 用法: swift make_logo.swift <输出.png>

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make_logo.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[1]
let size: CGFloat = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 1) 白色背景（整张方形）
ctx.setFillColor(NSColor.white.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// 2) 渐变圆（紫粉 → 蓝），居中
let cx = size / 2, cy = size / 2
let r: CGFloat = 440
ctx.saveGState()
let circle = CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
ctx.addPath(circle)
ctx.clip()
let colors = [
    NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.86, alpha: 1).cgColor, // 顶部粉
    NSColor(calibratedRed: 0.72, green: 0.52, blue: 0.95, alpha: 1).cgColor, // 中部紫
    NSColor(calibratedRed: 0.50, green: 0.55, blue: 0.98, alpha: 1).cgColor  // 底部蓝
] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: cx, y: cy + r), end: CGPoint(x: cx, y: cy - r), options: [])
ctx.restoreGState()

// 3) 白色鸟形剪影：用系统 SF Symbol `bird.fill`（干净专业），居中放在渐变圆上
let symbolNames = ["bird.fill", "bird"]
var birdImg: NSImage? = nil
for n in symbolNames {
    let cfg = NSImage.SymbolConfiguration(pointSize: 460, weight: .regular)
    if let img = NSImage(systemSymbolName: n, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        birdImg = img; break
    }
}
if let bird = birdImg {
    // 染成白色
    let tinted = NSImage(size: bird.size)
    tinted.lockFocus()
    NSColor.white.set()
    let rect = NSRect(origin: .zero, size: bird.size)
    bird.draw(in: rect)
    rect.fill(using: .sourceAtop)
    tinted.unlockFocus()
    // 居中绘制（略缩放使其落在圆内）
    let target: CGFloat = 580
    let scale = min(target / tinted.size.width, target / tinted.size.height)
    let w = tinted.size.width * scale, h = tinted.size.height * scale
    tinted.draw(in: NSRect(x: cx - w/2, y: cy - h/2, width: w, height: h))
} else {
    // 兜底：找不到系统符号时画一个简单白色圆点
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: cx - 120, y: cy - 120, width: 240, height: 240)).fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try data.write(to: URL(fileURLWithPath: outPath)) }
catch { FileHandle.standardError.write("error: cannot write output\n".data(using: .utf8)!); exit(1) }
print("logo written to \(outPath)")

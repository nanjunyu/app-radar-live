import AppKit
import Foundation

// 把任意方形 logo 渲染成 macOS 标准 App 图标样式：
//   - 1024×1024 画布、透明背景
//   - 图案居中并留出四周边距（与系统其它图标一致，给阴影留空间）
//   - 套圆角(squircle 近似)遮罩，四角透明
// 用法: swift make_icon.swift <输入图片> <输出PNG>

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: make_icon.swift <input> <output.png>\n".data(using: .utf8)!)
    exit(1)
}
guard let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("error: cannot load input image\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[2]

let size: CGFloat = 1024
let margin: CGFloat = 100                 // 四周留白
let artSize = size - margin * 2           // 实际图案区域 824
let radius: CGFloat = artSize * 0.2237    // Big Sur 圆角比例近似

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
}

let artRect = CGRect(x: margin, y: margin, width: artSize, height: artSize)
let clip = NSBezierPath(roundedRect: artRect, xRadius: radius, yRadius: radius)
clip.addClip()
src.draw(in: artRect, from: .zero, operation: .sourceOver, fraction: 1.0)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try data.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("error: cannot write output\n".data(using: .utf8)!)
    exit(1)
}

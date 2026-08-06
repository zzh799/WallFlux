import AppKit
import CoreGraphics

// 生成 WallFlux 应用图标（1024×1024，全出血无 alpha，系统自动加圆角遮罩）
// 用法：swift tools/generate_app_icon.swift [输出路径]

let pixelSize = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: pixelSize,
    height: pixelSize,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    print("创建绘图上下文失败")
    exit(1)
}

// 深蓝渐变背景（左上亮 → 右下暗）
let colors = [
    CGColor(red: 0.05, green: 0.42, blue: 0.95, alpha: 1),
    CGColor(red: 0.04, green: 0.10, blue: 0.38, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: CGFloat(pixelSize)),
    end: CGPoint(x: CGFloat(pixelSize), y: 0),
    options: []
)

// 壁纸符号（白色，居中）
if let symbol = NSImage(systemSymbolName: "photo.stack.fill", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let scaled = symbol.withSymbolConfiguration(config) {
        var rect = NSRect(x: 256, y: 266, width: 512, height: 512)
        if let cgImage = scaled.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            // CoreGraphics 原点在左下角，需翻转 y
            let flipped = CGRect(x: rect.minX, y: CGFloat(pixelSize) - rect.maxY, width: rect.width, height: rect.height)
            ctx.draw(cgImage, in: flipped)
        }
    }
}

// 左下角装饰色块（模拟壁纸缩略图）
let blockColors = [
    CGColor(red: 0.20, green: 0.75, blue: 1.0, alpha: 0.95),
    CGColor(red: 0.60, green: 0.95, blue: 1.0, alpha: 0.60),
] as CFArray
let blockGradient = CGGradient(colorsSpace: colorSpace, colors: blockColors, locations: [0, 1])!
let blockRect = CGRect(x: 200, y: 200, width: 200, height: 120)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: blockRect, cornerWidth: 24, cornerHeight: 24, transform: nil))
ctx.clip()
ctx.drawLinearGradient(
    blockGradient,
    start: CGPoint(x: blockRect.minX, y: blockRect.maxY),
    end: CGPoint(x: blockRect.maxX, y: blockRect.minY),
    options: []
)
ctx.restoreGState()

guard let image = ctx.makeImage() else {
    print("生成位图失败")
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else {
    print("PNG 编码失败")
    exit(1)
}

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "WallFlux/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
try! png.write(to: URL(fileURLWithPath: output))
print("已生成图标：\(output)")

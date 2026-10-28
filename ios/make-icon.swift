import AppKit

// 画 1024×1024 的 App 图标：靛蓝渐变底，白色打开的锁，两侧信号波纹（SF 符号）。
// 重新生成：swift ios/make-icon.swift ios/ProximityUnlock/Assets.xcassets/AppIcon.appiconset/AppIcon.png
let out = CommandLine.arguments[1]
let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let full = NSRect(x: 0, y: 0, width: side, height: side)
NSGradient(colors: [NSColor(srgbRed: 0.47, green: 0.46, blue: 0.98, alpha: 1),
                    NSColor(srgbRed: 0.25, green: 0.19, blue: 0.74, alpha: 1)])!.draw(in: full, angle: -50)
// 左上角一点高光
NSGradient(colors: [NSColor(white: 1, alpha: 0.20), NSColor(white: 1, alpha: 0)])!
    .draw(fromCenter: NSPoint(x: 180, y: 880), radius: 0, toCenter: NSPoint(x: 180, y: 880), radius: 760, options: [])

func symbol(_ name: String, _ pointSize: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
}
func draw(_ image: NSImage, centerX: CGFloat, centerY: CGFloat) {
    let s = image.size
    image.draw(in: NSRect(x: centerX - s.width / 2, y: centerY - s.height / 2, width: s.width, height: s.height))
}
let lock = symbol("lock.open.fill", 330, .semibold, .white)
draw(lock, centerX: 530, centerY: 500)
let waveColor = NSColor(white: 1, alpha: 0.72)
draw(symbol("wave.3.left", 230, .semibold, waveColor), centerX: 512 - lock.size.width / 2 - 120, centerY: 470)
draw(symbol("wave.3.right", 230, .semibold, waveColor), centerX: 512 + lock.size.width / 2 + 120, centerY: 470)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("ok", lock.size)

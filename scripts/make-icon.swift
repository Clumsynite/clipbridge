// Renders Resources/AppIcon.icns and docs/icon.png for ClipBridge.
//   swift scripts/make-icon.swift
// macOS icon grid: 1024 canvas, 824-point rounded square, soft drop shadow.
// The glyph is drawn from plain shapes (a clipboard holding a terminal prompt), not an SF Symbol:
// Apple's terms don't allow SF Symbols in app icons.
import AppKit

let canvas: CGFloat = 1024
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 186

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    ctx.interpolationQuality = .high

    let tile = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(40, 70, 160).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Tile: teal at the top to indigo at the bottom.
    NSGradient(colors: [color(32, 196, 190), color(58, 92, 214), color(76, 52, 170)])!
        .draw(in: tile, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.22).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: radius - 2, yRadius: radius - 2)
    rim.lineWidth = 4
    rim.stroke()

    // Clipboard board.
    let board = NSRect(x: 262, y: 212, width: 500, height: 590)
    let boardPath = NSBezierPath(roundedRect: board, xRadius: 64, yRadius: 64)
    NSGraphicsContext.saveGraphicsState()
    let boardShadow = NSShadow()
    boardShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    boardShadow.shadowBlurRadius = 24
    boardShadow.shadowOffset = NSSize(width: 0, height: -10)
    boardShadow.set()
    color(250, 251, 255).setFill()
    boardPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Terminal screen on the board.
    let screen = NSRect(x: board.minX + 58, y: board.minY + 62, width: board.width - 116, height: 360)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 34, yRadius: 34)
    color(28, 32, 48).setFill()
    screenPath.fill()

    // Prompt: ">" chevron and "_" cursor, in the tile's teal.
    let accent = color(52, 220, 200)
    let chevron = NSBezierPath()
    let cx = screen.minX + 70, cy = screen.midY + 10
    chevron.move(to: NSPoint(x: cx, y: cy + 62))
    chevron.line(to: NSPoint(x: cx + 74, y: cy))
    chevron.line(to: NSPoint(x: cx, y: cy - 62))
    chevron.lineWidth = 34
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    accent.setStroke()
    chevron.stroke()
    let cursor = NSBezierPath(roundedRect: NSRect(x: cx + 120, y: cy - 78, width: 120, height: 32), xRadius: 16, yRadius: 16)
    accent.setFill()
    cursor.fill()

    // Two text lines above the screen (what's being copied).
    color(150, 160, 190).setFill()
    NSBezierPath(roundedRect: NSRect(x: board.minX + 58, y: screen.maxY + 44, width: 300, height: 26), xRadius: 13, yRadius: 13).fill()
    NSBezierPath(roundedRect: NSRect(x: board.minX + 58, y: screen.maxY + 92, width: 210, height: 26), xRadius: 13, yRadius: 13).fill()

    // Clip at the top of the board.
    let clip = NSRect(x: board.midX - 120, y: board.maxY - 52, width: 240, height: 104)
    let clipPath = NSBezierPath(roundedRect: clip, xRadius: 34, yRadius: 34)
    NSGraphicsContext.saveGraphicsState()
    let clipShadow = NSShadow()
    clipShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    clipShadow.shadowBlurRadius = 10
    clipShadow.shadowOffset = NSSize(width: 0, height: -5)
    clipShadow.set()
    NSGradient(colors: [color(214, 220, 236), color(160, 170, 198)])!.draw(in: clipPath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(110, 120, 150).setFill()
    NSBezierPath(ovalIn: NSRect(x: clip.midX - 22, y: clip.maxY - 44 - 8, width: 44, height: 44)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
try? fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
try? fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
let iconset = fm.temporaryDirectory.appendingPathComponent("ClipBridgeIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: base * scale).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(size: 512).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("docs/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")

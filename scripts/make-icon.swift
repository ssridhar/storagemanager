// Renders Resources/AppIcon.icns: a disk-ring on a rounded tile. Run: swift scripts/make-icon.swift
import AppKit

let colors: [NSColor] = [.systemBlue, .systemOrange, .systemTeal, .systemGreen, .systemPink, .systemYellow]
let shares: [CGFloat] = [0.26, 0.18, 0.14, 0.12, 0.1, 0.06]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.2, blue: 0.3, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1))!.draw(in: tilePath, angle: -90)

    let center = NSPoint(x: s / 2, y: s / 2)
    let radius = s * 0.27, width = s * 0.1
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    NSColor(white: 1, alpha: 0.12).setStroke()
    track.stroke()

    var angle: CGFloat = 90
    for (color, share) in zip(colors, shares) {
        let sweep = share * 360
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: angle - 2, endAngle: angle - sweep + 2, clockwise: true)
        arc.lineWidth = width
        color.setStroke()
        arc.stroke()
        angle -= sweep
    }
    let hub = NSBezierPath(ovalIn: NSRect(x: center.x - s * 0.06, y: center.y - s * 0.06, width: s * 0.12, height: s * 0.12))
    NSColor(white: 1, alpha: 0.85).setFill()
    hub.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print(set.path)

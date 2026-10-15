// Draws the app icon and writes an .icns file. The same icon as MegaGlass for Android
// (docs/logo.svg): a white cloud on a red gradient, on the macOS icon grid.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")

func color(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

/// An SVG arc (same x and y radius, no rotation) from the current point of `path` to `end`.
func addArc(_ path: CGMutablePath, to end: CGPoint, radius: CGFloat, large: Bool, sweep: Bool) {
    let start = path.currentPoint
    let half = CGPoint(x: (start.x - end.x) / 2, y: (start.y - end.y) / 2)
    let squared = half.x * half.x + half.y * half.y
    let r = max(radius, squared.squareRoot())
    let factor = (large == sweep ? -1 : 1) * max(0, (r * r - squared) / squared).squareRoot()
    let center = CGPoint(x: factor * half.y + (start.x + end.x) / 2, y: -factor * half.x + (start.y + end.y) / 2)
    path.addArc(center: center, radius: r,
                startAngle: atan2(start.y - center.y, start.x - center.x),
                endAngle: atan2(end.y - center.y, end.x - center.x),
                clockwise: !sweep)
}

/// The cloud of docs/logo.svg, in its 108-unit Android viewport.
func cloud() -> CGMutablePath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 38.46, y: 69.12))
    addArc(path, to: CGPoint(x: 39.33, y: 52.37), radius: 8.4, large: true, sweep: true)
    addArc(path, to: CGPoint(x: 63.93, y: 47.73), radius: 12.6, large: false, sweep: true)
    addArc(path, to: CGPoint(x: 67.02, y: 69.12), radius: 10.92, large: true, sweep: true)
    path.closeSubpath()
    return path
}

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let scale = size / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

    // Drop shadow.
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
    color(0x8E0B10).setFill()
    shape.fill()
    context.setShadow(offset: .zero, blur: 0, color: nil)

    // Body: the gradient of the Android icon, from the top left to the bottom right.
    NSGradient(colors: [color(0xFF3B30), color(0xD21F24), color(0x8E0B10)])!.draw(in: shape, angle: -45)

    // The visible part of the Android icon (units 18 to 90) fills the body; SVG y goes down.
    let unit = body.width / 72
    var transform = CGAffineTransform(a: unit, b: 0, c: 0, d: -unit,
                                      tx: body.minX - 18 * unit, ty: body.maxY + 18 * unit)
    if let path = cloud().copy(using: &transform) {
        context.addPath(path)
        context.setFillColor(.white)
        context.fillPath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = CGFloat(base * factor)
        let name = factor == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: pixels).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")

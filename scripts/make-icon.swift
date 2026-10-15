// Draws the app icon and writes an .icns file.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)

    // Drop shadow.
    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                                                   color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(red: 0.6, green: 0, blue: 0.04, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

    // Body: deep red to MEGA red.
    NSGradient(colors: [NSColor(red: 1.0, green: 0.27, blue: 0.24, alpha: 1),
                        NSColor(red: 0.85, green: 0.0, blue: 0.03, alpha: 1),
                        NSColor(red: 0.5, green: 0.0, blue: 0.06, alpha: 1)])!
        .draw(in: shape, angle: -70)

    // Glass: a soft top highlight and a thin bright rim.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let highlight = NSBezierPath(ovalIn: NSRect(x: body.minX - 120 * scale, y: body.midY + 40 * scale,
                                                width: body.width + 240 * scale, height: body.height * 0.9))
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.42), NSColor.white.withAlphaComponent(0.0)])!
        .draw(in: highlight, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.45).setStroke()
    shape.lineWidth = 6 * scale
    shape.stroke()

    // Cloud with a lock: encrypted storage.
    let config = NSImage.SymbolConfiguration(pointSize: 420 * scale, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 0.75, green: 0, blue: 0.04, alpha: 1), .white]))
    if let symbol = NSImage(systemSymbolName: "lock.icloud.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let rect = NSRect(x: body.midX - symbolSize.width / 2, y: body.midY - symbolSize.height / 2 - 10 * scale,
                          width: symbolSize.width, height: symbolSize.height)
        NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -6 * scale), blur: 18 * scale,
                                                       color: NSColor.black.withAlphaComponent(0.3).cgColor)
        symbol.draw(in: rect)
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

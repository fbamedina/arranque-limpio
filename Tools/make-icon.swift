// Genera AppIcon.icns para Arranque Limpio. Uso: swift Tools/make-icon.swift <salida.icns>
import AppKit

func render(_ side: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(side)
    // Rejilla de iconos de macOS: la baldosa ocupa ~80 % del lienzo.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.55, alpha: 1),
               ending: NSColor(calibratedRed: 0.02, green: 0.42, blue: 0.45, alpha: 1))!.draw(in: path, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, center: NSPoint, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        img.draw(in: NSRect(x: center.x - img.size.width / 2, y: center.y - img.size.height / 2,
                            width: img.size.width, height: img.size.height))
    }
    symbol("power", size: s * 0.36, weight: .semibold, center: NSPoint(x: s * 0.5, y: s * 0.52), color: .white)
    // Distintivo de "todo en orden".
    let badge = NSRect(x: s * 0.6, y: s * 0.16, width: s * 0.22, height: s * 0.22)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: badge).fill()
    symbol("checkmark", size: s * 0.1, weight: .heavy, center: NSPoint(x: badge.midX, y: badge.midY),
           color: NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.45, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
exit(task.terminationStatus)

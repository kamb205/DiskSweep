// Renders the 1024×1024 app icon PNG. Usage: swift make_icon.swift <output.png>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "icon_1024.png"
let px = 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt body inset 100pt, with a soft shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.56, blue: 1.0, alpha: 1),
           ending: NSColor(srgbRed: 0.45, green: 0.26, blue: 0.93, alpha: 1))!
    .draw(in: shape, angle: -90)

func drawSymbol(_ name: String, pointSize: CGFloat, center: NSPoint, alpha: CGFloat = 1) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }
    let size = symbol.size
    symbol.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                           width: size.width, height: size.height))
}

drawSymbol("internaldrive.fill", pointSize: 330, center: NSPoint(x: 500, y: 470))
drawSymbol("sparkles", pointSize: 200, center: NSPoint(x: 700, y: 700))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")

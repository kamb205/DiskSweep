// Renders the 1280×640 image GitHub shows when the repository link is shared.
// Usage: swift Scripts/make_social_preview.swift <icon_1024.png> <output.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let icon = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make_social_preview.swift icon.png out.png\n".data(using: .utf8)!)
    exit(1)
}
let size = NSSize(width: 1280, height: 640)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(colors: [NSColor(srgbRed: 0.07, green: 0.08, blue: 0.14, alpha: 1),
                    NSColor(srgbRed: 0.16, green: 0.10, blue: 0.28, alpha: 1)])!
    .draw(in: NSRect(origin: .zero, size: size), angle: -30)

icon.draw(in: NSRect(x: 90, y: 150, width: 340, height: 340))

func text(_ string: String, _ font: NSFont, _ color: NSColor, at point: NSPoint) {
    NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
}
text("DiskSweep", .systemFont(ofSize: 104, weight: .heavy), .white, at: NSPoint(x: 480, y: 340))
text("Clean up your Mac and make it fast again.", .systemFont(ofSize: 34, weight: .medium),
     NSColor.white.withAlphaComponent(0.85), at: NSPoint(x: 486, y: 280))
text("Free  ·  Open source  ·  macOS 26 Tahoe  ·  Apple silicon & Intel", .systemFont(ofSize: 24, weight: .regular),
     NSColor(srgbRed: 0.70, green: 0.62, blue: 1.0, alpha: 1), at: NSPoint(x: 488, y: 222))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))

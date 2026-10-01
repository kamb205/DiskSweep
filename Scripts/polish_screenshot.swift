// Tidies a snapshot-mode PNG for the README: paints over the toolbar controls (Liquid Glass can't be
// captured, so they render as white blobs) with the title bar colour, then scales it down.
// Usage: swift Scripts/polish_screenshot.swift <in.png> <out.png> [width]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let image = NSImage(contentsOfFile: args[1]),
      let source = image.representations.first as? NSBitmapImageRep ?? NSBitmapImageRep(data: image.tiffRepresentation!) else {
    FileHandle.standardError.write("usage: polish_screenshot.swift in.png out.png [width]\n".data(using: .utf8)!)
    exit(1)
}
let width = source.pixelsWide, height = source.pixelsHigh
let targetWidth = args.count > 3 ? Int(args[3])! : 1600
let scale = CGFloat(width) / 1280  // snapshots are taken of a 1280-point-wide window

guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let cg = source.cgImage else { exit(1) }
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

// Windows with a toolbar have a 52-point title bar; the start screen has a plain 28-point one.
// The controls sit at 98–210 pt and 858–1274 pt. Each pixel column is refilled from the title bar
// just above them, which keeps the sidebar/content colour split intact.
let hasToolbar = (source.colorAt(x: Int(150 * scale), y: Int(26 * scale))?.brightnessComponent ?? 0) > 0.9
if hasToolbar, let data = ctx.data?.assumingMemoryBound(to: UInt32.self) {
    let stride = ctx.bytesPerRow / 4
    for range in [(96.0, 212.0), (856.0, 1276.0)] {
        for x in Int(range.0 * scale)..<min(width, Int(range.1 * scale)) {
            let fill = data[Int(4 * scale) * stride + x]
            for y in Int(5 * scale)..<Int(48 * scale) { data[y * stride + x] = fill }
        }
    }
}

guard let painted = ctx.makeImage() else { exit(1) }
let targetHeight = Int(CGFloat(height) * CGFloat(targetWidth) / CGFloat(width))
guard let out = CGContext(data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
out.interpolationQuality = .high
out.draw(painted, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))

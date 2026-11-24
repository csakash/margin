// Cuts the icon tile out of its rendered canvas, leaving everything around it transparent.
//
// qlmanage renders design/icon.svg faithfully (blur and glass highlights included) but always on
// an opaque white page. Shipped as is, that white page becomes a white frame around the icon in
// the Dock. This keeps only the tile: the rounded rectangle at (16,16) 480×480 r112 in the SVG's
// 512 grid, which bundle.sh pads to a 600 grid.
//
//   swift scripts/mask-icon.swift <in.png> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: mask-icon.swift <in.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let px = 1024
let unit = CGFloat(px) / 600                // one SVG unit, after bundle.sh's padding
let inset: CGFloat = 1                      // drops the antialiased edge that blended with white
let tile = NSRect(x: (16 + 44) * unit, y: (16 + 44) * unit, width: 480 * unit, height: 480 * unit)
    .insetBy(dx: inset, dy: inset)
let radius = 112 * unit - inset

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).addClip()
src.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: args[2])) } catch {
    FileHandle.standardError.write("mask-icon: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}

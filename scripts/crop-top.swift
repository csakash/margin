// Keeps the top-left <width>×<height> pixels of a PNG. (sips -c crops around the centre, which
// pushed the disk image background up and let Quick Look's white page show below it.)
//
//   swift scripts/crop-top.swift <in.png> <out.png> <width> <height>
import AppKit

let a = CommandLine.arguments
guard a.count == 5, let w = Int(a[3]), let h = Int(a[4]),
      let src = NSImage(contentsOfFile: a[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil),
      cg.width >= w, cg.height >= h,
      let top = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) else {
    FileHandle.standardError.write("crop-top: bad arguments or image too small\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: top)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: a[2])) } catch { exit(1) }

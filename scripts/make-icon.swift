// SPDX-License-Identifier: GPL-3.0-or-later
// Builds the macOS AppIcon set from a square artwork image: the artwork is
// scaled to Apple's 824/1024 icon grid and clipped to a rounded rect, so the
// corners outside the shape are transparent.
// Usage: swift scripts/make-icon.swift <artwork.png|jpg> <AppIcon.appiconset dir>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOfFile: args[1]),
      let artCG = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("usage: make-icon.swift <artwork> <appiconset dir>\n", stderr)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let inset = s * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(artCG, in: rect)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = point * scale
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        try render(px).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(point)x\(point)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons to \(outDir.path)")

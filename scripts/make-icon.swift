// SPDX-License-Identifier: GPL-3.0-or-later
// Builds the legacy macOS AppIcon set and optionally a native Icon Composer
// document. Legacy bitmaps use the 824/1024 grid; native artwork fills its
// 1024-point canvas because the system supplies the enclosure and Dock inset.
// Usage: swift scripts/make-icon.swift <artwork> <AppIcon.appiconset> [AppIcon.icon]
import AppKit

let args = CommandLine.arguments
guard (3...4).contains(args.count), let art = NSImage(contentsOfFile: args[1]),
      let artCG = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("usage: make-icon.swift <artwork> <appiconset dir> [icon document]\n", stderr)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ size: Int, legacy: Bool = true) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let inset = legacy ? s * 100 / 1024 : 0
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    if legacy {
        let radius = rect.width * 0.225
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
    }
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

if args.count == 4 {
    let iconDir = URL(fileURLWithPath: args[3])
    let assets = iconDir.appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    // Image dimensions are points in Icon Composer, so normalize the original
    // artwork rather than letting a larger source image overflow the canvas.
    try render(1024, legacy: false).write(to: assets.appendingPathComponent("artwork.png"))
    let document: [String: Any] = [
        "fill": ["solid": "srgb:0.06000,0.12000,0.19000,1.00000"],
        "groups": [[
            "name": "Original artwork",
            "blur-material": 0,
            "layers": [["image-name": "artwork.png", "name": "mlv2Resolve", "glass": false]],
            "shadow": ["kind": "neutral", "opacity": 0],
            "specular": false,
            "translucency": ["enabled": false, "value": 0]
        ]],
        "supported-platforms": ["squares": ["macOS"]]
    ]
    let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: iconDir.appendingPathComponent("icon.json"))
    print("wrote native icon to \(iconDir.path)")
}

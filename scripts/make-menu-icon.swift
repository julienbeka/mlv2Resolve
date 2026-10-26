// SPDX-License-Identifier: GPL-3.0-or-later
// A template camera/ML mark derived from the app identity, drawn as vector paths.
// Usage: swift scripts/make-menu-icon.swift <MenuIcon.imageset>
import AppKit
let args = CommandLine.arguments
guard args.count == 2 else { fatalError("Expected the MenuIcon.imageset output directory") }
let output = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var box = CGRect(x: 0, y: 0, width: 28, height: 20)
let data = NSMutableData()
let consumer = CGDataConsumer(data: data)!
let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
context.beginPDFPage(nil)
let mark = CGMutablePath()
mark.move(to: CGPoint(x: 4, y: 15))
mark.addLine(to: CGPoint(x: 7, y: 15))
mark.addCurve(to: CGPoint(x: 10.5, y: 18.5), control1: CGPoint(x: 8.2, y: 15), control2: CGPoint(x: 8.3, y: 18.5))
mark.addLine(to: CGPoint(x: 17.5, y: 18.5))
mark.addCurve(to: CGPoint(x: 21, y: 15), control1: CGPoint(x: 19.7, y: 18.5), control2: CGPoint(x: 19.8, y: 15))
mark.addLine(to: CGPoint(x: 24, y: 15))
mark.addCurve(to: CGPoint(x: 27.5, y: 11.5), control1: CGPoint(x: 26.2, y: 15), control2: CGPoint(x: 27.5, y: 13.7))
mark.addLine(to: CGPoint(x: 27.5, y: 4.5))
mark.addCurve(to: CGPoint(x: 24, y: 1), control1: CGPoint(x: 27.5, y: 2.3), control2: CGPoint(x: 26.2, y: 1))
mark.addLine(to: CGPoint(x: 4, y: 1))
mark.addCurve(to: CGPoint(x: 0.5, y: 4.5), control1: CGPoint(x: 1.8, y: 1), control2: CGPoint(x: 0.5, y: 2.3))
mark.addLine(to: CGPoint(x: 0.5, y: 11.5))
mark.addCurve(to: CGPoint(x: 4, y: 15), control1: CGPoint(x: 0.5, y: 13.7), control2: CGPoint(x: 1.8, y: 15))
mark.closeSubpath()
mark.addRoundedRect(in: CGRect(x: 3, y: 3.7, width: 17.5, height: 9.5), cornerWidth: 1.5, cornerHeight: 1.5)
func polygon(_ points: [(CGFloat, CGFloat)]) {
    mark.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for point in points.dropFirst() { mark.addLine(to: CGPoint(x: point.0, y: point.1)) }
    mark.closeSubpath()
}
polygon([(4.7,5.1),(4.7,11.8),(7.1,11.8),(8.7,7.8),(10.2,11.8),(12.6,11.8),(12.6,5.1),(10.7,5.1),(10.7,9.1),(9.3,5.1),(8,5.1),(6.6,9.1),(6.6,5.1)])
polygon([(14,5.1),(14,11.8),(16,11.8),(16,6.9),(18.7,6.9),(18.7,5.1)])
mark.addEllipse(in: CGRect(x: 21.9, y: 12.1, width: 2.8, height: 2.8))
context.addPath(mark)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.drawPath(using: .eoFill)
context.endPDFPage(); context.closePDF()
try (data as Data).write(to: output.appendingPathComponent("menu-icon.pdf"))
let contents: [String: Any] = ["images": [["filename": "menu-icon.pdf", "idiom": "universal"]],
    "info": ["author": "xcode", "version": 1],
    "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
print("Wrote vector ML camera menu icon")

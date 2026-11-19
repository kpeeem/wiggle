import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let phone = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "ios"
let sizes = phone ? [1024] : [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: Double(size) / 1024, y: Double(size) / 1024)
    let plate = phone ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
    if !phone {
        context.addPath(CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil))
        context.clip()
    }
    context.setFillColor(CGColor(srgbRed: 0.965, green: 0.957, blue: 0.937, alpha: 1))
    context.fill(plate)
    let frame = { (x: Double, color: CGColor, width: Double) in
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.addPath(CGPath(
            roundedRect: CGRect(x: x, y: 364, width: 392, height: 296), cornerWidth: 44, cornerHeight: 44, transform: nil))
        context.strokePath()
    }
    let ink = CGColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    for step in 1...3 {
        frame(212 + Double(step) * 52, ink.copy(alpha: 0.16)!, 10)
    }
    frame(212, CGColor(srgbRed: 0.64, green: 0.33, blue: 0.10, alpha: 1), 28)
    frame(420, CGColor(srgbRed: 0.06, green: 0.42, blue: 0.36, alpha: 1), 28)
    let destination = CGImageDestinationCreateWithURL(
        directory.appendingPathComponent("icon_\(size).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}
let entries = phone ? [] : [(16, 1, 16), (16, 2, 32), (32, 1, 32), (32, 2, 64), (128, 1, 128), (128, 2, 256), (256, 1, 256), (256, 2, 512), (512, 1, 512), (512, 2, 1024)]
let images = phone ? [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon_1024.png"]] : entries.map { ["idiom": "mac", "size": "\($0.0)x\($0.0)", "scale": "\($0.1)x", "filename": "icon_\($0.2).png"] }
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: directory.appendingPathComponent("Contents.json"))

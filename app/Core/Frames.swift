import CoreGraphics
import Foundation
import ImageIO

struct WiggleError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

struct Gray {
    let width: Int
    let height: Int
    let pixels: [Float]
}

func loadFrames(from url: URL, maxPixelSize: Int) throws -> [CGImage] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
        throw WiggleError("Не удалось прочитать \(url.lastPathComponent)")
    }
    let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    let groups = properties?[kCGImagePropertyGroups] as? [[CFString: Any]] ?? []
    let pair = groups.first { $0[kCGImagePropertyGroupType] as? String == kCGImagePropertyGroupTypeStereoPair as String }
    var indexes = [CGImageSourceGetPrimaryImageIndex(source)]
    if let left = pair?[kCGImagePropertyGroupImageIndexLeft] as? Int, let right = pair?[kCGImagePropertyGroupImageIndexRight] as? Int {
        indexes = [left, right]
    }
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ] as CFDictionary
    return try indexes.map { index in
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
            throw WiggleError("Не удалось декодировать \(url.lastPathComponent)")
        }
        return image
    }
}

func isSpatialPhoto(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    let groups = properties?[kCGImagePropertyGroups] as? [[CFString: Any]] ?? []
    return groups.contains { $0[kCGImagePropertyGroupType] as? String == kCGImagePropertyGroupTypeStereoPair as String }
}

struct Placement {
    var a = 0.0
    var b = 1.0
    var c = 0.0
    var shift = 0.0

    func transform(width: Double) -> CGAffineTransform {
        CGAffineTransform(a: b, b: a, c: -a, d: b, tx: shift * width, ty: c * width)
    }
}

func render(
    _ image: CGImage, placement: Placement, sourceSize: CGSize, crop: CGRect, scale: Double = 1,
    levels: [[UInt8]]? = nil
) throws -> CGImage {
    let width = Int((crop.width * scale).rounded())
    let height = Int((crop.height * scale).rounded())
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw WiggleError("Не удалось создать изображение \(width)×\(height)") }
    let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceSize.height)
    let flipTarget = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(height))
    let placed = placement.transform(width: sourceSize.width)
        .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    context.interpolationQuality = .high
    context.concatenate(flipSource.concatenating(placed).concatenating(flipTarget))
    context.draw(image, in: CGRect(origin: .zero, size: sourceSize))
    if let levels, let data = context.data {
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            bytes[offset] = levels[0][Int(bytes[offset])]
            bytes[offset + 1] = levels[1][Int(bytes[offset + 1])]
            bytes[offset + 2] = levels[2][Int(bytes[offset + 2])]
        }
    }
    guard let result = context.makeImage() else { throw WiggleError("Не удалось создать изображение") }
    return result
}

func gray(_ image: CGImage, width: Int) -> Gray {
    let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
    var bytes = [UInt8](repeating: 0, count: width * height)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.interpolationQuality = .medium
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return Gray(width: width, height: height, pixels: bytes.map(Float.init))
}

func channelStatistics(_ image: CGImage) -> [(mean: Double, deviation: Double)] {
    let width = 96
    let height = max(1, width * image.height / image.width)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (0..<3).map { channel in
        let values = stride(from: channel, to: bytes.count, by: 4).map { Double(bytes[$0]) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, max(variance.squareRoot(), 1))
    }
}

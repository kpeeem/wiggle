import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

struct Failure: Error {
    let message: String
}

do {
    var paths: [String] = []
    var phases: [Double] = []
    var outputPath: String?
    var qualityName = "normal"
    var arguments = CommandLine.arguments.dropFirst()
    while let argument = arguments.popFirst() {
        switch argument {
        case "--phases":
            while let phase = arguments.first.flatMap(Double.init) {
                phases.append(phase)
                arguments.removeFirst()
            }
        case "--out":
            outputPath = arguments.popFirst()
        case "--quality":
            qualityName = arguments.popFirst() ?? ""
        default:
            paths.append(argument)
        }
    }
    let qualities: [String: VTFrameRateConversionConfiguration.QualityPrioritization] = ["normal": .normal, "quality": .quality]
    guard paths.count == 2, !phases.isEmpty, let outputPath, let quality = qualities[qualityName],
          phases.allSatisfy({ (0...1).contains($0) })
    else {
        throw Failure(message: "usage: run LEFT.png RIGHT.png --phases 0.25 0.5 0.75 --out DIR [--quality normal|quality]")
    }

    let images = try paths.map { path in
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure(message: "cannot read image \(path)") }
        return image
    }
    let outputWidth = images[0].width
    let outputHeight = images[0].height
    guard images[1].width == outputWidth, images[1].height == outputHeight else {
        throw Failure(message: "images differ in size")
    }
    let fit = min(1, 8192 / Double(outputWidth), 4320 / Double(outputHeight))
    let colorSpace = images[0].colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!

    var clock = ProcessInfo.processInfo.systemUptime
    let lap = {
        let now = ProcessInfo.processInfo.systemUptime
        defer { clock = now }
        return now - clock
    }

    guard VTFrameRateConversionConfiguration.isSupported else {
        throw Failure(message: "frame rate conversion is not supported on this system")
    }
    let processor = VTFrameProcessor()
    var started: VTFrameRateConversionConfiguration?
    var startFailure: Error = Failure(message: "cannot create configuration for \(outputWidth)x\(outputHeight)")
    for enlargement in [1, 1.1, 1.2, 1.34] where started == nil {
        guard let candidate = VTFrameRateConversionConfiguration(
            frameWidth: max(1, Int(Double(outputWidth) * fit * enlargement)),
            frameHeight: max(1, Int(Double(outputHeight) * fit * enlargement)),
            usePrecomputedFlow: false, qualityPrioritization: quality,
            revision: VTFrameRateConversionConfiguration.defaultRevision),
            candidate.supportedPixelFormats.contains(kCVPixelFormatType_64RGBAHalf)
        else { continue }
        do {
            try processor.startSession(configuration: candidate)
            started = candidate
        } catch {
            startFailure = error
        }
    }
    guard let configuration = started else { throw startFailure }
    let width = configuration.frameWidth
    let height = configuration.frameHeight
    let loadSeconds = lap()

    let makeBuffer = { (attributes: [String: Any]) in
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &buffer)
        guard let buffer else { throw Failure(message: "cannot create pixel buffer \(width)x\(height)") }
        return buffer
    }
    let halfFloatContext = { (buffer: CVPixelBuffer) in
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 16,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        else { throw Failure(message: "cannot create bitmap context") }
        return context
    }

    let sources = try zip(images, [CMTime.zero, CMTime(value: 1, timescale: 1)]).map { image, time in
        let buffer = try makeBuffer(configuration.sourcePixelBufferAttributes)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try halfFloatContext(buffer)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else {
            throw Failure(message: "cannot wrap source buffer")
        }
        return frame
    }
    let interpolate = { (phases: [Double]) in
        let destinations = try phases.map { phase in
            guard let frame = VTFrameProcessorFrame(
                buffer: try makeBuffer(configuration.destinationPixelBufferAttributes),
                presentationTimeStamp: CMTime(seconds: phase, preferredTimescale: 1_000_000))
            else { throw Failure(message: "cannot wrap destination buffer") }
            return frame
        }
        guard let parameters = VTFrameRateConversionParameters(
            sourceFrame: sources[0], nextFrame: sources[1], opticalFlow: nil,
            interpolationPhase: phases.map(Float.init), submissionMode: .random, destinationFrames: destinations)
        else { throw Failure(message: "cannot create parameters") }
        _ = try await processor.process(parameters: parameters)
        return destinations
    }

    _ = lap()
    _ = try await interpolate([0.5])
    let warmupSeconds = lap()
    let destinations = try await interpolate(phases)
    let batchSeconds = lap()
    processor.endSession()

    try FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true)
    let output = URL(fileURLWithPath: outputPath)
    for (phase, destination) in zip(phases, destinations) {
        CVPixelBufferLockBaseAddress(destination.buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(destination.buffer, .readOnly) }
        let url = output.appendingPathComponent(String(format: "frame_%.3f.png", phase))
        guard let interpolated = try halfFloatContext(destination.buffer).makeImage(),
              let context = CGContext(
                data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure(message: "cannot encode \(url.path)") }
        context.interpolationQuality = .high
        context.draw(interpolated, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        CGImageDestinationAddImage(file, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(file) else { throw Failure(message: "cannot write \(url.path)") }
    }
    let timing: [String: Any] = [
        "engine": "vt",
        "variant": "\(qualityName) revision\(configuration.revision.rawValue)",
        "width": outputWidth,
        "height": outputHeight,
        "load_seconds": loadSeconds,
        "warmup_seconds": warmupSeconds,
        "batch_seconds": batchSeconds,
        "frames": phases.map { ["phase": $0, "seconds": batchSeconds / Double(phases.count)] },
    ]
    try JSONSerialization.data(withJSONObject: timing, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("timing.json"))
} catch {
    FileHandle.standardError.write(Data("vt: \((error as? Failure)?.message ?? String(describing: error))\n".utf8))
    exit(1)
}

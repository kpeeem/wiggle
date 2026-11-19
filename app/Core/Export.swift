import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func write(_ wiggle: Wiggle, options: WiggleOptions, to url: URL) async throws {
    try? FileManager.default.removeItem(at: url)
    let width = wiggle.steps[0].width
    let height = wiggle.steps[0].height

    if options.format == .gif {
        let scale = min(1, 720 / Double(width))
        let gifWidth = Int(Double(width) * scale)
        let gifHeight = Int(Double(height) * scale)
        let rate = min(options.frameRate, 20)
        let count = max(2, Int((options.cycle * Double(rate)).rounded()))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw WiggleError("Не удалось создать файл \(url.lastPathComponent)")
        }
        CGImageDestinationSetProperties(
            destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 1 / Double(rate)]] as CFDictionary
        for frame in 0..<count {
            let step = wiggle.steps[options.stepIndex(at: Double(frame) / Double(rate), count: wiggle.steps.count)]
            guard let context = CGContext(
                data: nil, width: gifWidth, height: gifHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw WiggleError("Не удалось уменьшить кадр") }
            context.interpolationQuality = .high
            context.draw(step, in: CGRect(x: 0, y: 0, width: gifWidth, height: gifHeight))
            CGImageDestinationAddImage(destination, context.makeImage()!, delay)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw WiggleError("Не удалось записать \(url.lastPathComponent)")
        }
        return
    }

    var videoURL = url
    var identifier: String?
    if options.format == .livePhoto {
        let token = UUID().uuidString
        identifier = token
        videoURL = url.deletingPathExtension().appendingPathExtension("mov")
        try? FileManager.default.removeItem(at: videoURL)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw WiggleError("Не удалось создать файл \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(
            destination, wiggle.steps[options.stepIndex(at: 0, count: wiggle.steps.count)],
            [kCGImagePropertyMakerAppleDictionary: ["17": token]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WiggleError("Не удалось записать \(url.lastPathComponent)")
        }
    }

    let writer = try AVAssetWriter(outputURL: videoURL, fileType: identifier == nil ? .mp4 : .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: options.format == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    var stillMarker: AVAssetWriterInputMetadataAdaptor?
    if let identifier {
        let content = AVMutableMetadataItem()
        content.keySpace = .quickTimeMetadata
        content.key = "com.apple.quicktime.content.identifier" as NSString
        content.value = identifier as NSString
        content.dataType = "com.apple.metadata.datatype.UTF-8"
        writer.metadata = [content]
        let specification = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8",
        ]
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description)
        let markerInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        writer.add(markerInput)
        stillMarker = AVAssetWriterInputMetadataAdaptor(assetWriterInput: markerInput)
    }
    guard writer.startWriting() else { throw writer.error ?? WiggleError("Не удалось начать запись видео") }
    writer.startSession(atSourceTime: .zero)
    if let stillMarker {
        let still = AVMutableMetadataItem()
        still.keySpace = .quickTimeMetadata
        still.key = "com.apple.quicktime.still-image-time" as NSString
        still.value = 0 as NSNumber
        still.dataType = "com.apple.metadata.datatype.int8"
        stillMarker.append(AVTimedMetadataGroup(
            items: [still], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: Int32(options.frameRate)))))
        stillMarker.assetWriterInput.markAsFinished()
    }
    for frame in 0..<Int((options.duration * Double(options.frameRate)).rounded()) {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(4))
        }
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        guard let buffer else { throw WiggleError("Не удалось выделить кадр видео") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let step = wiggle.steps[options.stepIndex(at: Double(frame) / Double(options.frameRate), count: wiggle.steps.count)]
        context?.draw(step, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(options.frameRate))) else {
            throw writer.error ?? WiggleError("Не удалось записать кадр видео")
        }
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: options.duration, preferredTimescale: 600))
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? WiggleError("Запись видео не завершилась") }
}

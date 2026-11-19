import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

#if targetEnvironment(simulator)
final class Interpolator {
    static let isAvailable = false

    init(width: Int, height: Int) throws {
        throw WiggleError("В симуляторе нет интерполяции кадров")
    }

    func frames(between first: CGImage, and second: CGImage, phases: [Float]) async throws -> [CGImage] {
        []
    }
}
#else
final class Interpolator {
    static var isAvailable: Bool {
        VTFrameRateConversionConfiguration.isSupported
    }

    private let processor: VTFrameProcessor
    private let configuration: VTFrameRateConversionConfiguration
    private let outputWidth: Int
    private let outputHeight: Int
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int) throws {
        guard VTFrameRateConversionConfiguration.isSupported else {
            throw WiggleError("Интерполяция кадров не поддерживается на этом устройстве")
        }
        #if os(macOS)
        let limit = (width: 8192.0, height: 4320.0)
        #else
        let limit = (width: 4096.0, height: 2160.0)
        #endif
        let fit = min(1, limit.width / Double(width), limit.height / Double(height))
        let processor = VTFrameProcessor()
        var started: VTFrameRateConversionConfiguration?
        var failure: Error = WiggleError("Интерполяция не принимает кадр \(width)×\(height)")
        for enlargement in [1, 1.1, 1.2, 1.34] where started == nil {
            guard let candidate = VTFrameRateConversionConfiguration(
                frameWidth: max(1, Int(Double(width) * fit * enlargement)),
                frameHeight: max(1, Int(Double(height) * fit * enlargement)),
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: VTFrameRateConversionConfiguration.defaultRevision),
                candidate.supportedPixelFormats.contains(kCVPixelFormatType_64RGBAHalf)
            else { continue }
            do {
                try processor.startSession(configuration: candidate)
                started = candidate
            } catch {
                failure = error
            }
        }
        guard let started else { throw failure }
        self.processor = processor
        configuration = started
        outputWidth = width
        outputHeight = height
    }

    deinit {
        processor.endSession()
    }

    private func makeBuffer(_ attributes: [String: Any]) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, configuration.frameWidth, configuration.frameHeight, kCVPixelFormatType_64RGBAHalf,
            attributes as CFDictionary, &buffer)
        guard let buffer else { throw WiggleError("Не удалось выделить буфер кадра") }
        return buffer
    }

    private func halfFloatContext(_ buffer: CVPixelBuffer) throws -> CGContext {
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: configuration.frameWidth, height: configuration.frameHeight,
            bitsPerComponent: 16, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue)
        else { throw WiggleError("Не удалось создать контекст кадра") }
        return context
    }

    func frames(between first: CGImage, and second: CGImage, phases: [Float]) async throws -> [CGImage] {
        let bounds = CGRect(x: 0, y: 0, width: configuration.frameWidth, height: configuration.frameHeight)
        let sources = try zip([first, second], [CMTime.zero, CMTime(value: 1, timescale: 1)]).map { image, time in
            let buffer = try makeBuffer(configuration.sourcePixelBufferAttributes)
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let context = try halfFloatContext(buffer)
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
            guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else {
                throw WiggleError("Не удалось подготовить исходный кадр")
            }
            return frame
        }
        let destinations = try phases.map { phase in
            guard let frame = VTFrameProcessorFrame(
                buffer: try makeBuffer(configuration.destinationPixelBufferAttributes),
                presentationTimeStamp: CMTime(seconds: Double(phase), preferredTimescale: 1_000_000))
            else { throw WiggleError("Не удалось подготовить кадр результата") }
            return frame
        }
        guard let parameters = VTFrameRateConversionParameters(
            sourceFrame: sources[0], nextFrame: sources[1], opticalFlow: nil,
            interpolationPhase: phases, submissionMode: .random, destinationFrames: destinations)
        else { throw WiggleError("Не удалось настроить интерполяцию") }
        _ = try await processor.process(parameters: parameters)
        return try destinations.map { destination in
            CVPixelBufferLockBaseAddress(destination.buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(destination.buffer, .readOnly) }
            guard let interpolated = try halfFloatContext(destination.buffer).makeImage(),
                  let context = CGContext(
                    data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw WiggleError("Не удалось прочитать кадр результата") }
            context.interpolationQuality = .high
            context.draw(interpolated, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
            guard let image = context.makeImage() else { throw WiggleError("Не удалось прочитать кадр результата") }
            return image
        }
    }
}
#endif

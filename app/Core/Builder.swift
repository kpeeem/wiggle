import CoreGraphics
import Foundation

enum LoopMode: String, Codable, CaseIterable {
    case pingPong
    case forward
}

enum Easing: String, Codable, CaseIterable {
    case smooth
    case linear
}

enum ExportFormat: String, Codable, CaseIterable {
    case hevc
    case h264
    case gif
    case livePhoto
}

struct WiggleOptions: Codable, Equatable {
    var workingWidth = 1920
    var intermediateFrames = 7
    var alignGeometry = true
    var matchExposure = true
    var reversed = false
    var convergenceX: Double?
    var convergenceY: Double?
    var loop = LoopMode.pingPong
    var easing = Easing.smooth
    var swings = 3
    var duration = 3.0
    var frameRate = 30
    var format = ExportFormat.hevc
    var grade = Grade()

    var cycle: Double {
        duration / Double(max(swings, 1))
    }

    func stepIndex(at time: Double, count: Int) -> Int {
        let phase = (time / cycle).truncatingRemainder(dividingBy: 1)
        switch loop {
        case .forward:
            return min(Int(phase * Double(count)), count - 1)
        case .pingPong:
            let position = easing == .smooth ? 0.5 - 0.5 * cos(2 * .pi * phase) : 1 - abs(2 * phase - 1)
            return Int((position * Double(count - 1)).rounded())
        }
    }
}

struct Prepared {
    let frames: [CGImage]
    let size: CGSize
    let reference: Int
    let placements: [Placement]
    let ranges: [ClosedRange<Double>]
    let levels: [[[UInt8]]]
    let aligned: [Bool]
}

struct Wiggle {
    let steps: [CGImage]
    let keyframes: Int
    let crop: CGRect
    let workingSize: CGSize
}

func prepare(urls: [URL], workingWidth: Int, reversed: Bool, alignGeometry: Bool) async throws -> Prepared {
    var frames = try urls.flatMap { try loadFrames(from: $0, maxPixelSize: workingWidth == 0 ? 16384 : workingWidth * 2) }
    if reversed {
        frames.reverse()
    }
    guard frames.count >= 2 else {
        throw WiggleError("Нужен один spatial-снимок или минимум два снимка одной сцены")
    }
    let width = workingWidth == 0 ? frames[0].width : min(workingWidth, frames[0].width)
    let aspect = Double(frames[0].height) / Double(frames[0].width)
    guard frames.allSatisfy({ abs(Double($0.height) / Double($0.width) - aspect) < 0.02 }) else {
        throw WiggleError("У снимков разные пропорции")
    }
    let size = CGSize(width: Double(width), height: (Double(width) * aspect).rounded())
    let reference = (frames.count - 1) / 2
    let target = channelStatistics(frames[reference])

    var placements: [Placement] = []
    var ranges: [ClosedRange<Double>] = []
    var levels: [[[UInt8]]] = []
    var aligned: [Bool] = []
    for (index, frame) in frames.enumerated() {
        let statistics = channelStatistics(frame)
        levels.append((0..<3).map { channel in
            (0..<256).map { value in
                let gain = target[channel].deviation / statistics[channel].deviation
                let mapped = (Double(value) - statistics[channel].mean) * gain + target[channel].mean
                return UInt8(min(max(mapped.rounded(), 0), 255))
            }
        })
        guard index != reference else {
            placements.append(Placement())
            ranges.append(0...0)
            aligned.append(true)
            continue
        }
        var matches = findMatches(floating: frame, reference: frames[reference])
        var placement = Placement()
        let fit = alignGeometry ? fitVertical(matches) : nil
        if let fit {
            placement.a = fit.a
            placement.b = fit.b
            placement.c = fit.c
            matches = fit.inliers
        }
        let disparities = matches.map { $0.reference.x - (placement.b * $0.floating.x - placement.a * $0.floating.y) }.sorted()
        if disparities.isEmpty {
            ranges.append(-0.05...0.05)
        } else {
            placement.shift = disparities[disparities.count / 2]
            ranges.append(disparities[disparities.count / 50]...disparities[disparities.count - 1 - disparities.count / 50])
        }
        placements.append(placement)
        aligned.append(fit != nil || !alignGeometry)
    }
    return Prepared(
        frames: frames, size: size, reference: reference, placements: placements, ranges: ranges, levels: levels,
        aligned: aligned)
}

func build(_ prepared: Prepared, options: WiggleOptions) async throws -> Wiggle {
    let size = prepared.size
    var placements = prepared.placements
    if let x = options.convergenceX, let y = options.convergenceY {
        for index in placements.indices where index != prepared.reference {
            if let shift = try convergenceShift(
                at: CGPoint(x: x, y: y), reference: prepared.frames[prepared.reference], floating: prepared.frames[index],
                placement: placements[index], size: size, range: prepared.ranges[index])
            {
                placements[index].shift = shift
            }
        }
    }

    var left = 0.0
    var top = 0.0
    var right = size.width
    var bottom = size.height
    for placement in placements {
        let transform = placement.transform(width: size.width)
        let corners = [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            .map { $0.applying(transform) }
        left = max(left, corners[0].x, corners[2].x)
        right = min(right, corners[1].x, corners[3].x)
        top = max(top, corners[0].y, corners[1].y)
        bottom = min(bottom, corners[2].y, corners[3].y)
    }
    let cropWidth = Int((right.rounded(.down) - left.rounded(.up)) / 2) * 2
    let cropHeight = Int((bottom.rounded(.down) - top.rounded(.up)) / 2) * 2
    guard cropWidth >= 64, cropHeight >= 64 else {
        throw WiggleError("Снимки слишком сильно расходятся, общей области не осталось")
    }
    let crop = CGRect(x: left.rounded(.up), y: top.rounded(.up), width: Double(cropWidth), height: Double(cropHeight))

    let keyframes = try prepared.frames.indices.map { index in
        try render(
            prepared.frames[index], placement: placements[index], sourceSize: size, crop: crop,
            levels: options.matchExposure ? prepared.levels[index] : nil)
    }
    guard options.intermediateFrames > 0, Interpolator.isAvailable else {
        return Wiggle(steps: keyframes, keyframes: keyframes.count, crop: crop, workingSize: size)
    }
    let interpolator = try Interpolator(width: cropWidth, height: cropHeight)
    let phases = (1...options.intermediateFrames).map { Float($0) / Float(options.intermediateFrames + 1) }
    var steps = [keyframes[0]]
    for index in 1..<keyframes.count {
        try Task.checkCancellation()
        steps += try await interpolator.frames(between: keyframes[index - 1], and: keyframes[index], phases: phases)
        steps.append(keyframes[index])
    }
    return Wiggle(steps: steps, keyframes: keyframes.count, crop: crop, workingSize: size)
}

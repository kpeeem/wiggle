import CoreGraphics
import Foundation
import simd

struct Match {
    let floating: SIMD2<Double>
    let reference: SIMD2<Double>
}

struct Peak {
    let x: Double
    let y: Double
    let score: Float
}

func bestOffset(
    of patchOrigin: (x: Int, y: Int), size: Int, in floating: Gray, against reference: Gray,
    around guess: (x: Int, y: Int), rangeX: Int, rangeY: Int
) -> Peak? {
    var patch = [Float](repeating: 0, count: size * size)
    var mean: Float = 0
    for row in 0..<size {
        for column in 0..<size {
            let value = floating.pixels[(patchOrigin.y + row) * floating.width + patchOrigin.x + column]
            patch[row * size + column] = value
            mean += value
        }
    }
    mean /= Float(size * size)
    var energy: Float = 0
    for index in patch.indices {
        patch[index] -= mean
        energy += patch[index] * patch[index]
    }
    guard energy > Float(size * size) * 16 else { return nil }

    let minX = max(0, guess.x - rangeX)
    let maxX = min(reference.width - size, guess.x + rangeX)
    let minY = max(0, guess.y - rangeY)
    let maxY = min(reference.height - size, guess.y + rangeY)
    guard minX <= maxX, minY <= maxY else { return nil }
    let columns = maxX - minX + 1
    let rows = maxY - minY + 1
    var scores = [Float](repeating: -1, count: columns * rows)
    let count = Float(size * size)
    reference.pixels.withUnsafeBufferPointer { pixels in
        patch.withUnsafeBufferPointer { template in
            for y in minY...maxY {
                for x in minX...maxX {
                    var sum: Float = 0
                    var squares: Float = 0
                    var product: Float = 0
                    for row in 0..<size {
                        let line = (y + row) * reference.width + x
                        let templateLine = row * size
                        for column in 0..<size {
                            let value = pixels[line + column]
                            sum += value
                            squares += value * value
                            product += value * template[templateLine + column]
                        }
                    }
                    let variance = squares - sum * sum / count
                    if variance > count * 16 {
                        scores[(y - minY) * columns + (x - minX)] = product / (variance * energy).squareRoot()
                    }
                }
            }
        }
    }
    guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else { return nil }
    let column = best % columns
    let row = best / columns
    let refine = { (before: Float, center: Float, after: Float) -> Double in
        let curvature = before - 2 * center + after
        return curvature < 0 ? Double(0.5 * (before - after) / curvature) : 0
    }
    var x = Double(minX + column)
    var y = Double(minY + row)
    if column > 0, column < columns - 1 {
        x += refine(scores[best - 1], scores[best], scores[best + 1])
    }
    if row > 0, row < rows - 1 {
        y += refine(scores[best - columns], scores[best], scores[best + columns])
    }
    return Peak(x: x, y: y, score: scores[best])
}

func findMatches(floating: CGImage, reference: CGImage) -> [Match] {
    let coarseWidth = 192
    let fineWidth = min(768, reference.width)
    let ratio = Double(fineWidth) / Double(coarseWidth)
    let coarseFloating = gray(floating, width: coarseWidth)
    let coarseReference = gray(reference, width: coarseWidth)
    let fineFloating = gray(floating, width: fineWidth)
    let fineReference = gray(reference, width: fineWidth)
    let coarseSize = 16
    let fineSize = Int((Double(coarseSize) * ratio).rounded())
    var matches: [Match] = []
    for y in stride(from: 4, through: coarseFloating.height - coarseSize - 4, by: 10) {
        for x in stride(from: 4, through: coarseFloating.width - coarseSize - 4, by: 10) {
            guard let coarse = bestOffset(
                of: (x, y), size: coarseSize, in: coarseFloating, against: coarseReference,
                around: (x, y), rangeX: coarseWidth * 3 / 10, rangeY: coarseWidth * 7 / 100),
                coarse.score > 0.7
            else { continue }
            let origin = (x: Int((Double(x) * ratio).rounded()), y: Int((Double(y) * ratio).rounded()))
            guard origin.x + fineSize <= fineFloating.width, origin.y + fineSize <= fineFloating.height,
                  let fine = bestOffset(
                    of: origin, size: fineSize, in: fineFloating, against: fineReference,
                    around: (Int((coarse.x * ratio).rounded()), Int((coarse.y * ratio).rounded())), rangeX: 6, rangeY: 6),
                  fine.score > 0.8
            else { continue }
            let half = Double(fineSize) / 2
            matches.append(Match(
                floating: SIMD2(Double(origin.x) + half, Double(origin.y) + half) / Double(fineWidth),
                reference: SIMD2(fine.x + half, fine.y + half) / Double(fineWidth)))
        }
    }
    return matches
}

func fitVertical(_ matches: [Match], tolerance: Double = 1.5 / 1920) -> (a: Double, b: Double, c: Double, inliers: [Match])? {
    guard matches.count >= 12 else { return nil }
    let solve = { (sample: [Match]) -> SIMD3<Double>? in
        let design = simd_double3x3(rows: sample.map { SIMD3($0.floating.x, $0.floating.y, 1) })
        guard abs(design.determinant) > 1e-9 else { return nil }
        return design.inverse * SIMD3(sample[0].reference.y, sample[1].reference.y, sample[2].reference.y)
    }
    let residual = { (model: SIMD3<Double>, match: Match) in
        abs(model.x * match.floating.x + model.y * match.floating.y + model.z - match.reference.y)
    }
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    let next = { (bound: Int) -> Int in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
    var best: [Match] = []
    for _ in 0..<1500 {
        let sample = [matches[next(matches.count)], matches[next(matches.count)], matches[next(matches.count)]]
        guard let model = solve(sample) else { continue }
        let inliers = matches.filter { residual(model, $0) < tolerance }
        if inliers.count > best.count {
            best = inliers
        }
    }
    guard best.count >= 12 else { return nil }
    var normal = simd_double3x3()
    var target = SIMD3<Double>()
    for match in best {
        let row = SIMD3(match.floating.x, match.floating.y, 1)
        normal += simd_double3x3(columns: (row * row.x, row * row.y, row * row.z))
        target += row * match.reference.y
    }
    guard abs(normal.determinant) > 1e-12 else { return nil }
    let model = normal.inverse * target
    let rotation = atan2(model.x, model.y) * 180 / .pi
    let scale = (model.x * model.x + model.y * model.y).squareRoot()
    guard abs(rotation) < 10, scale > 0.8, scale < 1.25 else { return nil }
    return (model.x, model.y, model.z, best)
}

func convergenceShift(
    at point: CGPoint, reference: CGImage, floating: CGImage, placement: Placement, size: CGSize, range: ClosedRange<Double>
) throws -> Double? {
    let width = min(768, Int(size.width))
    let scale = Double(width) / size.width
    let full = CGRect(origin: .zero, size: size)
    var unshifted = placement
    unshifted.shift = 0
    let target = gray(try render(reference, placement: Placement(), sourceSize: size, crop: full, scale: scale), width: width)
    let moved = gray(try render(floating, placement: unshifted, sourceSize: size, crop: full, scale: scale), width: width)
    let patch = width / 8
    let x = min(max(Int(point.x * Double(target.width)) - patch / 2, 0), target.width - patch)
    let y = min(max(Int(point.y * Double(target.height)) - patch / 2, 0), target.height - patch)
    let low = Int((range.lowerBound * Double(width)).rounded(.down)) - patch / 2
    let high = Int((range.upperBound * Double(width)).rounded(.up)) + patch / 2
    let center = x - (low + high) / 2
    guard let peak = bestOffset(
        of: (x, y), size: patch, in: target, against: moved, around: (center, y), rangeX: (high - low) / 2 + 1, rangeY: 0)
    else { return nil }
    return (Double(x) - peak.x) / Double(width)
}

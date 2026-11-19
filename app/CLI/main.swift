import Foundation

var options = WiggleOptions()
var paths: [String] = []
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--frames": options.intermediateFrames = Int(arguments.popFirst() ?? "") ?? 7
    case "--width": options.workingWidth = Int(arguments.popFirst() ?? "") ?? 1920
    case "--duration": options.duration = Double(arguments.popFirst() ?? "") ?? 3
    case "--fps": options.frameRate = Int(arguments.popFirst() ?? "") ?? 30
    case "--swings": options.swings = Int(arguments.popFirst() ?? "") ?? 3
    case "--converge":
        options.convergenceX = Double(arguments.popFirst() ?? "")
        options.convergenceY = Double(arguments.popFirst() ?? "")
    case "--no-align": options.alignGeometry = false
    case "--reverse": options.reversed = true
    case "--linear": options.easing = .linear
    case "--h264": options.format = .h264
    case "--gif": options.format = .gif
    case "--live": options.format = .livePhoto
    case "--look": options.grade.look = arguments.popFirst() ?? "none"
    case "--exposure": options.grade.exposure = Double(arguments.popFirst() ?? "") ?? 0
    default: paths.append(argument)
    }
}
guard paths.count >= 2 else {
    FileHandle.standardError.write(Data("usage: wiggle-cli OUTPUT INPUT... [--frames N] [--width W] [--converge X Y] [--duration S] [--fps N] [--swings N] [--no-align] [--reverse] [--linear] [--h264] [--gif]\n".utf8))
    exit(2)
}

do {
    var clock = Date()
    let lap = {
        defer { clock = Date() }
        return String(format: "%.2f s", Date().timeIntervalSince(clock))
    }
    let prepared = try await prepare(
        urls: paths.dropFirst().map { URL(fileURLWithPath: $0) }, workingWidth: options.workingWidth,
        reversed: options.reversed, alignGeometry: options.alignGeometry)
    print("prepare \(lap()): \(prepared.frames.count) frames, working size \(Int(prepared.size.width))x\(Int(prepared.size.height))")
    for (index, placement) in prepared.placements.enumerated() where index != prepared.reference {
        print(String(
            format: "  frame %d: rotation %+.2f deg, scale %.4f, vertical %+.1f px, disparity %+.0f..%+.0f px, median %+.1f px%@",
            index, atan2(placement.a, placement.b) * 180 / .pi, hypot(placement.a, placement.b), placement.c * prepared.size.width,
            prepared.ranges[index].lowerBound * prepared.size.width, prepared.ranges[index].upperBound * prepared.size.width,
            placement.shift * prepared.size.width, prepared.aligned[index] ? "" : " (alignment failed)"))
    }
    let wiggle = graded(try await build(prepared, options: options), grade: options.grade)
    print("build \(lap()): \(wiggle.steps.count) steps \(wiggle.steps[0].width)x\(wiggle.steps[0].height)")
    try await write(wiggle, options: options, to: URL(fileURLWithPath: paths[0]))
    print("export \(lap()): \(paths[0])")
} catch {
    FileHandle.standardError.write(Data("wiggle-cli: \(error.localizedDescription)\n".utf8))
    exit(1)
}

import SwiftUI

struct LoopPreview: View {
    let project: Project
    let wiggle: Wiggle

    var body: some View {
        let size = CGSize(width: wiggle.steps[0].width, height: wiggle.steps[0].height)
        TimelineView(.animation(paused: !project.isPlaying)) { context in
            let index = project.options.stepIndex(at: context.date.timeIntervalSinceReferenceDate, count: wiggle.steps.count)
            Image(decorative: wiggle.steps[min(index, wiggle.steps.count - 1)], scale: 1)
                .resizable()
                .interpolation(.high)
        }
        .aspectRatio(size, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { location in
                            project.pickConvergence(x: location.x / geometry.size.width, y: location.y / geometry.size.height)
                        }
                    if let marker = project.convergenceMarker {
                        Image(systemName: "scope")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.45), in: .circle)
                            .position(x: marker.x * geometry.size.width, y: marker.y * geometry.size.height)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .help("Нажмите на объект, который должен стоять на месте")
        .accessibilityLabel("Предпросмотр wiggle")
    }
}

struct CameraRail: View {
    let project: Project
    let wiggle: Wiggle

    var body: some View {
        TimelineView(.animation(paused: !project.isPlaying)) { context in
            let count = wiggle.steps.count
            let current = project.options.stepIndex(at: context.date.timeIntervalSinceReferenceDate, count: count)
            let spacing = (count - 1) / max(wiggle.keyframes - 1, 1)
            Canvas { canvas, size in
                let inset = 6.0
                let step = (size.width - inset * 2) / Double(max(count - 1, 1))
                let middle = size.height / 2
                canvas.fill(
                    Path(CGRect(x: inset, y: middle - 0.5, width: size.width - inset * 2, height: 1)), with: .color(.primary.opacity(0.12)))
                for index in 0..<count {
                    let isSource = index % max(spacing, 1) == 0
                    let height = isSource ? 12.0 : 4.0
                    let tick = CGRect(x: inset + Double(index) * step - 1, y: middle - height / 2, width: 2, height: height)
                    canvas.fill(Path(roundedRect: tick, cornerRadius: 1), with: .color(.primary.opacity(isSource ? 0.55 : 0.22)))
                }
                let head = CGRect(x: inset + Double(current) * step - 5, y: middle - 5, width: 10, height: 10)
                canvas.fill(Path(ellipseIn: head), with: .color(.accentColor))
            }
        }
        .help("Положение камеры: высокие риски это снимки, короткие это достроенные кадры")
        .accessibilityLabel("Положение камеры между снимками")
    }
}

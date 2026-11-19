import Photos
import SwiftUI

struct GradeTool: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let path: WritableKeyPath<Grade, Double>?
    let range: ClosedRange<Double>
    let neutral: Double
}

private let gradeTools = [
    GradeTool(id: "film", title: "Плёнка", symbol: "camera.filters", path: nil, range: 0...1, neutral: 0),
    GradeTool(id: "exposure", title: "Экспозиция", symbol: "plusminus.circle", path: \.exposure, range: -2...2, neutral: 0),
    GradeTool(id: "contrast", title: "Контраст", symbol: "circle.lefthalf.filled", path: \.contrast, range: 0.5...1.5, neutral: 1),
    GradeTool(id: "saturation", title: "Насыщ.", symbol: "drop", path: \.saturation, range: 0...2, neutral: 1),
    GradeTool(id: "warmth", title: "Теплота", symbol: "thermometer.medium", path: \.warmth, range: -1...1, neutral: 0),
    GradeTool(id: "vignette", title: "Виньетка", symbol: "circle.dashed", path: \.vignette, range: 0...1, neutral: 0),
]

struct EditorScreen: View {
    @Bindable var project: Project
    @Environment(\.dismiss) private var dismiss
    @State private var showsSettings = false
    @State private var saved: String?
    @State private var savedCount = 0
    @State private var toolID = "film"
    @State private var thumbnails: [String: CGImage] = [:]

    private let formats: [(title: String, format: ExportFormat)] = [("Видео", .hevc), ("Live Photo", .livePhoto), ("GIF", .gif)]

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        topBar
                            .frame(height: 52)
                            .padding(.horizontal, 16)
                        stage
                    }
                    ScrollView {
                        panel
                            .padding(.vertical, 12)
                    }
                    .scrollIndicators(.never)
                    .frame(width: min(360, geometry.size.width * 0.42))
                }
            } else {
                VStack(spacing: 0) {
                    topBar
                        .frame(height: 56)
                        .padding(.horizontal, 16)
                    stage
                    panel
                        .padding(.bottom, 12)
                }
            }
        }
        .background(.black)
        .sheet(isPresented: $showsSettings) {
            SettingsSheet(project: project)
        }
        .sensoryFeedback(.success, trigger: savedCount)
        .sensoryFeedback(.selection, trigger: project.options.grade.look)
        .task(id: project.ungraded?.steps.first.map(ObjectIdentifier.init)) {
            guard let source = project.ungraded?.steps.first else { return }
            thumbnails = await Task.detached {
                let side = 160
                let scale = Double(side) / Double(min(source.width, source.height))
                let width = Int(Double(source.width) * scale)
                let height = Int(Double(source.height) * scale)
                guard let context = CGContext(
                    data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                else { return [:] }
                context.interpolationQuality = .medium
                context.draw(source, in: CGRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
                guard let small = context.makeImage() else { return [:] }
                var result: [String: CGImage] = [:]
                for look in filmLooks {
                    var grade = Grade()
                    grade.look = look.id
                    result[look.id] = apply(grade, to: small)
                }
                return result
            }.value
        }
    }

    private var topBar: some View {
        HStack {
            Button("Камера", systemImage: "camera") {
                dismiss()
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glassEffect(in: .capsule)
            Spacer()
            Button(project.isPlaying ? "Пауза" : "Воспроизвести", systemImage: project.isPlaying ? "pause.fill" : "play.fill") {
                project.isPlaying.toggle()
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .glassEffect(in: .circle)
            .disabled(project.wiggle == nil)
            Button("Настройки", systemImage: "slider.horizontal.3") {
                showsSettings = true
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .glassEffect(in: .circle)
        }
        .foregroundStyle(.white)
    }

    private var stage: some View {
        ZStack {
            if let wiggle = project.wiggle {
                LoopPreview(project: project, wiggle: wiggle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else if let failure = project.failure {
                ContentUnavailableView("Не получилось собрать wiggle", systemImage: "exclamationmark.triangle", description: Text(failure))
            }
            if project.isWorking || project.isExporting {
                ProgressView(project.isExporting ? "Сохранение" : "Обработка")
                    .controlSize(.large)
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .glassEffect(in: .rect(cornerRadius: 20))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panel: some View {
        VStack(spacing: 12) {
            if let wiggle = project.wiggle {
                CameraRail(project: project, wiggle: wiggle)
                    .frame(height: 20)
                    .padding(.horizontal, 24)
            }
            Text(statusText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
            toolContent
                .frame(height: 88)
            toolBar
            formatPicker
                .padding(.horizontal, 16)
            actions
                .padding(.horizontal, 16)
        }
    }

    private func isChanged(_ tool: GradeTool) -> Bool {
        guard let path = tool.path else { return project.options.grade.look != "none" }
        return abs(project.options.grade[keyPath: path] - tool.neutral) > 0.001
    }

    @ViewBuilder private var toolContent: some View {
        if let tool = gradeTools.first(where: { $0.id == toolID }), let path = tool.path {
            let value = Binding(
                get: { project.options.grade[keyPath: path] },
                set: { project.options.grade[keyPath: path] = $0 })
            HStack(spacing: 12) {
                Slider(value: value, in: tool.range)
                    .accessibilityLabel(tool.title)
                Text((value.wrappedValue - tool.neutral).formatted(.number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false))))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .trailing)
                Button("Сбросить", systemImage: "arrow.uturn.backward") {
                    value.wrappedValue = tool.neutral
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .glassEffect(in: .circle)
                .disabled(!isChanged(tool))
            }
            .padding(.horizontal, 16)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(filmLooks, id: \.id) { look in
                        let selected = look.id == project.options.grade.look
                        Button {
                            project.options.grade.look = look.id
                        } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if let thumbnail = thumbnails[look.id] {
                                        Image(decorative: thumbnail, scale: 1)
                                            .resizable()
                                    } else {
                                        Color.white.opacity(0.08)
                                    }
                                }
                                .frame(width: 60, height: 60)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                                Text(look.title)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(selected ? Color.accentColor : .white.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Плёнка \(look.title)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.never)
        }
    }

    private var toolBar: some View {
        HStack(spacing: 0) {
            ForEach(gradeTools) { tool in
                let selected = tool.id == toolID
                Button {
                    toolID = tool.id
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .frame(height: 24)
                            .overlay(alignment: .topTrailing) {
                                if isChanged(tool) {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 6, height: 6)
                                        .offset(x: 6, y: -2)
                                }
                            }
                        Text(tool.title)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selected ? Color.accentColor : .white.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
    }

    private var statusText: String {
        if let saved {
            return saved
        }
        if let notice = project.notice {
            return notice
        }
        if project.wiggle == nil {
            return " "
        }
        return project.options.convergenceX == nil ? "Коснитесь объекта, и он останется на месте" : "Точка сведения выбрана"
    }

    private var formatPicker: some View {
        HStack(spacing: 8) {
            ForEach(formats, id: \.title) { item in
                let selected = item.format == project.options.format || (item.format == .hevc && project.options.format == .h264)
                Button {
                    project.options.format = item.format
                    saved = nil
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? Color.accentColor : .white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(selected ? Color.white.opacity(0.14) : .clear, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(in: .capsule)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                Task { await saveToPhotos() }
            } label: {
                Label("Сохранить в Фото", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.accentColor, in: .capsule)
            }
            .buttonStyle(ShutterStyle())
            .disabled(project.wiggle == nil || project.isExporting || project.isWorking)
            .opacity(project.wiggle == nil ? 0.4 : 1)

            if let exported = project.exported {
                ShareLink(items: sharedFiles(exported)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .glassEffect(in: .circle)
                }
                .accessibilityLabel("Поделиться")
            }
        }
    }

    private func sharedFiles(_ url: URL) -> [URL] {
        url.pathExtension == "heic" ? [url, url.deletingPathExtension().appendingPathExtension("mov")] : [url]
    }

    private func saveToPhotos() async {
        saved = nil
        let format = project.options.format
        let suffix = format == .gif ? "gif" : format == .livePhoto ? "heic" : "mp4"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("wiggle").appendingPathExtension(suffix)
        guard await project.export(to: url) else { return }
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
            saved = "Нет доступа к медиатеке. Разрешите добавление фото в Настройках"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                switch format {
                case .livePhoto:
                    request.addResource(with: .photo, fileURL: url, options: nil)
                    request.addResource(with: .pairedVideo, fileURL: url.deletingPathExtension().appendingPathExtension("mov"), options: nil)
                case .gif:
                    request.addResource(with: .photo, fileURL: url, options: nil)
                case .hevc, .h264:
                    request.addResource(with: .video, fileURL: url, options: nil)
                }
            }
            saved = format == .livePhoto ? "Live Photo сохранено в Фото" : "Сохранено в Фото"
            savedCount += 1
        } catch {
            saved = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }
}

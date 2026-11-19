import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PickedImage: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let suffix = received.file.pathExtension.isEmpty ? "heic" : received.file.pathExtension
            let target = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedImage(url: target)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let isRunning: Bool
    let angle: CGFloat

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}

struct CameraScreen: View {
    @Bindable var project: Project
    @State private var camera = Camera()
    @State private var showsEditor = false
    @State private var showsSettings = false
    @State private var spatialSelection: [PhotosPickerItem] = []
    @State private var sequenceSelection: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var picksSpatial = false
    @State private var picksSequence = false
    @State private var blink = false

    private var canShoot: Bool {
        camera.isRunning && camera.isLandscape && !camera.isCapturing && camera.failure == nil
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            let angle: CGFloat = wide && camera.isLandscape ? camera.captureAngle : 90
            if wide {
                HStack(spacing: 0) {
                    VStack(spacing: 12) {
                        quickControls
                    }
                    .frame(width: 136)
                    .padding(.vertical, 16)
                    viewfinder(angle: angle, ratio: 4 / 3)
                    VStack(spacing: 0) {
                        controls
                    }
                    .frame(width: 136)
                    .padding(.vertical, 16)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        quickControls
                    }
                    .frame(height: 56)
                    .padding(.horizontal, 16)
                    viewfinder(angle: angle, ratio: 3 / 4)
                    Spacer(minLength: 0)
                    HStack {
                        controls
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(.black)
        .statusBarHidden()
        .animation(.easeOut(duration: 0.2), value: camera.isLandscape)
        .onAppear {
            let defaults = UserDefaults.standard
            guard let paths = defaults.string(forKey: "WiggleOpen") else {
                camera.start()
                return
            }
            if defaults.object(forKey: "WiggleFrames") != nil {
                project.options.intermediateFrames = defaults.integer(forKey: "WiggleFrames")
            }
            if let look = defaults.string(forKey: "WiggleLook") {
                project.options.grade.look = look
            }
            project.open(paths.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
            if let point = defaults.string(forKey: "WiggleConverge")?.split(separator: ",").compactMap({ Double($0) }), point.count == 2 {
                project.options.convergenceX = point[0]
                project.options.convergenceY = point[1]
            }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                showsEditor = true
            }
        }
        .fullScreenCover(isPresented: $showsEditor) {
            EditorScreen(project: project)
        }
        .onChange(of: showsEditor) { _, shown in
            shown ? camera.stop() : camera.start()
        }
        .sheet(isPresented: $showsSettings) {
            SettingsSheet(project: project)
        }
        .photosPicker(
            isPresented: $picksSpatial, selection: $spatialSelection, maxSelectionCount: 1, matching: .spatialMedia,
            preferredItemEncoding: .current)
        .photosPicker(
            isPresented: $picksSequence, selection: $sequenceSelection, maxSelectionCount: 8, selectionBehavior: .ordered,
            matching: .images, preferredItemEncoding: .current)
        .onChange(of: spatialSelection) { _, items in
            Task { await load(items) }
        }
        .onChange(of: sequenceSelection) { _, items in
            Task { await load(items) }
        }
    }

    @ViewBuilder private var quickControls: some View {
        Button("Настройки", systemImage: "slider.horizontal.3") {
            showsSettings = true
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .glassEffect(in: .circle)
        Spacer()
        QuickChip(title: "+\(project.options.intermediateFrames) кадров") {
            let steps = [3, 5, 7, 11, 15]
            project.options.intermediateFrames = steps.first { $0 > project.options.intermediateFrames } ?? steps[0]
        }
        QuickChip(title: "\(project.options.duration.formatted(.number.precision(.fractionLength(0...1)))) с") {
            let steps = [2.0, 3, 5, 8]
            project.options.duration = steps.first { $0 > project.options.duration } ?? steps[0]
        }
    }

    private func viewfinder(angle: CGFloat, ratio: CGFloat) -> some View {
        ZStack {
            CameraPreview(session: camera.session, isRunning: camera.isRunning, angle: angle)
            Color.black.opacity(blink ? 1 : 0)
            if let failure = camera.failure {
                Banner(systemImage: "exclamationmark.triangle", text: failure)
            } else if camera.isRunning && !camera.isLandscape {
                Banner(systemImage: "rotate.right", text: "Поверните телефон горизонтально: только так объективы стоят рядом")
            } else if camera.isCapturing || isLoading {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(20)
                    .glassEffect(in: .circle)
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var controls: some View {
            Button {
                showsEditor = true
            } label: {
                Group {
                    if let still = project.wiggle?.steps.first {
                        Image(decorative: still, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(project.wiggle == nil)
            .accessibilityLabel("Последний результат")

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.08)) { blink = true }
                withAnimation(.easeIn(duration: 0.25).delay(0.08)) { blink = false }
                camera.capture { urls in
                    project.open(urls)
                    showsEditor = true
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 84, height: 84)
                    Circle()
                        .fill(.white)
                        .frame(width: 70, height: 70)
                        .scaleEffect(camera.isCapturing ? 0.86 : 1)
                }
                .contentShape(.circle)
            }
            .buttonStyle(ShutterStyle())
            .disabled(!canShoot)
            .opacity(canShoot ? 1 : 0.35)
            .sensoryFeedback(.impact(weight: .medium), trigger: camera.shutterCount)
            .accessibilityLabel("Снять")

            Spacer()

            Menu {
                Button("Spatial-снимок", systemImage: "pano") {
                    picksSpatial = true
                }
                Button("Склеить несколько снимков", systemImage: "square.stack") {
                    picksSequence = true
                }
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .glassEffect(in: .circle)
                }
            .accessibilityLabel("Открыть из медиатеки")
    }

    private func load(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("input", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, item) in items.enumerated() {
            guard let picked = try? await item.loadTransferable(type: PickedImage.self) else { continue }
            let target = folder.appendingPathComponent(String(format: "%02d", index)).appendingPathExtension(picked.url.pathExtension)
            try? FileManager.default.moveItem(at: picked.url, to: target)
            urls.append(target)
        }
        spatialSelection = []
        sequenceSelection = []
        guard !urls.isEmpty else {
            camera.failure = "Не удалось загрузить выбранные снимки"
            return
        }
        project.open(urls)
        showsEditor = true
    }
}

struct ShutterStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct QuickChip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 14)
                .frame(height: 36)
                .foregroundStyle(.white)
                .glassEffect(in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

struct Banner: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.leading)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(in: .rect(cornerRadius: 16))
            .padding(24)
    }
}

struct SettingsSheet: View {
    @Bindable var project: Project
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsPanel(project: project)
                .navigationTitle("Настройки")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово", systemImage: "checkmark") {
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

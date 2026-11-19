import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var project: Project
    @State private var showsInspector = true
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            stage
            if !project.sources.isEmpty {
                Divider()
                SourceStrip(project: project)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .inspector(isPresented: $showsInspector) {
            SettingsPanel(project: project)
                .inspectorColumnWidth(min: 270, ideal: 300, max: 380)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Открыть", systemImage: "photo.badge.plus") {
                    project.isImporting = true
                }
                .help("Открыть spatial-фото или несколько снимков")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(project.isPlaying ? LocalizedStringKey("Пауза") : LocalizedStringKey("Воспроизвести"), systemImage: project.isPlaying ? "pause.fill" : "play.fill") {
                    project.isPlaying.toggle()
                }
                .disabled(project.wiggle == nil)
                Button("Экспортировать", systemImage: "square.and.arrow.up") {
                    project.export()
                }
                .disabled(project.wiggle == nil || project.isExporting)
                .help("Сохранить видео или GIF")
                Button("Настройки", systemImage: "sidebar.trailing") {
                    showsInspector.toggle()
                }
                .help("Показать или скрыть настройки")
            }
        }
        .fileImporter(isPresented: $project.isImporting, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                project.open(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            project.open(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var title: String {
        guard let first = project.urls.first else { return "Wiggle" }
        return project.urls.count == 1 ? first.lastPathComponent : String(localized: "\(first.lastPathComponent) и ещё \(project.urls.count - 1)")
    }

    private var subtitle: String {
        guard let wiggle = project.wiggle else { return "" }
        let built = wiggle.steps.count - wiggle.keyframes
        return String(localized: "Снимков: \(wiggle.keyframes) · Достроено: \(built) · \(wiggle.steps[0].width) × \(wiggle.steps[0].height)")
    }

    @ViewBuilder private var stage: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let wiggle = project.wiggle {
                LoopPreview(project: project, wiggle: wiggle)
                    .padding(20)
            } else if let failure = project.failure {
                ContentUnavailableView("Не получилось собрать wiggle", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if project.urls.isEmpty {
                ContentUnavailableView {
                    Label("Перетащите снимки сюда", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Один spatial-снимок с iPhone или несколько кадров одной сцены, снятых со сдвигом вбок")
                } actions: {
                    Button("Открыть…") {
                        project.isImporting = true
                    }
                }
            }
            if project.isWorking || project.isExporting {
                ProgressView(project.isExporting ? LocalizedStringKey("Экспорт…") : LocalizedStringKey("Обработка…"))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassEffect(in: .rect(cornerRadius: 12))
            }
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
            }
        }
    }
}

struct SourceStrip: View {
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(project.sources.enumerated()), id: \.offset) { index, image in
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 72, height: 48)
                            .clipShape(.rect(cornerRadius: 6))
                            .overlay(alignment: .bottomLeading) {
                                Text("\(index + 1)")
                                    .font(.caption2.monospacedDigit().weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.regularMaterial, in: .capsule)
                                    .padding(4)
                            }
                            .accessibilityLabel("Снимок \(index + 1)")
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: 336, alignment: .leading)
            if let wiggle = project.wiggle {
                CameraRail(project: project, wiggle: wiggle)
                    .frame(minWidth: 120, maxWidth: .infinity)
                    .frame(height: 24)
            } else {
                Spacer(minLength: 0)
            }
            if let notice = project.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let exported = project.exported {
                Button("Показать \(exported.lastPathComponent) в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([exported])
                }
                .buttonStyle(.link)
            } else {
                Text("Собрано за \(project.buildSeconds.formatted(.number.precision(.fractionLength(1)))) с")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .background(.bar)
    }
}

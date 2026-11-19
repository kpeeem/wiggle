import CoreGraphics
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class Project {
    var urls: [URL] = []
    var options: WiggleOptions {
        didSet {
            guard options != oldValue else { return }
            var stored = options
            stored.convergenceX = nil
            stored.convergenceY = nil
            stored.reversed = false
            UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: "options")
            if buildInputs(options) != buildInputs(oldValue) {
                rebuild()
            } else if options.grade != oldValue.grade {
                regrade()
            }
        }
    }
    var wiggle: Wiggle?
    var sources: [CGImage] = []
    var isWorking = false
    var isExporting = false
    var isPlaying = true
    var isImporting = false
    var failure: String?
    var notice: String?
    var exported: URL?
    var buildSeconds = 0.0

    private var prepared: (urls: [URL], width: Int, reversed: Bool, aligned: Bool, value: Prepared)?
    private var task: Task<Void, Never>?
    private(set) var ungraded: Wiggle?
    private var gradedFor: Grade?
    private var isGrading = false

    init() {
        let stored = UserDefaults.standard.data(forKey: "options")
        options = stored.flatMap { try? JSONDecoder().decode(WiggleOptions.self, from: $0) } ?? WiggleOptions()
    }

    private func buildInputs(_ options: WiggleOptions) -> [Double?] {
        [
            Double(options.workingWidth), Double(options.intermediateFrames), options.alignGeometry ? 1 : 0,
            options.matchExposure ? 1 : 0, options.reversed ? 1 : 0, options.convergenceX, options.convergenceY,
        ]
    }

    func open(_ picked: [URL]) {
        let images = picked.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        guard !images.isEmpty else { return }
        urls = images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        exported = nil
        prepared = nil
        var fresh = options
        fresh.convergenceX = nil
        fresh.convergenceY = nil
        fresh.reversed = false
        if fresh == options {
            rebuild()
        } else {
            options = fresh
        }
    }

    func pickConvergence(x: Double, y: Double) {
        guard let wiggle else { return }
        options.convergenceX = (wiggle.crop.minX + x * wiggle.crop.width) / wiggle.workingSize.width
        options.convergenceY = (wiggle.crop.minY + y * wiggle.crop.height) / wiggle.workingSize.height
    }

    var convergenceMarker: CGPoint? {
        guard let wiggle, let x = options.convergenceX, let y = options.convergenceY else { return nil }
        return CGPoint(
            x: (x * wiggle.workingSize.width - wiggle.crop.minX) / wiggle.crop.width,
            y: (y * wiggle.workingSize.height - wiggle.crop.minY) / wiggle.crop.height)
    }

    func rebuild() {
        task?.cancel()
        guard !urls.isEmpty else { return }
        let previous = task
        let urls = urls
        let options = options
        let cached = prepared
        isWorking = true
        failure = nil
        task = Task {
            await previous?.value
            do {
                try await Task.sleep(for: .milliseconds(120))
                let started = Date()
                let value: Prepared
                if let cached, cached.urls == urls, cached.width == options.workingWidth, cached.reversed == options.reversed,
                   cached.aligned == options.alignGeometry {
                    value = cached.value
                } else {
                    value = try await prepare(
                        urls: urls, workingWidth: options.workingWidth, reversed: options.reversed,
                        alignGeometry: options.alignGeometry)
                }
                try Task.checkCancellation()
                let built = try await build(value, options: options)
                try Task.checkCancellation()
                prepared = (urls, options.workingWidth, options.reversed, options.alignGeometry, value)
                sources = value.frames
                ungraded = built
                gradedFor = nil
                buildSeconds = Date().timeIntervalSince(started)
                let missed = value.aligned.indices.filter { !value.aligned[$0] }.map { String($0 + 1) }
                notice = missed.isEmpty ? nil : "Не удалось выровнять снимок \(missed.joined(separator: ", ")): мало общих деталей"
                isWorking = false
                await applyGrade()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                wiggle = nil
                ungraded = nil
                sources = []
                failure = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func regrade() {
        guard !isWorking else { return }
        Task { await applyGrade() }
    }

    private func applyGrade() async {
        guard !isGrading else { return }
        isGrading = true
        defer { isGrading = false }
        while let source = ungraded, gradedFor != options.grade {
            let grade = options.grade
            let result = await Task.detached { graded(source, grade: grade) }.value
            guard ungraded?.steps.first === source.steps.first, ungraded?.steps.count == source.steps.count else { continue }
            wiggle = result
            gradedFor = grade
        }
    }

    func export(to url: URL) async -> Bool {
        guard let wiggle, !isExporting else { return false }
        isExporting = true
        exported = nil
        defer { isExporting = false }
        do {
            try await write(wiggle, options: options, to: url)
            exported = url
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
}

import AppKit

extension Project {
    func export() {
        guard wiggle != nil, !isExporting, let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.format == .gif ? .gif : options.format == .livePhoto ? .heic : .mpeg4Movie]
        panel.nameFieldStringValue = (urls.first?.deletingPathExtension().lastPathComponent ?? "wiggle") + "-wiggle"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { _ = await self.export(to: url) }
        }
    }
}

import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let project = Project()

    func application(_ application: NSApplication, open urls: [URL]) {
        project.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct WiggleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Wiggle", id: "main") {
            ContentView(project: delegate.project)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть…") {
                    delegate.project.isImporting = true
                }
                .keyboardShortcut("o")
                Button("Экспортировать…") {
                    delegate.project.export()
                }
                .keyboardShortcut("e")
                .disabled(delegate.project.wiggle == nil || delegate.project.isExporting)
            }
            CommandMenu("Просмотр") {
                Button(delegate.project.isPlaying ? "Пауза" : "Воспроизвести") {
                    delegate.project.isPlaying.toggle()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("Поменять порядок снимков") {
                    delegate.project.options.reversed.toggle()
                }
                .keyboardShortcut("r")
                .disabled(delegate.project.urls.isEmpty)
                Button("Сбросить точку сведения") {
                    delegate.project.options.convergenceX = nil
                    delegate.project.options.convergenceY = nil
                }
                .disabled(delegate.project.options.convergenceX == nil)
            }
        }
    }
}

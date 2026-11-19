import SwiftUI

@main
struct WiggleApp: App {
    @State private var project = Project()

    var body: some Scene {
        WindowGroup {
            CameraScreen(project: project)
                .preferredColorScheme(.dark)
        }
    }
}

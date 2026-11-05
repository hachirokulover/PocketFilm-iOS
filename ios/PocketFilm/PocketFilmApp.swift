import SwiftUI

@main @MainActor
struct PocketFilmApp: App {
    @State private var model = CameraModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            CameraView(model: model)
                .preferredColorScheme(.dark)
                .onAppear { model.setActive(phase == .active) }
                .onChange(of: phase) { _, value in model.setActive(value == .active) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) {
                    _ in model.memoryWarning()
                }
        }
    }
}

import SwiftUI

@main
struct CursorRecorderApp: App {
    @StateObject private var coordinator = RecordingCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .frame(minWidth: 920, minHeight: 600)
                .onAppear { coordinator.scan() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

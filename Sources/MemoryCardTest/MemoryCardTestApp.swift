import SwiftUI

@main
struct MemoryCardTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}

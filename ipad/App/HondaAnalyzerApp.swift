import SwiftUI

@main
struct HondaAnalyzerApp: App {
    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ble-soak") {
                BLESoakView()
            } else { ContentView() }
#else
            ContentView()
#endif
        }
    }
}

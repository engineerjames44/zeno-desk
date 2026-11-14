import SwiftUI

@main
struct ZenoCompanionApp: App {
    var body: some Scene {
        WindowGroup {
            DeskView()
                .onAppear {
                    // Always-on desk device: never let the screen auto-lock.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

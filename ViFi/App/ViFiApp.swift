import SwiftUI

@main
struct ViFiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                // Built by the delegate at launch, not here: see `AppDelegate.environment`.
                .environment(appDelegate.environment)
                .environment(router)
        }
    }
}

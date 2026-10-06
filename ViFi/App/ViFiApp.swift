import SwiftUI

@main
struct ViFiApp: App {
    @State private var environment = AppEnvironment.makeDefault()
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(router)
        }
    }
}

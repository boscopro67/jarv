import SwiftUI

@main
struct JarvisApp: App {
    @StateObject private var client = JarvisClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .preferredColorScheme(.dark)
        }
    }
}

import SwiftUI

@main
struct JarvisApp: App {
    @StateObject private var client = JarvisClient()
    @StateObject private var voice = LiveVoiceClient()
    @StateObject private var chat = ChatStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(voice)
                .environmentObject(chat)
                .preferredColorScheme(.dark)
        }
    }
}

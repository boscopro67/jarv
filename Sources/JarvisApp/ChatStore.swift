import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let speaker: String   // "user" | "jarvis" | "sys"
    let text: String
}

/// Historique des échanges (voix + texte), gardé sur le téléphone.
/// Toutes les méthodes sont appelées depuis le thread principal.
final class ChatStore: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false

    init() {
        messages = OfflineStore.load().map { ChatMessage(speaker: $0.speaker, text: $0.text) }
    }

    /// Enregistre une phrase (dite ou écrite) dans l'historique.
    func record(speaker: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        messages.append(ChatMessage(speaker: speaker, text: clean))
        var log = OfflineStore.load()
        log.append(StoredMessage(speaker: speaker, text: clean))
        OfflineStore.save(log)
        // Mémoire partagée (PC + téléphone)
        if speaker == "user" || speaker == "jarvis" {
            Task { await FirebaseSync.shared.append(speaker: speaker, text: clean) }
        }
    }

    /// Message écrit : JARVIS répond par écrit (Gemini direct).
    func send(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        record(speaker: "user", text: clean)

        guard let key = GeminiKeyStore.load() else {
            messages.append(ChatMessage(speaker: "sys", text: "Clé Gemini absente : ouvre les réglages."))
            return
        }
        isThinking = true
        let context = Array(OfflineStore.load().suffix(24))
        Task {
            var reply: String?
            var failure: String?
            do {
                let memory = await withTimeout(seconds: 4) { await FirebaseSync.shared.contextForPrompt() } ?? ""
                reply = try await GeminiClient.reply(history: context, apiKey: key, memory: memory)
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                if let reply = reply {
                    self.record(speaker: "jarvis", text: reply)
                } else if let failure = failure {
                    self.messages.append(ChatMessage(speaker: "sys", text: failure))
                }
                self.isThinking = false
            }
        }
    }

    func clear() {
        messages.removeAll()
        OfflineStore.save([])
    }
}

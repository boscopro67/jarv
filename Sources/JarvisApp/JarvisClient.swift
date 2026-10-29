import Foundation

/// État de la liaison avec JARVIS (PC) — tout passe par Firebase.
enum PCStatus: Equatable {
    case notConfigured   // pas encore lié : il faut taper le code d'appairage
    case checking
    case online          // lié
    case offline         // pas de réseau
}

/// Liaison avec le PC via Firebase uniquement : aucune adresse IP, aucun VPN.
/// Le téléphone s'identifie seul ; le PC l'autorise une fois (code d'appairage)
/// et lui remet la clé Gemini.
@MainActor
final class JarvisClient: ObservableObject {

    @Published var pcStatus: PCStatus = .checking
    @Published var detail: String = ""
    @Published var hasKey: Bool = GeminiKeyStore.load() != nil
    @Published var pairing = false
    @Published var pairMessage: String = ""

    private var loop: Task<Void, Never>?

    // ── Surveillance : vérifie la liaison toutes les 30 s, sans bruit ──
    func startMonitoring() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.checkOnce()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func recheckNow() { startMonitoring() }

    private func checkOnce() async {
        await FirebaseSync.shared.flush()
        switch await FirebaseSync.shared.checkLink() {
        case .linked:    pcStatus = .online
        case .notPaired: pcStatus = .notConfigured
        case .offline:   pcStatus = .offline
        case .error:     pcStatus = .offline
        }
        detail = await FirebaseSync.shared.status()
        hasKey = GeminiKeyStore.load() != nil
    }

    /// Lie ce téléphone avec le code affiché par le PC.
    func pair(code: String) {
        guard !pairing else { return }
        pairing = true
        pairMessage = "Liaison en cours…"
        Task {
            let error = await FirebaseSync.shared.pair(code: code)
            if let error = error {
                pairMessage = error
            } else {
                pairMessage = "Lié ! Plus besoin de recommencer."
                await checkOnce()
            }
            pairing = false
        }
    }

    func saveKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        GeminiKeyStore.save(clean)
        hasKey = true
        detail = "Clé Gemini enregistrée sur ce téléphone."
    }
}

import Foundation

/// État de la liaison avec le serveur du PC.
enum PCStatus: Equatable {
    case notConfigured   // aucune adresse saisie
    case checking
    case online
    case offline
}

/// Liaison discrète avec le PC (serveur) : elle n'affiche rien et ne pilote
/// rien. Elle sert à récupérer la clé Gemini et dira bientôt où est la mémoire
/// partagée. L'appli fonctionne très bien sans elle.
@MainActor
final class JarvisClient: ObservableObject {

    /// Adresse Tailscale du PC (100.x.x.x), saisie une seule fois.
    @Published var remoteHost: String {
        didSet { UserDefaults.standard.set(remoteHost, forKey: "jarvis_remote_host") }
    }
    @Published var pcStatus: PCStatus = .notConfigured
    @Published var detail: String = ""
    @Published var hasKey: Bool = GeminiKeyStore.load() != nil
    @Published var syncDetail: String = ""

    private var authToken: String?
    private var deviceToken: String? {
        didSet { UserDefaults.standard.set(deviceToken, forKey: "jarvis_device_token") }
    }
    private var loop: Task<Void, Never>?

    init() {
        self.remoteHost = UserDefaults.standard.string(forKey: "jarvis_remote_host")
            ?? UserDefaults.standard.string(forKey: "jarvis_ip") ?? ""
        self.deviceToken = UserDefaults.standard.string(forKey: "jarvis_device_token")
    }

    // ── Surveillance : vérifie le PC toutes les 30 s, sans bruit ────────
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

    func saveKey(_ key: String) {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        GeminiKeyStore.save(clean)
        hasKey = true
        detail = "Clé Gemini enregistrée sur ce téléphone."
    }

    // ── HTTP ────────────────────────────────────────────────────────────
    private enum Reply {
        case response(status: Int, json: [String: Any])
        case unreachable
    }

    private var host: String {
        remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    private func baseURL() -> String {
        host.contains(":") ? "http://\(host)" : "http://\(host):8000"
    }

    private func call(_ path: String, body: [String: Any]? = nil, token: String? = nil,
                      method: String = "POST") async -> Reply {
        guard let url = URL(string: "\(baseURL())\(path)") else { return .unreachable }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return .response(status: http.statusCode, json: json)
        } catch {
            return .unreachable
        }
    }

    // ── Une vérification complète ───────────────────────────────────────
    private func checkOnce() async {
        await FirebaseSync.shared.flush()
        guard !host.isEmpty else {
            pcStatus = .notConfigured
            detail = ""
            syncDetail = await FirebaseSync.shared.status()
            return
        }
        if pcStatus != .online { pcStatus = .checking }

        // 1) Clé Gemini avec le jeton actuel
        if let token = authToken, await fetchKey(token: token) {
            await afterCheck(token: token)
            return
        }

        // 2) Jeton absent ou périmé : on se reconnecte
        if let token = await login() {
            _ = await fetchKey(token: token)
            await afterCheck(token: token)
        } else {
            syncDetail = await FirebaseSync.shared.status()
        }
    }

    /// Une fois le PC joint : il autorise ce téléphone à lire/écrire la mémoire partagée.
    private func afterCheck(token: String) async {
        if pcStatus == .online, let uid = await FirebaseSync.shared.identity() {
            let defaults = UserDefaults.standard
            if defaults.string(forKey: "jarvis_fb_registered") != uid {
                switch await call("/api/firebase-register", body: ["uid": uid], token: token) {
                case .response(let status, _):
                    if status == 200 {
                        defaults.set(uid, forKey: "jarvis_fb_registered")
                    } else {
                        syncDetail = "Le PC n'a pas autorisé ce téléphone (code \(status)). Mets à jour le PC avec la nouvelle version."
                        return
                    }
                case .unreachable:
                    break
                }
            }
            await FirebaseSync.shared.flush()
        }
        syncDetail = await FirebaseSync.shared.status()
    }

    /// Renvoie true si la liaison est bonne (jeton valide).
    private func fetchKey(token: String) async -> Bool {
        switch await call("/api/standalone-config", token: token, method: "GET") {
        case .unreachable:
            pcStatus = .offline
            detail = "PC injoignable. Vérifie que Jarvis est lancé et que Tailscale est actif."
            return true   // inutile de se reconnecter : c'est le réseau
        case .response(let status, let json):
            if status == 401 {
                authToken = nil
                return false
            }
            pcStatus = .online
            if status == 200, let key = json["gemini_api_key"] as? String, !key.isEmpty {
                GeminiKeyStore.save(key)
                hasKey = true
                detail = "Lié au PC. Clé Gemini à jour."
            } else if status == 403 {
                detail = "Lié au PC, mais pas par Tailscale : la clé n'est envoyée que par Tailscale."
            } else if status == 404 {
                detail = "Lié au PC, mais aucune clé Gemini n'est configurée côté PC."
            }
            return true
        }
    }

    private func login() async -> String? {
        if let device = deviceToken {
            switch await call("/api/device-login", body: ["device_token": device]) {
            case .unreachable:
                pcStatus = .offline
                detail = "PC injoignable. Vérifie que Jarvis est lancé et que Tailscale est actif."
                return nil
            case .response(let status, let json):
                if status == 200, let token = json["token"] as? String {
                    authToken = token
                    return token
                }
                if status == 401 { deviceToken = nil }
            }
        }
        switch await call("/api/auto-pair") {
        case .unreachable:
            pcStatus = .offline
            detail = "PC injoignable. Vérifie que Jarvis est lancé et que Tailscale est actif."
            return nil
        case .response(let status, let json):
            if status == 200, let token = json["token"] as? String {
                authToken = token
                if let device = json["device_token"] as? String { deviceToken = device }
                return token
            }
            pcStatus = .offline
            detail = "Le PC a refusé l'appairage automatique depuis ce réseau."
            return nil
        }
    }
}

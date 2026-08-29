import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let speaker: String   // "user" | "jarvis" | "sys"
    let text: String
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case needsPin
    case connected
    case error(String)
}

@MainActor
final class JarvisClient: ObservableObject {

    @Published var serverIP: String {
        didSet { UserDefaults.standard.set(serverIP, forKey: "jarvis_ip") }
    }
    @Published var state: ConnectionState = .disconnected
    @Published var messages: [ChatMessage] = []
    @Published var jarvisActive: Bool = false

    private var authToken: String?
    /// Exposé (lecture seule pour l'app) pour que AudioStreamer puisse ouvrir
    /// le WebSocket /ws/phone-audio avec le même token que le reste de l'appli.
    var currentToken: String? { authToken }
    private var deviceToken: String? {
        didSet { UserDefaults.standard.set(deviceToken, forKey: "jarvis_device_token") }
    }
    private var wsTask: URLSessionWebSocketTask?

    init() {
        self.serverIP = UserDefaults.standard.string(forKey: "jarvis_ip") ?? ""
        self.deviceToken = UserDefaults.standard.string(forKey: "jarvis_device_token")
    }

    private var baseURL: String { "http://\(serverIP):8000" }

    // ── Démarrage : tente une reconnexion silencieuse si on a déjà un device_token ──
    func start() {
        guard !serverIP.isEmpty else { state = .needsPin; return }
        guard let dev = deviceToken else { state = .needsPin; return }
        state = .connecting
        Task {
            do {
                let (tok, _) = try await deviceLogin(deviceToken: dev)
                self.authToken = tok
                connectWebSocket()
            } catch {
                self.deviceToken = nil
                self.state = .needsPin
            }
        }
    }

    // ── Connexion manuelle avec le PIN affiché dans "Remote Control" ──
    func login(pin: String) {
        guard !serverIP.isEmpty else {
            state = .error("Renseigne l'adresse IP du PC.")
            return
        }
        state = .connecting
        Task {
            do {
                guard let url = URL(string: "\(baseURL)/api/pin-login") else { throw URLError(.badURL) }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["pin": pin])

                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

                guard http.statusCode == 200, (json["ok"] as? Bool) == true,
                      let tok = json["token"] as? String else {
                    let msg = (json["error"] as? String) ?? "Code invalide ou expiré."
                    self.state = .error(msg)
                    return
                }
                self.authToken   = tok
                self.deviceToken = json["device_token"] as? String
                connectWebSocket()
            } catch {
                self.state = .error("Impossible de joindre le PC (\(error.localizedDescription)).")
            }
        }
    }

    private func deviceLogin(deviceToken: String) async throws -> (String, String) {
        guard let url = URL(string: "\(baseURL)/api/device-login") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["device_token": deviceToken])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (json["ok"] as? Bool) == true, let tok = json["token"] as? String else {
            throw URLError(.userAuthenticationRequired)
        }
        return (tok, deviceToken)
    }

    // ── WebSocket temps réel (fil de discussion + statut) ──
    private func connectWebSocket() {
        guard let tok = authToken,
              let url = URL(string: "ws://\(serverIP):8000/ws?token=\(tok)") else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        wsTask = task
        task.resume()
        state = .connected
        messages.append(ChatMessage(speaker: "sys", text: "Connecté à JARVIS."))
        listen()
    }

    private func listen() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in
                    self.state = .disconnected
                    self.messages.append(ChatMessage(speaker: "sys", text: "Connexion perdue."))
                }
            case .success(let message):
                if case .string(let text) = message {
                    Task { @MainActor in self.handleIncoming(text) }
                }
                Task { @MainActor in self.listen() }
            }
        }
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "log":
            let speaker = (obj["speaker"] as? String) ?? "jarvis"
            let txt = (obj["text"] as? String) ?? ""
            messages.append(ChatMessage(speaker: speaker, text: txt))
        case "status":
            jarvisActive = (obj["state"] as? String) == "active"
        case "sys":
            messages.append(ChatMessage(speaker: "sys", text: (obj["text"] as? String) ?? ""))
        default:
            break
        }
    }

    // ── Envoyer une commande texte ──
    func sendCommand(_ text: String) {
        guard let tok = authToken, let url = URL(string: "\(baseURL)/api/command") else { return }
        messages.append(ChatMessage(speaker: "user", text: text))
        Task {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func wake() {
        guard let tok = authToken, let url = URL(string: "\(baseURL)/api/wake") else { return }
        Task {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func disconnect() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        authToken = nil
        deviceToken = nil
        messages.removeAll()
        state = .needsPin
    }
}

import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let speaker: String   // "user" | "jarvis" | "sys"
    let text: String
}

enum ConnectionState: Equatable {
    case home             // écran d'accueil — bloc "JARVIS" à toucher
    case searching        // recherche automatique du PC (aucune saisie)
    case connecting
    case needsPin         // écran de réglage : adresse du PC (+ code en secours)
    case connected
    case offline          // PC injoignable — mode autonome (Gemini direct depuis le téléphone)
    case error(String)
}

@MainActor
final class JarvisClient: ObservableObject {

    /// Adresse réellement utilisée pour la connexion en cours.
    @Published var serverIP: String {
        didSet { UserDefaults.standard.set(serverIP, forKey: "jarvis_ip") }
    }
    /// Adresse du PC saisie une fois (ex. son adresse Tailscale 100.x.x.x).
    /// Elle est toujours essayée en premier, en Wi-Fi comme en 4G/5G.
    @Published var remoteHost: String {
        didSet { UserDefaults.standard.set(remoteHost, forKey: "jarvis_remote_host") }
    }
    @Published var state: ConnectionState = .home
    @Published var messages: [ChatMessage] = []
    @Published var jarvisActive: Bool = false
    @Published var isThinking: Bool = false

    private var authToken: String?
    /// Exposé (lecture seule pour l'app) pour que AudioStreamer puisse ouvrir
    /// le WebSocket /ws/phone-audio avec le même token que le reste de l'appli.
    var currentToken: String? { authToken }
    private var deviceToken: String? {
        didSet { UserDefaults.standard.set(deviceToken, forKey: "jarvis_device_token") }
    }
    private var wsTask: URLSessionWebSocketTask?
    private let finder = BonjourFinder()
    private var connectTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init() {
        self.serverIP = UserDefaults.standard.string(forKey: "jarvis_ip") ?? ""
        self.remoteHost = UserDefaults.standard.string(forKey: "jarvis_remote_host") ?? ""
        self.deviceToken = UserDefaults.standard.string(forKey: "jarvis_device_token")
    }

    private var baseURL: String { "http://\(serverIP):8000" }

    /// Dernière adresse avec laquelle la connexion a réellement fonctionné
    /// (à défaut : l'ancienne adresse mémorisée par les versions précédentes).
    private var lastWorkingHost: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: "jarvis_last_host") { return saved }
            return UserDefaults.standard.string(forKey: "jarvis_ip") ?? ""
        }
        set { UserDefaults.standard.set(newValue, forKey: "jarvis_last_host") }
    }

    // ── Petit client HTTP avec délai court : si le PC est éteint, on le
    // sait en quelques secondes au lieu d'attendre une minute. ──
    private enum HTTPResult {
        case response(status: Int, json: [String: Any])
        case unreachable
    }

    private func send(_ path: String,
                      body: [String: Any]? = nil,
                      token: String? = nil,
                      method: String = "POST",
                      timeout: TimeInterval = 4) async -> HTTPResult {
        guard let url = URL(string: "\(baseURL)\(path)") else { return .unreachable }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            var json: [String: Any] = [:]
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = object
            }
            return .response(status: http.statusCode, json: json)
        } catch {
            return .unreachable
        }
    }

    // ── Démarrage 100% automatique ─────────────────────────────────────
    // 1) adresse du PC mémorisée (Tailscale) → 2) dernière adresse qui a
    // marché → 3) découverte Bonjour sur le réseau local.
    // Si le PC ne répond nulle part : mode autonome (Gemini direct).
    func start() {
        retryTask?.cancel()
        retryTask = nil
        connectTask?.cancel()
        state = .searching
        connectTask = Task {
            await self.connectFlow(silent: false)
        }
    }

    private enum Attempt {
        case connected
        case unreachable
        case refused
    }

    private func connectFlow(silent: Bool) async {
        var tried = Set<String>()
        var refused = false

        func run(_ raw: String) async -> Bool {
            let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty || tried.contains(host) || Task.isCancelled { return false }
            tried.insert(host)
            switch await attempt(host: host) {
            case .connected:
                return true
            case .refused:
                refused = true
                return false
            case .unreachable:
                return false
            }
        }

        let hasRemote = !remoteHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if await run(remoteHost) { return }
        if await run(lastWorkingHost) { return }
        if !silent || !hasRemote {
            if let lan = await discoverLAN(timeout: hasRemote ? 3.0 : 6.0) {
                if await run(lan) { return }
            }
        }
        if Task.isCancelled || silent { return }

        if refused {
            state = .error("Le PC refuse l'appairage automatique depuis ce réseau. Entre le code affiché par « Remote Control » sur JARVIS (côté PC).")
        } else if !hasRemote {
            state = .needsPin
        } else {
            enterOffline()
        }
    }

    private func attempt(host: String) async -> Attempt {
        serverIP = host

        // Appareil déjà connu : reconnexion immédiate avec son jeton.
        if let dev = deviceToken {
            switch await send("/api/device-login", body: ["device_token": dev]) {
            case .unreachable:
                return .unreachable
            case .response(let status, let json):
                if status == 200, (json["ok"] as? Bool) == true, let tok = json["token"] as? String {
                    return finishConnect(token: tok, newDeviceToken: nil)
                }
                if status == 401 { deviceToken = nil }   // jeton périmé : on retente un appairage frais
            }
        }

        // Premier lancement : appairage sans code (accepté par le PC depuis
        // le réseau local ou Tailscale uniquement).
        switch await send("/api/auto-pair") {
        case .unreachable:
            return .unreachable
        case .response(let status, let json):
            if status == 200, (json["ok"] as? Bool) == true, let tok = json["token"] as? String {
                return finishConnect(token: tok, newDeviceToken: json["device_token"] as? String)
            }
            return .refused
        }
    }

    private func finishConnect(token: String, newDeviceToken: String?) -> Attempt {
        if Task.isCancelled { return .unreachable }
        authToken = token
        if let fresh = newDeviceToken { deviceToken = fresh }
        lastWorkingHost = serverIP
        retryTask?.cancel()
        retryTask = nil
        connectWebSocket()
        syncStandaloneKey()
        return .connected
    }

    private func discoverLAN(timeout: TimeInterval) async -> String? {
        let finder = self.finder
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var done = false
            finder.find(timeout: timeout) { ip in
                if done { return }
                done = true
                continuation.resume(returning: ip)
            }
        }
    }

    /// Récupère (une fois connecté au PC par un tunnel chiffré) la clé Gemini
    /// qui sert au mode autonome. Le PC la refuse en dehors de Tailscale.
    private func syncStandaloneKey() {
        guard let tok = authToken else { return }
        Task {
            let result = await self.send("/api/standalone-config", token: tok, method: "GET", timeout: 8)
            if case .response(let status, let json) = result, status == 200,
               (json["ok"] as? Bool) == true,
               let key = json["gemini_api_key"] as? String, !key.isEmpty {
                GeminiKeyStore.save(key)
            }
        }
    }

    /// Réessaie tout le flux automatique depuis le début.
    func retryAutomatically() {
        start()
    }

    /// Ouvre l'écran de réglage (adresse du PC).
    func openSettings() {
        retryTask?.cancel()
        retryTask = nil
        state = .needsPin
    }

    // ── Mode autonome : le PC est injoignable ──────────────────────────
    func enterOffline() {
        connectTask?.cancel()
        retryTask?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        authToken = nil
        jarvisActive = false
        isThinking = false

        var list: [ChatMessage] = []
        for stored in OfflineStore.load() {
            list.append(ChatMessage(speaker: stored.speaker, text: stored.text))
        }
        if GeminiKeyStore.load() != nil {
            list.append(ChatMessage(speaker: "sys", text: "PC injoignable — mode autonome. Je réponds seul ; je ne pourrai agir sur l'ordinateur qu'une fois reconnecté."))
        } else {
            list.append(ChatMessage(speaker: "sys", text: "PC injoignable. Le mode autonome sera disponible après une première connexion au PC (allumé, Jarvis lancé, Tailscale actif) : le téléphone y récupère alors la clé Gemini."))
        }
        messages = list
        state = .offline
        startRetryLoop()
    }

    /// En mode autonome, tente discrètement de retrouver le PC toutes les 20 s.
    private func startRetryLoop() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self = self, !Task.isCancelled, self.state == .offline else { return }
                await self.connectFlow(silent: true)
            }
        }
    }

    private func askStandalone(_ text: String) {
        messages.append(ChatMessage(speaker: "user", text: text))
        var log = OfflineStore.load()
        log.append(StoredMessage(speaker: "user", text: text))
        OfflineStore.save(log)

        guard let key = GeminiKeyStore.load() else {
            messages.append(ChatMessage(speaker: "sys", text: "Mode autonome indisponible : la clé Gemini n'est pas encore sur ce téléphone. Connecte-toi une première fois au PC (via Tailscale)."))
            return
        }
        isThinking = true
        let context = Array(log.suffix(24))
        Task {
            do {
                let reply = try await GeminiClient.reply(history: context, apiKey: key)
                self.messages.append(ChatMessage(speaker: "jarvis", text: reply))
                var updated = OfflineStore.load()
                updated.append(StoredMessage(speaker: "jarvis", text: reply))
                OfflineStore.save(updated)
            } catch {
                self.messages.append(ChatMessage(speaker: "sys", text: error.localizedDescription))
            }
            self.isThinking = false
        }
    }

    // ── Connexion manuelle avec le PIN affiché dans "Remote Control" ──
    // Gardée uniquement comme secours si l'appairage automatique est refusé.
    func login(pin: String) {
        let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            state = .error("Renseigne l'adresse du PC.")
            return
        }
        retryTask?.cancel()
        retryTask = nil
        serverIP = host
        state = .connecting
        Task {
            let result = await self.send("/api/pin-login", body: ["pin": pin], timeout: 8)
            switch result {
            case .unreachable:
                self.state = .error("Impossible de joindre le PC (\(host)). Vérifie que Jarvis est lancé et que Tailscale est actif.")
            case .response(let status, let json):
                guard status == 200, (json["ok"] as? Bool) == true,
                      let tok = json["token"] as? String else {
                    self.state = .error((json["error"] as? String) ?? "Code invalide ou expiré.")
                    return
                }
                self.authToken = tok
                self.deviceToken = json["device_token"] as? String
                self.lastWorkingHost = host
                self.connectWebSocket()
                self.syncStandaloneKey()
            }
        }
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
                    self.messages.append(ChatMessage(speaker: "sys", text: "Connexion perdue — reconnexion…"))
                    self.wsTask = nil
                    self.start()   // reconnexion 100% automatique, sans rien demander
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
        if state == .offline {
            askStandalone(text)
            return
        }
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
        connectTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        isThinking = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        authToken = nil
        // deviceToken n'est PAS effacé : l'appareil reste enregistré, la
        // prochaine fois qu'on touche le bloc JARVIS, la reconnexion est
        // immédiate sans re-appairage.
        messages.removeAll()
        state = .home   // retour à l'écran d'accueil (bloc JARVIS)
    }
}

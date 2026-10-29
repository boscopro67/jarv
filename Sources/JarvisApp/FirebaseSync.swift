import Foundation

// ══════════════════════════════════════════════════════════════════════
//  MÉMOIRE PARTAGÉE — Firebase Realtime Database (REST, sans SDK).
//  Le téléphone s'identifie anonymement, écrit chaque échange dans
//  /memory/messages et relit l'historique (PC + téléphone) au démarrage.
//  La base reste verrouillée : seuls les appareils que le PC a autorisés
//  (/allowed/<uid>) peuvent lire ou écrire.
// ══════════════════════════════════════════════════════════════════════

enum FirebaseConfig {
    /// Clé web du projet (publique : elle sert seulement à créer l'identité anonyme).
    static let apiKey = "AIzaSyCS0GUSO9rUovaY4xsDtzL6Tz341cTWrQE"
    static let databaseURL = "https://jarvis-sync-b9371-default-rtdb.europe-west1.firebasedatabase.app"
}

struct SharedMessage {
    let speaker: String   // "user" | "jarvis"
    let text: String
    let device: String    // "pc" | "iphone"
    let ts: Double        // millisecondes depuis 1970
}

private enum FBError: Error {
    case badURL
    case auth(String)
}

actor FirebaseSync {
    static let shared = FirebaseSync()

    private let defaults = UserDefaults.standard
    private var idToken: String?
    private var tokenExpiry = Date.distantPast
    private var flushing = false
    private var lastStatus = "Mémoire partagée : pas encore synchronisée."

    private let uidKey = "jarvis_fb_uid"
    private let refreshKey = "jarvis_fb_refresh"
    private let pendingKey = "jarvis_fb_pending"

    func status() -> String { lastStatus }

    // ── HTTP ────────────────────────────────────────────────────────────
    private func send(_ url: URL, method: String, body: Data? = nil,
                      contentType: String = "application/json",
                      timeout: TimeInterval = 5) async throws -> (Int, Data) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let body = body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let bundle = Bundle.main.bundleIdentifier {
            request.setValue(bundle, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let text = error["message"] as? String {
                return text
            }
            if let text = object["error"] as? String { return text }
        }
        return "erreur inconnue"
    }

    // ── Identité anonyme ────────────────────────────────────────────────
    private func store(id: String, refresh: String, expires: String?, uid: String?) {
        idToken = id
        tokenExpiry = Date().addingTimeInterval(Double(expires ?? "3600") ?? 3600)
        defaults.set(refresh, forKey: refreshKey)
        if let uid = uid { defaults.set(uid, forKey: uidKey) }
    }

    private func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let current = idToken, tokenExpiry > Date().addingTimeInterval(60) {
            return current
        }
        if let refresh = defaults.string(forKey: refreshKey), let fresh = try await refreshToken(refresh) {
            return fresh
        }
        return try await signUp()
    }

    private func refreshToken(_ refresh: String) async throws -> String? {
        guard let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(FirebaseConfig.apiKey)") else {
            throw FBError.badURL
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = refresh.addingPercentEncoding(withAllowedCharacters: allowed) ?? refresh
        let body = Data("grant_type=refresh_token&refresh_token=\(encoded)".utf8)
        let (status, data) = try await send(url, method: "POST", body: body,
                                            contentType: "application/x-www-form-urlencoded")
        guard status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id_token"] as? String,
              let newRefresh = object["refresh_token"] as? String else {
            return nil
        }
        store(id: id, refresh: newRefresh, expires: object["expires_in"] as? String,
              uid: object["user_id"] as? String)
        return id
    }

    private func signUp() async throws -> String {
        guard let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(FirebaseConfig.apiKey)") else {
            throw FBError.badURL
        }
        let body = Data("{\"returnSecureToken\":true}".utf8)
        let (status, data) = try await send(url, method: "POST", body: body)
        guard status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["idToken"] as? String,
              let refresh = object["refreshToken"] as? String else {
            throw FBError.auth(message(from: data))
        }
        store(id: id, refresh: refresh, expires: object["expiresIn"] as? String,
              uid: object["localId"] as? String)
        return id
    }

    /// Identifiant Firebase anonyme de ce téléphone (créé au premier appel).
    func identity() async -> String? {
        do {
            _ = try await token()
            return defaults.string(forKey: uidKey)
        } catch FBError.auth(let text) {
            lastStatus = "Identité Firebase impossible : \(text). Vérifie que la connexion anonyme est activée et que la clé web est bonne."
            return nil
        } catch {
            lastStatus = "Hors ligne : la mémoire partagée reprendra avec le réseau."
            return nil
        }
    }

    // ── Accès à la base ─────────────────────────────────────────────────
    private func database(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                          body: Data? = nil) async throws -> (Int, Data) {
        var attempt = 0
        while true {
            let current = try await token(forceRefresh: attempt > 0)
            guard var components = URLComponents(string: FirebaseConfig.databaseURL + "/" + path + ".json") else {
                throw FBError.badURL
            }
            components.queryItems = query + [URLQueryItem(name: "auth", value: current)]
            guard let url = components.url else { throw FBError.badURL }
            let (status, data) = try await send(url, method: method, body: body)
            if status == 401 && attempt == 0 {
                attempt = 1
                continue
            }
            return (status, data)
        }
    }

    private func explain(status: Int, data: Data) {
        if status == 401 || status == 403 {
            lastStatus = "En attente d'autorisation : ouvre l'appli avec le PC allumé (Tailscale) pour qu'il autorise ce téléphone."
        } else {
            lastStatus = "Firebase a répondu \(status) : \(message(from: data))"
        }
    }

    // ── Écriture (avec file d'attente hors ligne) ───────────────────────
    private func loadPending() -> [[String: Any]] {
        guard let data = defaults.data(forKey: pendingKey),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    private func savePending(_ list: [[String: Any]]) {
        let trimmed = Array(list.suffix(200))
        if let data = try? JSONSerialization.data(withJSONObject: trimmed) {
            defaults.set(data, forKey: pendingKey)
        }
    }

    /// Ajoute un échange à la mémoire partagée (envoyé tout de suite si possible).
    func append(speaker: String, text: String) async {
        var list = loadPending()
        list.append(["speaker": speaker, "text": String(text.prefix(2000)),
                     "ts": Date().timeIntervalSince1970 * 1000])
        savePending(list)
        await flush()
    }

    /// Mémorise un fait durable (nom, préférence, projet…), comme le fait le PC.
    func saveFact(category: String, key: String, value: String) async {
        let valid = ["identity", "preferences", "projects", "relationships", "wishes", "notes"]
        let cat = valid.contains(category) ? category : "notes"
        let cleanKey = String(key.map { ".$#[]/".contains($0) ? "_" : $0 })
        guard !cleanKey.isEmpty, !value.isEmpty else { return }
        var list = loadPending()
        list.append(["kind": "fact", "category": cat, "key": cleanKey,
                     "value": String(value.prefix(380))])
        savePending(list)
        await flush()
    }

    /// Envoie ce qui est en attente (échanges et faits). Sans effet s'il n'y a rien.
    func flush() async {
        if flushing { return }
        flushing = true
        defer { flushing = false }

        while let item = loadPending().first {
            do {
                let result: (Int, Data)
                if (item["kind"] as? String) == "fact" {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd"
                    let body = try JSONSerialization.data(withJSONObject: [
                        "value": item["value"] as? String ?? "",
                        "updated": formatter.string(from: Date()),
                        "source": "iphone"
                    ])
                    let path = "memory/facts/\(item["category"] as? String ?? "notes")/\(item["key"] as? String ?? "note")"
                    result = try await database(path, method: "PUT", body: body)
                } else {
                    let body = try JSONSerialization.data(withJSONObject: [
                        "speaker": item["speaker"] as? String ?? "user",
                        "text": item["text"] as? String ?? "",
                        "device": "iphone",
                        "ts": item["ts"] as? Double ?? Date().timeIntervalSince1970 * 1000
                    ])
                    result = try await database("memory/messages", method: "POST", body: body)
                }
                let (status, data) = result
                guard status == 200 else {
                    explain(status: status, data: data)
                    return
                }
                var current = loadPending()
                if !current.isEmpty { current.removeFirst() }
                savePending(current)
                lastStatus = "Mémoire partagée active."
            } catch FBError.auth(let text) {
                lastStatus = "Identité Firebase impossible : \(text)"
                return
            } catch {
                lastStatus = "Hors ligne : tout est gardé et partira avec le réseau."
                return
            }
        }
    }

    // ── Lecture ─────────────────────────────────────────────────────────
    func recent(limit: Int = 30) async -> [SharedMessage]? {
        do {
            let query = [URLQueryItem(name: "orderBy", value: "\"$key\""),
                         URLQueryItem(name: "limitToLast", value: String(limit))]
            let (status, data) = try await database("memory/messages", query: query)
            guard status == 200 else {
                explain(status: status, data: data)
                return nil
            }
            lastStatus = "Mémoire partagée active."
            guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let dict = object as? [String: Any] else { return [] }
            return dict.keys.sorted().compactMap { key -> SharedMessage? in
                guard let entry = dict[key] as? [String: Any],
                      let text = entry["text"] as? String else { return nil }
                return SharedMessage(speaker: entry["speaker"] as? String ?? "user",
                                     text: text,
                                     device: entry["device"] as? String ?? "pc",
                                     ts: entry["ts"] as? Double ?? 0)
            }
        } catch FBError.auth(let text) {
            lastStatus = "Identité Firebase impossible : \(text)"
            return nil
        } catch {
            lastStatus = "Hors ligne : mémoire locale utilisée."
            return nil
        }
    }

    /// Faits durables connus par le PC (nom, préférences, projets…).
    func factsText() async -> String {
        do {
            let (status, data) = try await database("memory/facts")
            guard status == 200 else { return "" }
            guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let dict = object as? [String: Any] else { return "" }
            var lines: [String] = []
            for category in ["identity", "preferences", "projects", "relationships", "wishes", "notes"] {
                guard let items = dict[category] as? [String: Any] else { continue }
                for key in items.keys.sorted() {
                    var value: String?
                    var source = ""
                    if let entry = items[key] as? [String: Any] {
                        value = entry["value"] as? String
                        if let src = entry["source"] as? String { source = src == "iphone" ? " [iPhone]" : " [PC]" }
                    } else { value = items[key] as? String }
                    if let value = value, !value.isEmpty { lines.append("- \(category)/\(key) : \(value)\(source)") }
                }
            }
            return String(lines.joined(separator: "\n").prefix(1500))
        } catch {
            return ""
        }
    }

    private func relative(_ ms: Double) -> String {
        guard ms > 0 else { return "date inconnue" }
        let seconds = max(0, Date().timeIntervalSince1970 - ms / 1000)
        if seconds < 90 { return "à l'instant" }
        if seconds < 3600 { return "il y a \(Int(seconds / 60)) min" }
        if seconds < 86400 { return "il y a \(Int(seconds / 3600)) h" }
        return "il y a \(Int(seconds / 86400)) j"
    }

    /// Du PLUS RÉCENT au plus ancien : la première ligne est le dernier échange.
    private func format(_ messages: [SharedMessage]) -> String {
        return messages.sorted { $0.ts > $1.ts }.map { m -> String in
            let origin = m.device == "iphone" ? "iPhone" : "PC"
            let who = m.speaker == "user" ? "Utilisateur" : "Jarvis"
            return "\(relative(m.ts)) [\(origin)] — \(who) : \(String(m.text.prefix(300)))"
        }.joined(separator: "\n")
    }

    /// Bloc de mémoire à glisser dans les consignes de JARVIS au démarrage.
    func contextForPrompt() async -> String {
        await flush()
        var parts: [String] = []
        let facts = await factsText()
        if !facts.isEmpty { parts.append("Ce que tu sais sur l'utilisateur :\n" + facts) }
        if let messages = await recent(limit: 24), !messages.isEmpty {
            parts.append("Derniers échanges, DU PLUS RÉCENT AU PLUS ANCIEN (la première ligne est le tout dernier échange ; l'origine de chaque ligne est entre crochets) :\n" + format(messages))
        }
        let result = parts.joined(separator: "\n\n")
        if !result.isEmpty {
            defaults.set(result, forKey: "jarvis_fb_ctx_cache")
            return result
        }
        // Serveur injoignable : dernière mémoire partagée connue.
        return defaults.string(forKey: "jarvis_fb_ctx_cache") ?? ""
    }

    /// Réponse à l'outil recall_memory : l'historique partagé le plus frais.
    func recallText() async -> String {
        await flush()
        if let messages = await recent(limit: 40), !messages.isEmpty {
            return "Historique partagé, DU PLUS RÉCENT AU PLUS ANCIEN (la première ligne est le tout dernier échange ; l'origine de chaque ligne est entre crochets) :\n" + format(messages)
        }
        if let cached = defaults.string(forKey: "jarvis_fb_ctx_cache"), !cached.isEmpty {
            return "Serveur injoignable ; dernière mémoire partagée connue :\n" + cached
        }
        let local = OfflineStore.load().suffix(20)
        if local.isEmpty { return "Aucun historique pour l'instant." }
        let lines = local.map { ($0.speaker == "user" ? "Utilisateur" : "Jarvis") + " : " + String($0.text.prefix(300)) }
        return "Mémoire du serveur injoignable ; historique local du téléphone :\n" + lines.joined(separator: "\n")
    }
}

/// Lance une opération et abandonne après `seconds` (renvoie nil).
func withTimeout<T: Sendable>(seconds: Double,
                              _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

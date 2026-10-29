import Foundation
import Security

// ══════════════════════════════════════════════════════════════════════
//  MODE AUTONOME — JARVIS répond directement depuis le téléphone (Gemini)
//  quand le PC est éteint ou injoignable.
// ══════════════════════════════════════════════════════════════════════

/// Message gardé sur le téléphone pour le mode autonome.
struct StoredMessage: Codable {
    let speaker: String   // "user" | "jarvis"
    let text: String
}

/// Historique des échanges du mode autonome (gardé sur le téléphone).
enum OfflineStore {
    private static let storageKey = "jarvis_offline_log"
    private static let maxMessages = 60

    static func load() -> [StoredMessage] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([StoredMessage].self, from: data) else {
            return []
        }
        return list
    }

    static func save(_ list: [StoredMessage]) {
        let trimmed = Array(list.suffix(maxMessages))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

/// Clé Gemini : récupérée automatiquement depuis le PC (une fois connecté
/// via Tailscale), puis gardée dans le Trousseau de l'iPhone.
enum GeminiKeyStore {
    private static let service = "com.jarvis.remote.app.gemini"
    private static let account = "gemini_api_key"
    private static let fallbackKey = "jarvis_gemini_key_fallback"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }
        let fallback = UserDefaults.standard.string(forKey: fallbackKey)
        if let fallback = fallback, !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    static func save(_ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        } else {
            // Trousseau indisponible (appli installée sans certificat complet) : repli.
            UserDefaults.standard.set(value, forKey: fallbackKey)
        }
    }
}

enum GeminiError: LocalizedError {
    case http(Int, String)
    case blocked
    case empty
    case network(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let message):
            if code == 429 {
                return "Gemini : trop de demandes pour l'instant (quota atteint). Réessaie dans un moment."
            }
            return "Gemini a refusé la demande (\(code)) : \(message)"
        case .blocked:
            return "Gemini a bloqué cette demande."
        case .empty:
            return "Gemini n'a renvoyé aucune réponse."
        case .network(let detail):
            return "Impossible de joindre Gemini (\(detail)). Vérifie la connexion du téléphone (essaie de couper Tailscale 5 secondes) puis réessaie."
        }
    }
}

enum GeminiClient {

    /// Modèles essayés dans l'ordre (le suivant n'est utilisé que si le
    /// précédent n'existe plus côté Google).
    static let models = ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-flash-latest"]

    private static func systemPrompt(memory: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let now = formatter.string(from: Date())
        var memoryBlock = ""
        if !memory.isEmpty {
            memoryBlock = "Mémoire partagée entre le PC et le téléphone (tu t'en souviens, ne la récite pas) :\n" + memory
        }
        return """
        Tu es JARVIS, l'assistant personnel de l'utilisateur, dans l'esprit de Jarvis d'Iron Man : professionnel, efficace, direct, légèrement ironique. Pas de blabla.
        Réponds dans la langue de l'utilisateur. Adapte la longueur à la demande : court par défaut, détaillé seulement si la question l'exige.
        N'utilise pas de mise en forme Markdown (pas d'astérisques ni de listes à puces) : du texte simple.
        Tu écris dans l'appli du téléphone de l'utilisateur. Tu ne peux exécuter aucune action sur son ordinateur (ouvrir une application, voir l'écran, accéder aux fichiers) : si on te le demande, dis-le en une phrase.
        Tu n'as pas accès à internet en direct : ne prétends jamais avoir vérifié une information récente, et signale quand une réponse peut être périmée.
        Date et heure actuelles : \(now).
        \(memoryBlock)
        """
    }

    /// Envoie l'historique à Gemini et renvoie la réponse de JARVIS.
    static func reply(history: [StoredMessage], apiKey: String, memory: String = "") async throws -> String {
        // Gemini veut des tours qui alternent, en commençant par l'utilisateur.
        var contents: [[String: Any]] = []
        for message in history {
            let role: String
            switch message.speaker {
            case "user":
                role = "user"
            case "jarvis":
                role = "model"
            default:
                continue
            }
            if contents.isEmpty && role == "model" { continue }
            if let last = contents.last,
               (last["role"] as? String) == role,
               var parts = last["parts"] as? [[String: Any]] {
                parts.append(["text": message.text])
                contents[contents.count - 1] = ["role": role, "parts": parts]
            } else {
                contents.append(["role": role, "parts": [["text": message.text]]])
            }
        }
        guard !contents.isEmpty else { throw GeminiError.empty }

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt(memory: memory)]]],
            "contents": contents,
            "generationConfig": ["temperature": 0.7]
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = GeminiError.empty
        for model in models {
            let address = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
            guard let url = URL(string: address) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = payload

            do {
                let (data, response) = try await fetch(request)
                guard let http = response as? HTTPURLResponse else { throw GeminiError.network("réponse invalide") }
                if http.statusCode == 404 {
                    lastError = GeminiError.http(404, "modèle introuvable")
                    continue
                }
                guard http.statusCode == 200 else {
                    throw GeminiError.http(http.statusCode, errorMessage(from: data))
                }
                return try parseReply(data)
            } catch let error as GeminiError {
                throw error
            } catch let error as URLError {
                throw GeminiError.network("\(error.code.rawValue) \(error.localizedDescription)")
            } catch {
                throw GeminiError.network(error.localizedDescription)
            }
        }
        throw lastError
    }

    /// Session dédiée : attend le réseau au lieu d'échouer, et ne réutilise pas
    /// de connexion périmée (fréquent quand le VPN Tailscale change de route).
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config)
    }()

    /// Envoie la requête ; réessaie 2 fois en cas de coupure réseau passagère.
    private static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                return try await session.data(for: request)
            } catch let error as URLError {
                let transient: [URLError.Code] = [.networkConnectionLost, .timedOut, .notConnectedToInternet,
                                                  .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost]
                if attempt < 2, transient.contains(error.code) {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                throw error
            }
        }
    }

    private static func parseReply(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.empty
        }
        if let feedback = object["promptFeedback"] as? [String: Any],
           feedback["blockReason"] != nil {
            throw GeminiError.blocked
        }
        guard let candidates = object["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw GeminiError.empty
        }
        var pieces: [String] = []
        for part in parts {
            if (part["thought"] as? Bool) == true { continue }
            if let text = part["text"] as? String { pieces.append(text) }
        }
        let result = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { throw GeminiError.empty }
        return result
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return String(message.prefix(160))
        }
        return "erreur inconnue"
    }
}

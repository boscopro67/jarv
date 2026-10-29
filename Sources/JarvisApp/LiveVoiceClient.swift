import Foundation
import AVFoundation
import UIKit

// ══════════════════════════════════════════════════════════════════════
//  VOIX AUTONOME — conversation Gemini Live directement depuis l'iPhone.
//  Micro et haut-parleur du téléphone, aucun passage par le PC.
// ══════════════════════════════════════════════════════════════════════

/// Petite enveloppe autour du WebSocket : tout ce qui est appelé depuis le
/// thread audio ou le réseau vit ici, à l'abri des règles d'isolation.
final class LiveSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _ready = false
    private var _muted = false
    private var _closed = false

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    var onMessage: ((Data) -> Void)?
    var onClose: ((String) -> Void)?

    /// true une fois que Gemini a confirmé la configuration (setupComplete).
    var ready: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _ready }
        set { lock.lock(); _ready = newValue; lock.unlock() }
    }
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; lock.unlock() }
    }

    func open(url: URL) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: queue)
        session = urlSession
        let wsTask = urlSession.webSocketTask(with: url)
        task = wsTask
        wsTask.resume()
        receiveLoop()
    }

    func sendText(_ text: String) {
        task?.send(.string(text)) { [weak self] error in
            if let error = error { self?.finish("envoi impossible : \(error.localizedDescription)") }
        }
    }

    func sendAudio(_ pcm: Data) {
        let b64 = pcm.base64EncodedString()
        sendText("{\"realtimeInput\":{\"audio\":{\"data\":\"\(b64)\",\"mimeType\":\"audio/pcm;rate=16000\"}}}")
    }

    /// Fermeture voulue : on ne prévient personne.
    func close() {
        lock.lock(); _closed = true; lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func finish(_ reason: String) {
        lock.lock()
        let already = _closed
        _closed = true
        lock.unlock()
        if already { return }
        onClose?(reason)
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.finish(error.localizedDescription)
            case .success(let message):
                switch message {
                case .data(let data): self.onMessage?(data)
                case .string(let text): self.onMessage?(Data(text.utf8))
                @unknown default: break
                }
                self.receiveLoop()
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        finish("code \(closeCode.rawValue) \(text)")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { finish(error.localizedDescription) }
    }
}

final class LiveVoiceClient: NSObject, ObservableObject {

    @Published var state: VoiceState = .idle
    @Published var muted = false
    @Published var level: CGFloat = 0          // 0…1, anime l'orbe
    @Published var caption = ""                // dernière phrase (toi ou JARVIS)
    @Published var captionIsUser = false
    @Published var errorText: String?

    /// Appelé (thread principal) à chaque phrase terminée : ("user" | "jarvis", texte).
    var onTranscript: ((String, String) -> Void)?

    /// Modèle Live à utiliser. À changer ici si Google le renomme.
    static let model = "gemini-3.8-live"
    static let voiceName = "Charon"

    private let audio = LiveAudioIO()
    private var socket: LiveSocket?
    private var userBuffer = ""
    private var jarvisBuffer = ""
    private var decayTimer: Timer?

    var isActive: Bool { state != .idle }

    // ── Démarrer / arrêter ────────────────────────────────────────────────
    func start() {
        guard state == .idle else { return }
        guard let key = GeminiKeyStore.load() else {
            errorText = "Clé Gemini absente. Ouvre les réglages : lie le PC une fois, ou colle la clé."
            return
        }
        errorText = nil
        caption = ""
        muted = false
        state = .connecting

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self, self.state == .connecting else { return }
                if !granted {
                    self.fail("Micro refusé. Réglages iPhone > JARVIS > Micro.")
                    return
                }
                // On relit la mémoire partagée (5 s max) avant d'ouvrir la session.
                Task {
                    let shared = await Self.withTimeout(seconds: 5) {
                        await FirebaseSync.shared.contextForPrompt()
                    }
                    DispatchQueue.main.async {
                        guard self.state == .connecting else { return }
                        self.open(key: key, sharedContext: shared ?? "")
                    }
                }
            }
        }
    }

    private static func withTimeout<T: Sendable>(seconds: Double,
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

    func stop() {
        flushTranscripts()
        socket?.close()
        socket = nil
        audio.stop()
        decayTimer?.invalidate()
        decayTimer = nil
        level = 0
        state = .idle
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func toggleMute() {
        muted.toggle()
        socket?.muted = muted
        if muted { level = 0 }
    }

    private func fail(_ message: String) {
        stop()
        errorText = message
    }

    // ── Connexion ──────────────────────────────────────────────────────────
    private func open(key: String, sharedContext: String) {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        let address = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(encodedKey)"
        guard let url = URL(string: address) else {
            fail("Clé Gemini invalide.")
            return
        }

        let sock = LiveSocket()
        sock.onMessage = { [weak self, weak sock] data in
            DispatchQueue.main.async {
                guard let self = self, let sock = sock, self.socket === sock else { return }
                self.handle(data)
            }
        }
        sock.onClose = { [weak self, weak sock] reason in
            DispatchQueue.main.async {
                guard let self = self, let sock = sock, self.socket === sock else { return }
                self.handleClose(reason)
            }
        }
        socket = sock

        audio.onMicChunk = { [weak sock] data in
            guard let sock = sock, sock.ready, !sock.muted else { return }
            sock.sendAudio(data)
        }
        audio.onLevel = { [weak self, weak sock] value, isOutput in
            if !isOutput, sock?.muted == true { return }
            DispatchQueue.main.async { self?.bump(CGFloat(value)) }
        }
        audio.onPlaybackIdle = { [weak self] in
            guard let self = self else { return }
            if self.state == .speaking { self.state = .listening }
        }

        sock.open(url: url)
        sock.sendText(setupMessage(sharedContext: sharedContext))
    }

    private func setupMessage(sharedContext: String) -> String {
        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(Self.model)",
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "speechConfig": [
                        "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": Self.voiceName]]
                    ]
                ],
                "systemInstruction": ["parts": [["text": Self.systemPrompt(sharedContext: sharedContext)]]],
                "tools": [[
                    "functionDeclarations": [[
                        "name": "recall_memory",
                        "description": "Relit l'historique le plus récent des conversations partagées entre le PC et le téléphone de l'utilisateur. À appeler dès que l'utilisateur parle de quelque chose dit plus tôt, hier, ou sur l'autre appareil (par exemple « le calcul que je t'ai demandé », « ce que je te disais tout à l'heure »).",
                        "parameters": [
                            "type": "OBJECT",
                            "properties": [
                                "reason": ["type": "STRING", "description": "Ce que tu cherches à retrouver"]
                            ]
                        ]
                    ]]
                ]],
                "inputAudioTranscription": [String: Any](),
                "outputAudioTranscription": [String: Any]()
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: setup),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func systemPrompt(sharedContext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let now = formatter.string(from: Date())

        var memory = ""
        let recent = OfflineStore.load().suffix(12)
        if !sharedContext.isEmpty {
            memory = "\n\nMémoire partagée entre le PC et le téléphone de l'utilisateur (tu t'en souviens, ne la récite pas) :\n" + sharedContext
                + "\nSi l'utilisateur parle de quelque chose qui n'est pas dans cette mémoire (dit à l'instant, ou sur l'autre appareil), appelle l'outil recall_memory pour relire l'historique le plus récent avant de répondre."
        } else if !recent.isEmpty {
            let lines = recent.map { m -> String in
                let who = m.speaker == "user" ? "Utilisateur" : "Jarvis"
                return "- \(who) : \(String(m.text.prefix(300)))"
            }
            memory = "\n\nMémoire des derniers échanges (tu t'en souviens, ne la récite pas) :\n" + lines.joined(separator: "\n")
        }

        return """
        Tu es JARVIS, l'assistant personnel de l'utilisateur, dans l'esprit de Jarvis d'Iron Man : professionnel, efficace, direct, légèrement ironique. Pas de blabla.
        Tu parles à voix haute depuis le téléphone de l'utilisateur : phrases courtes et naturelles, sans listes ni symboles, détaillé seulement si la question l'exige.
        Réponds dans la langue de l'utilisateur (français par défaut).
        Tu ne peux pas agir sur l'ordinateur et tu n'as pas accès à internet en direct : ne prétends jamais avoir vérifié une information récente, et signale quand une réponse peut être périmée.
        Date et heure actuelles : \(now).\(memory)
        """
    }

    // ── Messages reçus de Gemini ───────────────────────────────────────────
    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if object["setupComplete"] != nil {
            becameReady()
            return
        }
        if object["goAway"] != nil {
            caption = "La session va se terminer…"
            captionIsUser = false
        }
        if let toolCall = object["toolCall"] as? [String: Any],
           let calls = toolCall["functionCalls"] as? [[String: Any]] {
            for call in calls { answerTool(call) }
            return
        }
        guard let content = object["serverContent"] as? [String: Any] else { return }

        if (content["interrupted"] as? Bool) == true {
            audio.flushPlayback()
            flushTranscripts()
            if state == .speaking { state = .listening }
        }
        if let input = content["inputTranscription"] as? [String: Any],
           let text = input["text"] as? String {
            appendUser(text)
        }
        if let output = content["outputTranscription"] as? [String: Any],
           let text = output["text"] as? String {
            appendJarvis(text)
        }
        if let turn = content["modelTurn"] as? [String: Any],
           let parts = turn["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any],
                      let b64 = inline["data"] as? String,
                      let pcm = Data(base64Encoded: b64) else { continue }
                state = .speaking
                audio.playChunk(pcm)
            }
        }
        if (content["turnComplete"] as? Bool) == true {
            flushTranscripts()
        }
    }

    private func answerTool(_ call: [String: Any]) {
        guard let name = call["name"] as? String, let sock = socket else { return }
        let id = call["id"] as? String ?? ""
        Task {
            var result = "Fonction inconnue."
            if name == "recall_memory" {
                result = await FirebaseSync.shared.recallText()
            }
            let payload: [String: Any] = [
                "toolResponse": ["functionResponses": [["id": id, "name": name, "response": ["result": result]]]]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let text = String(data: data, encoding: .utf8) {
                sock.sendText(text)
            }
        }
    }

    private func becameReady() {
        guard let sock = socket else { return }
        sock.ready = true
        do {
            try audio.start()
        } catch {
            fail("Audio : \(error.localizedDescription)")
            return
        }
        state = .listening
        UIApplication.shared.isIdleTimerDisabled = true
        decayTimer?.invalidate()
        decayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, self.level != 0 else { return }
            let next = self.level * 0.82
            self.level = next < 0.01 ? 0 : next
        }
    }

    private func handleClose(_ reason: String) {
        let wasReady = socket?.ready ?? false
        stop()
        if wasReady {
            errorText = "Session terminée. Touche l'orbe pour reprendre."
        } else {
            errorText = "Gemini a refusé la connexion (\(String(reason.prefix(200))))."
        }
    }

    private func bump(_ value: CGFloat) {
        if value > level { level = value }
    }

    // ── Sous-titres et mémoire ─────────────────────────────────────────────
    private func appendUser(_ text: String) {
        if !jarvisBuffer.isEmpty { flushJarvis() }
        userBuffer += text
        caption = userBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        captionIsUser = true
    }

    private func appendJarvis(_ text: String) {
        if !userBuffer.isEmpty { flushUser() }
        jarvisBuffer += text
        caption = jarvisBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        captionIsUser = false
    }

    private func flushUser() {
        let text = userBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        userBuffer = ""
        if !text.isEmpty { onTranscript?("user", text) }
    }

    private func flushJarvis() {
        let text = jarvisBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        jarvisBuffer = ""
        if !text.isEmpty { onTranscript?("jarvis", text) }
    }

    private func flushTranscripts() {
        flushUser()
        flushJarvis()
    }
}

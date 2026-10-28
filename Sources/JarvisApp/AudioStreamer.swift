import Foundation
import AVFoundation

/// État de la conversation vocale, exposé à l'orbe.
enum VoiceState: Equatable {
    case idle        // pas de session
    case connecting  // ouverture de la session Gemini Live
    case listening   // le micro écoute
    case speaking    // JARVIS parle
}

/// Micro + haut-parleur du téléphone, dans UN SEUL moteur audio
/// (nécessaire pour que iOS annule l'écho : JARVIS ne s'entend pas lui-même).
///
/// - Entrée : micro → PCM 16 bits, 16 kHz, mono (format attendu par Gemini Live)
/// - Sortie : PCM 16 bits, 24 kHz, mono reçu de Gemini → converti en Float32
///   (le moteur audio d'iOS n'accepte que du Float32 entre ses nœuds).
final class LiveAudioIO {
    var onMicChunk: ((Data) -> Void)?          // appelé depuis le thread audio
    var onLevel: ((Float, Bool) -> Void)?      // (niveau 0…1, true = voix de JARVIS)
    var onPlaybackIdle: (() -> Void)?          // appelé sur le thread principal

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 24000, channels: 1,
                                           interleaved: false)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: 16000, channels: 1,
                                           interleaved: true)!
    private var running = false
    private var pending = 0          // paquets en cours de lecture (thread principal)
    private var generation = 0       // change à chaque interruption
    private var configObserver: NSObjectProtocol?

    enum AudioError: LocalizedError {
        case noInput
        var errorDescription: String? { "Micro indisponible sur ce téléphone." }
    }

    // ── Démarrage / arrêt ────────────────────────────────────────────────
    func start() throws {
        guard !running else { return }

        let session = AVAudioSession.sharedInstance()
        // .voiceChat = annulation d'écho + gain adapté à la conversation.
        try session.setCategory(.playAndRecord, mode: .voiceChat,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: sendFormat) else {
            throw AudioError.noInput
        }

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let ratio = sendFormat.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Niveau sonore du micro (pour animer l'orbe)
            if let channel = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                if count > 0 {
                    var sum: Float = 0
                    for i in 0..<count { sum += channel[i] * channel[i] }
                    let rms = (sum / Float(count)).squareRoot()
                    self.onLevel?(min(1, rms * 7), false)
                }
            }

            // Conversion vers 16 kHz / Int16
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: self.sendFormat, frameCapacity: capacity) else { return }
            var provided = false
            let block: AVAudioConverterInputBlock = { _, status in
                if provided { status.pointee = .noDataNow; return nil }
                provided = true
                status.pointee = .haveData
                return buffer
            }
            var error: NSError?
            converter.convert(to: out, error: &error, withInputFrom: block)
            guard error == nil, let channelData = out.int16ChannelData else { return }
            let frames = Int(out.frameLength)
            guard frames > 0 else { return }
            let data = Data(bytes: channelData[0], count: frames * MemoryLayout<Int16>.size)
            self.onMicChunk?(data)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true

        // Si le système interrompt le moteur (écouteurs branchés/débranchés…), on le relance.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.running else { return }
            self.engine.prepare()
            try? self.engine.start()
        }
    }

    func stop() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        engine.detach(player)
        generation += 1
        pending = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // ── Lecture de la voix de JARVIS ─────────────────────────────────────
    func playChunk(_ data: Data) {
        guard running else { return }
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat,
                                            frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        var peak: Float = 0
        data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress,
                  let dst = buffer.floatChannelData?[0] else { return }
            for i in 0..<sampleCount {
                let value = Float(src[i]) / 32768.0
                dst[i] = value
                if abs(value) > peak { peak = abs(value) }
            }
        }
        onLevel?(min(1, peak * 1.6), true)

        let gen = generation
        pending += 1
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                self.pending = max(0, self.pending - 1)
                if self.pending == 0 { self.onPlaybackIdle?() }
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// Coupe immédiatement la voix en cours (l'utilisateur a interrompu JARVIS).
    func flushPlayback() {
        generation += 1
        pending = 0
        player.stop()
    }
}

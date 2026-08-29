import Foundation
import AVFoundation

/// État exposé à l'orbe (OrbView) pour son animation.
enum VoiceState: Equatable {
    case idle
    case listening
    case speaking
}

@MainActor
final class AudioStreamer: NSObject, ObservableObject {
    @Published var voiceState: VoiceState = .idle

    private var wsTask: URLSessionWebSocketTask?
    private var pendingBuffers = 0

    // Capture micro → 16 kHz mono 16-bit PCM (format attendu par Gemini Live)
    private let captureEngine = AVAudioEngine()
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16000, channels: 1,
                                            interleaved: true)!

    // Lecture de la voix de JARVIS → 24 kHz mono 16-bit PCM
    private let playerEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 24000, channels: 1,
                                            interleaved: true)!

    var isActive: Bool { wsTask != nil }

    // ── Démarrer le micro live ──────────────────────────────────────────────
    func start(serverIP: String, token: String) {
        guard wsTask == nil,
              let url = URL(string: "ws://\(serverIP):8000/ws/phone-audio?token=\(token)")
        else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        session.requestRecordPermission { _ in }

        let task = URLSession.shared.webSocketTask(with: url)
        wsTask = task
        task.resume()

        setupPlayback()
        listenForIncomingAudio()
        startCapturing()
        voiceState = .listening
    }

    func stop() {
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
        playerNode.stop()
        playerEngine.stop()
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        pendingBuffers = 0
        voiceState = .idle
    }

    // ── Capture + envoi ──────────────────────────────────────────────────────
    private func startCapturing() {
        let input = captureEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: sendFormat) else { return }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = self.sendFormat.sampleRate / inputFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: self.sendFormat, frameCapacity: outCapacity)
            else { return }

            var provided = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if provided { outStatus.pointee = .noDataNow; return nil }
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
            guard convError == nil, let channelData = outBuffer.int16ChannelData else { return }

            let frameLength = Int(outBuffer.frameLength)
            guard frameLength > 0 else { return }
            let data = Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
            self.wsTask?.send(.data(data)) { _ in }
        }
        captureEngine.prepare()
        try? captureEngine.start()
    }

    // ── Réception + lecture de la voix de JARVIS ────────────────────────────
    private func setupPlayback() {
        playerEngine.attach(playerNode)
        playerEngine.connect(playerNode, to: playerEngine.mainMixerNode, format: playFormat)
        playerEngine.prepare()
        try? playerEngine.start()
    }

    private func listenForIncomingAudio() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in
                    if self.wsTask != nil { self.stop() }
                }
            case .success(let message):
                if case .data(let data) = message {
                    Task { @MainActor in self.playChunk(data) }
                }
                Task { @MainActor in self.listenForIncomingAudio() }
            }
        }
    }

    private func playChunk(_ data: Data) {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            if let src = raw.bindMemory(to: Int16.self).baseAddress,
               let dst = buffer.int16ChannelData?[0] {
                dst.update(from: src, count: frameCount)
            }
        }
        pendingBuffers += 1
        voiceState = .speaking
        playerNode.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBuffers -= 1
                if self.pendingBuffers <= 0 {
                    self.pendingBuffers = 0
                    self.voiceState = self.wsTask != nil ? .listening : .idle
                }
            }
        }
        if !playerNode.isPlaying { playerNode.play() }
    }
}

import AVFoundation
import Foundation

/// Bidirectional voice session over a single WebSocket.
/// Mic frames flow up as raw 16kHz mono float32. Control messages + TTS
/// chunks flow down. Replaces the HTTP POST + local VAD + full-WAV playback
/// path with full-duplex streaming.
final class StreamingSession: NSObject, URLSessionWebSocketDelegate {
    enum Event {
        case speechStart
        case speechEnd
        case transcriptYou(String, speaker: String?)
        case transcriptGemma(String, source: String?)
        case ttsEnd
        case dropped(String)
        case connectionClosed(Error?)
    }

    /// Fire-and-forget callback; always invoked on main.
    var onEvent: ((Event) -> Void)?

    private let url: URL
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var isRunning = false
    private var isMuted = false
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let frameSize: AVAudioFrameCount = 512
    private var pcmAccumulator: [Float] = []
    private let accumulatorLock = NSLock()

    init?(url: URL) {
        self.url = url
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else { return nil }
        self.targetFormat = target
        super.init()
        self.urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: [])
        try? session.overrideOutputAudioPort(.speaker)

        // Output graph: player node -> main mixer -> output.
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: targetFormat)

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        self.converter = AVAudioConverter(from: hwFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }
        engine.prepare()
        try engine.start()

        // WebSocket + send loop.
        let task = urlSession.webSocketTask(with: url)
        webSocket = task
        task.resume()
        receiveLoop()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        playerNode.stop()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isRunning = false
    }

    func mute() {
        isMuted = true
        sendControl(["type": "mute"])
    }

    func unmute() {
        isMuted = false
        sendControl(["type": "unmute"])
    }

    func forceCut() {
        sendControl(["type": "force_cut"])
    }

    // MARK: - Mic path

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted, let converter = converter else { return }
        let ratio = targetFormat.sampleRate / hwFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return }
        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0, let ch = outBuffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: frameCount))
        accumulatorLock.lock()
        pcmAccumulator.append(contentsOf: samples)
        // Emit full 512-sample frames.
        while pcmAccumulator.count >= Int(frameSize) {
            let frame = Array(pcmAccumulator.prefix(Int(frameSize)))
            pcmAccumulator.removeFirst(Int(frameSize))
            accumulatorLock.unlock()
            let data = frame.withUnsafeBufferPointer { Data(buffer: $0) }
            webSocket?.send(.data(data)) { _ in }
            accumulatorLock.lock()
        }
        accumulatorLock.unlock()
    }

    // MARK: - Receive

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async { self.onEvent?(.connectionClosed(error)) }
                return
            case .success(let message):
                self.handleIncoming(message)
                self.receiveLoop()
            }
        }
    }

    private func handleIncoming(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let d):
            // TTS PCM16 chunk — schedule on player node as a buffer.
            self.scheduleTTSChunk(d)
        case .string(let s):
            guard let data = s.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return }
            DispatchQueue.main.async {
                switch type {
                case "speech_start":
                    self.onEvent?(.speechStart)
                case "speech_end":
                    self.onEvent?(.speechEnd)
                case "transcript_you":
                    self.onEvent?(.transcriptYou(json["text"] as? String ?? "",
                                                  speaker: json["speaker"] as? String))
                case "transcript_gemma":
                    self.onEvent?(.transcriptGemma(json["text"] as? String ?? "",
                                                    source: json["source"] as? String))
                case "tts_end":
                    self.onEvent?(.ttsEnd)
                case "dropped":
                    self.onEvent?(.dropped(json["reason"] as? String ?? ""))
                default: break
                }
            }
        @unknown default: break
        }
    }

    private func scheduleTTSChunk(_ data: Data) {
        // Incoming: 16kHz mono int16 PCM from Kokoro.
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return }
        data.withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                channel[i] = Float(int16[i]) / 32768.0
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Control

    private func sendControl(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(str)) { _ in }
    }
}

import AVFoundation
import Foundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var outputFormat: AVAudioFormat?
    private var samples: [Int16] = []
    private let samplesLock = NSLock()
    private let sampleRate: Double = 16_000
    private var isRecording = false

    /// Fired after each tap buffer with a 0..1 RMS level (linear). Called on an audio thread.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        guard !isRecording else { return }
        resetBuffer()

        let session = AVAudioSession.sharedInstance()
        // .spokenAudio mode with .playAndRecord supports simultaneous mic capture
        // and high-quality media-level playback. Not routed through the phone-call
        // stream, so volume is at normal media level.
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: [])
        try? session.overrideOutputAudioPort(.speaker)
        NSLog("[GemmaVoice] session configured: category=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate)")

        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: sampleRate,
                                               channels: 1,
                                               interleaved: true) else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create target format"])
        }
        self.outputFormat = targetFormat

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create converter"])
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            let ratio = targetFormat.sampleRate / hwFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

            var error: NSError?
            var inputConsumed = false
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                if inputConsumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error || error != nil { return }

            let frameCount = Int(outBuffer.frameLength)
            guard frameCount > 0, let channelData = outBuffer.int16ChannelData?[0] else { return }
            let bufferPointer = UnsafeBufferPointer(start: channelData, count: frameCount)

            // RMS on the new frames (normalized to 0..1).
            var sumSq: Double = 0
            for i in 0..<frameCount {
                let v = Double(channelData[i])
                sumSq += v * v
            }
            let rms = sqrt(sumSq / Double(frameCount))
            let level = Float(min(1.0, rms / 10_000.0))
            self.onLevel?(level)

            self.samplesLock.lock()
            self.samples.append(contentsOf: bufferPointer)
            self.samplesLock.unlock()
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop the engine and release the session. Returns the final WAV if there is any buffered audio.
    func stopAndProduceWAV() -> Data? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        return snapshotAndReset()
    }

    /// Soft-mute: detach tap and clear buffer, but leave engine + session running so
    /// re-arming the tap is instant (no AVAudioSession reactivation race).
    func suspend() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        resetBuffer()
        // engine stays running, isRecording stays true
    }

    /// Re-attach the tap after a suspend(). Idempotent if already attached.
    func resume() throws {
        guard isRecording, let targetFormat = self.outputFormat else {
            // Cold start path
            try start()
            return
        }
        // If engine was stopped (e.g. session interruption), restart it.
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        NSLog("[GemmaVoice] resume: engine.isRunning=\(engine.isRunning) hwFormat=\(hwFormat)")
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw NSError(domain: "AudioRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create converter on resume"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            let ratio = targetFormat.sampleRate / hwFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }
            var error: NSError?
            var inputConsumed = false
            let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
                if inputConsumed { inputStatus.pointee = .noDataNow; return nil }
                inputConsumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error || error != nil { return }
            let frameCount = Int(outBuffer.frameLength)
            guard frameCount > 0, let channelData = outBuffer.int16ChannelData?[0] else { return }
            let bufferPointer = UnsafeBufferPointer(start: channelData, count: frameCount)
            var sumSq: Double = 0
            for i in 0..<frameCount {
                let v = Double(channelData[i])
                sumSq += v * v
            }
            let rms = sqrt(sumSq / Double(frameCount))
            let level = Float(min(1.0, rms / 10_000.0))
            self.onLevel?(level)
            self.samplesLock.lock()
            self.samples.append(contentsOf: bufferPointer)
            self.samplesLock.unlock()
        }
    }

    /// Snapshot currently buffered samples as a WAV and clear the buffer. Engine keeps running.
    func snapshotAndReset() -> Data? {
        samplesLock.lock()
        let buffered = samples
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()
        guard !buffered.isEmpty else { return nil }
        let pcmBytes = buffered.withUnsafeBufferPointer { Data(buffer: $0) }
        return Self.wavData(pcm16: pcmBytes, sampleRate: Int(sampleRate), channels: 1)
    }

    func resetBuffer() {
        samplesLock.lock()
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()
    }

    func bufferedSampleCount() -> Int {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        return samples.count
    }

    static func wavData(pcm16: Data, sampleRate: Int, channels: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2
        let dataSize = UInt32(pcm16.count)
        let chunkSize = 36 + dataSize

        data.append("RIFF".data(using: .ascii)!)
        data.append(uint32LE(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(uint32LE(16))
        data.append(uint16LE(1))
        data.append(uint16LE(UInt16(channels)))
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(byteRate)))
        data.append(uint16LE(UInt16(blockAlign)))
        data.append(uint16LE(16))
        data.append("data".data(using: .ascii)!)
        data.append(uint32LE(dataSize))
        data.append(pcm16)
        return data
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 4)
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        var v = v.littleEndian
        return Data(bytes: &v, count: 2)
    }
}

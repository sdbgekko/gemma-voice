import AVFoundation
import UIKit

/// Plays a ~150ms soft descending two-tone the moment the server reports
/// speech_end, so Sherman hears "I got it" instead of silence while the
/// pipeline is thinking. Also fires a light haptic in the same instant.
///
/// Tone is synthesized once in memory (two sine blips, 880Hz → 660Hz)
/// and replayed via AVAudioPlayer — no bundle asset needed.
final class EarbackTone {
    static let shared = EarbackTone()
    private var player: AVAudioPlayer?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private init() {
        haptic.prepare()
        player = try? AVAudioPlayer(data: Self.buildToneData())
        player?.prepareToPlay()
    }

    func play() {
        // Read live so the Settings slider takes effect without a restart.
        let raw = UserDefaults.standard.object(forKey: "earbackVolume") as? Double
        let vol = Float(raw ?? 0.5)
        if vol <= 0.01 { return }  // fully muted
        player?.volume = vol
        haptic.impactOccurred(intensity: 0.6)
        player?.currentTime = 0
        player?.play()
    }

    private static func buildToneData() -> Data {
        let rate = 24_000
        let total = 0.16       // 160ms
        let split = 0.08       // 80ms each half
        let samples = Int(Double(rate) * total)
        var pcm = [Int16](repeating: 0, count: samples)
        for i in 0..<samples {
            let t = Double(i) / Double(rate)
            let freq = t < split ? 880.0 : 660.0
            // Short fade in/out on each half to avoid clicks.
            let localT = t < split ? t : t - split
            let halfLen = split
            let fade = min(localT, halfLen - localT) / 0.012
            let env = max(0, min(1, fade))
            let amp = 0.22 * env
            pcm[i] = Int16(amp * 32767.0 * sin(2 * .pi * freq * t))
        }
        return wrapPCM16(pcm, sampleRate: rate)
    }

    private static func wrapPCM16(_ pcm: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let bytes = pcm.count * 2
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + bytes))
        d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
        u16(2); u16(16)
        d.append("data".data(using: .ascii)!)
        u32(UInt32(bytes))
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

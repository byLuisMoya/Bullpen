import AppKit
import Foundation

/// The sound for each thing an agent can tell you (Ajustes › Avisos): soft macOS sounds and a few
/// of Bullpen's own, synthesized, at the chosen volume.
@MainActor
enum AlertSounds {
    enum Event: String, CaseIterable, Identifiable {
        case needsYou, done, error, message
        var id: String { rawValue }
        var key: String { "sound.\(rawValue)" }
        var title: String {
            switch self {
            case .needsYou: "Te pregunta algo o pide permiso"
            case .done: "Ha terminado"
            case .error: "Ha fallado"
            case .message: "Un agente te escribe"
            }
        }
        var standard: String {
            switch self {
            case .needsYou: "bullpen.chime"
            case .done: "Pop"
            case .error: "Purr"
            case .message: "bullpen.drop"
            }
        }
    }

    static let volumeKey = "sound.volume"
    static let whileLookingKey = "sound.whileLooking"

    /// "" is silence; `bullpen.*` are synthesized here; the rest are in /System/Library/Sounds.
    static let choices: [(id: String, name: String)] = [
        ("", "Sin sonido"),
        ("bullpen.chime", "Campanita"),
        ("bullpen.drop", "Gota"),
        ("bullpen.bubble", "Burbuja"),
        ("bullpen.marimba", "Marimba"),
        ("Tink", "Tink"), ("Pop", "Pop"), ("Glass", "Cristal"), ("Purr", "Ronroneo"),
        ("Bottle", "Botella"), ("Ping", "Ping"), ("Morse", "Morse"), ("Submarine", "Submarino"), ("Blow", "Soplido"),
    ]

    static func sound(for event: Event) -> String {
        UserDefaults.standard.string(forKey: event.key) ?? event.standard
    }

    static var volume: Float {
        UserDefaults.standard.object(forKey: volumeKey) == nil ? 0.6 : UserDefaults.standard.float(forKey: volumeKey)
    }

    private static var lastPlayed = Date.distantPast
    /// Kept alive while playing (NSSound stops when released).
    private static var playing: NSSound?

    /// Plays the event's sound; several state changes at once make one sound, not a burst.
    static func play(_ event: Event) {
        guard Date().timeIntervalSince(lastPlayed) > 1.5 else { return }
        if preview(sound(for: event)) { lastPlayed = Date() }
    }

    @discardableResult
    static func preview(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        let sound: NSSound? = if let tone = Tone.named(id) {
            NSSound(data: tone.wav())
        } else {
            NSSound(named: NSSound.Name(id))
        }
        guard let sound else { return false }
        playing?.stop()
        sound.volume = volume
        sound.play()
        playing = sound
        return true
    }
}

/// Short, soft tones: sine partials with a quick attack and an exponential fade.
struct Tone {
    /// (frequency Hz, start s, amplitude)
    var notes: [(Double, Double, Double)]
    var length: Double
    var decay: Double
    /// Pitch rising over each note (the bubble).
    var glide: Double = 0

    static func named(_ id: String) -> Tone? {
        switch id {
        case "bullpen.chime": Tone(notes: [(1318.5, 0, 0.5), (1760, 0.12, 0.45)], length: 0.9, decay: 5)
        case "bullpen.drop": Tone(notes: [(1567.98, 0, 0.55)], length: 0.35, decay: 14, glide: -0.35)
        case "bullpen.bubble": Tone(notes: [(523.25, 0, 0.5), (659.25, 0.07, 0.4)], length: 0.4, decay: 11, glide: 0.6)
        case "bullpen.marimba": Tone(notes: [(784, 0, 0.5), (1046.5, 0.1, 0.4), (1318.5, 0.2, 0.35)], length: 0.8, decay: 9)
        default: nil
        }
    }

    /// 16-bit mono WAV at 44.1 kHz.
    func wav(rate: Double = 44_100) -> Data {
        let count = Int(length * rate)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / rate
            var value = 0.0
            for (frequency, start, amplitude) in notes where t >= start {
                let local = t - start
                let attack = min(local / 0.006, 1)
                // A soft octave on top makes it a bell rather than a beep.
                let phase = 2 * .pi * frequency * (local + glide * local * local)
                value += amplitude * attack * exp(-decay * local) * (sin(phase) + 0.25 * sin(2 * phase))
            }
            samples[i] = Int16(max(-1, min(1, value * 0.7)) * Double(Int16.max))
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        samples.forEach { append($0) }
        return data
    }
}

@preconcurrency import AVFoundation
import Observation
@preconcurrency import Speech
import SwiftUI

/// Speech to text with macOS's recognizer (on the Mac when the language allows it): what you
/// say ends up typed in the terminal, for any agent, without pressing Return.
@MainActor
@Observable
final class Dictation {
    enum State: Equatable { case idle, listening, finishing }

    private(set) var state = State.idle
    /// What has been understood so far (shown while speaking).
    private(set) var text = ""
    /// Microphone level 0…1, for the button's pulse.
    private(set) var level: Double = 0
    var problem: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var finished: CheckedContinuation<Void, Never>?
    /// Which dictation is running: late callbacks of an earlier one must not touch it.
    @ObservationIgnored private var generation = 0

    /// Language of the recognizer (Ajustes › General), Spanish by default.
    static var localeID: String {
        UserDefaults.standard.string(forKey: "dictation.locale") ?? "es-ES"
    }

    func start() async {
        guard state == .idle else { return }
        problem = nil
        text = ""
        guard await Self.authorized() else {
            problem = "Bullpen no tiene permiso para el micrófono o el reconocimiento de voz (Ajustes del Sistema › Privacidad y seguridad)."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.localeID)), recognizer.isAvailable else {
            problem = "El reconocimiento de voz no está disponible para \(Self.localeID)."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // On the Mac when possible: private, free and without the one-minute limit.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            problem = "No hay ningún micrófono disponible."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, request] buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.level = level }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "No se pudo abrir el micrófono: \(error.localizedDescription)"
            return
        }
        self.engine = engine
        self.request = request
        generation += 1
        let current = generation
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                guard let self, self.generation == current, self.state != .idle else { return }
                if let heard { self.text = heard }
                if done { self.finish() }
            }
        }
    }

    /// Stops listening and returns everything understood (empty if nothing was).
    func stop() async -> String {
        guard state == .listening else { return "" }
        state = .finishing
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // The last words arrive just after the audio ends; don't wait forever for them.
        let current = generation
        await withCheckedContinuation { continuation in
            finished = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.generation == current, self.state == .finishing else { return }
                self.finish()
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        task?.cancel()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        finish()
        text = ""
    }

    private func finish() {
        if state == .listening {
            // The recognizer ended on its own (silence, error): stop the microphone too.
            engine?.stop()
            engine?.inputNode.removeTap(onBus: 0)
        }
        task = nil
        request = nil
        engine = nil
        level = 0
        if state != .idle { state = .idle }
        finished?.resume()
        finished = nil
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return Double(min(max(rms * 12, 0), 1))
    }
}

/// Floating microphone over the terminal. Click to start and click again to finish, or hold
/// it while you speak and let go. The text is typed in the terminal, not sent.
struct DictationButton: View {
    /// Types the text into the terminal shown.
    let insert: (String) -> Void
    @State private var dictation = Dictation()
    @State private var pressedAt: Date?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if dictation.state != .idle, !dictation.text.isEmpty {
                Text(dictation.text)
                    .font(.callout)
                    .lineLimit(6)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: 420, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .transition(.opacity)
            }
            if let problem = dictation.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: 360, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { dictation.problem = nil }
            }
            button
        }
        .padding(14)
        .animation(.easeOut(duration: 0.15), value: dictation.state)
    }

    private var listening: Bool { dictation.state == .listening }

    private var button: some View {
        ZStack {
            Circle()
                .fill(listening ? Color.red : Color.accentColor)
                .frame(width: 40, height: 40)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            Circle()
                .stroke(Color.red.opacity(0.5), lineWidth: 3)
                .frame(width: 40, height: 40)
                .scaleEffect(1 + dictation.level * 0.6)
                .opacity(listening ? 1 : 0)
                .animation(.easeOut(duration: 0.08), value: dictation.level)
            if dictation.state == .finishing {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressedAt == nil else { return }
                    pressedAt = Date()
                    startedBefore = listening
                    if dictation.state == .idle { Task { await dictation.start() } }
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressedAt ?? Date())
                    pressedAt = nil
                    // A long press is push-to-talk; a click started (or now finishes) a dictation.
                    if held > 0.5 || startedBefore { finish() }
                }
        )
        .help(listening ? "Terminar y escribir en la terminal (⌘⇧D)" : "Dictar (⌘⇧D): pulsa y habla, o mantén pulsado mientras hablas")
        .background {
            // Same toggle from the keyboard.
            Button("") {
                if listening { finish() } else { Task { await dictation.start() } }
            }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    /// Whether a dictation was already running when this click began.
    @State private var startedBefore = false

    private func finish() {
        Task {
            let said = await dictation.stop()
            if !said.isEmpty { insert(said) }
        }
    }
}

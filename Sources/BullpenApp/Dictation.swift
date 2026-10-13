@preconcurrency import AVFoundation
import Observation
import os
@preconcurrency import Speech
import SwiftUI

/// Speech to text with macOS's recognizer, for any agent: you record, check (and correct) the
/// text, and send it to the terminal.
@MainActor
@Observable
final class Dictation {
    enum State: Equatable {
        case idle
        case listening
        /// Stopped: the text waits to be sent, recorded again or thrown away.
        case ready
    }

    private(set) var state = State.idle
    /// What has been understood (editable once stopped).
    var text = ""
    /// Microphone level 0…1, for the pulse.
    private(set) var level: Double = 0
    var problem: String?
    /// macOS answered that Siri and Dictation are off: without them the recognizer hears nothing.
    var dictationDisabled = false

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Which recording is running: late callbacks of an earlier one must not touch it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var onDevice = true
    /// The recognizer's last text: once stopped, its late words only replace an unedited text.
    @ObservationIgnored private var heard = ""
    @ObservationIgnored private let log = Logger.bullpen("dictation")

    /// Language of the recognizer (Ajustes › General), Spanish by default.
    static var localeID: String {
        UserDefaults.standard.string(forKey: "dictation.locale") ?? "es-ES"
    }

    func start() async {
        guard state != .listening else { return }
        problem = nil
        text = ""
        heard = ""
        guard await Self.speechAuthorized() else {
            problem = "Bullpen no tiene permiso de reconocimiento de voz: actívalo en Ajustes del Sistema › Privacidad y seguridad › Reconocimiento de voz."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            problem = "Bullpen no tiene permiso para el micrófono: actívalo en Ajustes del Sistema › Privacidad y seguridad › Micrófono."
            return
        }
        onDevice = true
        begin()
    }

    private func begin() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.localeID)) else {
            problem = "No hay reconocimiento de voz para \(Self.localeID). Cambia el idioma en Ajustes › General."
            return
        }
        guard recognizer.isAvailable else {
            problem = "El reconocimiento de voz no está disponible ahora mismo. Comprueba la conexión o activa el dictado en Ajustes del Sistema › Teclado."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // On the Mac when it can (private, no time limit); falls back to Apple's servers below.
        request.requiresOnDeviceRecognition = onDevice && recognizer.supportsOnDeviceRecognition

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
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
            log.error("Microphone: \(error.localizedDescription, privacy: .public)")
            problem = "No se pudo abrir el micrófono: \(error.localizedDescription)"
            return
        }
        self.engine = engine
        self.request = request
        generation += 1
        let current = generation
        startedAt = Date()
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error.map { error in
                let error = error as NSError
                return "\(error.localizedDescription) (\(error.domain) \(error.code))"
            }
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if let heard, !heard.isEmpty, self.state == .listening || self.text == self.heard {
                    self.text = heard
                    self.heard = heard
                }
                if let message { self.recognitionFailed(message) } else if isFinal { self.stopAudio(); self.settle() }
            }
        }
    }

    /// The recognizer gave up. Right at the start on the Mac's own model (not downloaded,
    /// language not supported there): try again through Apple's servers.
    private func recognitionFailed(_ message: String) {
        log.error("Recognition: \(message, privacy: .public)")
        // Apple's servers need it too: retrying there only ends in "No speech detected".
        if message.localizedCaseInsensitiveContains("Siri and Dictation are disabled") {
            stopAudio()
            dictationDisabled = true
            settle()
            return
        }
        let early = Date().timeIntervalSince(startedAt) < 3 && text.isEmpty
        stopAudio()
        if state == .listening, early, onDevice {
            onDevice = false
            begin()
            return
        }
        if state == .listening, text.isEmpty {
            problem = "El reconocimiento de voz falló: \(message)"
        }
        settle()
    }

    /// Stop recording and keep the text to check it.
    func stop() {
        guard state == .listening else { return }
        request?.endAudio()
        stopAudio()
        // The last words come right after the audio ends; the text is editable meanwhile anyway.
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.generation == current else { return }
            self.task?.cancel()
            self.task = nil
        }
        settle()
    }

    /// Throw the recording (or the text waiting) away.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        stopAudio()
        text = ""
        state = .idle
    }

    private func settle() {
        request = nil
        state = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .ready
    }

    private func stopAudio() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        level = 0
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
    }

    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return Double(min(max(rms * 12, 0), 1))
    }
}

/// Floating microphone over the terminal. Recording: ■ stops, ✕ cancels. Stopped: the text can
/// be corrected, then sent (typed and Return), recorded again, or thrown away.
struct DictationButton: View {
    /// Types the text into the terminal shown; `submit` also presses Return.
    let send: (_ text: String, _ submit: Bool) -> Void
    @State private var dictation = Dictation()

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let problem = dictation.problem {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button { dictation.problem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                }
                .padding(8)
                .frame(maxWidth: 380, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            switch dictation.state {
            case .idle:
                round("mic.fill", color: .accentColor, help: "Dictar (⌘⇧D)") { Task { await dictation.start() } }
            case .listening:
                VStack(alignment: .trailing, spacing: 8) {
                    if !dictation.text.isEmpty { bubble(Text(dictation.text).font(.callout).lineLimit(8)) }
                    HStack(spacing: 10) {
                        round("xmark", color: .secondary, size: 32, help: "Cancelar la grabación") { dictation.cancel() }
                        ZStack {
                            Circle().stroke(Color.red.opacity(0.5), lineWidth: 3)
                                .frame(width: 44, height: 44)
                                .scaleEffect(1 + dictation.level * 0.6)
                                .animation(.easeOut(duration: 0.08), value: dictation.level)
                            round("stop.fill", color: .red, help: "Parar la grabación (⌘⇧D)") { dictation.stop() }
                        }
                    }
                }
            case .ready:
                VStack(alignment: .trailing, spacing: 8) {
                    bubble(
                        TextField("", text: $dictation.text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .lineLimit(1...8)
                            .onSubmit { submit() }
                    )
                    HStack(spacing: 10) {
                        round("xmark", color: .secondary, size: 32, help: "Descartar") { dictation.cancel() }
                        round("mic.fill", color: .accentColor, size: 32, help: "Grabar de nuevo") { Task { await dictation.start() } }
                        round("arrow.up", color: .accentColor, help: "Enviar al agente (⌘↩)") { submit() }
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }
            }
        }
        .padding(14)
        .animation(.easeOut(duration: 0.15), value: dictation.state)
        .alert("El dictado de macOS está desactivado", isPresented: $dictation.dictationDisabled) {
            Button("Abrir Ajustes de Teclado") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Bullpen usa el reconocimiento de voz del sistema, que no funciona con el dictado apagado. Actívalo en Ajustes del Sistema › Teclado › Dictado (con el idioma de \(Dictation.localeID)) y vuelve a grabar.")
        }
        .background {
            // ⌘⇧D: start, or stop while recording.
            Button("") {
                switch dictation.state {
                case .listening: dictation.stop()
                default: Task { await dictation.start() }
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private func submit() {
        let text = dictation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(text, true)
        dictation.cancel()
    }

    private func bubble(_ content: some View) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 380, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .transition(.opacity)
    }

    private func round(_ symbol: String, color: Color, size: CGFloat = 40, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(color))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        // The terminal underneath claims the I-beam through its cursor rect: set the hand on every move.
        .onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.iBeam.set()
            }
        }
    }
}

import AVFoundation
import Speech
import SwiftUI

// Speak to Nikita instead of typing. Live, on-device where the phone supports
// it, streaming partial text straight into the message field so the user sees
// their words appear as they talk and can hit send the moment they finish.
//
// Deliberately small and self-contained: it owns the audio engine and the
// recognizer, exposes a transcript and a listening flag, and asks for the two
// permissions (microphone + speech) the first time it is used. Nothing here
// touches the agent -- the view copies the transcript into its draft, so the
// spoken path and the typed path converge on the exact same send().
@MainActor
final class NikitaDictation: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var transcript = ""
    @Published private(set) var lastError: String?

    // The device locale, so Portuguese speech is recognised as Portuguese. Nil
    // (unsupported locale) falls back to the recognizer's default.
    private let recognizer = SFSpeechRecognizer(locale: .current)
        ?? SFSpeechRecognizer()

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    // Toggle: begins listening, or ends and keeps the final transcript.
    func toggle() {
        if listening { stop() } else { start() }
    }

    func start() {
        guard !listening else { return }
        lastError = nil
        transcript = ""

        // Both permissions, chained: speech authorisation first, then the mic.
        // Asked here, on the first tap, not at launch -- so the prompt has
        // obvious context.
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.lastError = "Speech recognition is off. Enable it in "
                        + "Settings › Nikita."
                    return
                }
                self.requestMicThenRun()
            }
        }
    }

    private func requestMicThenRun() {
        // A plain @Sendable completion that hops to the main actor -- capturing
        // a stored closure here trips Swift's Sendable check, so the handler is
        // written inline instead.
        @Sendable func granted(_ ok: Bool) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard ok else {
                    self.lastError = "Microphone is off. Enable it in "
                        + "Settings › Nikita."
                    return
                }
                self.beginSession()
            }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted($0) }
        } else {
            AVAudioSession.sharedInstance()
                .requestRecordPermission { granted($0) }
        }
    }

    private func beginSession() {
        guard let recognizer, recognizer.isAvailable else {
            lastError = "Speech recognition is not available right now."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .record, mode: .measurement, options: .duckOthers)
            try session.setActive(
                true, options: .notifyOthersOnDeactivation)
        } catch {
            lastError = "Could not start audio: \(error.localizedDescription)"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(
            onBus: 0, bufferSize: 1024, format: format
        ) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            lastError = "Could not start the microphone: "
                + error.localizedDescription
            teardown()
            return
        }

        listening = true
        task = recognizer.recognitionTask(
            with: request
        ) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { self.stop() }
                }
                if error != nil { self.stop() }
            }
        }
    }

    func stop() {
        guard listening || engine.isRunning else { teardown(); return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.finish()
        teardown()
    }

    private func teardown() {
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }
}

//  Dictation.swift
//  PitBoard Stage 2 — Apple Speech framework: tap mic, talk, ops happen.

import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
final class Dictation: ObservableObject {
    @Published var listening = false
    @Published var authDenied = false

    private var audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer()

    /// Called with the running transcript; `isFinal` true when recognition ends.
    var onText: ((String, Bool) -> Void)?

    func toggle() {
        if listening { stop(sendFinal: true) } else { start() }
    }

    private func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard let self else { return }
                guard auth == .authorized else { self.authDenied = true; return }
                self.begin()
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable, !listening else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = audioEngine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
            req.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch { return }
        listening = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let r = result {
                    self.onText?(r.bestTranscription.formattedString, r.isFinal)
                    if r.isFinal { self.stop(sendFinal: false) }
                }
                if error != nil { self.stop(sendFinal: false) }
            }
        }
    }

    func stop(sendFinal: Bool) {
        guard listening || task != nil else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil; request = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if sendFinal { onText?("", true) }   // signal "user tapped stop" with current text
    }
}

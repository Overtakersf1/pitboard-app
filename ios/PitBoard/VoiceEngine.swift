//  VoiceEngine.swift
//  PitBoard v0.6 — Stage 3: full-duplex voice inside the app.
//
//  Wraps PipecatClient + SmallWebRTC transport. Connects to the PitBoard
//  Voice server (voice/stage2_bot.py behind Tailscale Serve): POSTs to
//  <server>/start for a session id, then negotiates WebRTC at
//  <server>/sessions/<id>/api/offer. Echo cancellation comes with WebRTC.

import Combine
import Foundation
import PipecatClientIOS
import PipecatClientIOSSmallWebrtc

@MainActor
final class VoiceEngine: NSObject, ObservableObject {

    enum State: Equatable {
        case off, connecting, connected
        case error(String)
    }

    @Published var state: State = .off
    @Published var botSpeaking = false
    @Published var userSpeaking = false

    private var client: PipecatClient?

    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "voice_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voice_url") }
    }

    var configured: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func toggle() {
        switch state {
        case .off, .error: start()
        case .connecting, .connected: stop()
        }
    }

    func start() {
        guard client == nil || state == .off || {
            if case .error = state { return true }; return false }() else { return }

        // Normalize: the SDK derives the offer URL by replacing "/start",
        // so the endpoint must end with exactly that.
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { state = .error("No voice server URL — set it in Settings."); return }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/start") { base += "/start" }
        guard let endpoint = URL(string: base), endpoint.scheme?.hasPrefix("http") == true else {
            state = .error("Voice server URL doesn't look like a URL.")
            return
        }

        let options = PipecatClientOptions(
            transport: SmallWebRTCTransport(),
            enableMic: true,
            enableCam: false
        )
        let c = PipecatClient(options: options)
        c.delegate = self
        client = c
        state = .connecting

        c.startBotAndConnect(startBotParams: APIRequest(endpoint: endpoint)) {
            [weak self] (result: Result<SmallWebRTCStartBotResult, AsyncExecutionError>) in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    break  // onConnected / transport state drives UI from here
                case .failure(let err):
                    self.state = .error(Self.friendly(err))
                    self.teardown()
                }
            }
        }
    }

    func stop() {
        guard let c = client else { state = .off; return }
        state = .off
        c.disconnect { [weak self] _ in
            Task { @MainActor in self?.teardown() }
        }
    }

    private func teardown() {
        client?.release()
        client = nil
        botSpeaking = false
        userSpeaking = false
        if state == .connecting || state == .connected { state = .off }
    }

    private static func friendly(_ err: Error) -> String {
        let s = String(describing: err)
        if s.contains("-1004") || s.lowercased().contains("could not connect") {
            return "Can't reach the voice server — is stage2 running and Tailscale Serve on?"
        }
        if s.contains("-1200") || s.lowercased().contains("ssl") {
            return "TLS problem — use the https://…ts.net URL from Tailscale Serve."
        }
        return "Voice connect failed: \(String(s.prefix(120)))"
    }
}

extension VoiceEngine: PipecatClientDelegate {

    nonisolated func onConnected() {
        Task { @MainActor in self.state = .connected }
    }

    nonisolated func onDisconnected() {
        Task { @MainActor in
            self.botSpeaking = false
            self.userSpeaking = false
            if self.state != .off { self.state = .off }
            self.client?.release()
            self.client = nil
        }
    }

    nonisolated func onTransportStateChanged(state: TransportState) {
        Task { @MainActor in
            switch state {
            case .connecting, .authenticating, .initializing:
                if self.state == .off { self.state = .connecting }
            case .error:
                if self.state != .off { self.state = .error("Voice transport error.") }
            default:
                break
            }
        }
    }

    nonisolated func onError(message: RTVIMessageInbound) {
        Task { @MainActor in
            // Non-fatal pipeline errors arrive here too; only surface if
            // we aren't happily connected.
            if self.state == .connecting {
                self.state = .error("Voice server rejected the connection.")
            }
        }
    }

    nonisolated func onBotStartedSpeaking() {
        Task { @MainActor in self.botSpeaking = true }
    }

    nonisolated func onBotStoppedSpeaking() {
        Task { @MainActor in self.botSpeaking = false }
    }

    nonisolated func onUserStartedSpeaking() {
        Task { @MainActor in self.userSpeaking = true }
    }

    nonisolated func onUserStoppedSpeaking() {
        Task { @MainActor in self.userSpeaking = false }
    }
}

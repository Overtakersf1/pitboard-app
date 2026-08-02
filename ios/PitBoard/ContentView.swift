//  ContentView.swift
//  PitBoard — top bar (sync status, undo, finger toggle, settings) + canvas

import SwiftUI

struct ContentView: View {
    @StateObject private var engine = SyncEngine()
    @State private var fingerDraws = true
    @State private var showSettings = false
    @State private var canvasCoordinator: CanvasView.Coordinator?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            CanvasView(engine: engine, fingerDraws: $fingerDraws,
                       coordinatorRef: $canvasCoordinator)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color(BoardRenderer.canvasBG))
        .sheet(isPresented: $showSettings) {
            SettingsSheet(engine: engine)
        }
        .task {
            if engine.token != nil { await engine.connect() }
            else { showSettings = true }
        }
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.64, blue: 1.0),
                                                  Color(red: 1.0, green: 0.71, blue: 0.33)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 24, height: 24)
                    .overlay(Text("PB").font(.system(size: 11, weight: .heavy)).foregroundColor(.black))
                Text("PITBOARD").font(.system(size: 13, weight: .bold)).kerning(1.5)
                    .foregroundColor(.white)
                Text("native v0.1.3").font(.system(size: 10)).foregroundColor(.gray)
            }
            Spacer()
            Button { canvasCoordinator?.undoLast() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            Button { fingerDraws.toggle() } label: {
                Image(systemName: fingerDraws ? "hand.draw" : "hand.raised")
            }
            Button { showSettings = true } label: {
                statusDot
            }
        }
        .font(.system(size: 17))
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.055, green: 0.067, blue: 0.086))
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 12, height: 12)
            .shadow(color: dotColor.opacity(0.8), radius: 4)
    }

    private var dotColor: Color {
        switch engine.status {
        case .off: return .gray
        case .ok: return .green
        case .pending: return .orange
        case .error: return .red
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var tokenInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Live sync") {
                    LabeledContent("Repo", value: engine.repo)
                    LabeledContent("Branch", value: engine.branch)
                    SecureField("github_pat_… fine-grained token", text: $tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button(engine.isConnected ? "Reconnect" : "Connect & sync") {
                        if !tokenInput.isEmpty {
                            KeychainStore.save(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                               key: "gh_token")
                        }
                        Task { await engine.connect(); dismiss() }
                    }
                    .disabled(tokenInput.isEmpty && engine.token == nil)
                    if engine.isConnected {
                        Button("Disconnect", role: .destructive) { engine.disconnect(); dismiss() }
                    }
                }
                if !engine.lastError.isEmpty {
                    Section("Last error") { Text(engine.lastError).font(.footnote) }
                }
                Section {
                    Text("Token is stored in the iOS Keychain. It only needs Contents read/write on the board repo.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("PitBoard Sync")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear { tokenInput = "" }
    }
}

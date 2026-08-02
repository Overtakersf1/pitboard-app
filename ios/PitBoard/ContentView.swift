//  ContentView.swift
//  PitBoard v0.2 — mode toolbar (draw/select/erase/shapes/text/beacon),
//  object color palette, undo/redo, sync status + settings

import SwiftUI

struct ContentView: View {
    @StateObject private var engine = SyncEngine()
    @State private var fingerDraws = true
    @State private var showSettings = false
    @State private var mode: BoardMode = .draw
    @State private var objColor: String = "ink"
    @State private var canvasCoordinator: CanvasView.Coordinator?

    private let palette = ["ink", "#4da3ff", "#ffb454", "#ff6b6b", "#51d88a", "#b78cff"]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            CanvasView(engine: engine, fingerDraws: $fingerDraws,
                       mode: $mode, objColor: $objColor,
                       coordinatorRef: $canvasCoordinator)
                .ignoresSafeArea(edges: .bottom)
        }
        .background(Color(BoardRenderer.canvasBG))
        .sheet(isPresented: $showSettings) { SettingsSheet(engine: engine) }
        .task {
            if engine.token != nil { await engine.connect() }
            else { showSettings = true }
        }
        .statusBarHidden()
    }

    // MARK: - toolbar

    private var topBar: some View {
        HStack(spacing: 10) {
            logo
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    modeButton(.draw, "pencil.tip")
                    modeButton(.select, "cursorarrow")
                    modeButton(.erase, "eraser")
                    divider
                    modeButton(.rect, "rectangle")
                    modeButton(.ellipse, "circle")
                    modeButton(.diamond, "diamond")
                    modeButton(.arrow, "arrow.up.right")
                    modeButton(.line, "line.diagonal")
                    modeButton(.text, "textformat")
                    modeButton(.beacon, "eye")
                    divider
                    if mode != .draw { colorDots; divider }
                    Button { canvasCoordinator?.undo() } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }.buttonStyle(ToolStyle(active: false))
                    Button { canvasCoordinator?.redo() } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }.buttonStyle(ToolStyle(active: false))
                    if mode == .select {
                        Button { canvasCoordinator?.deleteSelected() } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(ToolStyle(active: false, tint: .red))
                    }
                }
            }
            Spacer(minLength: 4)
            Button { fingerDraws.toggle() } label: {
                Image(systemName: fingerDraws ? "hand.draw" : "hand.raised")
            }.buttonStyle(ToolStyle(active: false))
            Button { showSettings = true } label: { statusDot }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(red: 0.055, green: 0.067, blue: 0.086))
    }

    private var logo: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.64, blue: 1.0),
                                              Color(red: 1.0, green: 0.71, blue: 0.33)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 24, height: 24)
                .overlay(Text("PB").font(.system(size: 11, weight: .heavy)).foregroundColor(.black))
            VStack(alignment: .leading, spacing: 0) {
                Text("PITBOARD").font(.system(size: 12, weight: .bold)).kerning(1.2)
                    .foregroundColor(.white)
                Text("native v0.2.1").font(.system(size: 8)).foregroundColor(.gray)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 24).padding(.horizontal, 3)
    }

    private func modeButton(_ m: BoardMode, _ icon: String) -> some View {
        Button { mode = m } label: { Image(systemName: icon) }
            .buttonStyle(ToolStyle(active: mode == m))
    }

    private var colorDots: some View {
        HStack(spacing: 5) {
            ForEach(palette, id: \.self) { c in
                Button { objColor = c } label: {
                    ZStack {
                        Circle().fill(swiftColor(c)).frame(width: 20, height: 20)
                        if objColor == c {
                            Circle().stroke(Color.white, lineWidth: 2).frame(width: 26, height: 26)
                        }
                    }
                }.frame(width: 28, height: 36)
            }
        }
    }

    private func swiftColor(_ s: String) -> Color {
        if s == "ink" { return .white }
        var hex = s; hex.removeFirst()
        guard let v = UInt64(hex, radix: 16) else { return .white }
        return Color(red: Double((v >> 16) & 0xFF)/255,
                     green: Double((v >> 8) & 0xFF)/255,
                     blue: Double(v & 0xFF)/255)
    }

    private var statusDot: some View {
        Circle().fill(dotColor).frame(width: 12, height: 12)
            .shadow(color: dotColor.opacity(0.8), radius: 4)
            .frame(width: 34, height: 34)
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

struct ToolStyle: ButtonStyle {
    var active: Bool
    var tint: Color = .white
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(active ? .black : tint.opacity(0.85))
            .frame(width: 34, height: 34)
            .background(active ? Color(red: 0.30, green: 0.64, blue: 1.0) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
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

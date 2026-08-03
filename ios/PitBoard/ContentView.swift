//  ContentView.swift
//  PitBoard v0.2 — mode toolbar (draw/select/erase/shapes/text/beacon),
//  object color palette, undo/redo, sync status + settings

import SwiftUI
import PhotosUI

struct ContentView: View {
    @StateObject private var engine = SyncEngine()
    @State private var fingerDraws = false   // finger pans by default; Pencil draws
    @State private var showSettings = false
    @State private var mode: BoardMode = .draw
    @State private var objColor: String = "ink"
    @State private var canvasCoordinator: CanvasView.Coordinator?
    @State private var showBoards = false
    @State private var showCmdBar = false
    @State private var cmdText = ""
    @State private var aiStatus = ""
    @State private var aiBusy = false
    @StateObject private var dictation = Dictation()
    @State private var photoItem: PhotosPickerItem?

    private let palette = ["ink", "#4da3ff", "#ffb454", "#ff6b6b", "#51d88a", "#b78cff"]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            CanvasView(engine: engine, fingerDraws: $fingerDraws,
                       mode: $mode, objColor: $objColor,
                       coordinatorRef: $canvasCoordinator)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) { if showCmdBar { commandBar } }
        }
        .background(Color(BoardRenderer.canvasBG))
        .sheet(isPresented: $showSettings) { SettingsSheet(engine: engine) }
        .sheet(isPresented: $showBoards) { BoardsSheet(engine: engine) }
        .task {
            if engine.token != nil { await engine.connect() }
            else { showSettings = true }
        }
        .statusBarHidden()
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await insertPhoto(item); photoItem = nil }
        }
    }

    private func insertPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              var ui = UIImage(data: data) else { aiStatus = "Couldn't read that image."; return }
        let maxDim: CGFloat = 1600
        let m = max(ui.size.width, ui.size.height)
        if m > maxDim {
            let s = maxDim / m
            let ns = CGSize(width: ui.size.width * s, height: ui.size.height * s)
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            ui = UIGraphicsImageRenderer(size: ns, format: fmt).image { _ in
                ui.draw(in: CGRect(origin: .zero, size: ns))
            }
        }
        var q: CGFloat = 0.82
        var jpeg = ui.jpegData(compressionQuality: q)
        while let d = jpeg, d.count > 900_000, q > 0.3 {
            q -= 0.12
            jpeg = ui.jpegData(compressionQuality: q)
        }
        guard let d = jpeg else { return }
        let id = newElementID()
        let src = "images/\(id).jpg"
        do { try await engine.putFile(src, data: d) }
        catch { aiStatus = "Image upload failed — check sync."; return }
        let center = canvasCoordinator?.centerWorld() ?? CGPoint(x: 1500, y: 1000)
        let dw = min(480.0, Double(ui.size.width))
        let dh = dw * Double(ui.size.height) / max(1.0, Double(ui.size.width))
        canvasCoordinator?.primeImage(src: src, ui: ui)
        canvasCoordinator?.snapshotUndoPublic()
        engine.elements.append(Element(id: id, type: "image",
                                       x: Double(center.x) - dw/2, y: Double(center.y) - dh/2,
                                       w: dw, h: dh, src: src))
        engine.boardChanged()
        canvasCoordinator?.refreshLayer()
        mode = .select
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
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(width: 34, height: 34)
                    }
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
            Button {
                if KeychainStore.load(key: "ai_key")?.isEmpty ?? true { showSettings = true }
                else { showCmdBar.toggle() }
            } label: {
                Image(systemName: "bolt.fill")
            }.buttonStyle(ToolStyle(active: showCmdBar, tint: .yellow))
            Button { showBoards = true } label: {
                Image(systemName: "square.grid.2x2")
            }.buttonStyle(ToolStyle(active: false))
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
                Text("v0.5.0 · \(engine.boardTitle)").font(.system(size: 8))
                    .foregroundColor(Color(red: 1.0, green: 0.71, blue: 0.33))
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

    // MARK: - AI command bar (Stage 1 + 2)

    private var commandBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Tell the board what to do…", text: $cmdText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.white)
                    .autocorrectionDisabled()
                    .onSubmit { runCommand() }
                Button { micTapped() } label: {
                    Image(systemName: dictation.listening ? "mic.fill" : "mic")
                        .font(.system(size: 17))
                        .foregroundColor(dictation.listening ? .red : .white.opacity(0.85))
                        .frame(width: 40, height: 40)
                        .background(dictation.listening ? Color.red.opacity(0.25) : Color.clear)
                        .clipShape(Circle())
                }
                Button { runCommand() } label: {
                    Text(aiBusy ? "…" : "Do it").font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color(red: 0.30, green: 0.64, blue: 1.0))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }.disabled(aiBusy)
            }
            if !aiStatus.isEmpty {
                Text(aiStatus).font(.system(size: 12)).foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 720)
        .padding(.horizontal, 16)
        .padding(.bottom, 90)   // clear of the PencilKit tool palette
        .onAppear {
            dictation.onText = { text, isFinal in
                if !text.isEmpty { cmdText = text }
                if isFinal { runCommand() }
            }
        }
    }

    private func micTapped() {
        if !dictation.listening { cmdText = ""; aiStatus = "Listening…" }
        dictation.toggle()
    }

    private func runCommand() {
        let cmd = cmdText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !aiBusy else { return }
        aiBusy = true; aiStatus = "Thinking…"
        Task {
            do {
                let resp = try await AIClient.run(command: cmd, elements: engine.elements)
                let n = canvasCoordinator?.applyAIOps(resp) ?? 0
                aiStatus = (resp.reply ?? "Done.") + (n > 0 ? " (\(n) change\(n == 1 ? "" : "s"))" : "")
                cmdText = ""
            } catch {
                aiStatus = "⚠ \(error.localizedDescription)"
            }
            aiBusy = false
        }
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

struct BoardsSheet: View {
    @ObservedObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var boards: [SyncEngine.BoardRef] = []
    @State private var newName = ""
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Boards") {
                    if loading { ProgressView() }
                    ForEach(boards) { b in
                        Button {
                            dismiss()
                            Task { await engine.switchBoard(b.path) }
                        } label: {
                            HStack {
                                Text(b.title).foregroundColor(.primary)
                                Spacer()
                                if b.path == engine.path {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }
                Section("New board") {
                    TextField("Board name", text: $newName)
                    Button("Create & open") {
                        let name = newName
                        dismiss()
                        Task { await engine.createBoard(named: name) }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section {
                    Text("Each board is its own synced canvas — Claude sees them all. Your last board reopens next launch.")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Boards")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task { boards = await engine.listBoards(); loading = false }
    }
}

struct SettingsSheet: View {
    @ObservedObject var engine: SyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var tokenInput = ""
    @State private var aiKeyInput = ""
    @State private var aiModelInput = UserDefaults.standard.string(forKey: "ai_model") ?? ""

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
                Section("AI command bar (bolt button)") {
                    SecureField("sk-ant-…  Anthropic API key", text: $aiKeyInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("model (default: claude-haiku-4-5)", text: $aiModelInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save AI settings") {
                        if !aiKeyInput.isEmpty {
                            KeychainStore.save(aiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines),
                                               key: "ai_key")
                        }
                        UserDefaults.standard.set(aiModelInput.trimmingCharacters(in: .whitespaces),
                                                  forKey: "ai_model")
                        dismiss()
                    }
                    .disabled(aiKeyInput.isEmpty && (KeychainStore.load(key: "ai_key")?.isEmpty ?? true))
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

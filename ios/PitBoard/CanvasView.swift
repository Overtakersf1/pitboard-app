//  CanvasView.swift
//  PitBoard v0.2 — PencilKit capture surface over a rendered board layer,
//  plus object tools: select/move, erase, shapes, text, beacon.
//
//  Modes:
//  - .draw: PKCanvasView is interactive (ink, tool picker, pan/zoom).
//  - everything else: a transparent overlay above the canvas takes single-
//    finger gestures and edits the shared model directly. (Pan/zoom is
//    parked in object modes for v0.2.0 — switch to draw mode to navigate.)

import SwiftUI
import PencilKit

enum BoardMode: String, CaseIterable {
    case draw, select, erase, rect, ellipse, diamond, arrow, line, text, beacon
}

struct CanvasView: UIViewRepresentable {
    @ObservedObject var engine: SyncEngine
    @Binding var fingerDraws: Bool
    @Binding var mode: BoardMode
    @Binding var objColor: String
    @Binding var coordinatorRef: Coordinator?

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(engine: engine)
        DispatchQueue.main.async { coordinatorRef = c }
        return c
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = BoardRenderer.canvasBG

        let imageView = UIImageView()
        imageView.contentMode = .scaleToFill
        container.addSubview(imageView)

        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .dark   // white-first palette; commit maps b/w -> "ink"
        canvas.contentSize = BoardRenderer.worldSize
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 4.0
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas)

        let overlay = UIView()
        overlay.backgroundColor = .clear
        overlay.isHidden = true
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let co = context.coordinator
        co.canvas = canvas
        co.imageView = imageView
        co.overlay = overlay
        co.container = container
        co.installGestures()
        co.startDisplayLink()
        co.showToolPicker()
        co.refreshLayer()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let co = context.coordinator
        co.modeBinding = $mode
        co.objColor = objColor
        co.canvas?.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        if co.mode != mode { co.setMode(mode) }
        if co.lastBoardEpoch != engine.boardEpoch {
            co.lastBoardEpoch = engine.boardEpoch
            co.clearUndoStacks()
        }
        if co.lastRemoteBump != engine.remoteBumped {
            co.lastRemoteBump = engine.remoteBumped
            co.selectedId = nil
            co.refreshLayer()
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate, UITextFieldDelegate {
        let engine: SyncEngine
        weak var canvas: PKCanvasView?
        weak var imageView: UIImageView?
        weak var overlay: UIView?
        weak var container: UIView?

        var mode: BoardMode = .draw
        var objColor: String = "ink"
        var modeBinding: Binding<BoardMode>?
        var lastRemoteBump = -1
        var lastBoardEpoch = 0
        var selectedId: String?

        private var picker: PKToolPicker?
        private var displayLink: CADisplayLink?
        private var commitWork: Task<Void, Never>?
        private var suppressChange = false

        private let selectionLayer = CAShapeLayer()
        private let handleLayer = CAShapeLayer()
        private let previewLayer = CAShapeLayer()
        private var resizingId: String?
        private var resizeAspect: Double?
        private let resizable: Set<String> = ["rect", "ellipse", "diamond", "image"]

        // gesture state
        private var dragStartWorld: CGPoint = .zero
        private var dragLastWorld: CGPoint = .zero
        private var draggingId: String?
        private var shapeDraft: Element?
        private var lastDragRender = Date.distantPast
        private var eraseSnapshotTaken = false

        // undo
        private var undoStack: [Data] = []
        private var redoStack: [Data] = []
        var canUndo: Bool { !undoStack.isEmpty }
        var canRedo: Bool { !redoStack.isEmpty }

        // text editing
        private var activeField: UITextField?
        private enum TextContext { case newAt(CGPoint), editText(String), editLabel(String) }
        private var textContext: TextContext?

        init(engine: SyncEngine) { self.engine = engine }

        // MARK: mode & picker

        func setMode(_ m: BoardMode) {
            commitTextField()
            mode = m
            let drawing = (m == .draw)
            canvas?.isUserInteractionEnabled = drawing
            overlay?.isHidden = drawing
            if !drawing { commitStrokes() }   // don't leave uncommitted ink behind
            if let canvas {
                picker?.setVisible(drawing, forFirstResponder: canvas)
                if drawing { reclaimToolPicker() } else { canvas.resignFirstResponder() }
            }
            if m != .select { selectedId = nil }
            updateSelectionLayer()
        }

        func showToolPicker() {
            guard let canvas else { return }
            let p = PKToolPicker()
            p.setVisible(true, forFirstResponder: canvas)
            p.addObserver(canvas)
            p.colorUserInterfaceStyle = .dark
            picker = p
            reclaimToolPicker()
            for delay in [0.4, 1.0, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.reclaimToolPicker()
                }
            }
        }

        func reclaimToolPicker() {
            guard mode == .draw, let canvas, canvas.window != nil else { return }
            if !canvas.isFirstResponder {
                picker?.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
            }
        }

        // MARK: layers & display link

        func installGestures() {
            guard let overlay else { return }
            selectionLayer.fillColor = nil
            selectionLayer.strokeColor = UIColor(red: 0.30, green: 0.64, blue: 1.0, alpha: 1).cgColor
            selectionLayer.lineWidth = 1.5
            selectionLayer.lineDashPattern = [6, 5]
            overlay.layer.addSublayer(selectionLayer)

            handleLayer.fillColor = UIColor(red: 0.30, green: 0.64, blue: 1.0, alpha: 1).cgColor
            handleLayer.strokeColor = nil
            overlay.layer.addSublayer(handleLayer)

            previewLayer.fillColor = UIColor.white.withAlphaComponent(0.06).cgColor
            previewLayer.strokeColor = UIColor.white.withAlphaComponent(0.8).cgColor
            previewLayer.lineWidth = 2
            overlay.layer.addSublayer(previewLayer)

            let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
            tap.numberOfTapsRequired = 1
            let dbl = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
            dbl.numberOfTapsRequired = 2
            tap.require(toFail: dbl)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
            pan.maximumNumberOfTouches = 1
            overlay.addGestureRecognizer(tap)
            overlay.addGestureRecognizer(dbl)
            overlay.addGestureRecognizer(pan)
        }

        func startDisplayLink() {
            displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink?.add(to: .main, forMode: .common)
        }

        @objc private func tick() {
            guard let canvas, let imageView else { return }
            let z = canvas.zoomScale
            let s = canvas.window?.screen.scale ?? 2
            func snap(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s }
            imageView.frame = CGRect(x: snap(-canvas.contentOffset.x),
                                     y: snap(-canvas.contentOffset.y),
                                     width: snap(BoardRenderer.worldSize.width * z),
                                     height: snap(BoardRenderer.worldSize.height * z))
            updateSelectionLayer()
        }

        private var imageCache: [String: UIImage] = [:]
        private var imagePending: Set<String> = []

        func primeImage(src: String, ui: UIImage) { imageCache[src] = ui }

        func centerWorld() -> CGPoint {
            guard let canvas else { return CGPoint(x: 1500, y: 1000) }
            let z = canvas.zoomScale
            return CGPoint(x: (canvas.contentOffset.x + canvas.bounds.width / 2) / z,
                           y: (canvas.contentOffset.y + canvas.bounds.height / 2) / z)
        }

        func refreshLayer() {
            guard let imageView else { return }
            let els = engine.elements
            // fetch any images we haven't cached yet
            for el in els where el.type == "image" {
                guard let src = el.src, imageCache[src] == nil, !imagePending.contains(src)
                else { continue }
                imagePending.insert(src)
                Task { [weak self] in
                    guard let self else { return }
                    if let d = try? await self.engine.fetchFile(src), let ui = UIImage(data: d) {
                        self.imageCache[src] = ui
                        self.refreshLayer()
                    }
                    self.imagePending.remove(src)
                }
            }
            let imgs = imageCache
            Task.detached(priority: .userInitiated) {
                let img = BoardRenderer.render(elements: els, images: imgs)
                await MainActor.run { imageView.image = img }
            }
        }

        // MARK: coordinate transforms

        private func toWorld(_ p: CGPoint) -> CGPoint {
            guard let canvas else { return p }
            let z = canvas.zoomScale
            return CGPoint(x: (p.x + canvas.contentOffset.x) / z,
                           y: (p.y + canvas.contentOffset.y) / z)
        }
        private func toScreen(_ r: CGRect) -> CGRect {
            guard let canvas else { return r }
            let z = canvas.zoomScale
            return CGRect(x: r.origin.x * z - canvas.contentOffset.x,
                          y: r.origin.y * z - canvas.contentOffset.y,
                          width: r.width * z, height: r.height * z)
        }

        private func updateSelectionLayer() {
            guard let id = selectedId,
                  let el = engine.elements.first(where: { $0.id == id }) else {
                selectionLayer.path = nil; handleLayer.path = nil; return
            }
            let r = toScreen(BoardRenderer.bbox(el)).insetBy(dx: -8, dy: -8)
            selectionLayer.path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
            if resizable.contains(el.type) {
                let hs: CGFloat = 12
                handleLayer.path = CGPath(ellipseIn:
                    CGRect(x: r.maxX - hs/2, y: r.maxY - hs/2, width: hs, height: hs), transform: nil)
            } else {
                handleLayer.path = nil
            }
        }

        // MARK: undo / redo

        private func snapshotUndo() {
            if let d = try? JSONEncoder().encode(engine.elements) {
                undoStack.append(d)
                if undoStack.count > 60 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
        }
        func undo() {
            guard let d = undoStack.popLast() else { return }
            if let cur = try? JSONEncoder().encode(engine.elements) { redoStack.append(cur) }
            if let els = try? JSONDecoder().decode([Element].self, from: d) {
                engine.elements = els
                selectedId = nil
                engine.boardChanged(); refreshLayer()
            }
        }
        func redo() {
            guard let d = redoStack.popLast() else { return }
            if let cur = try? JSONEncoder().encode(engine.elements) { undoStack.append(cur) }
            if let els = try? JSONDecoder().decode([Element].self, from: d) {
                engine.elements = els
                selectedId = nil
                engine.boardChanged(); refreshLayer()
            }
        }
        // MARK: AI ops (Stage 1/2)

        private func aiValid(_ el: inout Element) -> Bool {
            func num(_ v: Double?) -> Bool { v != nil && v!.isFinite }
            switch el.type {
            case "rect", "ellipse", "diamond":
                guard num(el.x), num(el.y), num(el.w), num(el.h) else { return false }
                if let l = el.label { el.label = String(l.prefix(80)) }
            case "arrow", "line":
                guard num(el.x1), num(el.y1), num(el.x2), num(el.y2) else { return false }
            case "text":
                guard num(el.x), num(el.y), let t = el.text else { return false }
                el.text = String(t.prefix(300))
                el.fontSize = min(40, max(10, el.fontSize ?? 17))
            case "stroke":
                guard let pts = el.points, !pts.isEmpty, pts.count <= 600,
                      pts.allSatisfy({ $0.count >= 2 && $0[0].isFinite && $0[1].isFinite })
                else { return false }
            default: return false
            }
            if let v = el.x  { el.x  = min(3500, max(-500, v)) }
            if let v = el.y  { el.y  = min(2500, max(-500, v)) }
            if let v = el.x1 { el.x1 = min(3500, max(-500, v)) }
            if let v = el.x2 { el.x2 = min(3500, max(-500, v)) }
            if let v = el.y1 { el.y1 = min(2500, max(-500, v)) }
            if let v = el.y2 { el.y2 = min(2500, max(-500, v)) }
            el.size = min(16, max(1, el.size ?? 3))
            if el.color == nil { el.color = "ink" }
            return true
        }

        /// Apply a validated AI response. Returns the number of changes made.
        func applyAIOps(_ r: AIResponse) -> Int {
            var adds: [Element] = []
            for raw in (r.add ?? []).prefix(40) {
                guard var el = raw.toElement(), aiValid(&el) else { continue }
                el.id = newElementID()
                adds.append(el)
            }
            let ups = (r.update ?? []).prefix(60).filter { $0.id != nil }
            let dels = (r.delete ?? []).prefix(60)
            var count = 0
            let hasWork = !adds.isEmpty ||
                ups.contains { u in engine.elements.contains { $0.id == u.id } } ||
                dels.contains { id in engine.elements.contains { $0.id == id } }
            guard hasWork else { return 0 }
            snapshotUndoPublic()
            engine.elements.append(contentsOf: adds); count += adds.count
            for u in ups {
                guard let i = engine.elements.firstIndex(where: { $0.id == u.id }) else { continue }
                if let v = u.x { engine.elements[i].x = v }
                if let v = u.y { engine.elements[i].y = v }
                if let v = u.w { engine.elements[i].w = v }
                if let v = u.h { engine.elements[i].h = v }
                if let v = u.x1 { engine.elements[i].x1 = v }
                if let v = u.y1 { engine.elements[i].y1 = v }
                if let v = u.x2 { engine.elements[i].x2 = v }
                if let v = u.y2 { engine.elements[i].y2 = v }
                if let v = u.size { engine.elements[i].size = min(16, max(1, v)) }
                if let v = u.fontSize { engine.elements[i].fontSize = min(40, max(10, v)) }
                if let v = u.alpha { engine.elements[i].alpha = min(1, max(0.05, v)) }
                if let v = u.text { engine.elements[i].text = String(v.prefix(300)) }
                if let v = u.label { engine.elements[i].label = String(v.prefix(80)) }
                if let v = u.color { engine.elements[i].color = v }
                if let v = u.points { engine.elements[i].points = v }
                count += 1
            }
            for id in dels {
                let before = engine.elements.count
                engine.elements.removeAll { $0.id == id }
                if engine.elements.count < before { count += 1 }
            }
            selectedId = nil
            updateSelectionLayer()
            engine.boardChanged()
            refreshLayer()
            return count
        }

        func snapshotUndoPublic() { snapshotUndo() }

        func clearUndoStacks() {
            undoStack.removeAll(); redoStack.removeAll()
            selectedId = nil
            updateSelectionLayer()
        }

        func deleteSelected() {
            guard let id = selectedId else { return }
            snapshotUndo()
            engine.elements.removeAll { $0.id == id }
            selectedId = nil
            engine.boardChanged(); refreshLayer()
        }

        // MARK: gestures

        @objc private func onTap(_ g: UITapGestureRecognizer) {
            commitTextField()
            let w = toWorld(g.location(in: overlay))
            switch mode {
            case .select:
                let tol = 10.0 / (canvas?.zoomScale ?? 1)
                selectedId = BoardRenderer.hitTest(engine.elements, at: w, tol: tol)?.id
                updateSelectionLayer()
            case .erase:
                eraseAt(w, snapshot: true)
            case .text:
                beginTextEntry(.newAt(w), initial: "", worldPoint: w, fontSize: 20)
            case .beacon:
                snapshotUndo()
                engine.elements.append(Element(id: "beacon-" + newElementID(), type: "ellipse",
                                               x: w.x - 45, y: w.y - 45, w: 90, h: 90,
                                               label: "👀", color: "#ff6b6b", size: 3))
                engine.boardChanged(); refreshLayer()
                modeBinding?.wrappedValue = .select   // one-shot tool
            default: break
            }
        }

        @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
            guard mode == .select else { return }
            commitTextField()
            let w = toWorld(g.location(in: overlay))
            let tol = 10.0 / (canvas?.zoomScale ?? 1)
            guard let el = BoardRenderer.hitTest(engine.elements, at: w, tol: tol) else { return }
            selectedId = el.id
            updateSelectionLayer()
            if el.type == "text" {
                let origin = CGPoint(x: el.x ?? 0, y: el.y ?? 0)
                beginTextEntry(.editText(el.id), initial: el.text ?? "",
                               worldPoint: origin, fontSize: el.fontSize ?? 17)
            } else if ["rect", "ellipse", "diamond"].contains(el.type) {
                let b = BoardRenderer.bbox(el)
                beginTextEntry(.editLabel(el.id), initial: el.label ?? "",
                               worldPoint: CGPoint(x: b.midX - 60, y: b.midY - 12), fontSize: 16)
            }
        }

        @objc private func onPan(_ g: UIPanGestureRecognizer) {
            let w = toWorld(g.location(in: overlay))
            switch mode {
            case .select: panSelect(g, w)
            case .erase: panErase(g, w)
            case .rect, .ellipse, .diamond, .arrow, .line: panShape(g, w)
            default: break
            }
        }

        private func panSelect(_ g: UIPanGestureRecognizer, _ w: CGPoint) {
            switch g.state {
            case .began:
                commitTextField()
                // resize grab: selected element + touch near its corner handle
                if let sid = selectedId,
                   let el = engine.elements.first(where: { $0.id == sid }),
                   resizable.contains(el.type) {
                    let b = BoardRenderer.bbox(el)
                    let corner = CGPoint(x: b.maxX + 8, y: b.maxY + 8)
                    if hypot(w.x - corner.x, w.y - corner.y) < 20 / (canvas?.zoomScale ?? 1) {
                        snapshotUndo()
                        resizingId = sid
                        resizeAspect = el.type == "image"
                            ? Double(max(1, b.width) / max(1, b.height)) : nil
                        return
                    }
                }
                let tol = 10.0 / (canvas?.zoomScale ?? 1)
                if let hit = BoardRenderer.hitTest(engine.elements, at: w, tol: tol) {
                    selectedId = hit.id
                    draggingId = hit.id
                    dragStartWorld = w; dragLastWorld = w
                    snapshotUndo()
                }
                updateSelectionLayer()
            case .changed:
                if let rid = resizingId,
                   let idx = engine.elements.firstIndex(where: { $0.id == rid }) {
                    let x0 = engine.elements[idx].x ?? 0
                    let y0 = engine.elements[idx].y ?? 0
                    let nw = max(24, Double(w.x) - x0 - 8)
                    engine.elements[idx].w = nw
                    engine.elements[idx].h = resizeAspect.map { nw / $0 }
                        ?? max(24, Double(w.y) - y0 - 8)
                    updateSelectionLayer()
                    if Date().timeIntervalSince(lastDragRender) > 0.12 {
                        lastDragRender = Date(); refreshLayer()
                    }
                    return
                }
                guard let id = draggingId,
                      let idx = engine.elements.firstIndex(where: { $0.id == id }) else { return }
                let dx = w.x - dragLastWorld.x, dy = w.y - dragLastWorld.y
                dragLastWorld = w
                BoardRenderer.move(&engine.elements[idx], dx: dx, dy: dy)
                updateSelectionLayer()
                if Date().timeIntervalSince(lastDragRender) > 0.12 {
                    lastDragRender = Date(); refreshLayer()
                }
            case .ended, .cancelled:
                if resizingId != nil {
                    resizingId = nil; resizeAspect = nil
                    engine.boardChanged(); refreshLayer()
                }
                if draggingId != nil {
                    draggingId = nil
                    engine.boardChanged(); refreshLayer()
                }
            default: break
            }
        }

        private func panErase(_ g: UIPanGestureRecognizer, _ w: CGPoint) {
            switch g.state {
            case .began:
                eraseSnapshotTaken = false
                eraseAt(w, snapshot: true)
            case .changed:
                eraseAt(w, snapshot: false)
            case .ended, .cancelled:
                engine.boardChanged(); refreshLayer()
            default: break
            }
        }

        private func eraseAt(_ w: CGPoint, snapshot: Bool) {
            let tol = 12.0 / (canvas?.zoomScale ?? 1)
            guard let hit = BoardRenderer.hitTest(engine.elements, at: w, tol: tol) else { return }
            if snapshot || !eraseSnapshotTaken { snapshotUndo(); eraseSnapshotTaken = true }
            engine.elements.removeAll { $0.id == hit.id }
            if selectedId == hit.id { selectedId = nil }
            engine.boardChanged()
            if Date().timeIntervalSince(lastDragRender) > 0.12 {
                lastDragRender = Date(); refreshLayer()
            }
        }

        private func panShape(_ g: UIPanGestureRecognizer, _ w: CGPoint) {
            switch g.state {
            case .began:
                commitTextField()
                dragStartWorld = w
                var el = Element(id: newElementID(), type: mode.rawValue, color: objColor, size: 3)
                if mode == .arrow || mode == .line {
                    el.x1 = w.x; el.y1 = w.y; el.x2 = w.x; el.y2 = w.y
                } else {
                    el.x = w.x; el.y = w.y; el.w = 1; el.h = 1
                }
                shapeDraft = el
            case .changed:
                guard var el = shapeDraft else { return }
                if mode == .arrow || mode == .line { el.x2 = w.x; el.y2 = w.y }
                else { el.w = w.x - dragStartWorld.x; el.h = w.y - dragStartWorld.y }
                shapeDraft = el
                drawPreview(el)
            case .ended, .cancelled:
                previewLayer.path = nil
                guard var el = shapeDraft else { return }
                shapeDraft = nil
                if mode == .arrow || mode == .line {
                    if hypot((el.x2 ?? 0) - (el.x1 ?? 0), (el.y2 ?? 0) - (el.y1 ?? 0)) < 6 { return }
                } else {
                    if abs(el.w ?? 0) < 6 && abs(el.h ?? 0) < 6 { return }
                    if (el.w ?? 0) < 0 { el.x = (el.x ?? 0) + (el.w ?? 0); el.w = -(el.w ?? 0) }
                    if (el.h ?? 0) < 0 { el.y = (el.y ?? 0) + (el.h ?? 0); el.h = -(el.h ?? 0) }
                }
                snapshotUndo()
                engine.elements.append(el)
                engine.boardChanged(); refreshLayer()
            default: break
            }
        }

        private func drawPreview(_ el: Element) {
            let p = CGMutablePath()
            if el.type == "arrow" || el.type == "line" {
                let a = toScreen(CGRect(x: el.x1 ?? 0, y: el.y1 ?? 0, width: 0, height: 0)).origin
                let b = toScreen(CGRect(x: el.x2 ?? 0, y: el.y2 ?? 0, width: 0, height: 0)).origin
                p.move(to: a); p.addLine(to: b)
            } else {
                let r = toScreen(BoardRenderer.bbox(el))
                switch el.type {
                case "ellipse": p.addEllipse(in: r)
                case "diamond":
                    p.move(to: CGPoint(x: r.midX, y: r.minY))
                    p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                    p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                    p.addLine(to: CGPoint(x: r.minX, y: r.midY))
                    p.closeSubpath()
                default: p.addRoundedRect(in: r, cornerWidth: 8, cornerHeight: 8)
                }
            }
            previewLayer.path = p
        }

        // MARK: text entry

        private func beginTextEntry(_ ctx: TextContext, initial: String,
                                    worldPoint: CGPoint, fontSize: Double) {
            commitTextField()
            guard let container, let canvas else { return }
            let z = canvas.zoomScale
            let field = UITextField()
            field.text = initial
            field.textColor = BoardRenderer.inkColor
            field.tintColor = UIColor(red: 0.30, green: 0.64, blue: 1.0, alpha: 1)
            field.font = UIFont.systemFont(ofSize: fontSize * z, weight: .medium)
            field.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            field.layer.borderColor = UIColor(red: 0.30, green: 0.64, blue: 1.0, alpha: 1).cgColor
            field.layer.borderWidth = 1.5
            field.layer.cornerRadius = 6
            field.autocorrectionType = .no
            field.delegate = self
            let sp = CGPoint(x: worldPoint.x * z - canvas.contentOffset.x,
                             y: worldPoint.y * z - canvas.contentOffset.y)
            field.frame = CGRect(x: sp.x - 4, y: sp.y - 4, width: max(180, 40), height: fontSize * z + 16)
            container.addSubview(field)
            activeField = field
            textContext = ctx
            field.becomeFirstResponder()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            commitTextField(); return true
        }

        func commitTextField() {
            guard let field = activeField, let ctx = textContext else { return }
            let value = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            field.removeFromSuperview()
            activeField = nil; textContext = nil
            switch ctx {
            case .newAt(let w):
                guard !value.isEmpty else { return }
                snapshotUndo()
                engine.elements.append(Element(id: newElementID(), type: "text",
                                               x: w.x, y: w.y, text: value,
                                               fontSize: 20, color: objColor))
            case .editText(let id):
                guard let idx = engine.elements.firstIndex(where: { $0.id == id }) else { return }
                snapshotUndo()
                if value.isEmpty { engine.elements.remove(at: idx) }
                else { engine.elements[idx].text = value }
            case .editLabel(let id):
                guard let idx = engine.elements.firstIndex(where: { $0.id == id }) else { return }
                snapshotUndo()
                engine.elements[idx].label = value
            }
            engine.boardChanged(); refreshLayer()
        }

        // MARK: PencilKit commit (draw mode)

        nonisolated func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            Task { @MainActor in
                guard !self.suppressChange else { return }
                self.commitWork?.cancel()
                self.commitWork = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    guard !Task.isCancelled else { return }
                    self?.commitStrokes()
                }
            }
        }

        private func commitStrokes() {
            guard let canvas, !canvas.drawing.strokes.isEmpty else { return }
            var newElements: [Element] = []
            for stroke in canvas.drawing.strokes {
                var locs: [CGPoint] = []
                var widths: [Double] = []
                for p in stroke.path {
                    locs.append(p.location.applying(stroke.transform))
                    widths.append(Double(p.size.width))
                }
                guard !locs.isEmpty else { continue }
                // Empirically measured: PencilKit ink renders ~0.68x narrower
                // than PKStrokePoint.size reports (see PITBOARD-MEMORY.md).
                let CAL = 0.68
                let sorted = widths.sorted()
                let baseWidth = max(1.0, min(14.0, sorted[sorted.count / 2] * CAL))
                var pts: [[Double]] = []
                for (i, loc) in locs.enumerated() {
                    let ideal = (widths[i] * CAL / baseWidth - 0.55) / 0.9
                    let press = max(0.05, min(1.0, ideal))
                    pts.append([(loc.x * 100).rounded() / 100, (loc.y * 100).rounded() / 100,
                                (press * 100).rounded() / 100])
                }
                let resolved = stroke.ink.color.resolvedColor(
                    with: UITraitCollection(userInterfaceStyle: .dark))
                var hex = "#f2f4f8"
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
                    if (r > 0.92 && g > 0.92 && b > 0.92) || (r < 0.15 && g < 0.15 && b < 0.15) {
                        hex = "ink"
                    } else {
                        hex = String(format: "#%02x%02x%02x", Int(r*255), Int(g*255), Int(b*255))
                    }
                }
                // ink type → translucency (texture itself isn't representable in the
                // schema, but see-through-ness is most of marker/watercolor's character)
                let inkName = stroke.ink.inkType.rawValue
                    .components(separatedBy: ".").last ?? "pen"
                let alphaMap: [String: Double] = ["marker": 0.55, "watercolor": 0.45,
                                                 "crayon": 0.85, "pencil": 0.9]
                newElements.append(Element(id: newElementID(), type: "stroke",
                                           points: pts, color: hex, size: baseWidth,
                                           alpha: alphaMap[inkName],
                                           ink: inkName == "pen" ? nil : inkName))
            }
            guard !newElements.isEmpty else { return }
            snapshotUndo()
            suppressChange = true
            canvas.drawing = PKDrawing()
            suppressChange = false
            engine.elements.append(contentsOf: newElements)
            engine.boardChanged()
            refreshLayer()
        }
    }
}

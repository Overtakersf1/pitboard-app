//  CanvasView.swift
//  PitBoard — PencilKit capture surface over a rendered board layer.
//
//  How it works:
//  - PKCanvasView (transparent) captures ink at native latency with the
//    system tool picker and palm rejection.
//  - A UIImageView UNDERNEATH shows all committed board elements
//    (yours + Claude's), rendered by BoardRenderer.
//  - Shortly after you finish a stroke, it is converted into the shared
//    JSON schema, moved out of the PKDrawing into the model, and the
//    layer image refreshes. A CADisplayLink keeps the image aligned with
//    the canvas's scroll offset and zoom.

import SwiftUI
import PencilKit

struct CanvasView: UIViewRepresentable {
    @ObservedObject var engine: SyncEngine
    @Binding var fingerDraws: Bool
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
        canvas.overrideUserInterfaceStyle = .dark
        canvas.contentSize = BoardRenderer.worldSize
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 4.0
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: container.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        context.coordinator.canvas = canvas
        context.coordinator.imageView = imageView
        context.coordinator.startDisplayLink()
        context.coordinator.showToolPicker()
        context.coordinator.refreshLayer()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.canvas?.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        if context.coordinator.lastRemoteBump != engine.remoteBumped {
            context.coordinator.lastRemoteBump = engine.remoteBumped
            context.coordinator.refreshLayer()
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let engine: SyncEngine
        weak var canvas: PKCanvasView?
        weak var imageView: UIImageView?
        var lastRemoteBump = -1
        private var displayLink: CADisplayLink?
        private var commitWork: Task<Void, Never>?
        private var suppressChange = false

        init(engine: SyncEngine) { self.engine = engine }

        func showToolPicker() {
            guard let canvas else { return }
            let picker = PKToolPicker()
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            picker.colorUserInterfaceStyle = .dark
            canvas.becomeFirstResponder()
            // keep a strong reference
            objc_setAssociatedObject(canvas, "picker", picker, .OBJC_ASSOCIATION_RETAIN)
        }

        func startDisplayLink() {
            displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink?.add(to: .main, forMode: .common)
        }

        @objc private func tick() {
            guard let canvas, let imageView else { return }
            let z = canvas.zoomScale
            imageView.frame = CGRect(x: -canvas.contentOffset.x,
                                     y: -canvas.contentOffset.y,
                                     width: BoardRenderer.worldSize.width * z,
                                     height: BoardRenderer.worldSize.height * z)
        }

        func refreshLayer() {
            guard let imageView else { return }
            let els = engine.elements
            Task.detached(priority: .userInitiated) {
                let img = BoardRenderer.render(elements: els)
                await MainActor.run { imageView.image = img }
            }
        }

        // Called on every drawing change; debounce, then commit strokes into the model.
        nonisolated func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            Task { @MainActor in
                guard !self.suppressChange else { return }
                self.commitWork?.cancel()
                self.commitWork = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    self?.commitStrokes()
                }
            }
        }

        private func commitStrokes() {
            guard let canvas, !canvas.drawing.strokes.isEmpty else { return }
            var newElements: [Element] = []
            for stroke in canvas.drawing.strokes {
                var pts: [[Double]] = []
                var widths: [Double] = []
                for p in stroke.path {
                    let loc = p.location.applying(stroke.transform)
                    let force = max(0.15, min(1.0, Double(p.force == 0 ? 0.5 : p.force)))
                    pts.append([(loc.x * 100).rounded() / 100, (loc.y * 100).rounded() / 100,
                                (force * 100).rounded() / 100])
                    widths.append(Double(p.size.width))
                }
                guard !pts.isEmpty else { continue }
                let avgWidth = widths.reduce(0, +) / Double(widths.count)
                var hex = "#f2f4f8"
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                if stroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a) {
                    hex = String(format: "#%02x%02x%02x", Int(r*255), Int(g*255), Int(b*255))
                }
                newElements.append(Element(id: newElementID(), type: "stroke",
                                           points: pts, color: hex,
                                           size: max(2.0, min(12.0, avgWidth * 0.55))))
            }
            guard !newElements.isEmpty else { return }
            suppressChange = true
            canvas.drawing = PKDrawing()      // move strokes out of PencilKit...
            suppressChange = false
            engine.elements.append(contentsOf: newElements)   // ...into the shared model
            engine.boardChanged()
            refreshLayer()
        }

        /// Remove the most recently added local element (simple undo).
        func undoLast() {
            guard !engine.elements.isEmpty else { return }
            engine.elements.removeLast()
            engine.boardChanged()
            refreshLayer()
        }
    }
}

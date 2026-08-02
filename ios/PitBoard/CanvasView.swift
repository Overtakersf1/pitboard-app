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
        // Dark mode: the palette leads with white and ink DISPLAYS white while
        // drawing — but PencilKit STORES the light-mode value (black). The
        // near-black→"ink" mapping at commit time squares that circle.
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
        // The tool picker follows first-responder status; sheets (e.g. settings)
        // steal it — take it back whenever SwiftUI re-renders us.
        context.coordinator.reclaimToolPicker()
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

        private var picker: PKToolPicker?

        func showToolPicker() {
            guard let canvas else { return }
            let p = PKToolPicker()
            p.setVisible(true, forFirstResponder: canvas)
            p.addObserver(canvas)
            p.colorUserInterfaceStyle = .dark
            picker = p
            // First responder only sticks once the view is in a window;
            // retry briefly until it takes.
            reclaimToolPicker()
            for delay in [0.4, 1.0, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.reclaimToolPicker()
                }
            }
        }

        func reclaimToolPicker() {
            guard let canvas, canvas.window != nil else { return }
            if !canvas.isFirstResponder {
                picker?.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
            }
        }

        func startDisplayLink() {
            displayLink = CADisplayLink(target: self, selector: #selector(tick))
            displayLink?.add(to: .main, forMode: .common)
        }

        @objc private func tick() {
            guard let canvas, let imageView else { return }
            let z = canvas.zoomScale
            // Snap to the physical pixel grid: a bitmap composited on a
            // fractional offset gets resampled, smearing every stroke edge
            // ~1px per side (the "committed strokes grow" bug).
            let s = canvas.window?.screen.scale ?? 2
            func snap(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s }
            imageView.frame = CGRect(x: snap(-canvas.contentOffset.x),
                                     y: snap(-canvas.contentOffset.y),
                                     width: snap(BoardRenderer.worldSize.width * z),
                                     height: snap(BoardRenderer.worldSize.height * z))
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
                    // ink stays in PencilKit (erasable with the picker's eraser)
                    // for 3.5s of idle before committing to the shared board
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
                // PKStrokePoint.size is the FINAL rendered width at that point.
                // The renderer draws width = size * (0.55 + 0.9 * pressure), so
                // pick base = median width and solve pressure PER POINT so the
                // renderer reproduces each captured width exactly.
                // Empirically measured (screenshot pixel analysis): PencilKit's pen
                // ink renders ~0.68x narrower than PKStrokePoint.size reports.
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
                // PencilKit palette colors are dynamic (light/dark variants) —
                // resolve for dark, since that's what the user saw on our canvas.
                let resolved = stroke.ink.color.resolvedColor(
                    with: UITraitCollection(userInterfaceStyle: .dark))
                var hex = "#f2f4f8"
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                if resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
                    if (r > 0.92 && g > 0.92 && b > 0.92) || (r < 0.15 && g < 0.15 && b < 0.15) {
                        // near-white OR near-black → auto-contrast token: on our dark
                        // canvas both mean "default ink", and black would be invisible
                        hex = "ink"
                    } else {
                        hex = String(format: "#%02x%02x%02x", Int(r*255), Int(g*255), Int(b*255))
                    }
                }
                newElements.append(Element(id: newElementID(), type: "stroke",
                                           points: pts, color: hex,
                                           size: max(1.5, min(14.0, baseWidth))))
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

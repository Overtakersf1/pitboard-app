//  BoardRenderer.swift
//  PitBoard — renders committed board elements to a UIImage
//  (mirrors the web app's canvas drawing: quadratic-smoothed strokes,
//   10%-fill shapes with centered labels, arrowheads, dark canvas ink)

import UIKit

nonisolated enum BoardRenderer {

    static let worldSize = CGSize(width: 3000, height: 2000)
    static let canvasBG = UIColor(red: 0x14/255, green: 0x17/255, blue: 0x1D/255, alpha: 1)
    static let inkColor = UIColor(red: 0xF2/255, green: 0xF4/255, blue: 0xF8/255, alpha: 1)

    static func color(_ s: String?) -> UIColor {
        guard let s, s != "ink" else { return inkColor }
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = UInt64(hex, radix: 16) else { return inkColor }
        return UIColor(red: CGFloat((v >> 16) & 0xFF)/255,
                       green: CGFloat((v >> 8) & 0xFF)/255,
                       blue: CGFloat(v & 0xFF)/255, alpha: 1)
    }

    /// Render all elements at the given scale (2.0 = retina-ish for the layer image).
    static func render(elements: [Element], images: [String: UIImage] = [:],
                       scale: CGFloat = 2.0) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: worldSize, format: fmt)
        return renderer.image { rc in
            let ctx = rc.cgContext
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for el in elements { draw(el, in: ctx, images: images) }
        }
    }

    private static func draw(_ el: Element, in ctx: CGContext, images: [String: UIImage] = [:]) {
        let col = color(el.color)
        let size = CGFloat(el.size ?? 4.5)

        switch el.type {
        case "stroke":
            guard let raw = el.points, !raw.isEmpty else { return }
            let alpha = CGFloat(el.alpha ?? 1.0)
            ctx.setFillColor(col.withAlphaComponent(alpha).cgColor)
            if raw.count == 1 {
                let p = raw[0]
                let w = Double(size) * (0.55 + 0.9 * (p.count > 2 ? p[2] : 0.5))
                ctx.fillEllipse(in: CGRect(x: p[0] - w/2, y: p[1] - w/2, width: w, height: w))
                return
            }
            // Single-pass ribbon fill (PencilKit-style): offset the centerline
            // by the half-width on each side and fill ONCE. Stroking dozens of
            // overlapping capped segments double-composites the AA edges and
            // visually fattens the line — this avoids that entirely.
            var pl: [CGPoint] = []   // centerline
            var hw: [CGFloat] = []   // half-widths
            for p in raw {
                pl.append(CGPoint(x: p[0], y: p[1]))
                let press = CGFloat(p.count > 2 ? p[2] : 0.5)
                hw.append(size * (0.55 + 0.9 * press) / 2)
            }
            var left: [CGPoint] = [], right: [CGPoint] = []
            let n = pl.count
            for i in 0..<n {
                let a = pl[max(0, i-1)], b = pl[min(n-1, i+1)]
                var dx = b.x - a.x, dy = b.y - a.y
                let len = max(0.0001, sqrt(dx*dx + dy*dy))
                dx /= len; dy /= len
                let nx = -dy, ny = dx
                left.append(CGPoint(x: pl[i].x + nx*hw[i], y: pl[i].y + ny*hw[i]))
                right.append(CGPoint(x: pl[i].x - nx*hw[i], y: pl[i].y - ny*hw[i]))
            }
            let path = CGMutablePath()
            path.move(to: left[0])
            for i in 1..<n { path.addLine(to: left[i]) }
            // round end cap
            path.addArc(center: pl[n-1], radius: hw[n-1],
                        startAngle: atan2(left[n-1].y - pl[n-1].y, left[n-1].x - pl[n-1].x),
                        endAngle: atan2(right[n-1].y - pl[n-1].y, right[n-1].x - pl[n-1].x),
                        clockwise: true)
            for i in stride(from: n-1, through: 0, by: -1) { path.addLine(to: right[i]) }
            // round start cap
            path.addArc(center: pl[0], radius: hw[0],
                        startAngle: atan2(right[0].y - pl[0].y, right[0].x - pl[0].x),
                        endAngle: atan2(left[0].y - pl[0].y, left[0].x - pl[0].x),
                        clockwise: true)
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()

        case "rect", "ellipse", "diamond":
            guard var x = el.x, var y = el.y, var w = el.w, var h = el.h else { return }
            if w < 0 { x += w; w = -w }
            if h < 0 { y += h; h = -h }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            let path = shapePath(el.type, rect)
            ctx.setFillColor(col.withAlphaComponent(0.10).cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(col.cgColor)
            ctx.setLineWidth(size)
            ctx.addPath(path); ctx.strokePath()
            if let label = el.label, !label.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                    .foregroundColor: inkColor,
                ]
                let ts = (label as NSString).size(withAttributes: attrs)
                (label as NSString).draw(at: CGPoint(x: rect.midX - ts.width/2, y: rect.midY - ts.height/2),
                                         withAttributes: attrs)
            }

        case "line", "arrow":
            guard let x1 = el.x1, let y1 = el.y1, let x2 = el.x2, let y2 = el.y2 else { return }
            ctx.setStrokeColor(col.cgColor)
            ctx.setLineWidth(size)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x1, y: y1))
            ctx.addLine(to: CGPoint(x: x2, y: y2))
            ctx.strokePath()
            if el.type == "arrow" {
                let a = atan2(y2 - y1, x2 - x1)
                let len = 6 + Double(size) * 2.4
                ctx.beginPath()
                ctx.move(to: CGPoint(x: x2, y: y2))
                ctx.addLine(to: CGPoint(x: x2 - len * cos(a - 0.46), y: y2 - len * sin(a - 0.46)))
                ctx.move(to: CGPoint(x: x2, y: y2))
                ctx.addLine(to: CGPoint(x: x2 - len * cos(a + 0.46), y: y2 - len * sin(a + 0.46)))
                ctx.strokePath()
            }

        case "image":
            guard var x = el.x, var y = el.y, var w = el.w, var h = el.h else { return }
            if w < 0 { x += w; w = -w }
            if h < 0 { y += h; h = -h }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if let src = el.src, let ui = images[src] {
                ui.draw(in: rect, blendMode: .normal, alpha: CGFloat(el.alpha ?? 1.0))
            } else {
                ctx.setStrokeColor(UIColor(white: 0.4, alpha: 1).cgColor)
                ctx.setLineWidth(2)
                ctx.setLineDash(phase: 0, lengths: [6, 5])
                ctx.stroke(rect)
                ctx.setLineDash(phase: 0, lengths: [])
            }

        case "text":
            guard let x = el.x, let y = el.y, let text = el.text else { return }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: CGFloat(el.fontSize ?? 17), weight: .medium),
                .foregroundColor: col,
            ]
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)

        default:
            break
        }
    }

    // MARK: - geometry helpers for select/erase (v0.2)

    static func bbox(_ el: Element) -> CGRect {
        switch el.type {
        case "stroke":
            guard let pts = el.points, !pts.isEmpty else { return .zero }
            var x0 = Double.infinity, y0 = Double.infinity
            var x1 = -Double.infinity, y1 = -Double.infinity
            for p in pts { x0 = min(x0, p[0]); y0 = min(y0, p[1]); x1 = max(x1, p[0]); y1 = max(y1, p[1]) }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        case "line", "arrow":
            guard let x1 = el.x1, let y1 = el.y1, let x2 = el.x2, let y2 = el.y2 else { return .zero }
            return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        case "text":
            guard let x = el.x, let y = el.y, let t = el.text else { return .zero }
            let f = UIFont.systemFont(ofSize: CGFloat(el.fontSize ?? 17), weight: .medium)
            let s = (t as NSString).size(withAttributes: [.font: f])
            return CGRect(x: x, y: y, width: s.width, height: s.height)
        default:
            guard var x = el.x, var y = el.y, var w = el.w, var h = el.h else { return .zero }
            if w < 0 { x += w; w = -w }
            if h < 0 { y += h; h = -h }
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private static func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx*dx + dy*dy
        var t: CGFloat = l2 > 0 ? ((p.x - a.x)*dx + (p.y - a.y)*dy) / l2 : 0
        t = max(0, min(1, t))
        return hypot(a.x + t*dx - p.x, a.y + t*dy - p.y)
    }

    /// Topmost element within tolerance of a world point.
    static func hitTest(_ els: [Element], at p: CGPoint, tol: CGFloat) -> Element? {
        for el in els.reversed() {
            let size = CGFloat(el.size ?? 4.5)
            switch el.type {
            case "stroke":
                guard let pts = el.points, !pts.isEmpty else { continue }
                if pts.count == 1 {
                    if hypot(pts[0][0] - p.x, pts[0][1] - p.y) < tol + size { return el }
                    continue
                }
                for i in 1..<pts.count {
                    if distToSegment(p, CGPoint(x: pts[i-1][0], y: pts[i-1][1]),
                                     CGPoint(x: pts[i][0], y: pts[i][1])) < tol + size { return el }
                }
            case "line", "arrow":
                guard let x1 = el.x1, let y1 = el.y1, let x2 = el.x2, let y2 = el.y2 else { continue }
                if distToSegment(p, CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)) < tol + size { return el }
            default:
                if bbox(el).insetBy(dx: -tol, dy: -tol).contains(p) { return el }
            }
        }
        return nil
    }

    static func move(_ el: inout Element, dx: Double, dy: Double) {
        switch el.type {
        case "stroke":
            if var pts = el.points {
                for i in 0..<pts.count { pts[i][0] += dx; pts[i][1] += dy }
                el.points = pts
            }
        case "line", "arrow":
            el.x1 = (el.x1 ?? 0) + dx; el.y1 = (el.y1 ?? 0) + dy
            el.x2 = (el.x2 ?? 0) + dx; el.y2 = (el.y2 ?? 0) + dy
        default:
            el.x = (el.x ?? 0) + dx; el.y = (el.y ?? 0) + dy
        }
    }

    private static func shapePath(_ type: String, _ r: CGRect) -> CGPath {
        switch type {
        case "ellipse":
            return CGPath(ellipseIn: r, transform: nil)
        case "diamond":
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.closeSubpath()
            return p
        default:
            let radius = min(10, r.width/4, r.height/4)
            return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
    }
}

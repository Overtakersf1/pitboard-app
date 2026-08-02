//  BoardRenderer.swift
//  PitBoard — renders committed board elements to a UIImage
//  (mirrors the web app's canvas drawing: quadratic-smoothed strokes,
//   10%-fill shapes with centered labels, arrowheads, dark canvas ink)

import UIKit

enum BoardRenderer {

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
    static func render(elements: [Element], scale: CGFloat = 2.0) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: worldSize, format: fmt)
        return renderer.image { rc in
            let ctx = rc.cgContext
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for el in elements { draw(el, in: ctx) }
        }
    }

    private static func draw(_ el: Element, in ctx: CGContext) {
        let col = color(el.color)
        let size = CGFloat(el.size ?? 4.5)

        switch el.type {
        case "stroke":
            guard let pts = el.points, !pts.isEmpty else { return }
            ctx.setStrokeColor(col.cgColor)
            if pts.count == 1 {
                let p = pts[0]
                ctx.setFillColor(col.cgColor)
                ctx.fillEllipse(in: CGRect(x: p[0] - Double(size)/2, y: p[1] - Double(size)/2,
                                           width: Double(size), height: Double(size)))
                return
            }
            for i in 1..<pts.count {
                let p0 = pts[i-1], p1 = pts[i]
                let press = CGFloat((p0.count > 2 ? p0[2] : 0.5) + (p1.count > 2 ? p1[2] : 0.5)) / 2
                ctx.setLineWidth(size * (0.55 + 0.9 * press))
                ctx.beginPath()
                if i == 1 {
                    ctx.move(to: CGPoint(x: p0[0], y: p0[1]))
                } else {
                    let pm = pts[i-2]
                    ctx.move(to: CGPoint(x: (pm[0] + p0[0])/2, y: (pm[1] + p0[1])/2))
                }
                ctx.addQuadCurve(to: CGPoint(x: (p0[0] + p1[0])/2, y: (p0[1] + p1[1])/2),
                                 control: CGPoint(x: p0[0], y: p0[1]))
                if i == pts.count - 1 { ctx.addLine(to: CGPoint(x: p1[0], y: p1[1])) }
                ctx.strokePath()
            }

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

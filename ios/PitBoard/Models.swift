//  Models.swift
//  PitBoard — shared board schema (must match the web app / board.json exactly)

import Foundation

/// One board element. A single struct with optionals keeps Codable simple and
/// byte-compatible with the JSON the web app and Claude read/write.
struct Element: Codable, Identifiable, Equatable {
    var id: String
    var type: String            // "stroke" | "rect" | "ellipse" | "diamond" | "line" | "arrow" | "text"
    // stroke
    var points: [[Double]]?     // [[x, y, pressure], ...]
    // shapes
    var x: Double?
    var y: Double?
    var w: Double?
    var h: Double?
    var label: String?
    // line / arrow
    var x1: Double?
    var y1: Double?
    var x2: Double?
    var y2: Double?
    // text
    var text: String?
    var fontSize: Double?
    // common
    var color: String?          // "ink" or "#rrggbb"
    var size: Double?
    var alpha: Double?          // stroke translucency (marker/watercolor); nil = opaque
    var ink: String?            // source ink type ("marker", "crayon", …) for future texture renderers
}

struct BoardDoc: Codable {
    var app: String = "pitboard"
    var version: Int = 1
    var rev: Int = 0
    var updatedBy: String = "sean"
    var elements: [Element] = []
}

extension Element {
    /// Stable JSON string for diffing (sorted keys), used by the 3-way merge.
    func stableJSON() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(self) else { return id }
        return String(data: d, encoding: .utf8) ?? id
    }
}

func newElementID() -> String {
    "e" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
}

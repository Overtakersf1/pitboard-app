//  AIClient.swift
//  PitBoard — Stage 1/2 brain: command + board -> Anthropic API -> validated ops.
//  Same provider-agnostic op protocol as the web app (see PITBOARD-MEMORY.md).

import Foundation

struct AIUpdate: Codable {
    var id: String?          // tolerant: a missing id skips the op, not the batch
    var x: Double?; var y: Double?; var w: Double?; var h: Double?
    var x1: Double?; var y1: Double?; var x2: Double?; var y2: Double?
    var size: Double?; var fontSize: Double?; var alpha: Double?
    var text: String?; var label: String?; var color: String?; var ink: String?
    var points: [[Double]]?
}

/// Mirror of Element with EVERYTHING optional — the model is instructed to
/// omit `id` on additions, so decoding straight into Element (required id)
/// throws "data missing". This shim decodes tolerantly, then converts.
struct AIAdd: Codable {
    var id: String?
    var type: String?
    var points: [[Double]]?
    var x: Double?; var y: Double?; var w: Double?; var h: Double?
    var label: String?
    var x1: Double?; var y1: Double?; var x2: Double?; var y2: Double?
    var text: String?; var fontSize: Double?
    var color: String?; var size: Double?
    var alpha: Double?; var ink: String?

    func toElement() -> Element? {
        guard let type else { return nil }
        return Element(id: id ?? newElementID(), type: type, points: points,
                       x: x, y: y, w: w, h: h, label: label,
                       x1: x1, y1: y1, x2: x2, y2: y2,
                       text: text, fontSize: fontSize,
                       color: color, size: size, alpha: alpha, ink: ink)
    }
}

struct AIResponse: Codable {
    var reply: String?
    var add: [AIAdd]?
    var update: [AIUpdate]?
    var delete: [String]?
}

enum AIError: LocalizedError {
    case noKey, parse, api(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "No API key — add one in settings."
        case .parse: return "Couldn't parse the model's response."
        case .api(let m): return "API error: \(m)"
        }
    }
}

enum AIClient {

    static let systemPrompt = """
You are PitBoard's board-operation assistant. PitBoard is a shared drawing canvas. You receive the board's current elements as JSON and a user command. You respond with ONLY a JSON object (no prose, no code fences):
{"reply":"<one short sentence describing what you did>","add":[<Element>...],"update":[{"id":"<existing id>",...changed fields}],"delete":["<existing id>"...]}

Element types and required fields:
- rect|ellipse|diamond: x,y,w,h (top-left + size), optional label (short), color, size (stroke width, default 3)
- arrow|line: x1,y1,x2,y2, color, size 3
- text: x,y,text,fontSize (14-30), color
- stroke: points [[x,y,pressure0to1]...], color, size — avoid creating strokes unless asked to draw freehand

Rules:
- Canvas is 3000x2000, y grows downward. Place new content near related content or in clear space; never overlap existing elements.
- Colors: "ink" (auto-contrast default), "#4da3ff" blue, "#ffb454" amber, "#ff6b6b" red, "#51d88a" green, "#b78cff" violet. Match the user's color words to these.
- Arrows should visually connect shape edges (not centers).
- Only reference existing ids for update/delete. Omit "id" on added elements (assigned by the app).
- image elements exist ({x,y,w,h,src}); you may move/resize them via update but never create one or change src.
- Prefer few, well-placed elements. Empty add/update/delete arrays are fine when the command needs none.
- If the command is unclear or risky, do nothing and explain in "reply".
"""

    static func run(command: String, elements: [Element]) async throws -> AIResponse {
        guard let key = KeychainStore.load(key: "ai_key"), !key.isEmpty else { throw AIError.noKey }
        let model = UserDefaults.standard.string(forKey: "ai_model").flatMap { $0.isEmpty ? nil : $0 }
            ?? "claude-haiku-4-5"

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let boardJSON = String(data: (try? JSONEncoder().encode(elements)) ?? Data("[]".utf8),
                               encoding: .utf8) ?? "[]"
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 3000,
            "system": [["type": "text", "text": systemPrompt,
                        "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user",
                          "content": "CURRENT BOARD ELEMENTS:\n\(boardJSON)\n\nCOMMAND: \(command)"]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.api("no response") }
        guard http.statusCode == 200 else {
            throw AIError.api("\(http.statusCode) — \(String((String(data: data, encoding: .utf8) ?? "").prefix(160)))")
        }
        struct Msg: Codable {
            struct C: Codable { let type: String; let text: String? }
            let content: [C]
        }
        let m = try JSONDecoder().decode(Msg.self, from: data)
        let text = m.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s <= e else {
            throw AIError.parse
        }
        return try JSONDecoder().decode(AIResponse.self, from: Data(String(text[s...e]).utf8))
    }
}

//  SyncEngine.swift
//  PitBoard — GitHub relay sync, ported from the web app.
//  Same protocol: contents API, ETag polling, 5s min push gap,
//  monotonic-rev stale-read guard, 3-way merge by element id.

import Foundation

enum SyncStatus { case off, ok, pending, error }

@MainActor
final class SyncEngine: ObservableObject {

    @Published var status: SyncStatus = .off
    @Published var lastError: String = ""
    @Published var elements: [Element] = []
    @Published var remoteBumped: Int = 0   // increments when a remote update is adopted (renderer refresh hook)

    // config
    var repo = "Overtakersf1/pitboard-sync"
    var branch = "main"
    var path = "board.json"
    var who = "sean"
    var token: String? { KeychainStore.load(key: "gh_token") }

    // sync state
    private var sha: String?
    private var etag: String?
    private var base: [Element] = []
    private var rev = 0
    private var dirty = false
    private var busy = false
    private var errs = 0
    private var lastPush = Date.distantPast
    private var pollTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?

    var isConnected: Bool { pollTask != nil }

    // MARK: - lifecycle

    func connect() async {
        guard token != nil else { status = .off; return }
        status = .pending
        do {
            let r = try await ghGet(useEtag: false)
            switch r {
            case .missing:
                dirty = true
                await pushNow()
            case .doc(let doc, let newSha, let newEtag):
                sha = newSha; etag = newEtag; rev = doc.rev
                if doc.elements.isEmpty && !elements.isEmpty {
                    dirty = true
                    await pushNow()
                } else {
                    elements = doc.elements
                    base = doc.elements
                    remoteBumped += 1
                }
            case .unchanged:
                break
            }
            errs = 0
            status = dirty ? .pending : .ok
            startPolling()
        } catch {
            status = .error
            lastError = "Connect failed: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        pollTask?.cancel(); pollTask = nil
        pushTask?.cancel(); pushTask = nil
        status = .off
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.poll()
            }
        }
    }

    // MARK: - local changes

    /// Call whenever the local board mutates.
    func boardChanged() {
        guard isConnected else { return }
        dirty = true
        status = .pending
        schedulePush(after: 2.0)
    }

    private func schedulePush(after seconds: Double) {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.pushNow()
        }
    }

    // MARK: - push

    private func pushNow() async {
        guard isConnected || status == .pending, dirty, !busy else { return }
        let since = Date().timeIntervalSince(lastPush)
        if since < 5.0 { schedulePush(after: 5.2 - since); return }

        busy = true; defer { busy = false }
        status = .pending
        do {
            var attemptRev = rev + 1
            let payload = elements
            var result = try await ghPut(doc: makeDoc(rev: attemptRev, elements: payload), sha: sha)
            if case .conflict = result {
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                let remote = try await ghGet(useEtag: false)
                guard case .doc(let rdoc, let rsha, _) = remote else { throw SyncError.remoteVanished }
                elements = merge(base: base, local: elements, remote: rdoc.elements)
                remoteBumped += 1
                attemptRev = max(attemptRev, rdoc.rev + 1)
                result = try await ghPut(doc: makeDoc(rev: attemptRev, elements: elements), sha: rsha)
                if case .conflict = result { throw SyncError.conflict }
            }
            guard case .pushed(let newSha) = result else { throw SyncError.conflict }
            sha = newSha; etag = nil
            base = elements
            rev = attemptRev
            dirty = false
            errs = 0
            lastPush = Date()
            status = .ok
        } catch {
            errs += 1
            status = errs >= 3 ? .error : .pending
            lastError = "Push retrying: \(error.localizedDescription)"
            schedulePush(after: min(20, 4 * Double(errs)))
        }
    }

    // MARK: - poll

    private func poll() async {
        guard isConnected, !busy, !dirty else { return }
        busy = true; defer { busy = false }
        do {
            let r = try await ghGet(useEtag: true)
            guard case .doc(let doc, let newSha, let newEtag) = r else { errs = 0; return }
            etag = newEtag
            guard newSha != sha else { errs = 0; return }
            if doc.rev <= rev {
                // stale read (GitHub eventual consistency) — ignore
            } else if dirty {
                elements = merge(base: base, local: elements, remote: doc.elements)
                sha = newSha; rev = doc.rev; base = doc.elements
                remoteBumped += 1
                schedulePush(after: 0.6)
            } else {
                sha = newSha; rev = doc.rev
                elements = doc.elements
                base = doc.elements
                remoteBumped += 1
            }
            errs = 0
            status = dirty ? .pending : .ok
        } catch {
            errs += 1
            if errs >= 3 { status = .error; lastError = error.localizedDescription }
        }
    }

    // MARK: - merge (3-way by element id; local wins when both changed)

    private func merge(base: [Element], local: [Element], remote: [Element]) -> [Element] {
        let bm = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0.stableJSON()) })
        let lm = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rm = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func changed(_ m: [String: Element], _ id: String) -> Bool {
            guard let cur = m[id] else { return bm[id] != nil }         // deleted vs base
            return cur.stableJSON() != bm[id]                           // added or modified
        }
        var out: [Element] = []
        var seen = Set<String>()
        for e in remote {
            seen.insert(e.id)
            if changed(lm, e.id) {
                if let mine = lm[e.id] { out.append(mine) }             // local wins; local-deleted stays gone
            } else {
                out.append(e)
            }
        }
        for e in local where !seen.contains(e.id) {
            if bm[e.id] != nil && rm[e.id] == nil && !changed(lm, e.id) { continue } // remote deleted, local untouched
            out.append(e)
        }
        return out
    }

    // MARK: - GitHub API

    private enum GetResult { case doc(BoardDoc, sha: String, etag: String?), unchanged, missing }
    private enum PutResult { case pushed(sha: String), conflict }
    private enum SyncError: Error { case badResponse, remoteVanished, conflict, noToken }

    private func makeDoc(rev: Int, elements: [Element]) -> BoardDoc {
        BoardDoc(app: "pitboard", version: 1, rev: rev, updatedBy: who, elements: elements)
    }

    private func request(_ urlStr: String, method: String = "GET") throws -> URLRequest {
        guard let token else { throw SyncError.noToken }
        var req = URLRequest(url: URL(string: urlStr)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    private func ghGet(useEtag: Bool) async throws -> GetResult {
        var req = try request("https://api.github.com/repos/\(repo)/contents/\(path)?ref=\(branch)")
        if useEtag, let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badResponse }
        switch http.statusCode {
        case 304: return .unchanged
        case 404: return .missing
        case 200:
            struct ContentsResp: Codable { let content: String; let sha: String }
            let c = try JSONDecoder().decode(ContentsResp.self, from: data)
            let raw = c.content.replacingOccurrences(of: "\n", with: "")
            guard let jsonData = Data(base64Encoded: raw) else { throw SyncError.badResponse }
            let doc = try JSONDecoder().decode(BoardDoc.self, from: jsonData)
            return .doc(doc, sha: c.sha, etag: http.value(forHTTPHeaderField: "ETag"))
        default: throw SyncError.badResponse
        }
    }

    private func ghPut(doc: BoardDoc, sha: String?) async throws -> PutResult {
        var req = try request("https://api.github.com/repos/\(repo)/contents/\(path)", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        let docData = try enc.encode(doc)
        var body: [String: Any] = [
            "message": "pitboard: \(doc.updatedBy) rev \(doc.rev)",
            "content": docData.base64EncodedString(),
            "branch": branch,
        ]
        if let sha { body["sha"] = sha }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SyncError.badResponse }
        if http.statusCode == 409 || http.statusCode == 422 { return .conflict }
        guard (200...201).contains(http.statusCode) else { throw SyncError.badResponse }
        struct PutResp: Codable { struct C: Codable { let sha: String }; let content: C }
        let p = try JSONDecoder().decode(PutResp.self, from: data)
        return .pushed(sha: p.content.sha)
    }
}

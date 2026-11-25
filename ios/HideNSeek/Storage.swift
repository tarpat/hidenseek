import Foundation

/// Everything for one game lives in Documents/Games/<CODE>/ on this phone:
/// chat.json, media/, track.json, snapshot.json, results.json.
enum GameFiles {
    static var root: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Games")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func dir(_ code: String) -> URL {
        let u = root.appendingPathComponent(code.uppercased())
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func mediaDir(_ code: String) -> URL {
        let u = dir(code).appendingPathComponent("media")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func delete(_ code: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(code.uppercased())) }
    static func hasResults(_ code: String) -> Bool { FileManager.default.fileExists(atPath: dir(code).appendingPathComponent("results.json").path) }

    static func loadMessages(_ code: String) -> [LocalMessage] {
        guard let d = try? Data(contentsOf: dir(code).appendingPathComponent("chat.json")) else { return [] }
        return (try? JSONDecoder().decode([LocalMessage].self, from: d)) ?? []
    }
    static func saveMessages(_ code: String, _ m: [LocalMessage]) {
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: dir(code).appendingPathComponent("chat.json"), options: .atomic) }
    }
    static func folderSize(_ code: String) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: dir(code), includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return total
    }
}

/// The phone's full-resolution route for the current game. Survives an app kill, and is re-uploaded
/// to the server after dropouts or a server restart (the server tells us how many points it has).
final class TrackBuffer {
    private(set) var points: [[Double]] = [] // [t(ms, server clock), lat, lng, speed, accuracy]
    var sentCount = 0
    private var code: String?
    private var dirty = false

    func load(code: String) {
        self.code = code
        if let d = try? Data(contentsOf: GameFiles.dir(code).appendingPathComponent("track.json")),
           let p = try? JSONDecoder().decode([[Double]].self, from: d) { points = p }
        sentCount = 0 // the server's ack tells us what it already has
    }
    func append(_ p: [Double]) { points.append(p); dirty = true }
    func saveIfNeeded() {
        guard dirty, let code, let d = try? JSONEncoder().encode(points) else { return }
        try? d.write(to: GameFiles.dir(code).appendingPathComponent("track.json"), options: .atomic)
        dirty = false
    }
    func reset() { points = []; sentCount = 0; code = nil; dirty = false }
}

/// Latest encrypted game snapshot from the server. We can't read it; we only hand it back after a server restart.
enum SnapshotStore {
    private struct Snap: Codable { var version: Int; var blob: String }
    static func save(code: String, version: Int, blob: String) {
        if let d = try? JSONEncoder().encode(Snap(version: version, blob: blob)) {
            try? d.write(to: GameFiles.dir(code).appendingPathComponent("snapshot.json"), options: .atomic)
        }
    }
    static func load(code: String) -> (version: Int, blob: String)? {
        guard let d = try? Data(contentsOf: GameFiles.dir(code).appendingPathComponent("snapshot.json")),
              let s = try? JSONDecoder().decode(Snap.self, from: d) else { return nil }
        return (s.version, s.blob)
    }
    static func delete(code: String) { try? FileManager.default.removeItem(at: GameFiles.dir(code).appendingPathComponent("snapshot.json")) }
}

struct PastGame: Identifiable {
    var id: String { code }
    var code: String
    var endedAt: Date
    var winner: String?
    var bytes: Int64
}

/// Past games are just game folders that have a results.json. Everything stays on this phone.
enum HistoryStore {
    static func save(results: Results, code: String) {
        if let d = try? JSONEncoder().encode(results) { try? d.write(to: GameFiles.dir(code).appendingPathComponent("results.json"), options: .atomic) }
    }
    static func load(code: String) -> Results? {
        guard let d = try? Data(contentsOf: GameFiles.dir(code).appendingPathComponent("results.json")) else { return nil }
        return try? JSONDecoder().decode(Results.self, from: d)
    }
    static func list() -> [PastGame] {
        let codes = (try? FileManager.default.contentsOfDirectory(atPath: GameFiles.root.path)) ?? []
        return codes.compactMap { code -> PastGame? in
            guard let r = load(code: code) else { return nil }
            return PastGame(code: code, endedAt: Date(timeIntervalSince1970: r.endedAt / 1000), winner: r.winner, bytes: GameFiles.folderSize(code))
        }.sorted { $0.endedAt > $1.endedAt }
    }
}

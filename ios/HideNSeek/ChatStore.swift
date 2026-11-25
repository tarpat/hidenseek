import Foundation

/// Chat history for the current game, kept on this phone only.
@Observable
@MainActor
final class ChatStore {
    private(set) var messages: [LocalMessage] = []
    @ObservationIgnored private var code: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    func load(code: String) {
        self.code = code
        messages = GameFiles.loadMessages(code)
    }
    func reset() { saveNow(); messages = []; code = nil }

    func has(_ id: String) -> Bool { messages.contains { $0.id == id } }

    func add(_ m: LocalMessage) {
        guard !has(m.id) else { return }
        messages.append(m)
        messages.sort { $0.at < $1.at }
        scheduleSave()
    }

    func update(_ id: String, _ change: (inout LocalMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
        scheduleSave()
    }

    func mediaURL(_ m: LocalMessage) -> URL? {
        guard let code, let f = m.mediaFile else { return nil }
        return GameFiles.mediaDir(code).appendingPathComponent(f)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.saveNow() }
        }
    }
    func saveNow() {
        if let code { GameFiles.saveMessages(code, messages) }
    }
}


/// Saves a game's photos and videos (never GIFs) to the Photos library, once.
@Observable
@MainActor
final class MediaSaver {
    let chat: ChatStore
    var message: String?
    var dismissed = false
    init(chat: ChatStore) { self.chat = chat }

    private var media: [LocalMessage] { chat.messages.filter { ($0.kind == "photo" || $0.kind == "video") && $0.mediaFile != nil && $0.status != "expired" } }
    var photos: Int { media.filter { $0.kind == "photo" }.count }
    var videos: Int { media.filter { $0.kind == "video" }.count }
    var unsaved: Int { media.filter { $0.saved != true }.count }

    func save() async {
        let todo = media.filter { $0.saved != true }
        let items = todo.compactMap { m in chat.mediaURL(m).map { (url: $0, isVideo: m.kind == "video") } }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !items.isEmpty else { message = "No new photos or videos to save."; return }
        do {
            let f = DateFormatter()
            f.dateStyle = .medium
            try await PhotosSaver.save(items: items, album: "Hide n Seek – \(f.string(from: Date()))")
            for m in todo { chat.update(m.id) { $0.saved = true } }
            chat.saveNow()
            message = "Saved \(items.count) item\(items.count == 1 ? "" : "s") to Photos."
        } catch {
            message = error.localizedDescription
        }
    }
}

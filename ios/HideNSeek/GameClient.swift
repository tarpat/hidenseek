import Foundation
import CoreLocation
import UIKit

struct OOBMarker: Equatable {
    let playerId: String
    let lat: Double
    let lng: Double
    let at: Double
    let willConvert: Bool
}

/// The phone's side of the game: WebSocket connection, game state, route tracking, chat, snapshots.
/// The server is the authority. This class only displays what the server says a player may see.
@Observable
@MainActor
final class GameClient {
    // MARK: Observable state
    var gameCode: String?
    var myID: String?
    var state: GameState?
    var avatars: [String: UIImage] = [:]
    var status = "Not connected"
    var lastError: String?
    var banner: String?
    var results: Results?
    var gameOver = false
    var oob: [String: OOBMarker] = [:]
    var myLocation: CLLocation?
    var mySpeed = 0.0
    var myDistanceM = 0.0
    var unread: [String: Int] = [:]
    var activeChannel: String?
    var pendingJoinCode: String?
    var connecting = false
    var locationStatus: CLAuthorizationStatus = .notDetermined
    let chat: ChatStore
    let saver: MediaSaver
    @ObservationIgnored var profile: ProfileStore?

    // MARK: Internals
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var serverURL = ""
    @ObservationIgnored private var firstMessage: [String: Any] = [:]
    @ObservationIgnored private var shouldRun = false
    @ObservationIgnored private var retry = 0
    @ObservationIgnored private var lastSent = Date.distantPast
    @ObservationIgnored private var offsetMs = 0.0
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private let location = LocationService()
    @ObservationIgnored private let track = TrackBuffer()
    @ObservationIgnored private var trackInflight = Date.distantPast
    @ObservationIgnored private var lastTrackLoc: CLLocation?
    @ObservationIgnored private var lastTrackAt = Date.distantPast
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var lastPong = Date()
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var seenEvents = Set<String>()
    @ObservationIgnored private var downloading = Set<String>()
    private static let sessionKey = "game.session"

    init() {
        let c = ChatStore()
        chat = c
        saver = MediaSaver(chat: c)
        location.onLocation = { [weak self] loc in
            Task { @MainActor in self?.handle(location: loc) }
        }
        location.onAuthChange = { [weak self] st in
            Task { @MainActor in self?.locationStatus = st }
        }
        locationStatus = location.status
    }

    // MARK: Derived

    var roster: [RosterEntry] { state?.roster ?? [] }
    var me: RosterEntry? { roster.first { $0.id == myID } }
    var myRole: Role { state?.role ?? .unassigned }
    var isLeader: Bool { me?.isLeader ?? false }
    var metric: Bool { profile?.metric ?? false }
    var serverNow: Double { Date().timeIntervalSince1970 * 1000 + offsetMs }
    func player(_ id: String?) -> RosterEntry? { roster.first { $0.id == id } }
    func name(_ id: String?) -> String { player(id)?.name ?? "Someone" }

    /// Chat channels this player may see right now. A tagged hider loses the hiders' channel until the game ends.
    var visibleChannels: [String] {
        if state?.status == "ended" || myRole == .referee { return ["all", "seekers", "hiders"] }
        switch myRole {
        case .hider: return ["all", "hiders"]
        case .seeker: return ["all", "seekers"]
        default: return ["all"]
        }
    }

    // MARK: Session start / resume

    func resumeIfNeeded() {
        guard gameCode == nil, let s = UserDefaults.standard.dictionary(forKey: Self.sessionKey) as? [String: String],
              let code = s["code"], let tok = s["token"], let server = s["server"] else { return }
        gameCode = code
        token = tok
        serverURL = server
        myID = s["id"]
        shouldRun = true
        beginLocalGame(code: code)
        connect()
    }

    func create(server: String) {
        begin(server: server, first: ["type": "create"])
    }

    func join(code: String, server: String) {
        begin(server: server, first: ["type": "join", "code": code.uppercased()])
    }

    private func begin(server: String, first: [String: Any]) {
        serverURL = server
        firstMessage = first
        shouldRun = true
        connecting = true
        retry = 0
        lastError = nil
        location.requestPermission()
        Notifier.requestPermission()
        connect()
    }

    private func identity() -> [String: Any] {
        var d: [String: Any] = ["name": profile?.displayName ?? "Player", "color": profile?.colorHex ?? "#3478F6"]
        if let a = profile?.avatarBase64 { d["avatar"] = a }
        return d
    }

    func leave(tellServer: Bool = true) {
        let old = task
        task = nil // the receive loop ignores sockets that aren't current
        if tellServer, state?.status != "ended", let data = try? JSONSerialization.data(withJSONObject: ["type": "leave"]), let s = String(data: data, encoding: .utf8) {
            old?.send(.string(s)) { _ in old?.cancel(with: .goingAway, reason: nil) } // close only after it's sent
        } else {
            old?.cancel(with: .goingAway, reason: nil)
        }
        shouldRun = false
        connecting = false
        stopTimers()
        location.stop()
        if let code = gameCode {
            chat.reset()
            track.saveIfNeeded()
            if !GameFiles.hasResults(code) { GameFiles.delete(code) } else { SnapshotStore.delete(code: code) }
        }
        track.reset()
        gameCode = nil; token = nil; myID = nil; state = nil; results = nil; gameOver = false
        oob = [:]; avatars = [:]; unread = [:]; seenEvents = []; flushing = false; myDistanceM = 0
        lastTrackLoc = nil
        status = "Not connected"
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
    }

    private func beginLocalGame(code: String) {
        chat.load(code: code)
        track.load(code: code)
    }

    // MARK: Connection

    private func connect() {
        guard shouldRun else { return }
        guard let url = URL(string: serverURL), url.scheme == "ws" || url.scheme == "wss" else {
            lastError = "Invalid server URL (must start with ws:// or wss://)"
            leave(tellServer: false)
            return
        }
        status = retry == 0 ? "Connecting…" : "Reconnecting…"
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.maximumMessageSize = 4 * 1024 * 1024
        t.resume()
        if let code = gameCode, let token {
            var m = identity()
            m["type"] = "rejoin"; m["code"] = code; m["token"] = token
            send(m)
        } else {
            var m = identity()
            for (k, v) in firstMessage { m[k] = v }
            send(m)
        }
        Task { await receiveLoop(t) }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) async {
        while true {
            do {
                let msg = try await t.receive()
                guard task === t else { return }
                switch msg {
                case .string(let s): receive(Data(s.utf8))
                case .data(let d): receive(d)
                @unknown default: break
                }
            } catch {
                guard task === t else { return }
                scheduleReconnect()
                return
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        if gameCode == nil, retry >= 3 { // a fresh create/join that can't reach the server
            leave(tellServer: false)
            lastError = "Couldn't reach the server. Check the server address in Profile & Settings, and your connection."
            return
        }
        status = "Reconnecting…"
        retry += 1
        let delay = min(pow(2.0, Double(retry)), 15)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if task == nil || shouldRun { connect() }
        }
    }

    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    // MARK: Incoming messages

    private struct Head: Decodable { let type: String }
    private struct Joined: Decodable { let code: String; let playerId: String; let token: String; let epoch: Int }
    private struct AvatarsMsg: Decodable { let avatars: [String: String] }
    private struct EventMsg: Decodable { let event: GameEventMsg }
    private struct ChatMsg: Decodable { let msg: ChatEnvelope }
    private struct IdMsg: Decodable { let id: String }
    private struct TrackAck: Decodable { let epoch: Int; let count: Int }
    private struct SnapMsg: Decodable { let version: Int; let blob: String }
    private struct ResultsMsg: Decodable { let version: Int; let results: Results }
    private struct ErrorMsg: Decodable { let message: String; let fatal: Bool? }

    private func receive(_ data: Data) {
        let dec = JSONDecoder()
        guard let head = try? dec.decode(Head.self, from: data) else { return }
        switch head.type {
        case "joined":
            if let m = try? dec.decode(Joined.self, from: data) { onJoined(m) }
        case "avatars":
            if let m = try? dec.decode(AvatarsMsg.self, from: data) {
                for (id, b64) in m.avatars { if let d = Data(base64Encoded: b64), let img = UIImage(data: d) { avatars[id] = img } }
            }
        case "state":
            if let s = try? dec.decode(GameState.self, from: data) { apply(state: s) }
        case "event":
            if let m = try? dec.decode(EventMsg.self, from: data) { handle(event: m.event) }
        case "chat":
            if let m = try? dec.decode(ChatMsg.self, from: data) { onChat(m.msg) }
        case "chat_ack":
            if let m = try? dec.decode(IdMsg.self, from: data) { chat.update(m.id) { $0.status = "sent" } }
        case "track_ack":
            if let m = try? dec.decode(TrackAck.self, from: data) { onTrackAck(m.count) }
        case "snapshot":
            if let m = try? dec.decode(SnapMsg.self, from: data), let code = gameCode { SnapshotStore.save(code: code, version: m.version, blob: m.blob) }
        case "pong":
            lastPong = Date()
        case "need_restore":
            sendRestore()
        case "game_over":
            onGameOver()
        case "results":
            if let m = try? dec.decode(ResultsMsg.self, from: data) { onResults(m.results) }
        case "error":
            if let m = try? dec.decode(ErrorMsg.self, from: data) { onError(m) }
        default:
            break
        }
    }

    private func onJoined(_ m: Joined) {
        let isNewGame = gameCode != m.code
        gameCode = m.code
        myID = m.playerId
        token = m.token
        retry = 0
        connecting = false
        status = "Connected"
        lastPong = Date()
        UserDefaults.standard.set(["code": m.code, "token": m.token, "server": serverURL, "id": m.playerId], forKey: Self.sessionKey)
        if isNewGame { beginLocalGame(code: m.code) }
        location.requestPermission()
        location.start()
        startTimers()
        resendOutbox()
        track.sentCount = 0 // the server's ack tells us what it really has (it may have restarted)
        uploadTrack(force: true)
        if state?.status == "ended" || gameOver { send(["type": "get_results"]) }
    }

    private func onError(_ m: ErrorMsg) {
        lastError = m.message
        if m.fatal == true {
            leave(tellServer: false)
            lastError = m.message
        } else {
            showBanner(m.message)
        }
    }

    private func sendRestore() {
        guard let code = gameCode, let token else { return }
        var m: [String: Any] = ["type": "restore", "code": code, "token": token]
        if let s = SnapshotStore.load(code: code) { m["version"] = s.version; m["blob"] = s.blob }
        if let a = profile?.avatarBase64 { m["avatar"] = a }
        send(m)
    }

    private func apply(state s: GameState) {
        offsetMs = s.serverTime - Date().timeIntervalSince1970 * 1000
        let oldRole = state?.role
        state = s
        if oldRole != nil, oldRole != s.role, s.role == .seeker, oldRole == .hider { /* banner comes from the converted event */ }
        if s.status == "ended" && !gameOver { onGameOver() }
    }

    // MARK: Events

    private func handle(event e: GameEventMsg) {
        guard seenEvents.insert(e.id).inserted else { return }
        let who = name(e.playerId)
        let mine = e.playerId == myID
        var text: String?
        var haptic: UINotificationFeedbackGenerator.FeedbackType = .warning
        switch e.type {
        case "started":
            let hs = state?.settings.headStartMs ?? 0
            text = hs > 0 ? "Game on! Hiders have \(Fmt.minutes(hs)) to hide." : "Game on!"
            haptic = .success
        case "ping":
            text = "Ping #\(e.seq ?? 0): everyone's location is on the map"
        case "oob_start":
            if let id = e.playerId, let lat = e.lat, let lng = e.lng {
                oob[id] = OOBMarker(playerId: id, lat: lat, lng: lng, at: e.at, willConvert: e.willConvert ?? false)
            }
            text = mine ? "You left the play area! Get back inside." : "\(who) left the play area"
            haptic = mine ? .error : .warning
        case "oob_return":
            if let id = e.playerId { oob[id] = nil }
            text = "\(who) is back in the play area"
        case "converted":
            if let id = e.playerId { oob[id] = nil }
            switch e.reason {
            case "tag": text = "\(who) was tagged by \(name(e.by))"
            case "self_tag": text = "\(who) tagged themselves out"
            case "out_of_bounds": text = "\(who) stayed out of bounds and is now a seeker"
            case "dark": text = "\(who) went offline and is now a seeker"
            default: text = "\(who) is now a seeker"
            }
            if mine { text = "You're now a seeker!"; haptic = .error }
        case "paused": text = "Game paused"
        case "resumed": text = "Game resumed"
        case "ended":
            text = e.winner == "seekers" ? "Seekers win!" : "Hiders win!"
            haptic = .success
        default: break
        }
        guard let text else { return }
        showBanner(text)
        Notifier.haptic(haptic)
        Notifier.post("Hide n Seek", text)
        if ["started", "ping", "oob_start", "converted", "ended"].contains(e.type) {
            chat.add(LocalMessage(id: "sys-\(e.id)", channel: "all", senderId: "", senderName: "", kind: "system", body: text, mime: nil, mediaFile: nil,
                                  mediaId: nil, size: nil, at: e.at, mine: false, status: "sent"))
        }
    }

    func showBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.banner = nil }
        }
    }

    // MARK: Leader & player commands

    func setRole(_ id: String, _ role: Role) { send(["type": "set_role", "playerId": id, "role": role.rawValue]) }
    func assignRandom(seekers: Int) { send(["type": "assign_random", "seekers": seekers]) }
    func startGame() { send(["type": "start"]) }
    func endGame() { send(["type": "end"]) }
    func pause() { send(["type": "pause"]) }
    func resume() { send(["type": "resume"]) }
    func manualPing() { send(["type": "manual_ping"]) }
    func kick(_ id: String) { send(["type": "kick", "playerId": id]) }
    func forceSeeker(_ id: String) { send(["type": "force_seeker", "playerId": id]) }
    func tag(_ id: String) { send(["type": "tag", "hiderId": id]) }
    func selfTag() { send(["type": "self_tag"]) }
    func setGeofence(center: CLLocationCoordinate2D, radius: Double) {
        send(["type": "set_geofence", "lat": center.latitude, "lng": center.longitude, "radius": radius])
    }
    func updateSettings(_ s: GameSettings) {
        guard let d = try? JSONEncoder().encode(s), var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        o["center"] = nil; o["radiusM"] = nil // those are set through the geofence editor
        send(["type": "update_settings", "patch": o])
    }

    // MARK: Location & track

    private func handle(location loc: CLLocation) {
        myLocation = loc
        mySpeed = max(0, loc.speed)
        recordTrack(loc)
        guard gameCode != nil, Date().timeIntervalSince(lastSent) >= 3 else { return }
        sendLocation(loc)
    }

    private func sendLocation(_ loc: CLLocation) {
        guard gameCode != nil else { return }
        lastSent = Date()
        send(["type": "location", "lat": loc.coordinate.latitude, "lng": loc.coordinate.longitude,
              "acc": max(0, loc.horizontalAccuracy), "speed": max(0, loc.speed)])
    }

    private func recordTrack(_ loc: CLLocation) {
        guard state?.status == "active", loc.horizontalAccuracy >= 0 else { return }
        track.append([serverNow, loc.coordinate.latitude, loc.coordinate.longitude, max(0, loc.speed), loc.horizontalAccuracy])
        lastTrackAt = Date()
        if let prev = lastTrackLoc {
            let d = loc.distance(from: prev)
            let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
            if loc.horizontalAccuracy <= 25, d >= 3, dt > 0, d / dt <= 12 {
                myDistanceM += d
                lastTrackLoc = loc
            }
        } else if loc.horizontalAccuracy <= 25 {
            lastTrackLoc = loc
        }
    }

    private func startTimers() {
        stopTimers()
        // Keepalive: CoreLocation sends nothing while you stand still, so re-send the last fix.
        timers.append(Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let loc = self.myLocation else { return }
                if Date().timeIntervalSince(self.lastSent) >= 15 { self.sendLocation(loc) }
                // While standing still, still record a track point so "still time" is measured.
                if self.state?.status == "active", Date().timeIntervalSince(self.lastTrackAt) >= 5 {
                    self.track.append([self.serverNow, loc.coordinate.latitude, loc.coordinate.longitude, 0, max(0, loc.horizontalAccuracy)])
                    self.lastTrackAt = Date()
                }
            }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.uploadTrack(force: false)
                self?.track.saveIfNeeded()
                guard let self else { return }
                self.send(["type": "ping"])
                if Date().timeIntervalSince(self.lastPong) > 35, self.shouldRun, self.status == "Connected" {
                    // The connection looks dead even though iOS hasn't said so. Drop it and reconnect.
                    let t = self.task
                    self.task = nil
                    t?.cancel(with: .goingAway, reason: nil)
                    self.lastPong = Date()
                    self.scheduleReconnect()
                }
            }
        })
    }

    private func stopTimers() {
        timers.forEach { $0.invalidate() }
        timers = []
    }

    private func uploadTrack(force: Bool) {
        guard gameCode != nil, track.sentCount < track.points.count else { return }
        if !force, Date().timeIntervalSince(trackInflight) < 8 { return }
        trackInflight = Date()
        let batch = Array(track.points[track.sentCount..<min(track.points.count, track.sentCount + 300)])
        send(["type": "track_batch", "from": track.sentCount, "points": batch])
    }

    private func onTrackAck(_ count: Int) {
        track.sentCount = min(count, track.points.count)
        trackInflight = .distantPast
        if track.sentCount < track.points.count {
            uploadTrack(force: true) // keep going until the server has everything
        } else if flushing {
            flushing = false
            send(["type": "track_done"])
        }
    }

    // MARK: Game over & results

    private func onGameOver() {
        guard !gameOver else { return }
        gameOver = true
        if let code = gameCode { SnapshotStore.delete(code: code) }
        track.saveIfNeeded()
        // Flush the rest of the route so the results map is complete, then tell the server we're done.
        flushing = true
        if track.sentCount >= track.points.count { onTrackAck(track.points.count) } else { uploadTrack(force: true) }
        Task {
            try? await Task.sleep(for: .seconds(10))
            if flushing { flushing = false; send(["type": "track_done"]) }
        }
    }

    private func onResults(_ r: Results) {
        results = r
        if let code = gameCode {
            HistoryStore.save(results: r, code: code)
            chat.saveNow()
        }
        location.stop()
        if profile?.autoSaveMedia == true { Task { await saver.save() } }
    }

    // MARK: Chat

    private func endpoint() -> Endpoint? {
        guard let code = gameCode, let token else { return nil }
        return Endpoint(serverURL: serverURL, code: code, token: token)
    }

    func endpointForGifs() -> Endpoint? { endpoint() }

    private func newMessage(channel: String, kind: String, body: String?, mime: String? = nil, file: String? = nil, size: Double? = nil, status: String = "sending") -> LocalMessage {
        LocalMessage(id: UUID().uuidString, channel: channel, senderId: myID ?? "", senderName: me?.name ?? "Me", kind: kind, body: body, mime: mime,
                     mediaFile: file, mediaId: nil, size: size, at: serverNow, mine: true, status: status)
    }

    func sendText(_ text: String, channel: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let m = newMessage(channel: channel, kind: "text", body: t)
        chat.add(m)
        transmit(m)
    }

    func sendGif(url: String, channel: String) {
        let m = newMessage(channel: channel, kind: "gif", body: url)
        chat.add(m)
        transmit(m)
    }

    func sendPhoto(data: Data, channel: String) async {
        guard let code = gameCode else { return }
        do {
            let p = try MediaTools.preparePhoto(data: data, into: GameFiles.mediaDir(code))
            await sendPrepared(p, channel: channel)
        } catch { showBanner(error.localizedDescription) }
    }

    func sendVideo(file: URL, channel: String) async {
        guard let code = gameCode else { return }
        do {
            let p = try await MediaTools.prepareVideo(source: file, into: GameFiles.mediaDir(code))
            await sendPrepared(p, channel: channel)
        } catch { showBanner(error.localizedDescription) }
    }

    private func sendPrepared(_ p: PreparedMedia, channel: String) async {
        let m = newMessage(channel: channel, kind: p.kind, body: nil, mime: p.mime, file: p.url.lastPathComponent, size: p.size)
        chat.add(m)
        await uploadAndSend(m)
    }

    func retry(_ m: LocalMessage) {
        chat.update(m.id) { $0.status = "sending" }
        if m.kind == "photo" || m.kind == "video" { Task { await uploadAndSend(m) } } else { transmit(m) }
    }

    private func uploadAndSend(_ m: LocalMessage) async {
        guard let ep = endpoint(), let url = chat.mediaURL(m), let mime = m.mime else { return chat.update(m.id) { $0.status = "failed" } }
        do {
            let mediaId = try await Transfer.upload(file: url, mime: mime, endpoint: ep)
            chat.update(m.id) { $0.mediaId = mediaId }
            if let updated = chat.messages.first(where: { $0.id == m.id }) { transmit(updated) }
        } catch {
            chat.update(m.id) { $0.status = "failed" }
            showBanner(error.localizedDescription)
        }
    }

    private func transmit(_ m: LocalMessage) {
        var o: [String: Any] = ["type": "chat", "id": m.id, "channel": m.channel, "kind": m.kind]
        if let b = m.body { o["body"] = b }
        if let id = m.mediaId { o["mediaId"] = id }
        if let mime = m.mime { o["mime"] = mime }
        if let s = m.size { o["size"] = s }
        send(o)
    }

    /// After a reconnect, re-send anything the server never acknowledged. Text and GIFs only; media can be retried by hand.
    private func resendOutbox() {
        for m in chat.messages where m.mine && m.status == "sending" && (m.kind == "text" || m.kind == "gif" || m.mediaId != nil) { transmit(m) }
    }

    private func onChat(_ e: ChatEnvelope) {
        if chat.has(e.id) { send(["type": "chat_received", "id": e.id]); return }
        let kind = e.kind
        var m = LocalMessage(id: e.id, channel: e.channel, senderId: e.senderId, senderName: name(e.senderId), kind: kind, body: e.body, mime: e.mime,
                             mediaFile: nil, mediaId: e.mediaId, size: e.size, at: e.at, mine: false,
                             status: (kind == "photo" || kind == "video") ? "pending" : "sent")
        if kind == "photo" || kind == "video" {
            m.mediaFile = "\(e.id).\(MediaTools.ext(forMime: e.mime ?? "", kind: kind))"
        }
        chat.add(m)
        if activeChannel != e.channel || state?.status == "ended" { unread[e.channel, default: 0] += 1 }
        if kind == "text" || kind == "gif" {
            send(["type": "chat_received", "id": e.id])
            Notifier.post(m.senderName, kind == "gif" ? "sent a GIF" : (e.body ?? ""))
        } else if kind == "photo" {
            download(m) // photos download automatically, videos on tap
            Notifier.post(m.senderName, "sent a photo")
        } else {
            Notifier.post(m.senderName, "sent a video")
        }
    }

    func download(_ m: LocalMessage) {
        guard let ep = endpoint(), let mediaId = m.mediaId, let dest = chat.mediaURL(m), downloading.insert(m.id).inserted else { return }
        chat.update(m.id) { $0.status = "downloading" }
        Task {
            defer { downloading.remove(m.id) }
            do {
                try await Transfer.download(mediaId: mediaId, endpoint: ep, to: dest)
                chat.update(m.id) { $0.status = "downloaded" }
                send(["type": "chat_received", "id": m.id])
            } catch MediaError.expired {
                chat.update(m.id) { $0.status = "expired" }
            } catch {
                chat.update(m.id) { $0.status = "pending" }
                showBanner("Download failed. Tap to try again.")
            }
        }
    }
}

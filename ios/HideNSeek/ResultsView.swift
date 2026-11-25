import SwiftUI
import MapKit
import Charts

/// Results of the game that just ended (live). Waits for everyone's routes to arrive.
struct LiveResultsView: View {
    @Environment(GameClient.self) private var client

    var body: some View {
        if let r = client.results, let code = client.gameCode {
            NavigationStack { ResultsView(results: r, code: code, saver: client.saver, avatars: client.avatars, onDone: { client.leave() }) }
        } else {
            VStack(spacing: 16) {
                Text(client.state?.winner == "seekers" ? "Seekers win!" : "Hiders win!").font(.largeTitle.bold())
                ProgressView()
                Text("Collecting everyone's routes…").foregroundStyle(.secondary)
                Button("Leave") { client.leave() }.buttonStyle(.bordered)
            }
            .padding()
        }
    }
}

struct ResultsView: View {
    @Environment(ProfileStore.self) private var profile
    let results: Results
    let code: String
    let saver: MediaSaver
    var avatars: [String: UIImage] = [:]
    let onDone: () -> Void

    @State private var tab = 0
    @State private var selected: String?
    @State private var hidden = Set<String>()
    @State private var showPings = false

    private var metric: Bool { profile.metric }
    private var focus: PlayerResult? { results.players.first { $0.id == selected } }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                mediaCard
                if !results.awards.isEmpty { awards }
                Picker("View", selection: $tab) {
                    Text("Routes").tag(0); Text("Stats").tag(1); Text("Speed").tag(2)
                }.pickerStyle(.segmented)
                switch tab {
                case 0: routesTab
                case 1: statsTab
                default: speedTab
                }
            }
            .padding()
        }
        .navigationTitle("Results")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done", action: onDone).bold() } }
    }

    // MARK: Header, media, awards

    private var header: some View {
        VStack(spacing: 6) {
            Text(results.winner == "seekers" ? "Seekers win!" : "Hiders win!").font(.largeTitle.bold())
            let reason: String = {
                switch results.endReason {
                case "all_tagged": return "Every hider was tagged"
                case "time": return "Time ran out with hiders still free"
                default: return "Ended by the leader"
                }
            }()
            Text(reason).foregroundStyle(.secondary)
            Text("Hunt lasted \(Fmt.minutes(max(0, results.endedAt - results.huntStartsAt)))").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var mediaCard: some View {
        if saver.photos + saver.videos > 0 && !saver.dismissed {
            VStack(alignment: .leading, spacing: 8) {
                if saver.unsaved > 0 {
                    Text("Save \(saver.photos) photo\(saver.photos == 1 ? "" : "s") and \(saver.videos) video\(saver.videos == 1 ? "" : "s") from this game to your Photos library?").font(.subheadline.bold())
                    HStack {
                        Button("Save to Photos") { Task { await saver.save() } }.buttonStyle(.borderedProminent)
                        Button("Not now") { saver.dismissed = true }.buttonStyle(.bordered)
                    }
                } else {
                    Label("Saved to your Photos library", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let m = saver.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var awards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Awards").font(.headline)
            ForEach(results.awards) { a in
                HStack {
                    Image(systemName: icon(a.id)).foregroundStyle(.yellow).frame(width: 28)
                    VStack(alignment: .leading) {
                        Text(a.title).bold()
                        Text(a.playerIds.compactMap { id in results.players.first { $0.id == id }?.name }.joined(separator: ", ") + detail(a))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func icon(_ id: String) -> String {
        switch id {
        case "fastest": return "bolt.fill"
        case "marathoner": return "figure.run"
        case "statue": return "figure.stand"
        case "last_standing": return "trophy.fill"
        default: return "hand.tap.fill"
        }
    }

    private func detail(_ a: Award) -> String {
        guard let v = a.value else { return "" }
        switch a.id {
        case "fastest": return " · " + Fmt.speed(v, metric: metric)
        case "marathoner", "statue": return " · " + Fmt.dist(v, metric: metric)
        case "top_tagger": return " · \(Int(v)) tag\(Int(v) == 1 ? "" : "s")"
        default: return ""
        }
    }

    // MARK: Routes map

    private var visiblePlayers: [PlayerResult] { results.players.filter { !hidden.contains($0.id) } }

    private func coords(_ p: PlayerResult) -> [CLLocationCoordinate2D] { p.route.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) } }

    private func speedColor(_ v: Double) -> Color { Color(hue: 0.66 - 0.66 * min(max(v, 0) / 6, 1), saturation: 0.9, brightness: 0.95) }

    private func point(_ p: PlayerResult, at t: Double) -> CLLocationCoordinate2D? {
        guard let best = p.route.min(by: { abs($0[3] - t) < abs($1[3] - t) }) else { return nil }
        return CLLocationCoordinate2D(latitude: best[0], longitude: best[1])
    }

    private var routesTab: some View {
        VStack(spacing: 10) {
            Map(initialPosition: .automatic) {
                if let g = results.geofence {
                    MapCircle(center: g.center.coordinate, radius: g.radiusM).foregroundStyle(.orange.opacity(0.06)).stroke(.orange, lineWidth: 2)
                }
                ForEach(visiblePlayers) { p in
                    let c = coords(p)
                    if c.count > 1 {
                        if p.id == selected {
                            // Selected route is coloured by speed (blue = slow, red = fast)
                            ForEach(0..<(p.route.count - 1), id: \.self) { i in
                                MapPolyline(coordinates: [c[i], c[i + 1]]).stroke(speedColor(p.route[i + 1][2]), lineWidth: 6)
                            }
                        } else {
                            MapPolyline(coordinates: c).stroke(Color(hex: p.color), lineWidth: 3)
                        }
                    }
                    if let first = c.first { Annotation("", coordinate: first) { Circle().fill(.green).frame(width: 10, height: 10).overlay(Circle().stroke(.white, lineWidth: 2)) } }
                    if let last = c.last {
                        Annotation(p.name, coordinate: last) {
                            AvatarView(image: avatars[p.id], colorHex: p.color, initial: p.name, size: 28, ring: p.finalRole.tint)
                        }
                    }
                    if let t = p.convertedAt, p.startRole == .hider, let at = point(p, at: t) {
                        Annotation("\(p.name) tagged", coordinate: at) {
                            Image(systemName: "flag.fill").foregroundStyle(.white).padding(5).background(.red, in: Circle())
                        }
                    }
                }
                ForEach(results.events.filter { $0.type == "oob_start" }) { e in
                    if let lat = e.lat, let lng = e.lng {
                        Annotation("Out of bounds", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white).padding(4).background(.orange, in: Circle())
                        }
                    }
                }
                if showPings {
                    ForEach(results.pings, id: \.seq) { ping in
                        ForEach(ping.positions, id: \.id) { pos in
                            Annotation("", coordinate: pos.coordinate) {
                                Text("\(ping.seq)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(width: 16, height: 16)
                                    .background(Color(hex: results.players.first { $0.id == pos.id }?.color ?? "#888888"), in: Circle())
                            }
                        }
                    }
                }
            }
            .frame(height: 380).clipShape(RoundedRectangle(cornerRadius: 14))

            if let p = focus {
                HStack(spacing: 6) {
                    Text("Slow").font(.caption2)
                    LinearGradient(colors: stride(from: 0.0, through: 6.0, by: 1.0).map(speedColor), startPoint: .leading, endPoint: .trailing).frame(height: 8).clipShape(Capsule())
                    Text("Fast").font(.caption2)
                }
                Text("\(p.name)'s route, colored by speed").font(.footnote).foregroundStyle(.secondary)
            }

            Toggle("Show ping locations", isOn: $showPings).font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    chip("All", on: hidden.isEmpty) { hidden = [] }
                    chip("Hiders", on: false) { hidden = Set(results.players.filter { $0.startRole != .hider }.map(\.id)) }
                    chip("Seekers", on: false) { hidden = Set(results.players.filter { $0.startRole == .hider }.map(\.id)) }
                    ForEach(results.players) { p in
                        Button {
                            if selected == p.id { selected = nil } else { selected = p.id; hidden.remove(p.id) }
                        } label: {
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: p.color)).frame(width: 12, height: 12)
                                Text(p.name).font(.caption.bold())
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(selected == p.id ? Color.accentColor.opacity(0.25) : Color(.secondarySystemBackground), in: Capsule())
                            .opacity(hidden.contains(p.id) ? 0.4 : 1)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button(hidden.contains(p.id) ? "Show route" : "Hide route") { if hidden.contains(p.id) { hidden.remove(p.id) } else { hidden.insert(p.id) } } }
                    }
                }
            }
            Text("Tap a player to highlight their route. Long-press to hide or show it.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? Color.accentColor.opacity(0.25) : Color(.secondarySystemBackground), in: Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: Stats

    private var statsTab: some View {
        VStack(spacing: 10) {
            ForEach(results.players) { p in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        AvatarView(image: avatars[p.id], colorHex: p.color, initial: p.name, size: 34, ring: p.finalRole.tint)
                        VStack(alignment: .leading) {
                            Text(p.name).bold()
                            Text(p.startRole == .hider && p.finalRole == .seeker ? "Hider → Seeker" : p.startRole.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.startRole == .hider { Text("Survived \(Fmt.clock(p.survivedMs))").font(.caption.bold()) }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow { stat("Distance", Fmt.dist(p.stats.distanceM, metric: metric)); stat("Top speed", Fmt.speed(p.stats.topSpeedMps, metric: metric)) }
                        GridRow { stat("Avg moving", Fmt.speed(p.stats.avgMovingSpeedMps, metric: metric)); stat("Moving / still", "\(Fmt.clock(p.stats.movingMs)) / \(Fmt.clock(p.stats.stillMs))") }
                        if p.startRole == .hider && p.finalRole == .seeker {
                            GridRow { stat("As hider", Fmt.dist(p.stats.hiderDistanceM, metric: metric)); stat("As seeker", Fmt.dist(p.stats.seekerDistanceM, metric: metric)) }
                        }
                        if p.tagsMade > 0 { GridRow { stat("Tags made", "\(p.tagsMade)"); Color.clear } }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold()).monospacedDigit()
        }
    }

    // MARK: Speed chart

    private var speedTab: some View {
        let p = focus ?? results.players.first
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Player", selection: Binding(get: { selected ?? results.players.first?.id ?? "" }, set: { selected = $0 })) {
                ForEach(results.players) { Text($0.name).tag($0.id) }
            }
            if let p, !p.speedSeries.isEmpty {
                Chart {
                    ForEach(Array(p.speedSeries.enumerated()), id: \.offset) { _, s in
                        LineMark(x: .value("Time", Date(timeIntervalSince1970: s[0] / 1000)), y: .value("Speed", metric ? s[1] * 3.6 : s[1] * 2.23694))
                            .foregroundStyle(Color(hex: p.color))
                    }
                    ForEach(results.pings, id: \.seq) { ping in
                        RuleMark(x: .value("Ping", Date(timeIntervalSince1970: ping.at / 1000))).foregroundStyle(.gray.opacity(0.4))
                            .annotation(position: .top, alignment: .leading) { Text("P\(ping.seq)").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    if let t = p.convertedAt, p.startRole == .hider {
                        RuleMark(x: .value("Tagged", Date(timeIntervalSince1970: t / 1000))).foregroundStyle(.red)
                            .annotation(position: .bottom, alignment: .leading) { Text("Tagged").font(.system(size: 9)).foregroundStyle(.red) }
                    }
                }
                .chartYAxisLabel(metric ? "km/h" : "mph")
                .frame(height: 260)
                Text("Gray lines mark pings.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("No speed data for this player.").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Past games (stored only on this phone)

struct PastGamesView: View {
    @State private var games = HistoryStore.list()

    var body: some View {
        List {
            if games.isEmpty { Text("No past games yet. Finished games show up here and stay on this phone.").foregroundStyle(.secondary) }
            ForEach(games) { g in
                NavigationLink {
                    PastGameDetail(code: g.code)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.endedAt.formatted(date: .abbreviated, time: .shortened)).bold()
                        Text("\(g.winner == "seekers" ? "Seekers" : "Hiders") won · code \(g.code) · \(ByteCountFormatter.string(fromByteCount: g.bytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                for i in idx { GameFiles.delete(games[i].code) }
                games = HistoryStore.list()
            }
        }
        .navigationTitle("Past games")
        .toolbar { EditButton() }
    }
}

struct PastGameDetail: View {
    @Environment(\.dismiss) private var dismiss
    let code: String
    @State private var chat = ChatStore()
    @State private var saver: MediaSaver?

    var body: some View {
        Group {
            if let r = HistoryStore.load(code: code), let saver {
                ResultsView(results: r, code: code, saver: saver, onDone: { dismiss() })
            } else {
                ProgressView()
            }
        }
        .task {
            chat.load(code: code)
            saver = MediaSaver(chat: chat)
        }
    }
}

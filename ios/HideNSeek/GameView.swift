import SwiftUI
import MapKit

struct GameView: View {
    @Environment(GameClient.self) private var client
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var showChat = false
    @State private var showRoster = false
    @State private var showTag = false
    @State private var showSettings = false
    @State private var showGeofence = false
    @State private var confirmEnd = false
    @State private var confirmSelfTag = false

    var body: some View {
        ZStack {
            GameMap(camera: $camera)
            VStack(spacing: 8) {
                HUDView()
                if client.locationStatus == .denied || client.locationStatus == .restricted {
                    Button("Location access is off. Tap to open Settings, or you'll be removed as a hider.") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                    .font(.footnote.bold()).padding(10).frame(maxWidth: .infinity).background(.red, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                }
                OOBWarning()
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 10)
        }
        .sheet(isPresented: $showChat) { ChatView() }
        .sheet(isPresented: $showRoster) { RosterSheet() }
        .sheet(isPresented: $showTag) { TagSheet() }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                if let s = client.state?.settings { GameSettingsView(initial: s).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showSettings = false } } } }
            }
        }
        .sheet(isPresented: $showGeofence) {
            NavigationStack {
                if let s = client.state?.settings { GeofenceEditorView(initialCenter: s.center, initialRadius: s.radiusM) }
            }
        }
        .confirmationDialog("End the game for everyone?", isPresented: $confirmEnd) {
            Button("End game", role: .destructive) { client.endGame() }
        }
        .confirmationDialog("Mark yourself as tagged?", isPresented: $confirmSelfTag) {
            Button("I was tagged", role: .destructive) { client.selfTag() }
        }
    }

    private var huntStarted: Bool { client.serverNow >= (client.state?.timing.huntStartsAt ?? 0) }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            barButton("bubble.left.and.bubble.right.fill", badge: client.unread.values.reduce(0, +)) { showChat = true }
            barButton("person.3.fill") { showRoster = true }
            if client.myRole == .seeker {
                Button { showTag = true } label: { Label("Tag", systemImage: "hand.tap.fill").font(.headline).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            } else if client.myRole == .hider, client.state?.settings.hiderSelfTag == true {
                Button { confirmSelfTag = true } label: { Label("I'm out", systemImage: "flag.fill").font(.headline).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.blue).controlSize(.large)
            } else {
                Spacer()
            }
            barButton("location.fill") { camera = .userLocation(fallback: .automatic) }
            if client.isLeader { leaderMenu }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.bottom, 4)
    }

    private func barButton(_ icon: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(width: 44, height: 44)
                .background(.thinMaterial, in: Circle())
                .overlay(alignment: .topTrailing) {
                    if badge > 0 { Text("\(badge)").font(.caption2.bold()).padding(5).background(.red, in: Circle()).foregroundStyle(.white).offset(x: 4, y: -4) }
                }
        }
    }

    private var leaderMenu: some View {
        Menu {
            if client.state?.paused == true { Button("Resume game", systemImage: "play.fill") { client.resume() } }
            else { Button("Pause game", systemImage: "pause.fill") { client.pause() } }
            Button("Ping everyone now", systemImage: "dot.radiowaves.left.and.right") { client.manualPing() }
            Button("Game rules", systemImage: "slider.horizontal.3") { showSettings = true }
            Button("Play area", systemImage: "circle.dashed") { showGeofence = true }
            Button("End game", systemImage: "stop.fill", role: .destructive) { confirmEnd = true }
        } label: {
            Image(systemName: "crown.fill").font(.title3).frame(width: 44, height: 44).background(.thinMaterial, in: Circle())
        }
    }
}

struct GameMap: View {
    @Environment(GameClient.self) private var client
    @Binding var camera: MapCameraPosition

    var body: some View {
        let s = client.state
        let liveIDs = Set((s?.live ?? []).map(\.id))
        Map(position: $camera) {
            UserAnnotation()
            if let g = s?.settings, let c = g.center {
                MapCircle(center: c.coordinate, radius: g.radiusM).foregroundStyle(.orange.opacity(0.07)).stroke(.orange, lineWidth: 3)
            }
            // Teammates, live
            ForEach((s?.live ?? []).filter { $0.id != client.myID }) { p in
                Annotation(label(p), coordinate: p.coordinate) { dot(p.id, faded: false) }
            }
            // Everyone else, as of the last ping
            if let ping = s?.lastPing {
                ForEach(ping.positions.filter { $0.id != client.myID && !liveIDs.contains($0.id) }, id: \.id) { pos in
                    Annotation("\(client.name(pos.id)) · \(Fmt.ago(client.serverNow - ping.at))", coordinate: pos.coordinate) { dot(pos.id, faded: true) }
                }
            }
            // Players currently outside the play area
            ForEach(Array(client.oob.values), id: \.playerId) { m in
                Annotation("\(client.name(m.playerId)) is out of bounds", coordinate: CLLocationCoordinate2D(latitude: m.lat, longitude: m.lng)) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white).padding(6).background(.orange, in: Circle())
                }
            }
        }
        .mapControls { MapCompass() }
        .ignoresSafeArea()
    }

    private func label(_ p: LivePos) -> String {
        guard let v = p.speed, client.state?.settings.showTeamSpeed == true || client.state?.status == "ended" else { return client.name(p.id) }
        return "\(client.name(p.id)) · \(Fmt.speed(v, metric: client.metric))"
    }

    private func dot(_ id: String, faded: Bool) -> some View {
        let r = client.player(id)
        return AvatarView(image: client.avatars[id], colorHex: r?.color ?? "#888888", initial: r?.name ?? "?", size: faded ? 28 : 34, ring: (r?.role ?? .unassigned).tint)
            .opacity(faded ? 0.6 : 1)
    }
}

struct HUDView: View {
    @Environment(GameClient.self) private var client

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let s = client.state {
                let now = client.serverNow
                let t = s.timing
                let hiding = now < t.huntStartsAt
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(client.myRole.label.uppercased()).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(client.myRole.tint, in: Capsule()).foregroundStyle(.white)
                        if s.paused {
                            Text("Paused").font(.title2.bold())
                        } else {
                            Text(Fmt.clock(hiding ? t.huntStartsAt - now : t.endsAt - now)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                            Text(hiding ? (client.myRole == .seeker ? "Hiders are hiding" : "Time to hide!") : "Time left").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        if !s.paused, now < t.nextPingAt, t.nextPingAt < t.endsAt {
                            Label("Ping \(Fmt.clock(t.nextPingAt - now))", systemImage: "dot.radiowaves.left.and.right").font(.subheadline.bold())
                        }
                        Text("\(s.hidersLeft) hider\(s.hidersLeft == 1 ? "" : "s") left").font(.subheadline)
                        Text("\(Fmt.speed(client.mySpeed, metric: client.metric)) · \(Fmt.dist(client.myDistanceM, metric: client.metric))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if client.status != "Connected" { Text(client.status).font(.caption2).foregroundStyle(.orange) }
                        if client.locationStatus == .denied || client.locationStatus == .restricted {
                            Text("Location is off!").font(.caption2.bold()).foregroundStyle(.red)
                        }
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .padding(.top, 2)
    }
}

struct OOBWarning: View {
    @Environment(GameClient.self) private var client

    var body: some View {
        if let id = client.myID, let m = client.oob[id], let s = client.state {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let left = s.settings.graceMs - (client.serverNow - m.at)
                VStack(spacing: 2) {
                    Text("Get back inside the play area!").font(.headline)
                    if m.willConvert { Text("You become a seeker in \(Fmt.clock(left))").font(.subheadline).monospacedDigit() }
                }
                .frame(maxWidth: .infinity).padding(10)
                .background(.red, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
            }
        }
    }
}

struct TagSheet: View {
    @Environment(GameClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var target: RosterEntry?

    var body: some View {
        NavigationStack {
            let hiders = client.roster.filter { $0.role == .hider }
            List {
                if client.serverNow < (client.state?.timing.huntStartsAt ?? 0) {
                    Text("Tagging opens when the head start ends.").foregroundStyle(.orange)
                }
                Section("Who did you tag?") {
                    ForEach(hiders) { h in
                        Button {
                            target = h
                        } label: {
                            HStack {
                                AvatarView(image: client.avatars[h.id], colorHex: h.color, initial: h.name, size: 34, ring: .blue)
                                Text(h.name).foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                    if hiders.isEmpty { Text("No hiders left").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Tag a hider")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .confirmationDialog("Tag \(target?.name ?? "")?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { t in
                Button("Tag \(t.name)", role: .destructive) { client.tag(t.id); dismiss() }
            } message: { _ in Text("They'll become a seeker.") }
        }
        .presentationDetents([.medium, .large])
    }
}

struct RosterSheet: View {
    @Environment(GameClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach([Role.seeker, .hider, .referee], id: \.self) { role in
                    let group = client.roster.filter { $0.role == role }
                    if !group.isEmpty {
                        Section("\(role.label)s (\(group.count))") {
                            ForEach(group) { p in
                                HStack {
                                    AvatarView(image: client.avatars[p.id], colorHex: p.color, initial: p.name, size: 34, ring: p.role.tint)
                                    Text(p.name + (p.id == client.myID ? " (you)" : ""))
                                    if p.isLeader { Image(systemName: "crown.fill").foregroundStyle(.yellow).font(.caption) }
                                    Spacer()
                                    if !p.connected { Text("offline").font(.caption).foregroundStyle(.orange) }
                                }
                                .swipeActions {
                                    if client.isLeader && p.id != client.myID {
                                        Button("Remove", role: .destructive) { client.kick(p.id) }
                                        if p.role == .hider { Button("Make seeker") { client.forceSeeker(p.id) }.tint(.red) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Players")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

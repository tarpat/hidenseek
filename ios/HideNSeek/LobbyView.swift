import SwiftUI
import MapKit

struct LobbyView: View {
    @Environment(GameClient.self) private var client
    @State private var seekers = 1
    @State private var showChat = false
    @State private var confirmLeave = false

    private var roster: [RosterEntry] { client.roster }
    private var problem: String? {
        let roles = roster.map(\.role)
        if roles.contains(.unassigned) { return "Everyone needs a role" }
        if !roles.contains(.hider) { return "Need at least one hider" }
        if !roles.contains(.seeker) { return "Need at least one seeker" }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Join code").font(.caption).foregroundStyle(.secondary)
                            Text(client.gameCode ?? "").font(.system(size: 34, weight: .bold, design: .monospaced))
                        }
                        Spacer()
                        ShareLink(item: "Join my Hide n Seek game! Code: \(client.gameCode ?? "")  hidenseek://join/\(client.gameCode ?? "")") {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    HStack {
                        Text("Your role")
                        Spacer()
                        Text(client.myRole.label).bold().foregroundStyle(client.myRole.tint)
                    }
                }

                Section("Players (\(roster.count))") {
                    ForEach(roster) { p in PlayerRow(p: p) }
                }

                if client.isLeader, let s = client.state?.settings {
                    Section("Roles") {
                        Stepper("Seekers: \(seekers)", value: $seekers, in: 1...max(1, roster.count))
                        Button("Randomize roles") { client.assignRandom(seekers: seekers) }
                    }
                    Section("Game setup") {
                        NavigationLink {
                            GameSettingsView(initial: s)
                        } label: {
                            LabeledContent("Rules", value: "\(Fmt.minutes(s.headStartMs)) head start · \(Fmt.minutes(s.durationMs)) hunt")
                        }
                        NavigationLink {
                            GeofenceEditorView(initialCenter: s.center, initialRadius: s.radiusM)
                        } label: {
                            LabeledContent("Play area", value: s.center == nil ? "Not set" : "\(Int(s.radiusM)) m radius")
                        }
                    }
                    Section {
                        Button("Start game") { client.startGame() }.disabled(problem != nil).bold()
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
                        else if s.center == nil { Text("No play area is set, so players won't be kept inside a boundary.").font(.footnote).foregroundStyle(.orange) }
                    }
                } else {
                    Section { Text("Waiting for the leader to start the game…").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Lobby")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Leave", role: .destructive) { confirmLeave = true } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showChat = true } label: { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                        .badge(client.unread.values.reduce(0, +))
                }
            }
            .confirmationDialog("Leave this game?", isPresented: $confirmLeave) {
                Button("Leave game", role: .destructive) { client.leave() }
            }
            .sheet(isPresented: $showChat) { ChatView() }
        }
    }
}

struct PlayerRow: View {
    @Environment(GameClient.self) private var client
    let p: RosterEntry

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(image: client.avatars[p.id], colorHex: p.color, initial: p.name, size: 36, ring: p.role.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(p.name + (p.id == client.myID ? " (you)" : ""))
                    if p.isLeader { Image(systemName: "crown.fill").foregroundStyle(.yellow).font(.caption) }
                }
                if !p.connected { Text("offline").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if client.isLeader {
                Menu {
                    ForEach([Role.hider, .seeker, .referee], id: \.self) { r in Button(r.label) { client.setRole(p.id, r) } }
                    if p.id != client.myID { Button("Remove from game", role: .destructive) { client.kick(p.id) } }
                } label: {
                    Text(p.role == .unassigned ? "Choose role" : p.role.label).foregroundStyle(p.role.tint).bold()
                }
            } else {
                Text(p.role == .unassigned ? "—" : p.role.label).foregroundStyle(p.role.tint).bold()
            }
        }
    }
}

struct GameSettingsView: View {
    @Environment(GameClient.self) private var client
    @State private var s: GameSettings

    init(initial: GameSettings) { _s = State(initialValue: initial) }

    private func mins(_ kp: WritableKeyPath<GameSettings, Double>) -> Binding<Double> {
        Binding(get: { s[keyPath: kp] / 60_000 }, set: { s[keyPath: kp] = $0 * 60_000 })
    }
    private var graceSeconds: Binding<Double> {
        Binding(get: { s.graceMs / 1000 }, set: { s.graceMs = $0 * 1000 })
    }

    var body: some View {
        Form {
            Section("Timing") {
                Stepper(value: mins(\.headStartMs), in: 0...30) { Text("Head start: \(Fmt.minutes(s.headStartMs))") }
                Stepper(value: mins(\.durationMs), in: 1...180) { Text("Hunt length: \(Fmt.minutes(s.durationMs))") }
                Stepper(value: mins(\.pingIntervalMs), in: 1...30) { Text("Ping every: \(Fmt.minutes(s.pingIntervalMs))") }
            }
            Section {
                Stepper(value: graceSeconds, in: 10...300, step: 10) { Text("Out-of-bounds grace: \(Int(s.graceMs / 1000)) s") }
                Toggle("Warn seekers who leave the area", isOn: $s.warnSeekers)
                Stepper(value: mins(\.darkHiderMs), in: 0...10) {
                    Text(s.darkHiderMs == 0 ? "Offline hiders: never convert" : "Convert hiders offline for: \(Fmt.minutes(s.darkHiderMs))")
                }
            } header: { Text("Rules") } footer: {
                Text("Hiders who stay outside the play area past the grace period, or who stop sharing their location, become seekers.")
            }
            Section("Players") {
                Toggle("Hiders can mark themselves tagged", isOn: $s.hiderSelfTag)
                Toggle("Allow joining after the game starts", isOn: $s.allowLateJoin)
                if s.allowLateJoin {
                    Picker("Late joiners become", selection: $s.lateJoinRole) { Text("Seekers").tag("seeker"); Text("Hiders").tag("hider") }
                }
                Toggle("Seekers see each other live", isOn: $s.seekersSeeEachOther)
                Toggle("Show teammates' speed", isOn: $s.showTeamSpeed)
            }
            Section("Chat & results") {
                Toggle("Chat", isOn: $s.chatEnabled)
                Toggle("Photos & videos", isOn: $s.mediaEnabled).disabled(!s.chatEnabled)
                Toggle("End-of-game awards", isOn: $s.awards)
            }
        }
        .navigationTitle("Game rules")
        .onChange(of: s) { _, new in client.updateSettings(new) }
    }
}

struct GeofenceEditorView: View {
    @Environment(GameClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var center: CLLocationCoordinate2D?
    @State private var radius: Double
    @State private var camera: MapCameraPosition

    init(initialCenter: LatLng?, initialRadius: Double) {
        _center = State(initialValue: initialCenter?.coordinate)
        _radius = State(initialValue: initialRadius)
        if let c = initialCenter {
            _camera = State(initialValue: .region(MKCoordinateRegion(center: c.coordinate, latitudinalMeters: initialRadius * 3, longitudinalMeters: initialRadius * 3)))
        } else {
            _camera = State(initialValue: .userLocation(fallback: .automatic))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if let c = center {
                        MapCircle(center: c, radius: radius).foregroundStyle(.orange.opacity(0.15)).stroke(.orange, lineWidth: 3)
                        Marker("Center", coordinate: c).tint(.orange)
                    }
                }
                .mapControls { MapUserLocationButton(); MapCompass() }
                .onTapGesture { point in
                    if let c = proxy.convert(point, from: .local) { center = c; commit() }
                }
            }
            VStack(spacing: 10) {
                Text(center == nil ? "Tap the map to place the center of the play area" : "Radius: \(Int(radius)) m").font(.subheadline.bold())
                Slider(value: $radius, in: 50...3000, step: 10) { editing in if !editing { commit() } }
                HStack {
                    Button("Use my location") {
                        if let c = client.myLocation?.coordinate {
                            center = c
                            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: radius * 3, longitudinalMeters: radius * 3))
                            commit()
                        }
                    }.buttonStyle(.bordered)
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(.regularMaterial)
        }
        .navigationTitle("Play area")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func commit() {
        if let c = center { client.setGeofence(center: c, radius: radius) }
    }
}

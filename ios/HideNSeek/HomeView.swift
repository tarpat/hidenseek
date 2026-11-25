import SwiftUI
import PhotosUI

struct HomeView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(GameClient.self) private var client
    @State private var code = ""

    var body: some View {
        @Bindable var profile = profile
        NavigationStack {
            Form {
                Section("You (stored on this phone)") {
                    HStack(spacing: 12) {
                        AvatarView(image: profile.avatar, colorHex: profile.colorHex, initial: profile.displayName, size: 44)
                        TextField("Your name", text: $profile.name).textInputAutocapitalization(.words)
                    }
                    NavigationLink("Photo, colors & settings") { ProfileSettingsView() }
                }

                Section("Play") {
                    Button("Create a game") { client.create(server: profile.serverURL) }
                    HStack {
                        TextField("Join code", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Button("Join") { client.join(code: code, server: profile.serverURL) }
                            .disabled(code.trimmingCharacters(in: .whitespaces).count < 6)
                    }
                }

                Section {
                    NavigationLink("Past games") { PastGamesView() }
                }

                if let e = client.lastError {
                    Section { Text(e).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Hide n Seek")
            .onChange(of: client.pendingJoinCode) { _, new in
                if let new { code = new; client.pendingJoinCode = nil }
            }
            .task { // Wake the free server up before it's needed.
                if let url = healthURL(profile.serverURL) { _ = try? await URLSession.shared.data(from: url) }
            }
        }
    }

    private func healthURL(_ ws: String) -> URL? {
        guard var c = URLComponents(string: ws) else { return nil }
        c.scheme = c.scheme == "wss" ? "https" : "http"
        c.path = "/health"
        return c.url
    }
}

struct ProfileSettingsView: View {
    @Environment(ProfileStore.self) private var profile
    @State private var item: PhotosPickerItem?

    var body: some View {
        @Bindable var profile = profile
        Form {
            Section("Profile") {
                HStack(spacing: 14) {
                    AvatarView(image: profile.avatar, colorHex: profile.colorHex, initial: profile.displayName, size: 64)
                    VStack(alignment: .leading) {
                        PhotosPicker("Choose photo", selection: $item, matching: .images)
                        if profile.avatar != nil { Button("Remove photo", role: .destructive) { profile.setAvatar(nil) } }
                    }
                }
                TextField("Name", text: $profile.name)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(ProfileStore.palette, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 34, height: 34)
                                .overlay(Circle().stroke(.primary, lineWidth: profile.colorHex == hex ? 3 : 0))
                                .onTapGesture { profile.colorHex = hex }
                        }
                    }.padding(.vertical, 2)
                }
                Text("Your name, color and photo are stored only on this phone. They're shared with the players in a game while it runs, and removed from the server afterwards.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Units") {
                Picker("Speed & distance", selection: $profile.metric) {
                    Text("mph / feet").tag(false)
                    Text("km/h / meters").tag(true)
                }.pickerStyle(.segmented)
            }

            Section {
                Toggle("Automatically save photos & videos to Photos", isOn: $profile.autoSaveMedia)
            } footer: {
                Text("When a game ends, Hide n Seek asks before saving the game's photos and videos (not GIFs). Turn this on to skip the question.")
            }

            Section("Server") {
                TextField("wss://…/ws", text: $profile.serverURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text("Your Render URL, e.g. wss://your-app.onrender.com/ws, or ws://<Mac IP>:8080/ws for local testing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Profile & Settings")
        .onChange(of: item) { _, new in
            guard let new else { return }
            Task {
                if let d = try? await new.loadTransferable(type: Data.self), let img = UIImage(data: d) { profile.setAvatar(img) }
                item = nil
            }
        }
    }
}

import SwiftUI

@main
struct HideNSeekApp: App {
    @State private var profile = ProfileStore()
    @State private var client = GameClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(profile)
                .environment(client)
                .onOpenURL { url in
                    // hidenseek://join/ABC123
                    if url.scheme == "hidenseek", url.host == "join", let code = url.pathComponents.dropFirst().first {
                        client.pendingJoinCode = code.uppercased()
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(GameClient.self) private var client
    @Environment(ProfileStore.self) private var profile

    var body: some View {
        Group {
            if client.gameCode == nil && !client.connecting {
                HomeView()
            } else if let s = client.state {
                switch s.status {
                case "lobby": LobbyView()
                case "active": GameView()
                default: LiveResultsView()
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(client.status).foregroundStyle(.secondary)
                    Button("Cancel") { client.leave(tellServer: false) }
                }
            }
        }
        .overlay(alignment: .bottom) { BannerView() }
        .task {
            client.profile = profile
            client.resumeIfNeeded()
        }
    }
}

struct BannerView: View {
    @Environment(GameClient.self) private var client
    var body: some View {
        if let b = client.banner {
            Text(b)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThickMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 96)
                .padding(.horizontal)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring, value: client.banner)
                .allowsHitTesting(false)
        }
    }
}

extension Role {
    var tint: Color {
        switch self {
        case .hider: return .blue
        case .seeker: return .red
        case .referee: return .gray
        case .unassigned: return .secondary
        }
    }
}

struct AvatarView: View {
    let image: UIImage?
    let colorHex: String
    var initial: String = ""
    var size: CGFloat = 36
    var ring: Color = .white

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: colorHex))
            if let image {
                Image(uiImage: image).resizable().scaledToFill().clipShape(Circle())
            } else {
                Text(String(initial.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(ring, lineWidth: 2.5))
    }
}

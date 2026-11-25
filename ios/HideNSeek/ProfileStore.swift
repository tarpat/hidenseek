import SwiftUI
import UIKit

/// On-device profile and preferences. Never leaves the phone except as part of joining a game
/// (name, color and a tiny avatar are sent to the server and live there only for that game).
@Observable
final class ProfileStore {
    var name: String { didSet { UserDefaults.standard.set(name, forKey: "profile.name") } }
    var colorHex: String { didSet { UserDefaults.standard.set(colorHex, forKey: "profile.color") } }
    var serverURL: String { didSet { UserDefaults.standard.set(serverURL, forKey: "server.url") } }
    var metric: Bool { didSet { UserDefaults.standard.set(metric, forKey: "prefs.metric") } }
    var autoSaveMedia: Bool { didSet { UserDefaults.standard.set(autoSaveMedia, forKey: "prefs.autosave") } }
    private(set) var avatar: UIImage?

    let deviceID: String
    static let palette = ["#E5484D", "#F76B15", "#F5D90A", "#30A46C", "#3E63DD", "#8E4EC6", "#E93D82", "#12A594"]

    private static var avatarURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("avatar.jpg")
    }

    init() {
        let d = UserDefaults.standard
        name = d.string(forKey: "profile.name") ?? ""
        colorHex = d.string(forKey: "profile.color") ?? ProfileStore.palette.randomElement()!
        serverURL = d.string(forKey: "server.url") ?? "ws://localhost:8080/ws"
        metric = d.object(forKey: "prefs.metric") as? Bool ?? false // mph by default
        autoSaveMedia = d.object(forKey: "prefs.autosave") as? Bool ?? false // off by default
        if let id = d.string(forKey: "device.id") {
            deviceID = id
        } else {
            deviceID = UUID().uuidString
            d.set(deviceID, forKey: "device.id")
        }
        if let data = try? Data(contentsOf: Self.avatarURL) { avatar = UIImage(data: data) }
    }

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Player" : n
    }

    func setAvatar(_ image: UIImage?) {
        guard let image else {
            avatar = nil
            try? FileManager.default.removeItem(at: Self.avatarURL)
            return
        }
        let small = image.resized(maxSide: 256)
        avatar = small
        try? small.jpegData(compressionQuality: 0.8)?.write(to: Self.avatarURL)
    }

    /// ~128 px JPEG, base64. This is the only picture that ever leaves the phone for the profile.
    var avatarBase64: String? {
        avatar?.resized(maxSide: 128).jpegData(compressionQuality: 0.7)?.base64EncodedString()
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        if scale >= 1 { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

import Foundation
import UIKit
import SwiftUI
import ImageIO
import AVFoundation
import Photos
import PhotosUI
import UniformTypeIdentifiers
import UserNotifications

enum MediaError: LocalizedError {
    case unreadable, cannotStripLocation, uploadFailed(String), expired, noPhotosAccess

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Couldn't read that file."
        case .cannotStripLocation: return "Couldn't remove the location data, so it wasn't sent."
        case .uploadFailed(let m): return "Upload failed: \(m)"
        case .expired: return "This file is no longer available. Ask the sender to send it again."
        case .noPhotosAccess: return "Allow adding to Photos in Settings to save media."
        }
    }
}

struct PreparedMedia {
    let url: URL
    let mime: String
    let kind: String // photo | video
    let size: Double
}

/// Lossless handling only: photos and videos are sent exactly as captured. The only change is that
/// GPS/location metadata is removed WITHOUT re-encoding, so a photo can't give away a hiding spot.
enum MediaTools {
    static func preparePhoto(data: Data, into dir: URL) throws -> PreparedMedia {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src) else { throw MediaError.unreadable }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type, CGImageSourceGetCount(src), nil) else { throw MediaError.unreadable }
        var err: Unmanaged<CFError>?
        let opts = [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary
        guard CGImageDestinationCopyImageSource(dest, src, opts, &err) else { throw MediaError.cannotStripLocation }
        let uti = UTType(type as String)
        let ext = uti?.preferredFilenameExtension ?? "jpg"
        let url = dir.appendingPathComponent(UUID().uuidString + "." + ext)
        try (out as Data).write(to: url)
        return PreparedMedia(url: url, mime: uti?.preferredMIMEType ?? "image/jpeg", kind: "photo", size: Double(out.length))
    }

    static func prepareVideo(source: URL, into dir: URL) async throws -> PreparedMedia {
        let asset = AVURLAsset(url: source)
        let url = dir.appendingPathComponent(UUID().uuidString + ".mov")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw MediaError.unreadable }
        session.outputURL = url
        session.outputFileType = .mov
        let meta = try await asset.load(.metadata)
        session.metadata = meta.filter { !isLocation($0) }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
        guard session.status == .completed else { throw MediaError.cannotStripLocation }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return PreparedMedia(url: url, mime: "video/quicktime", kind: "video", size: Double(size))
    }

    private static func isLocation(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyLocation { return true }
        if let id = item.identifier?.rawValue.lowercased(), id.contains("location") || id.contains("xyz") { return true }
        if let k = item.key as? String, k.contains("xyz") || k.lowercased().contains("location") { return true }
        return false
    }

    static func ext(forMime mime: String, kind: String) -> String {
        UTType(mimeType: mime)?.preferredFilenameExtension ?? (kind == "video" ? "mov" : "jpg")
    }
}

/// Where HTTP calls go: derived from the WebSocket URL.
struct Endpoint {
    let base: URL
    let code: String
    let token: String

    init?(serverURL: String, code: String, token: String) {
        guard var c = URLComponents(string: serverURL) else { return nil }
        c.scheme = c.scheme == "wss" ? "https" : "http"
        c.path = ""
        c.query = nil
        guard let u = c.url else { return nil }
        base = u; self.code = code; self.token = token
    }

    func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET") -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue(code, forHTTPHeaderField: "x-code")
        r.setValue(token, forHTTPHeaderField: "x-token")
        return r
    }
}

enum Transfer {
    /// Uploads a file to the server's transient relay. Retries if the server's buffer is momentarily full.
    static func upload(file: URL, mime: String, endpoint: Endpoint) async throws -> String {
        var req = endpoint.request("media", method: "POST")
        req.setValue(mime, forHTTPHeaderField: "content-type")
        req.timeoutInterval = 600
        for _ in 0..<8 {
            let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["mediaId"] as? String { return id }
            if status == 503 { try await Task.sleep(for: .seconds(5)); continue }
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "HTTP \(status)"
            throw MediaError.uploadFailed(msg)
        }
        throw MediaError.uploadFailed("server busy")
    }

    static func download(mediaId: String, endpoint: Endpoint, to dest: URL) async throws {
        var req = endpoint.request("media/\(mediaId)")
        req.timeoutInterval = 600
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 404 ? MediaError.expired : MediaError.uploadFailed("HTTP \(status)") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    struct GifItem: Decodable, Identifiable { let id: String; let url: String; let preview: String?; let w: Double; let h: Double }

    static func gifs(query: String, endpoint: Endpoint) async throws -> [GifItem] {
        struct R: Decodable { let gifs: [GifItem] }
        let req = endpoint.request("gifs", query: [URLQueryItem(name: "q", value: query)])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.uploadFailed("GIFs aren't available on this server") }
        return try JSONDecoder().decode(R.self, from: data).gifs
    }
}

enum PhotosSaver {
    /// Saves into a new album using add-only permission (the app can't read the rest of the library).
    static func save(items: [(url: URL, isVideo: Bool)], album: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw MediaError.noPhotosAccess }
        try await PHPhotoLibrary.shared().performChanges {
            let albumReq = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
            var placeholders: [PHObjectPlaceholder] = []
            for item in items {
                let r = item.isVideo
                    ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.url)
                    : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: item.url)
                if let p = r?.placeholderForCreatedAsset { placeholders.append(p) }
            }
            albumReq.addAssets(placeholders as NSArray)
        }
    }
}

// MARK: Notifications & haptics

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    /// Local notification, only when the app is in the background.
    @MainActor static func post(_ title: String, _ body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
    @MainActor static func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}

// MARK: Picker helpers

struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { m in SentTransferredFile(m.url) } importing: { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

/// In-app camera, recording videos at the system "high" quality setting.
struct CameraPicker: UIViewControllerRepresentable {
    var onPhoto: (Data) -> Void
    var onVideo: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        p.videoQuality = .typeHigh
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                try? FileManager.default.copyItem(at: url, to: dest)
                parent.onVideo(dest)
            } else if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 1.0) {
                parent.onPhoto(d)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: Animated GIFs

enum GIFCache {
    static let cache = NSCache<NSURL, UIImage>()

    static func load(_ url: URL) async -> UIImage? {
        if let c = cache.object(forKey: url as NSURL) { return c }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let img = animated(from: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }

    static func animated(from data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = min(CGImageSourceGetCount(src), 80)
        if count <= 1 { return UIImage(data: data) }
        var frames: [UIImage] = []
        var total = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            total += max(delay, 0.02)
        }
        return UIImage.animatedImage(with: frames, duration: total)
    }
}

struct GIFView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        Task { v.image = await GIFCache.load(url) }
        return v
    }
    func updateUIView(_ v: UIImageView, context: Context) {}
}

import SwiftUI
import PhotosUI
import AVKit
import ImageIO

struct ChatView: View {
    @Environment(GameClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var channel = "all"
    @State private var text = ""
    @State private var item: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showGifs = false
    @State private var viewing: LocalMessage?

    private func title(_ c: String) -> String { c == "all" ? "Everyone" : c == "seekers" ? "Seekers" : "Hiders" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if client.visibleChannels.count > 1 {
                    Picker("Channel", selection: $channel) {
                        ForEach(client.visibleChannels, id: \.self) { c in
                            Text(title(c) + ((client.unread[c] ?? 0) > 0 && c != channel ? " (\(client.unread[c] ?? 0))" : "")).tag(c)
                        }
                    }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.top, 8)
                }
                let msgs = client.chat.messages.filter { $0.channel == channel }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(msgs) { m in MessageRow(m: m, onOpen: { viewing = m }).id(m.id) }
                        }.padding()
                    }
                    .onChange(of: msgs.count) { _, _ in if let last = msgs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                    .onAppear { if let last = msgs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                composer
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear { client.activeChannel = channel; client.unread[channel] = 0 }
            .onDisappear { client.activeChannel = nil }
            .onChange(of: channel) { _, c in client.activeChannel = c; client.unread[c] = 0 }
            .onChange(of: client.visibleChannels) { _, v in if !v.contains(channel) { channel = "all" } }
            .onChange(of: item) { _, new in
                guard let new else { return }
                Task { await send(picked: new); item = nil }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker(onPhoto: { d in Task { await client.sendPhoto(data: d, channel: channel) } },
                             onVideo: { u in Task { await client.sendVideo(file: u, channel: channel) } })
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showGifs) { GifPickerView(channel: channel) }
            .fullScreenCover(item: $viewing) { m in MediaViewer(message: m) }
        }
    }

    private var composer: some View {
        let enabled = client.state?.settings.chatEnabled != false
        let media = enabled && client.state?.settings.mediaEnabled != false
        return VStack(spacing: 4) {
            if !enabled { Text("Chat is turned off").font(.footnote).foregroundStyle(.secondary) }
            HStack(spacing: 10) {
                if media {
                    PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) { Image(systemName: "photo").font(.title3) }
                    Button { showCamera = true } label: { Image(systemName: "camera").font(.title3) }
                    Button { showGifs = true } label: { Text("GIF").font(.caption.bold()).padding(4).overlay(RoundedRectangle(cornerRadius: 4).stroke(lineWidth: 1.5)) }
                }
                TextField("Message \(title(channel))", text: $text, axis: .vertical).lineLimit(1...4)
                    .textFieldStyle(.roundedBorder).disabled(!enabled)
                Button {
                    client.sendText(text, channel: channel); text = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !enabled)
            }
        }
        .padding(10).background(.bar)
    }

    private func send(picked: PhotosPickerItem) async {
        if picked.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            if let m = try? await picked.loadTransferable(type: MovieFile.self) { await client.sendVideo(file: m.url, channel: channel) }
        } else if let d = try? await picked.loadTransferable(type: Data.self) {
            await client.sendPhoto(data: d, channel: channel)
        }
    }
}

struct MessageRow: View {
    @Environment(GameClient.self) private var client
    let m: LocalMessage
    let onOpen: () -> Void

    var body: some View {
        if m.kind == "system" {
            Text(m.body ?? "").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom) {
                if m.mine { Spacer(minLength: 40) }
                VStack(alignment: m.mine ? .trailing : .leading, spacing: 3) {
                    if !m.mine { Text(m.senderName).font(.caption).foregroundStyle(.secondary) }
                    bubble
                    if m.mine, m.status == "sending" { Text("Sending…").font(.caption2).foregroundStyle(.secondary) }
                    if m.mine, m.status == "failed" { Button("Failed. Tap to retry") { client.retry(m) }.font(.caption2).foregroundStyle(.red) }
                }
                if !m.mine { Spacer(minLength: 40) }
            }
        }
    }

    @ViewBuilder private var bubble: some View {
        switch m.kind {
        case "gif":
            if let s = m.body, let u = URL(string: s) { GIFView(url: u).frame(width: 200, height: 150).clipShape(RoundedRectangle(cornerRadius: 12)) }
        case "photo", "video":
            mediaBubble
        default:
            Text(m.body ?? "").padding(.horizontal, 12).padding(.vertical, 8)
                .background(m.mine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(m.mine ? .white : .primary)
        }
    }

    @ViewBuilder private var mediaBubble: some View {
        let url = client.chat.mediaURL(m)
        let ready = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        Button {
            if ready { onOpen() } else if m.status == "pending" { client.download(m) }
        } label: {
            ZStack {
                if ready, let url {
                    ThumbnailView(url: url, isVideo: m.kind == "video")
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
                    VStack(spacing: 4) {
                        switch m.status {
                        case "downloading": ProgressView(); Text("Downloading…").font(.caption)
                        case "expired": Image(systemName: "clock.badge.xmark"); Text("No longer available").font(.caption)
                        default:
                            Image(systemName: m.kind == "video" ? "video.fill" : "photo")
                            Text(m.kind == "video" ? "Tap to download video" : "Tap to download").font(.caption)
                            if let s = m.size { Text(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                if ready && m.kind == "video" { Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white).shadow(radius: 3) }
            }
            .frame(width: 220, height: 160).clipShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

/// Small preview of a photo/video, created without loading the full-size file into memory.
struct ThumbnailView: View {
    let url: URL
    let isVideo: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color(.secondarySystemBackground) }
        }
        .task(id: url) { image = await Self.thumbnail(url: url, isVideo: isVideo) }
    }

    static func thumbnail(url: URL, isVideo: Bool) async -> UIImage? {
        if isVideo {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 600, height: 600)
            return (try? await gen.image(at: .zero).image).map { UIImage(cgImage: $0) }
        }
        return await Task.detached {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 600]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
    }
}

struct MediaViewer: View {
    @Environment(GameClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let message: LocalMessage

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let url = client.chat.mediaURL(message) {
                if message.kind == "video" {
                    VideoPlayer(player: AVPlayer(url: url)).ignoresSafeArea()
                } else if let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.9)).padding() }
        }
    }
}

extension LocalMessage: Hashable { func hash(into h: inout Hasher) { h.combine(id) } }

struct GifPickerView: View {
    @Environment(GameClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let channel: String
    @State private var query = ""
    @State private var gifs: [Transfer.GifItem] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error { Text(error).foregroundStyle(.secondary).padding() }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(gifs) { g in
                        Button {
                            client.sendGif(url: g.url, channel: channel); dismiss()
                        } label: {
                            AsyncImage(url: URL(string: g.preview ?? g.url)) { img in img.resizable().scaledToFill() } placeholder: { Color(.secondarySystemBackground) }
                                .frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.padding(8)
                Text("Powered by GIPHY").font(.caption2).foregroundStyle(.secondary).padding()
            }
            .searchable(text: $query, prompt: "Search GIFs")
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let ep = client.endpointForGifs() else { return }
                do { gifs = try await Transfer.gifs(query: query, endpoint: ep); error = gifs.isEmpty ? "No GIFs found" : nil }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

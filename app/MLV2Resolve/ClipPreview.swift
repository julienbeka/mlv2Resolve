// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import MLV2ResolveCore

/// Serial decoding bounds simultaneous FUSE reads. Cached bytes are capped at 16 MB.
private actor PreviewLoader {
    static let shared = PreviewLoader()
    private let cache = NSCache<NSURL, NSData>()
    init() { cache.totalCostLimit = 16 * 1024 * 1024; cache.countLimit = 48 }
    func load(directory: URL) -> Data? {
        if let cached = cache.object(forKey: directory as NSURL) { return cached as Data }
        let sequence = ResolveProject.sequence(in: directory)
        var candidates: [URL] = []
        if let sequence {
            let frame = sequence.first + (sequence.last - sequence.first) / 2
            candidates.append(URL(fileURLWithPath: sequence.pattern.replacingOccurrences(of: "%06d", with: String(format: "%06d", frame))))
        }
        candidates.append(directory.appendingPathComponent("_PREVIEW.gif"))
        for url in candidates {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 960, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, cg, nil)
            guard CGImageDestinationFinalize(destination) else { continue }
            let data = output as Data
            cache.setObject(data as NSData, forKey: directory as NSURL, cost: data.count)
            return data
        }
        return nil
    }
    func discard(_ directory: URL) { cache.removeObject(forKey: directory as NSURL) }
}

struct ClipPreview: View {
    let clip: Clip
    let shoot: Shoot
    @ObservedObject var state: AppState
    @State private var image: NSImage?
    @State private var loading = true
    @State private var expanded = false
    @State private var directory: URL?

    var body: some View {
        Button { if image != nil { expanded = true } } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.8))
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }.frame(width: 96, height: 62).clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(image == nil ? "Preview unavailable" : "Enlarge Preview")
        .accessibilityLabel(Text("Preview of \(clip.name)"))
        .task(id: state.mounted.contains(GyroSyncCoordinator.key(of: shoot))) {
            guard state.mounted.contains(GyroSyncCoordinator.key(of: shoot)) else {
                image = nil; loading = false
                if let directory { await PreviewLoader.shared.discard(directory) }
                return
            }
            loading = true
            guard let dir = await state.previewDirectory(clip: clip, shoot: shoot) else { loading = false; return }
            directory = dir
            let data = await PreviewLoader.shared.load(directory: dir)
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:)); loading = false
        }
        .onDisappear {
            image = nil
            if let directory { Task { await PreviewLoader.shared.discard(directory) } }
        }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 16) {
                HStack {
                    Text(verbatim: clip.name).font(.headline)
                    Spacer()
                    Button("Close") { expanded = false }.keyboardShortcut(.cancelAction)
                }
                if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.padding(24).frame(width: 760, height: 500)
        }
    }
}

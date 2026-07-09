import SwiftUI
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import BannyRender

/// Backdrop stylizer: import any image (photo, AI render, sketch) and land it
/// on the show's pixel grid and palette. "Match show palette" quantizes to
/// colors learned from the images already in the bank, so every new backdrop
/// sits in the same world as the old ones.
struct StylizeSheet: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    @Binding var isPresented: Bool

    @State private var importing = false
    @State private var source: CGImage?
    @State private var preview: CGImage?
    @State private var name = "New backdrop"
    @State private var gridWidth = 480.0
    @State private var colors = 28.0
    @State private var dither = 0.06
    @State private var matchShow = true
    @State private var working = false
    @State private var stylePalette: [SIMD3<Float>]?

    /// Palette references: bank images directly, videos via a poster frame —
    /// the ep1 backdrops are videos, and they ARE the house style.
    private var bankImages: [CGImage] {
        model.document.assets.compactMap { asset -> CGImage? in
            guard let media = file.assetsMedia[asset.id] else { return nil }
            switch asset.kind {
            case .image:
                guard let src = CGImageSourceCreateWithData(media.data as CFData, nil)
                else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            case .video:
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("palette-\(asset.id).\(media.ext)")
                if !FileManager.default.fileExists(atPath: tmp.path) {
                    try? media.data.write(to: tmp)
                }
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: tmp))
                gen.maximumSize = CGSize(width: 320, height: 180)
                return try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600),
                                            actualTime: nil)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stylize into backdrop").font(.headline)
            if let preview {
                Image(decorative: preview, scale: 2)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
            } else {
                Button("Choose an image…") { importing = true }
                    .frame(maxWidth: .infinity, minHeight: 420)
                    .background(Color.primary.opacity(0.05))
            }
            if source != nil {
                TextField("Backdrop name", text: $name)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Pixels").font(.caption)
                    Slider(value: $gridWidth, in: 160...720, step: 40)
                    Text("\(Int(gridWidth))").font(.caption.monospacedDigit()).frame(width: 34)
                }
                HStack {
                    Text("Colors").font(.caption)
                    Slider(value: $colors, in: 8...48, step: 2)
                    Text("\(Int(colors))").font(.caption.monospacedDigit()).frame(width: 34)
                }
                HStack {
                    Text("Dither").font(.caption)
                    Slider(value: $dither, in: 0...0.16)
                }
                Toggle("Match show palette (learned from bank images)", isOn: $matchShow)
                    .font(.caption)
                    .disabled(bankImages.isEmpty)
                HStack {
                    Button("Different image…") { importing = true }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Cancel") { isPresented = false }
                    Button("Add to bank") { commit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview == nil)
                }
            } else {
                HStack { Spacer(); Button("Cancel") { isPresented = false } }
            }
        }
        .padding(16)
        .frame(minWidth: 1180, minHeight: 860)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.png, .jpeg, .heic, .gif, .webP, .tiff]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Read the bytes NOW — a file-backed CGImage decodes lazily,
            // after the security scope is gone, and comes out black.
            if let data = try? Data(contentsOf: url),
               let src = CGImageSourceCreateWithData(data as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                source = img
                name = url.deletingPathExtension().lastPathComponent
                stylePalette = nil
                restyle()
            }
        }
        .onChange(of: gridWidth) { _, _ in restyle() }
        .onChange(of: dither) { _, _ in restyle() }
        .onChange(of: colors) { _, _ in stylePalette = nil; restyle() }
        .onChange(of: matchShow) { _, _ in stylePalette = nil; restyle() }
    }

    private func restyle() {
        guard let source else { return }
        working = true
        let opts = PixelStyler.Options(gridWidth: Int(gridWidth), paletteSize: Int(colors),
                                       dither: dither, scale: 2)
        let refs = matchShow ? bankImages : []
        let cachedPalette = stylePalette
        let k = Int(colors)
        Task.detached(priority: .userInitiated) {
            let pal: [SIMD3<Float>]
            if let cachedPalette {
                pal = cachedPalette
            } else if !refs.isEmpty {
                pal = PixelStyler.palette(from: refs, size: k)
            } else {
                pal = PixelStyler.palette(from: [source], size: k)
            }
            let out = PixelStyler.stylize(source, palette: pal, options: opts)
            await MainActor.run {
                stylePalette = pal
                preview = out
                working = false
            }
        }
    }

    private func commit() {
        guard let preview else { return }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, preview, nil)
        CGImageDestinationFinalize(dest)
        _ = model.addAsset(data: data as Data, ext: "png", name: name)
        isPresented = false
    }
}

import SwiftUI
import ImageIO

/// The GIF backdrops bundled with the app (Resources/Backdrops). Clicking one
/// copies it into the document's asset bank so projects stay self-contained.
enum BuiltInBackdrops {
    /// The set a new scene opens on, so Live mode shows a room rather than an
    /// empty box. A still, not a GIF, so it never joins the gallery below.
    static var sunsetBar: URL? {
        Bundle.main.url(forResource: "Backdrops", withExtension: nil)?
            .appendingPathComponent("sunset-bar.png")
    }

    static let urls: [URL] = {
        guard let root = Bundle.main.url(forResource: "Backdrops", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "gif" }
            .sorted { displayName($0.lastPathComponent) < displayName($1.lastPathComponent) }
    }()

    /// "Banny-Stark no banny.gif" → "Banny Stark (no banny)".
    static func displayName(_ filename: String) -> String {
        var s = (filename as NSString).deletingPathExtension
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        var words = s.trimmingCharacters(in: .whitespaces).split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        if words.count >= 2, words.suffix(2).map({ $0.lowercased() }) == ["no", "banny"] {
            words.removeLast(2)
            return words.joined(separator: " ") + " (no banny)"
        }
        return words.joined(separator: " ")
    }

    /// First frame, decoded small for the gallery grid.
    static func thumbnail(for url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ] as CFDictionary)
    }
}

struct BackdropGallerySection: View {
    @Bindable var model: StudioModel
    var query = ""
    var expandedByDefault = false
    @State private var expanded = false
    @State private var customExpanded = true
    @State private var library = CustomBackgroundLibrary.shared
    @State private var creatingBackground = false
    @State private var managingBackgrounds = false

    private static let columns = [GridItem(.adaptive(minimum: 44), spacing: 4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Button {
                    creatingBackground = true
                } label: {
                    Label("Create Background", systemImage: "paintbrush.pointed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("create-background")

                Button {
                    managingBackgrounds = true
                } label: {
                    Label("My Backgrounds", systemImage: "photo.stack")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("manage-backgrounds")
            }

            if !library.backgrounds.isEmpty {
                DisclosureGroup(isExpanded: $customExpanded) {
                    LazyVGrid(columns: Self.columns, spacing: 4) {
                        ForEach(filteredCustomBackgrounds) { background in
                            CustomBackgroundThumbnail(
                                background: background,
                                animated: true
                            )
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .onTapGesture { model.addCustomBackground(background) }
                            .help(background.manifest.name)
                        }
                    }
                } label: {
                    Text("MY BACKGROUNDS (\(library.backgrounds.count))")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    LazyVGrid(columns: Self.columns, spacing: 4) {
                        ForEach(filteredURLs, id: \.self) { url in
                            BackdropThumb(url: url)
                                .onTapGesture { model.addBundledBackdrop(url: url) }
                                .help(BuiltInBackdrops.displayName(url.lastPathComponent))
                        }
                    }
                }
                .frame(maxHeight: 150)
            } label: {
                Text("BUILT-IN BACKDROPS (\(BuiltInBackdrops.urls.count))")
                    .font(.caption.bold()).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if expandedByDefault { expanded = true }
        }
        .sheet(isPresented: $creatingBackground) {
            CustomBackgroundStudio { background in
                model.addCustomBackground(background)
                creatingBackground = false
            }
        }
        .sheet(isPresented: $managingBackgrounds) {
            CustomBackgroundManager { background in
                model.addCustomBackground(background)
                managingBackgrounds = false
            }
        }
    }

    private var filteredURLs: [URL] {
        BuiltInBackdrops.urls.filter { url in
            query.isEmpty || BuiltInBackdrops.displayName(url.lastPathComponent)
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredCustomBackgrounds: [CustomBackgroundBundle] {
        library.backgrounds.filter {
            query.isEmpty
                || $0.manifest.name.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct BackdropThumb: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task {
            if image == nil {
                let url = url
                image = await Task.detached(priority: .utility) {
                    BuiltInBackdrops.thumbnail(for: url)
                }.value
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers
import Observation
import CoreGraphics
import ImageIO
import BannyRender
#if os(macOS)
import AppKit
#endif

struct CustomBackgroundManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = Self.currentFormatVersion
    var id: String
    var name: String
    var width: Int
    var height: Int
    var frameCount: Int
    var frameDelay: Double
    var createdAt: Date
    var modifiedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        width: Int,
        height: Int,
        frameCount: Int,
        frameDelay: Double,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.frameDelay = frameDelay
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

struct CustomBackgroundBundle: Codable, Equatable, Identifiable, Sendable {
    var manifest: CustomBackgroundManifest
    var gifData: Data
    var id: String { manifest.id }

    func validated() throws -> CustomBackgroundBundle {
        guard manifest.formatVersion == CustomBackgroundManifest.currentFormatVersion,
              UUID(uuidString: manifest.id) != nil,
              !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (64...2_400).contains(manifest.width),
              (64...2_400).contains(manifest.height),
              manifest.width * manifest.height <= 4_000_000,
              (1...5).contains(manifest.frameCount),
              (0.04...2).contains(manifest.frameDelay),
              let source = CGImageSourceCreateWithData(gifData as CFData, nil),
              CGImageSourceGetCount(source) == manifest.frameCount
        else { throw CustomBackgroundError.invalidBackground }
        return self
    }
}

enum CustomBackgroundError: LocalizedError {
    case invalidBackground
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidBackground:
            "The background must contain one to five GIF frames, with dimensions between 64 and 2,400 pixels."
        case .encodingFailed:
            "The animated GIF could not be encoded."
        }
    }
}

private enum CustomBackgroundStorage {
    static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Banny Studio", isDirectory: true)
            .appendingPathComponent("Backgrounds", isDirectory: true)
    }

    static func loadAll() -> [CustomBackgroundBundle] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "bannybackground",
                  let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(
                    CustomBackgroundBundle.self,
                    from: data
                  )
            else { return nil }
            return try? decoded.validated()
        }
    }

    static func write(_ bundle: CustomBackgroundBundle) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(bundle.validated()).write(
            to: directory.appendingPathComponent(
                "\(bundle.manifest.id.lowercased()).bannybackground"
            ),
            options: [.atomic]
        )
    }

    static func remove(id: String) throws {
        let url = directory.appendingPathComponent(
            "\(id.lowercased()).bannybackground"
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor
@Observable
final class CustomBackgroundLibrary {
    static let shared = CustomBackgroundLibrary()
    private(set) var backgrounds: [CustomBackgroundBundle]

    private init() {
        backgrounds = CustomBackgroundStorage.loadAll()
        sort()
    }

    @discardableResult
    func save(_ proposed: CustomBackgroundBundle) throws -> CustomBackgroundBundle {
        var bundle = proposed
        bundle.manifest.name = bundle.manifest.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        bundle.manifest.modifiedAt = Date()
        bundle = try bundle.validated()
        try CustomBackgroundStorage.write(bundle)
        if let index = backgrounds.firstIndex(where: { $0.id == bundle.id }) {
            backgrounds[index] = bundle
        } else {
            backgrounds.append(bundle)
        }
        sort()
        return bundle
    }

    @discardableResult
    func importGIF(data: Data, name: String) throws -> CustomBackgroundBundle {
        let decoded = try CustomBackgroundGIF.decode(data: data)
        let bundle = CustomBackgroundBundle(
            manifest: CustomBackgroundManifest(
                name: uniqueName(name),
                width: decoded.frames[0].width,
                height: decoded.frames[0].height,
                frameCount: decoded.frames.count,
                frameDelay: decoded.delay
            ),
            gifData: try CustomBackgroundGIF.encode(
                frames: decoded.frames,
                delay: decoded.delay
            )
        )
        return try save(bundle)
    }

    func delete(id: String) throws {
        try CustomBackgroundStorage.remove(id: id)
        backgrounds.removeAll { $0.id == id }
    }

    private func uniqueName(_ base: String) -> String {
        let clean = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = clean.isEmpty ? "Imported Background" : clean
        let names = Set(backgrounds.map { $0.manifest.name.lowercased() })
        if !names.contains(root.lowercased()) { return root }
        var number = 2
        while names.contains("\(root) \(number)".lowercased()) { number += 1 }
        return "\(root) \(number)"
    }

    private func sort() {
        backgrounds.sort {
            $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name)
                == .orderedAscending
        }
    }
}

private enum CustomBackgroundGIF {
    struct Decoded {
        let frames: [CGImage]
        let delay: Double
    }

    static func decode(data: Data) throws -> Decoded {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CustomBackgroundError.invalidBackground
        }
        let count = min(5, CGImageSourceGetCount(source))
        guard count > 0 else { throw CustomBackgroundError.invalidBackground }
        var frames: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                continue
            }
            frames.append(image)
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                index,
                nil
            ) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary]
                as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double
                ?? 0.2
            delays.append(max(0.04, min(2, delay)))
        }
        guard let first = frames.first else {
            throw CustomBackgroundError.invalidBackground
        }
        let normalized = frames.map {
            ($0.width == first.width && $0.height == first.height)
                ? $0
                : resample($0, width: first.width, height: first.height)
        }
        return Decoded(
            frames: normalized,
            delay: delays.isEmpty
                ? 0.2
                : delays.reduce(0, +) / Double(delays.count)
        )
    }

    static func encode(frames: [CGImage], delay: Double) throws -> Data {
        guard !frames.isEmpty, frames.count <= 5 else {
            throw CustomBackgroundError.encodingFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else { throw CustomBackgroundError.encodingFailed }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: max(0.04, min(2, delay)),
                    kCGImagePropertyGIFUnclampedDelayTime: max(0.04, min(2, delay)),
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CustomBackgroundError.encodingFailed
        }
        return data as Data
    }

    static func resample(_ image: CGImage, width: Int, height: Int) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

private enum BackgroundPaintTool: String, CaseIterable, Identifiable {
    case brush, eraser, fill, pick
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .fill: "paintbucket"
        case .pick: "eyedropper"
        }
    }
}

@Observable
private final class BackgroundFrameCanvas {
    var width: Int
    var height: Int
    var frames: [[UInt32]]
    var activeFrame = 0
    var tool = BackgroundPaintTool.brush
    var paintColor: UInt32 = 0x222222ff
    var brushSize = 12
    private var lastPoint: (x: Int, y: Int)?
    @ObservationIgnored private var imageCache: [CGImage?] = []

    init(width: Int = 1_200, height: Int = 1_200, images: [CGImage] = []) {
        self.width = width
        self.height = height
        if images.isEmpty {
            self.frames = [[UInt32](repeating: 0xffffffff, count: width * height)]
        } else {
            self.frames = images.prefix(5).map {
                Self.pixels(from: $0, width: width, height: height)
            }
        }
        self.imageCache = [CGImage?](repeating: nil, count: self.frames.count)
    }

    convenience init(bundle: CustomBackgroundBundle) {
        let decoded = try? CustomBackgroundGIF.decode(data: bundle.gifData)
        self.init(
            width: bundle.manifest.width,
            height: bundle.manifest.height,
            images: decoded?.frames ?? []
        )
    }

    var currentPixels: [UInt32] { frames[activeFrame] }
    var currentImage: CGImage? { image(frame: activeFrame) }

    func image(frame index: Int) -> CGImage? {
        guard frames.indices.contains(index) else { return nil }
        if let cached = imageCache[index] { return cached }
        let rendered = Self.image(pixels: frames[index], width: width, height: height)
        imageCache[index] = rendered
        return rendered
    }

    func beginStroke() { lastPoint = nil }
    func endStroke() { lastPoint = nil }

    func useTool(x: Int, y: Int) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        switch tool {
        case .brush, .eraser:
            let from = lastPoint ?? (x, y)
            let steps = max(abs(x - from.x), abs(y - from.y), 1)
            for step in 0...steps {
                let amount = Double(step) / Double(steps)
                stamp(
                    x: Int((Double(from.x) + Double(x - from.x) * amount).rounded()),
                    y: Int((Double(from.y) + Double(y - from.y) * amount).rounded()),
                    color: tool == .eraser ? 0x00000000 : paintColor
                )
            }
            lastPoint = (x, y)
            imageCache[activeFrame] = nil
        case .fill:
            fill(at: y * width + x)
            imageCache[activeFrame] = nil
            tool = .brush
        case .pick:
            let color = frames[activeFrame][y * width + x]
            if color & 0xff > 0 { paintColor = color | 0xff }
            tool = .brush
        }
    }

    func addBlankFrame() {
        guard frames.count < 5 else { return }
        frames.append([UInt32](repeating: 0xffffffff, count: width * height))
        imageCache.append(nil)
        activeFrame = frames.count - 1
    }

    func duplicateFrame() {
        guard frames.count < 5 else { return }
        frames.insert(frames[activeFrame], at: activeFrame + 1)
        imageCache.insert(nil, at: activeFrame + 1)
        activeFrame += 1
    }

    func deleteFrame() {
        guard frames.count > 1 else { return }
        frames.remove(at: activeFrame)
        imageCache.remove(at: activeFrame)
        activeFrame = min(activeFrame, frames.count - 1)
    }

    func replace(with images: [CGImage], width: Int, height: Int) {
        self.width = width
        self.height = height
        frames = images.prefix(5).map {
            Self.pixels(from: $0, width: width, height: height)
        }
        if frames.isEmpty {
            frames = [[UInt32](repeating: 0xffffffff, count: width * height)]
        }
        imageCache = [CGImage?](repeating: nil, count: frames.count)
        activeFrame = 0
    }

    func resize(width newWidth: Int, height newHeight: Int) {
        let images = frames.compactMap {
            Self.image(pixels: $0, width: width, height: height)
        }
        replace(with: images, width: newWidth, height: newHeight)
    }

    func images() -> [CGImage] {
        frames.indices.compactMap { image(frame: $0) }
    }

    private func stamp(x: Int, y: Int, color: UInt32) {
        let radius = max(0, brushSize - 1) / 2
        for py in max(0, y - radius)...min(height - 1, y + radius) {
            for px in max(0, x - radius)...min(width - 1, x + radius) {
                frames[activeFrame][py * width + px] = color
            }
        }
    }

    private func fill(at start: Int) {
        let target = frames[activeFrame][start]
        guard target != paintColor else { return }
        var queue = [start]
        var cursor = 0
        frames[activeFrame][start] = paintColor
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width
            let y = index / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let next = ny * width + nx
                if frames[activeFrame][next] == target {
                    frames[activeFrame][next] = paintColor
                    queue.append(next)
                }
            }
        }
    }

    static func image(
        pixels: [UInt32],
        width: Int,
        height: Int
    ) -> CGImage? {
        guard pixels.count == width * height else { return nil }
        var bytes = pixels.flatMap { value in
            [
                UInt8((value >> 24) & 0xff),
                UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff),
                UInt8(value & 0xff),
            ]
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    private static func pixels(from image: CGImage, width: Int, height: Int) -> [UInt32] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [UInt32](repeating: 0xffffffff, count: width * height) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map {
            UInt32(bytes[$0]) << 24
                | UInt32(bytes[$0 + 1]) << 16
                | UInt32(bytes[$0 + 2]) << 8
                | UInt32(bytes[$0 + 3])
        }
    }
}

private extension Color {
    init(backgroundRGBA value: UInt32) {
        self.init(
            red: Double((value >> 24) & 0xff) / 255,
            green: Double((value >> 16) & 0xff) / 255,
            blue: Double((value >> 8) & 0xff) / 255,
            opacity: 1
        )
    }

    var backgroundRGBA: UInt32 {
        #if os(macOS)
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return UInt32((color.redComponent * 255).rounded()) << 24
            | UInt32((color.greenComponent * 255).rounded()) << 16
            | UInt32((color.blueComponent * 255).rounded()) << 8
            | 0xff
        #else
        return 0x222222ff
        #endif
    }
}

struct CustomBackgroundStudio: View {
    let original: CustomBackgroundBundle?
    let onSave: (CustomBackgroundBundle) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var canvas: BackgroundFrameCanvas
    @State private var name: String
    @State private var frameDelay: Double
    @State private var playing = true
    @State private var importingFrames = false
    @State private var resizeTarget: (width: Int, height: Int)?
    @State private var customWidth: Int
    @State private var customHeight: Int
    @State private var errorMessage: String?
    private let id: String
    private let createdAt: Date

    init(
        editing: CustomBackgroundBundle? = nil,
        onSave: @escaping (CustomBackgroundBundle) -> Void
    ) {
        original = editing
        self.onSave = onSave
        let width = editing?.manifest.width ?? 1_200
        let height = editing?.manifest.height ?? 1_200
        _canvas = State(initialValue: editing.map(BackgroundFrameCanvas.init(bundle:))
            ?? BackgroundFrameCanvas(width: width, height: height))
        _name = State(initialValue: editing?.manifest.name ?? "")
        _frameDelay = State(initialValue: editing?.manifest.frameDelay ?? 0.2)
        _customWidth = State(initialValue: width)
        _customHeight = State(initialValue: height)
        id = editing?.manifest.id ?? UUID().uuidString.lowercased()
        createdAt = editing?.manifest.createdAt ?? Date()
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                controls.frame(width: 250)
                Divider()
                VStack(spacing: 0) {
                    BackgroundPaintSurface(canvas: canvas)
                        .padding(16)
                    Divider()
                    frameStrip
                        .padding(12)
                }
                Divider()
                previewPanel.frame(width: 270)
            }
            .navigationTitle(original == nil ? "Create Background" : "Edit Background")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("background-save")
                }
            }
        }
        .frame(minWidth: 1_080, minHeight: 720)
        .fileImporter(
            isPresented: $importingFrames,
            allowedContentTypes: [.image]
        ) { result in
            if case .success(let url) = result { importFrames(from: url) }
        }
        .confirmationDialog(
            "Resize every frame?",
            isPresented: Binding(
                get: { resizeTarget != nil },
                set: { if !$0 { resizeTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let target = resizeTarget {
                Button("Resize to \(target.width)×\(target.height)") {
                    canvas.resize(width: target.width, height: target.height)
                    customWidth = target.width
                    customHeight = target.height
                    resizeTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { resizeTarget = nil }
        } message: {
            Text("All frames keep their composition and are resampled to the new canvas.")
        }
        .alert("Background error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Background name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("background-name")

                VStack(alignment: .leading, spacing: 7) {
                    Text("CANVAS").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("\(canvas.width) × \(canvas.height)")
                        .font(.caption.monospacedDigit().bold())
                    HStack {
                        Button("Square") { requestResize(1_200, 1_200) }
                        Button("Landscape") { requestResize(1_920, 1_080) }
                    }
                    HStack {
                        Button("Portrait") { requestResize(1_080, 1_920) }
                        Button("Pixel art") { requestResize(400, 400) }
                    }
                    .buttonStyle(.bordered)
                    Text("Bundled Banny GIFs are 1200×1200. Other aspect ratios remain native when used as a backdrop.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("W", value: $customWidth, format: .number)
                        Text("×")
                        TextField("H", value: $customHeight, format: .number)
                        Button("Set") {
                            requestResize(customWidth, customHeight)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("TOOLS").font(.caption.bold()).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                        ForEach(BackgroundPaintTool.allCases) { tool in
                            Button {
                                canvas.tool = tool
                            } label: {
                                Label(tool.title, systemImage: tool.icon)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(canvas.tool == tool ? .orange : nil)
                        }
                    }
                    ColorPicker(
                        "Paint color",
                        selection: Binding(
                            get: { Color(backgroundRGBA: canvas.paintColor) },
                            set: { canvas.paintColor = $0.backgroundRGBA }
                        ),
                        supportsOpacity: false
                    )
                    Stepper("Brush: \(canvas.brushSize) px", value: $canvas.brushSize, in: 1...128)
                }

                Divider()
                Button {
                    importingFrames = true
                } label: {
                    Label("Import Image or GIF Frames…", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                Text("A GIF imports its first five frames. A still image becomes one editable frame.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private var frameStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(canvas.frames.indices), id: \.self) { index in
                Button {
                    canvas.activeFrame = index
                    playing = false
                } label: {
                    VStack(spacing: 3) {
                        if let image = canvas.image(frame: index) {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fit)
                        }
                        Text("\(index + 1)").font(.caption2.bold())
                    }
                    .frame(width: 88, height: 70)
                    .padding(4)
                    .background(
                        canvas.activeFrame == index
                            ? Color.orange.opacity(0.18)
                            : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(
                        canvas.activeFrame == index ? Color.orange : Color.clear,
                        lineWidth: 2
                    ))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { canvas.addBlankFrame() } label: {
                Label("Blank", systemImage: "plus")
            }
            .disabled(canvas.frames.count >= 5)
            .accessibilityIdentifier("background-add-frame")
            Button { canvas.duplicateFrame() } label: {
                Label("Duplicate", systemImage: "square.on.square")
            }
            .disabled(canvas.frames.count >= 5)
            .accessibilityIdentifier("background-duplicate-frame")
            Button(role: .destructive) { canvas.deleteFrame() } label: {
                Image(systemName: "trash")
            }
            .disabled(canvas.frames.count <= 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background-frame-strip")
    }

    private var previewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("GIF PREVIEW").font(.caption.bold()).foregroundStyle(.secondary)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { timeline in
                    let frameIndex = playing
                        ? Int(timeline.date.timeIntervalSinceReferenceDate / frameDelay)
                            % canvas.frames.count
                        : canvas.activeFrame
                    if let image = canvas.image(frame: frameIndex) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .background(Color.black.opacity(0.15))
                    }
                }
                .aspectRatio(CGFloat(canvas.width) / CGFloat(canvas.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    playing.toggle()
                } label: {
                    Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("background-preview-play")

                LabeledContent("Frame time") {
                    Text("\(frameDelay, format: .number.precision(.fractionLength(2))) s")
                        .monospacedDigit()
                }
                Slider(value: $frameDelay, in: 0.04...2, step: 0.01)
                    .accessibilityIdentifier("background-frame-delay")
                Text("\(canvas.frames.count) of 5 frames • loops forever")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Text("Saved backgrounds stay local. Adding one to a show embeds its GIF so the project remains portable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private func requestResize(_ width: Int, _ height: Int) {
        guard (64...2_400).contains(width),
              (64...2_400).contains(height),
              width * height <= 4_000_000
        else {
            errorMessage = "Use dimensions from 64 to 2,400 pixels, with no more than four million pixels per frame."
            return
        }
        guard width != canvas.width || height != canvas.height else { return }
        resizeTarget = (width, height)
    }

    private func importFrames(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try CustomBackgroundGIF.decode(data: data)
            let width = decoded.frames[0].width
            let height = decoded.frames[0].height
            guard width * height <= 4_000_000, width <= 2_400, height <= 2_400,
                  width >= 64, height >= 64 else {
                throw CustomBackgroundError.invalidBackground
            }
            canvas.replace(with: decoded.frames, width: width, height: height)
            customWidth = width
            customHeight = height
            frameDelay = decoded.delay
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            let gifData = try CustomBackgroundGIF.encode(
                frames: canvas.images(),
                delay: frameDelay
            )
            let saved = try CustomBackgroundLibrary.shared.save(
                CustomBackgroundBundle(
                    manifest: CustomBackgroundManifest(
                        id: id,
                        name: name,
                        width: canvas.width,
                        height: canvas.height,
                        frameCount: canvas.frames.count,
                        frameDelay: frameDelay,
                        createdAt: createdAt
                    ),
                    gifData: gifData
                )
            )
            onSave(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BackgroundPaintSurface: View {
    @Bindable var canvas: BackgroundFrameCanvas

    var body: some View {
        GeometryReader { geometry in
            let aspect = CGFloat(canvas.width) / CGFloat(canvas.height)
            let available = geometry.size
            let size = available.width / max(1, available.height) > aspect
                ? CGSize(width: available.height * aspect, height: available.height)
                : CGSize(width: available.width, height: available.width / aspect)
            let origin = CGPoint(
                x: (available.width - size.width) / 2,
                y: (available.height - size.height) / 2
            )
            ZStack {
                Color.white
                if let image = canvas.currentImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                }
            }
            .frame(width: size.width, height: size.height)
            .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            .overlay {
                Rectangle()
                    .stroke(Color.primary.opacity(0.35), lineWidth: 1)
                    .frame(width: size.width, height: size.height)
                    .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = Int(value.location.x / size.width
                            * CGFloat(canvas.width))
                        let y = Int(value.location.y / size.height
                            * CGFloat(canvas.height))
                        if x >= 0, y >= 0, x < canvas.width, y < canvas.height {
                            if value.translation == .zero { canvas.beginStroke() }
                            canvas.useTool(x: x, y: y)
                        }
                    }
                    .onEnded { _ in canvas.endStroke() }
            )
        }
        .background(Color.primary.opacity(0.025))
        .accessibilityElement()
        .accessibilityLabel("Background paint canvas")
        .accessibilityIdentifier("background-paint-canvas")
    }
}

struct CustomBackgroundGIFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.gif] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct CustomBackgroundManager: View {
    var onChoose: ((CustomBackgroundBundle) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var library = CustomBackgroundLibrary.shared
    @State private var creating = false
    @State private var editing: CustomBackgroundBundle?
    @State private var importing = false
    @State private var exporting: CustomBackgroundGIFDocument?
    @State private var exportName = "background.gif"
    @State private var deleting: CustomBackgroundBundle?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.backgrounds.isEmpty {
                    ContentUnavailableView {
                        Label("No Custom Backgrounds", systemImage: "photo.stack")
                    } description: {
                        Text("Create an animated background or import a GIF with up to five frames.")
                    } actions: {
                        Button("Create Background") { creating = true }
                            .buttonStyle(.borderedProminent)
                        Button("Import GIF") { importing = true }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(library.backgrounds) { background in
                                backgroundCard(background)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("My Backgrounds")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { importing = true } label: {
                        Label("Import GIF", systemImage: "square.and.arrow.down")
                    }
                    Button { creating = true } label: {
                        Label("Create Background", systemImage: "plus")
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .sheet(isPresented: $creating) {
            CustomBackgroundStudio { saved in
                onChoose?(saved)
                creating = false
            }
        }
        .sheet(item: $editing) { background in
            CustomBackgroundStudio(editing: background) { saved in
                onChoose?(saved)
                editing = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.gif]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let saved = try library.importGIF(
                    data: Data(contentsOf: url),
                    name: url.deletingPathExtension().lastPathComponent
                )
                onChoose?(saved)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exporting != nil },
                set: { if !$0 { exporting = nil } }
            ),
            document: exporting,
            contentType: .gif,
            defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
            exporting = nil
        }
        .confirmationDialog(
            "Delete \(deleting?.manifest.name ?? "background")?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let deleting else { return }
                do {
                    try library.delete(id: deleting.id)
                    self.deleting = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Shows already using it keep their embedded GIF.")
        }
        .alert("Background error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func backgroundCard(_ background: CustomBackgroundBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CustomBackgroundThumbnail(background: background, animated: true)
                .frame(maxWidth: .infinity)
                .aspectRatio(
                    CGFloat(background.manifest.width)
                        / CGFloat(background.manifest.height),
                    contentMode: .fit
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(background.manifest.name)
                .font(.subheadline.bold())
                .lineLimit(1)
            Text("\(background.manifest.width)×\(background.manifest.height) • \(background.manifest.frameCount) frame\(background.manifest.frameCount == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                if onChoose != nil {
                    Button("Use") {
                        onChoose?(background)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                Menu {
                    Button("Edit") { editing = background }
                    Button("Export GIF…") {
                        exportName = sanitizedFilename(background.manifest.name)
                        exporting = CustomBackgroundGIFDocument(data: background.gifData)
                    }
                    Divider()
                    Button("Delete", role: .destructive) { deleting = background }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sanitizedFilename(_ name: String) -> String {
        let stem = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(stem.isEmpty ? "background" : stem).gif"
    }
}

struct CustomBackgroundThumbnail: View {
    let background: CustomBackgroundBundle
    var animated = false
    @State private var sequence: GifSequence?
    @State private var still: CGImage?

    init(background: CustomBackgroundBundle, animated: Bool = false) {
        self.background = background
        self.animated = animated
        let decoded = GifSequence(data: background.gifData)
        _sequence = State(initialValue: decoded)
        if let source = CGImageSourceCreateWithData(background.gifData as CFData, nil) {
            _still = State(initialValue: CGImageSourceCreateImageAtIndex(source, 0, nil))
        } else {
            _still = State(initialValue: nil)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            let image = sequence.map {
                $0.frame(at: timeline.date.timeIntervalSinceReferenceDate)
            } ?? still
            ZStack {
                Color.black.opacity(0.12)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                }
            }
        }
    }

}

import SwiftUI
import UniformTypeIdentifiers
import Observation
import CoreGraphics
import ImageIO
import BannyCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension UTType {
    static let bannyOutfit = UTType(
        exportedAs: "com.banny.outfit",
        conformingTo: .json
    )
}

struct CustomOutfitFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.bannyOutfit, .json, .data] }
    var outfit: CustomOutfitBundle

    init(outfit: CustomOutfitBundle) {
        self.outfit = outfit
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        outfit = try JSONDecoder().decode(CustomOutfitBundle.self, from: data).validated()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(outfit.validated()))
    }
}

private enum PixelTool: String, CaseIterable, Identifiable {
    case brush
    case eraser
    case fill
    case eyedropper
    case section

    var id: String { rawValue }
    var title: String {
        switch self {
        case .brush: "Brush"
        case .eraser: "Eraser"
        case .fill: "Fill"
        case .eyedropper: "Pick"
        case .section: "Section"
        }
    }
    var icon: String {
        switch self {
        case .brush: "paintbrush.pointed"
        case .eraser: "eraser"
        case .fill: "paintbucket"
        case .eyedropper: "eyedropper"
        case .section: "square.dashed"
        }
    }
}

@MainActor
@Observable
private final class PixelOutfitCanvas {
    private(set) var gridSize: Int
    var pixels: [UInt32]
    var tool: PixelTool = .brush
    var brushSize = 1
    var paintColor: UInt32 = 0x111111ff
    private(set) var selectedPixels: Set<Int> = []

    private var undoStack: [[UInt32]] = []
    private var redoStack: [[UInt32]] = []
    private var strokeStart: [UInt32]?
    private var lastPaintPoint: (x: Int, y: Int)?

    init(gridSize: Int = 100, pixels: [UInt32]? = nil) {
        self.gridSize = gridSize
        let expected = gridSize * gridSize
        self.pixels = pixels?.count == expected
            ? pixels!
            : [UInt32](repeating: 0, count: expected)
    }

    convenience init(outfit: CustomOutfitBundle?) {
        guard let outfit,
              let image = Self.decodePNG(outfit.pngData),
              let pixels = Self.rgbaPixels(image: image, size: outfit.manifest.gridSize)
        else {
            self.init()
            return
        }
        self.init(gridSize: outfit.manifest.gridSize, pixels: pixels)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { !pixels.contains { ($0 & 0xff) > 0 } }
    var hasSelection: Bool { !selectedPixels.isEmpty }

    func beginStroke() {
        guard strokeStart == nil else { return }
        strokeStart = pixels
        lastPaintPoint = nil
    }

    func endStroke() {
        guard let start = strokeStart else { return }
        if start != pixels {
            undoStack.append(start)
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        strokeStart = nil
        lastPaintPoint = nil
    }

    func useTool(atX x: Int, y: Int, addingToSelection: Bool = false) {
        guard x >= 0, y >= 0, x < gridSize, y < gridSize else {
            if tool == .section {
                selectedPixels.removeAll()
            }
            return
        }
        switch tool {
        case .brush:
            if lastPaintPoint == nil { selectedPixels.removeAll() }
            paintLine(toX: x, y: y, color: paintColor)
        case .eraser:
            if lastPaintPoint == nil { selectedPixels.removeAll() }
            paintLine(toX: x, y: y, color: 0)
        case .fill:
            if lastPaintPoint == nil { selectedPixels.removeAll() }
            floodFill(x: x, y: y, replacement: paintColor)
        case .eyedropper:
            let sampled = pixels[y * gridSize + x]
            if sampled & 0xff > 0 { paintColor = sampled }
            selectedPixels.removeAll()
            tool = .brush
        case .section:
            guard lastPaintPoint == nil else { return }
            lastPaintPoint = (x, y)
            selectConnectedSection(
                x: x,
                y: y,
                addingToSelection: addingToSelection
            )
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(pixels)
        pixels = previous
        selectedPixels.removeAll()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pixels)
        pixels = next
        selectedPixels.removeAll()
    }

    func clear() {
        guard !isEmpty else { return }
        undoStack.append(pixels)
        redoStack.removeAll()
        pixels = [UInt32](repeating: 0, count: gridSize * gridSize)
        selectedPixels.removeAll()
    }

    func resize(to newSize: Int) {
        guard newSize != gridSize,
              CustomOutfitManifest.supportedGridSizes.contains(newSize) else { return }
        let old = pixels
        let oldSize = gridSize
        var resized = [UInt32](repeating: 0, count: newSize * newSize)
        for y in 0..<newSize {
            for x in 0..<newSize {
                let ox = min(oldSize - 1, x * oldSize / newSize)
                let oy = min(oldSize - 1, y * oldSize / newSize)
                resized[y * newSize + x] = old[oy * oldSize + ox]
            }
        }
        gridSize = newSize
        pixels = resized
        undoStack.removeAll()
        redoStack.removeAll()
        selectedPixels.removeAll()
    }

    func replacePixels(_ replacement: [UInt32]) {
        guard replacement.count == pixels.count else { return }
        undoStack.append(pixels)
        redoStack.removeAll()
        pixels = replacement
        selectedPixels.removeAll()
    }

    func replaceFromImage(_ image: CGImage, gridSize newSize: Int) {
        guard CustomOutfitManifest.supportedGridSizes.contains(newSize),
              let replacement = Self.rgbaPixels(image: image, size: newSize)
        else { return }
        if gridSize == newSize {
            replacePixels(replacement)
        } else {
            undoStack.removeAll()
            redoStack.removeAll()
            gridSize = newSize
            pixels = replacement
            selectedPixels.removeAll()
        }
    }

    func recolorSelection() {
        guard !selectedPixels.isEmpty else { return }
        undoStack.append(pixels)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        for index in selectedPixels where pixels.indices.contains(index) {
            pixels[index] = paintColor
        }
    }

    func clearSelection() {
        selectedPixels.removeAll()
    }

    func image() -> CGImage? {
        Self.image(pixels: pixels, size: gridSize)
    }

    func pngData() -> Data? {
        guard let image = image() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func paintLine(toX x: Int, y: Int, color: UInt32) {
        if let lastPaintPoint {
            let dx = x - lastPaintPoint.x
            let dy = y - lastPaintPoint.y
            let steps = max(abs(dx), abs(dy), 1)
            for step in 0...steps {
                paintDisc(
                    x: lastPaintPoint.x + dx * step / steps,
                    y: lastPaintPoint.y + dy * step / steps,
                    color: color
                )
            }
        } else {
            paintDisc(x: x, y: y, color: color)
        }
        lastPaintPoint = (x, y)
    }

    private func paintDisc(x: Int, y: Int, color: UInt32) {
        let radius = max(0, brushSize - 1)
        for yy in (y - radius)...(y + radius) {
            for xx in (x - radius)...(x + radius) {
                guard xx >= 0, yy >= 0, xx < gridSize, yy < gridSize else { continue }
                if radius == 0 || (xx - x) * (xx - x) + (yy - y) * (yy - y)
                    <= radius * radius + radius {
                    pixels[yy * gridSize + xx] = color
                }
            }
        }
    }

    private func floodFill(x: Int, y: Int, replacement: UInt32) {
        let target = pixels[y * gridSize + x]
        guard target != replacement else { return }
        var queue = [y * gridSize + x]
        var cursor = 0
        pixels[queue[0]] = replacement
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let px = index % gridSize
            let py = index / gridSize
            for (nx, ny) in [(px - 1, py), (px + 1, py), (px, py - 1), (px, py + 1)] {
                guard nx >= 0, ny >= 0, nx < gridSize, ny < gridSize else { continue }
                let next = ny * gridSize + nx
                if pixels[next] == target {
                    pixels[next] = replacement
                    queue.append(next)
                }
            }
        }
    }

    private func selectConnectedSection(
        x: Int,
        y: Int,
        addingToSelection: Bool
    ) {
        let start = y * gridSize + x
        guard pixels[start] & 0xff > 0 else {
            selectedPixels.removeAll()
            return
        }
        let section = PixelSection.connectedIndices(
            in: pixels,
            width: gridSize,
            startingAt: start
        )
        if addingToSelection {
            selectedPixels.formUnion(section)
        } else {
            selectedPixels = section
        }
    }

    static func image(pixels: [UInt32], size: Int) -> CGImage? {
        guard pixels.count == size * size else { return nil }
        var bytes = [UInt8](repeating: 0, count: pixels.count * 4)
        for (index, value) in pixels.enumerated() {
            bytes[index * 4] = UInt8((value >> 24) & 0xff)
            bytes[index * 4 + 1] = UInt8((value >> 16) & 0xff)
            bytes[index * 4 + 2] = UInt8((value >> 8) & 0xff)
            bytes[index * 4 + 3] = UInt8(value & 0xff)
        }
        return bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
    }

    static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func rgbaPixels(image: CGImage, size: Int) -> [UInt32]? {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &bytes,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            UInt32(bytes[index]) << 24
                | UInt32(bytes[index + 1]) << 16
                | UInt32(bytes[index + 2]) << 8
                | UInt32(bytes[index + 3])
        }
    }
}

private enum OutfitDraftStore {
    static var url: URL {
        CustomOutfitStorage.directory
            .deletingLastPathComponent()
            .appendingPathComponent("outfit-draft.bannyoutfit")
    }

    static func load() -> CustomOutfitBundle? {
        guard let data = try? Data(contentsOf: url),
              let bundle = try? JSONDecoder().decode(CustomOutfitBundle.self, from: data),
              let valid = try? bundle.validated()
        else { return nil }
        return valid
    }

    static func save(_ bundle: CustomOutfitBundle) {
        guard let data = try? JSONEncoder().encode(bundle) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct OutfitStudio: View {
    let bodyStyle: Body
    private let original: CustomOutfitBundle?
    let onSave: (CustomOutfitBundle) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var canvas: PixelOutfitCanvas
    @State private var name: String
    @State private var category: OutfitCategory
    @State private var createdAt: Date
    @State private var id: String
    @State private var starterImage: CGImage?
    @State private var choosingSourceOutfit = false
    @State private var showMannequin = true
    @State private var pendingGridSize: Int?
    @State private var errorMessage: String?
    @State private var draftTask: Task<Void, Never>?

    init(
        bodyStyle: Body,
        editing: CustomOutfitBundle? = nil,
        onSave: @escaping (CustomOutfitBundle) -> Void
    ) {
        self.bodyStyle = bodyStyle
        let source = editing ?? OutfitDraftStore.load()
        self.original = editing
        self.onSave = onSave
        _canvas = State(initialValue: PixelOutfitCanvas(outfit: source))
        _name = State(initialValue: source?.manifest.name ?? "My Outfit")
        _category = State(initialValue: source?.manifest.category ?? .suitTop)
        _createdAt = State(initialValue: source?.manifest.createdAt ?? Date())
        _id = State(initialValue: source?.manifest.id ?? UUID().uuidString.lowercased())
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width >= 820 {
                    HStack(spacing: 0) {
                        controls
                            .frame(width: 260)
                        Divider()
                        designArea
                        Divider()
                        previewPanel
                            .frame(width: 260)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            controls
                            designArea.frame(height: 520)
                            previewPanel
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(original == nil ? "Create Outfit" : "Edit Outfit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || canvas.isEmpty)
                        .accessibilityIdentifier("outfit-save")
                }
            }
        }
        .frame(minWidth: editorMinimumWidth, minHeight: editorMinimumHeight)
        .onChange(of: canvas.pixels) { _, _ in scheduleDraftSave() }
        .onChange(of: name) { _, _ in scheduleDraftSave() }
        .onChange(of: category) { _, _ in scheduleDraftSave() }
        .confirmationDialog(
            "Change pixel grid?",
            isPresented: Binding(
                get: { pendingGridSize != nil },
                set: { if !$0 { pendingGridSize = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingGridSize {
                Button("Resample to \(pendingGridSize)×\(pendingGridSize)") {
                    canvas.resize(to: pendingGridSize)
                    self.pendingGridSize = nil
                    scheduleDraftSave()
                }
            }
            Button("Cancel", role: .cancel) { pendingGridSize = nil }
        } message: {
            Text("The artwork keeps its size, but changing fidelity can add or remove pixel detail.")
        }
        .sheet(
            isPresented: $choosingSourceOutfit
        ) {
            OutfitCopyPicker(
                bodyStyle: bodyStyle,
                restrictedCategory: original?.manifest.category
            ) { source in
                copyExistingOutfit(source)
                choosingSourceOutfit = false
            }
        }
        .sheet(
            isPresented: Binding(
                get: { starterImage != nil },
                set: { if !$0 { starterImage = nil } }
            )
        ) {
            if let starterImage {
                OutfitImageStarter(
                    image: starterImage,
                    gridSize: canvas.gridSize,
                    bodyStyle: bodyStyle,
                    category: category
                ) { pixels in
                    canvas.replacePixels(pixels)
                    self.starterImage = nil
                }
            }
        }
        .alert(
            "Outfit could not be saved",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Outfit name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("outfit-name")

                VStack(alignment: .leading, spacing: 6) {
                    Text("CATEGORY").font(.caption.bold()).foregroundStyle(.secondary)
                    Picker("Category", selection: $category) {
                        ForEach(OutfitCategory.allCases) { category in
                            Label(category.displayName, systemImage: category.iconName)
                                .tag(category)
                        }
                    }
                    .disabled(original != nil)
                    .accessibilityIdentifier("outfit-category")
                    if original != nil {
                        Text("Category is fixed after saving so projects keep the same layer behavior.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(category.layerExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if category == .head || category == .suit {
                        Label(
                            category == .head
                                ? "Hides face, glasses, and head-top layers"
                                : "Hides Suit Top and Suit Bottom layers",
                            systemImage: "eye.slash"
                        )
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                    }
                }

                Button {
                    choosingSourceOutfit = true
                } label: {
                    Label("Copy Existing Outfit", systemImage: "square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("copy-existing-outfit")
                Text("Starts from its pixels as a new, independent outfit.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("PIXEL GRID").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Menu("\(canvas.gridSize)×\(canvas.gridSize)") {
                            ForEach(CustomOutfitManifest.supportedGridSizes, id: \.self) { size in
                                Button("\(size)×\(size)") {
                                    if size != canvas.gridSize { pendingGridSize = size }
                                }
                            }
                        }
                    }
                    Text(canvas.gridSize == 100
                         ? "Standard fidelity used by most Banny outfits."
                         : canvas.gridSize < 100
                            ? "Chunkier pixels and simpler silhouettes."
                            : "Higher fidelity for fine detail.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("Show mannequin guide", isOn: $showMannequin)
                        .font(.caption)
                        .accessibilityIdentifier("outfit-show-mannequin")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("TOOLS").font(.caption.bold()).foregroundStyle(.secondary)
                    LazyVGrid(columns: [
                        GridItem(.flexible()), GridItem(.flexible())
                    ], spacing: 6) {
                        ForEach(PixelTool.allCases) { tool in
                            Button {
                                canvas.tool = tool
                            } label: {
                                Label(tool.title, systemImage: tool.icon)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(canvas.tool == tool ? .orange : nil)
                            .accessibilityIdentifier(
                                tool == .section ? "outfit-section-tool" : "outfit-\(tool.rawValue)-tool"
                            )
                        }
                    }
                    ColorPicker("Paint color", selection: colorBinding, supportsOpacity: false)
                    Stepper("Brush size: \(canvas.brushSize)",
                            value: $canvas.brushSize, in: 1...8)
                    if canvas.hasSelection {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "\(canvas.selectedPixels.count) matching pixels selected",
                                systemImage: "square.dashed"
                            )
                            .font(.caption.bold())
                            Button {
                                canvas.recolorSelection()
                            } label: {
                                Label("Recolor Section", systemImage: "paintpalette")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .accessibilityIdentifier("outfit-recolor-section")
                            Button("Clear Selection") {
                                canvas.clearSelection()
                            }
                            .font(.caption)
                            Text("Shift-click another colored section to add it. Click transparent space to deselect all.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 7))
                    } else if canvas.tool == .section {
                        Text("Click a colored pixel to select its connected section. Shift-click to add more.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button { canvas.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!canvas.canUndo)
                    Button { canvas.redo() } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!canvas.canRedo)
                }
                .labelStyle(.iconOnly)

                Divider()
                Button {
                    if let image = pastedImage() {
                        starterImage = image
                    } else {
                        errorMessage = "Copy an image to the clipboard, then try Paste Image again."
                    }
                } label: {
                    Label("Paste Image as Starter", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button(role: .destructive) { canvas.clear() } label: {
                    Label("Clear Canvas", systemImage: "trash")
                }
                .disabled(canvas.isEmpty)
            }
            .padding(16)
        }
    }

    private var editorMinimumWidth: CGFloat {
        #if os(macOS)
        1_040
        #else
        320
        #endif
    }

    private var editorMinimumHeight: CGFloat {
        #if os(macOS)
        700
        #else
        560
        #endif
    }

    private var designArea: some View {
        VStack(spacing: 8) {
            Text("Paint directly on the mannequin")
                .font(.caption)
                .foregroundStyle(.secondary)
            PixelDesignSurface(
                canvas: canvas,
                bodyStyle: bodyStyle,
                showMannequin: showMannequin
            )
                .aspectRatio(1, contentMode: .fit)
                .padding(16)
                .accessibilityIdentifier("outfit-pixel-canvas")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.025))
    }

    private var previewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("LIVE PREVIEW").font(.caption.bold()).foregroundStyle(.secondary)
                OutfitMannequinPreview(
                    part: canvas.image(),
                    bodyStyle: bodyStyle,
                    category: category
                )
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("The preview uses the app’s actual wardrobe layer order. Transparent pixels reveal the Banny underneath.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Label("Saved locally on this device", systemImage: "internaldrive")
                    .font(.caption)
                Label("Used outfits travel inside shared projects", systemImage: "shippingbox")
                    .font(.caption)
                Text("Contract-compatible category does not publish or mint this artwork on-chain.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(rgba: canvas.paintColor) },
            set: { canvas.paintColor = $0.rgbaValue }
        )
    }

    private func makeBundle() -> CustomOutfitBundle? {
        guard let pngData = canvas.pngData() else { return nil }
        return CustomOutfitBundle(
            manifest: CustomOutfitManifest(
                id: id,
                name: name,
                category: category,
                gridSize: canvas.gridSize,
                createdAt: createdAt,
                modifiedAt: Date()
            ),
            pngData: pngData
        )
    }

    private func save() {
        guard let proposed = makeBundle() else {
            errorMessage = "The pixel canvas could not be encoded."
            return
        }
        do {
            let saved = try CustomOutfitLibrary.shared.save(proposed)
            OutfitDraftStore.clear()
            onSave(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyExistingOutfit(_ source: OutfitCopySource) {
        category = source.category
        canvas.replaceFromImage(source.image, gridSize: source.preferredGridSize)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty || cleanName == "My Outfit" {
            name = "\(source.label) Remix"
        }
        scheduleDraftSave()
    }

    private func scheduleDraftSave() {
        draftTask?.cancel()
        draftTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let bundle = makeBundle() else { return }
            OutfitDraftStore.save(bundle)
        }
    }
}

private struct OutfitCopySource {
    let label: String
    let category: OutfitCategory
    let image: CGImage
    let preferredGridSize: Int
}

private struct OutfitCopyPicker: View {
    private struct Choice: Identifiable {
        let name: String
        let label: String
        var id: String { name }
    }

    let bodyStyle: Body
    let restrictedCategory: OutfitCategory?
    let onChoose: (OutfitCopySource) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: OutfitCategory

    init(
        bodyStyle: Body,
        restrictedCategory: OutfitCategory?,
        onChoose: @escaping (OutfitCopySource) -> Void
    ) {
        self.bodyStyle = bodyStyle
        self.restrictedCategory = restrictedCategory
        self.onChoose = onChoose
        _category = State(initialValue: restrictedCategory ?? .suitTop)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CATEGORY")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Picker("Category", selection: $category) {
                            ForEach(OutfitCategory.allCases) { category in
                                Label(category.displayName, systemImage: category.iconName)
                                    .tag(category)
                            }
                        }
                        .disabled(restrictedCategory != nil)
                    }
                    Text(category.layerExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding([.horizontal, .top])

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 130), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(choices) { choice in
                            Button {
                                choose(choice)
                            } label: {
                                VStack(spacing: 7) {
                                    if let image = SharedAssets.catalog.outfitThumbnail(
                                        choice.name,
                                        body: bodyStyle
                                    ) {
                                        Image(decorative: image, scale: 1)
                                            .resizable()
                                            .interpolation(.none)
                                            .scaledToFit()
                                            .frame(maxWidth: .infinity)
                                            .aspectRatio(1, contentMode: .fit)
                                            .background(
                                                Color(red: 0.98, green: 0.97, blue: 0.92),
                                                in: RoundedRectangle(cornerRadius: 6)
                                            )
                                    }
                                    Text(choice.label)
                                        .font(.caption.bold())
                                        .lineLimit(2)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .background(Color.primary.opacity(0.055),
                                        in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        }
                    }
                    .padding()
                }

                Text("The copy is independent. Built-in palette variants use the current Banny body appearance as their starting pixels.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom])
            }
            .navigationTitle("Copy Existing Outfit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("outfit-copy-picker")
        .frame(minWidth: pickerMinimumWidth, minHeight: pickerMinimumHeight)
    }

    private var choices: [Choice] {
        SharedAssets.catalog.outfits(inSlot: category.rawValue)
            .map { Choice(name: $0.name, label: $0.label) }
    }

    private func choose(_ choice: Choice) {
        guard let image = SharedAssets.catalog.outfitImage(
            choice.name,
            body: bodyStyle
        ) else { return }
        let gridSize = CustomOutfitLibrary.shared
            .bundle(named: choice.name)?
            .manifest.gridSize ?? 100
        onChoose(OutfitCopySource(
            label: choice.label,
            category: category,
            image: image,
            preferredGridSize: gridSize
        ))
        dismiss()
    }

    private var pickerMinimumWidth: CGFloat {
        #if os(macOS)
        760
        #else
        320
        #endif
    }

    private var pickerMinimumHeight: CGFloat {
        #if os(macOS)
        620
        #else
        520
        #endif
    }
}

private struct PixelDesignSurface: View {
    @Bindable var canvas: PixelOutfitCanvas
    let bodyStyle: Body
    let showMannequin: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let origin = CGPoint(
                x: (geometry.size.width - side) / 2,
                y: (geometry.size.height - side) / 2
            )
            ZStack {
                Checkerboard()
                Canvas { context, size in
                    let box = CGRect(origin: .zero, size: size)
                    if showMannequin {
                        var ghost = context
                        ghost.opacity = 0.28
                        drawBasicMannequin(in: &ghost, box: box, bodyStyle: bodyStyle)
                    }
                    if let image = canvas.image() {
                        context.draw(
                            Image(decorative: image, scale: 1).interpolation(.none),
                            in: box
                        )
                    }
                    let cell = size.width / CGFloat(canvas.gridSize)
                    if !canvas.selectedPixels.isEmpty {
                        var selectionPath = Path()
                        for index in canvas.selectedPixels {
                            let x = index % canvas.gridSize
                            let y = index / canvas.gridSize
                            selectionPath.addRect(CGRect(
                                x: CGFloat(x) * cell,
                                y: CGFloat(y) * cell,
                                width: cell,
                                height: cell
                            ))
                        }
                        context.fill(
                            selectionPath,
                            with: .color(.orange.opacity(0.34))
                        )
                        if cell >= 2 {
                            context.stroke(
                                selectionPath,
                                with: .color(.white.opacity(0.68)),
                                lineWidth: 0.45
                            )
                        }
                    }
                    if cell >= 2.2 {
                        var path = Path()
                        for index in 0...canvas.gridSize {
                            let p = CGFloat(index) * cell
                            path.move(to: CGPoint(x: p, y: 0))
                            path.addLine(to: CGPoint(x: p, y: size.height))
                            path.move(to: CGPoint(x: 0, y: p))
                            path.addLine(to: CGPoint(x: size.width, y: p))
                        }
                        context.stroke(path, with: .color(.black.opacity(0.12)),
                                       lineWidth: 0.5)
                    }
                }
            }
            .frame(width: side, height: side)
            .position(x: origin.x + side / 2, y: origin.y + side / 2)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.35), lineWidth: 1)
                    .frame(width: side, height: side)
                    .position(x: origin.x + side / 2, y: origin.y + side / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        canvas.beginStroke()
                        let x = Int((value.location.x - origin.x) / side
                                    * CGFloat(canvas.gridSize))
                        let y = Int((value.location.y - origin.y) / side
                                    * CGFloat(canvas.gridSize))
                        canvas.useTool(
                            atX: x,
                            y: y,
                            addingToSelection: sectionSelectionIsAdditive
                        )
                    }
                    .onEnded { _ in canvas.endStroke() }
            )
        }
    }
}

private var sectionSelectionIsAdditive: Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.shift)
    #else
    false
    #endif
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 12
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(white: 0.92)))
            for y in stride(from: CGFloat(0), to: size.height, by: tile) {
                for x in stride(from: CGFloat(0), to: size.width, by: tile)
                where (Int(x / tile) + Int(y / tile)).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)),
                                 with: .color(Color(white: 0.82)))
                }
            }
        }
    }
}

private struct OutfitMannequinPreview: View {
    let part: CGImage?
    let bodyStyle: Body
    let category: OutfitCategory

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(red: 0.98, green: 0.97, blue: 0.92)))
            let box = CGRect(origin: .zero, size: size)
            func draw(_ image: CGImage?) {
                guard let image else { return }
                context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: box)
            }
            let catalog = SharedAssets.catalog
            if category == .backside { draw(part) }
            draw(catalog.bodyImage(bodyStyle))
            if category == .necklace {
                draw(part)
            } else {
                draw(catalog.necklaceImage(body: bodyStyle))
            }
            if category == .head {
                draw(part)
            } else {
                draw(catalog.eyesImage(option: "default", expression: .open, body: bodyStyle))
                if category == .glasses { draw(part) }
                draw(catalog.mouthImage(option: "default", state: .closed, body: bodyStyle))
                if category == .legs { draw(part) }
                if category == .suit { draw(part) }
                if category == .suitBottom { draw(part) }
                if category == .suitTop { draw(part) }
                if category == .headTop { draw(part) }
            }
            if category == .hand { draw(part) }
        }
    }
}

private func drawBasicMannequin(
    in context: inout GraphicsContext,
    box: CGRect,
    bodyStyle: Body
) {
    let catalog = SharedAssets.catalog
    func draw(_ image: CGImage?) {
        guard let image else { return }
        context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: box)
    }
    draw(catalog.bodyImage(bodyStyle))
    draw(catalog.necklaceImage(body: bodyStyle))
    draw(catalog.eyesImage(option: "default", expression: .open, body: bodyStyle))
    draw(catalog.mouthImage(option: "default", state: .closed, body: bodyStyle))
}

private struct OutfitImageStarter: View {
    let image: CGImage
    let gridSize: Int
    let bodyStyle: Body
    let category: OutfitCategory
    let apply: ([UInt32]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    @State private var offsetX = 0.0
    @State private var offsetY = 0.0
    @State private var paletteSize = 16
    @State private var alphaThreshold = 0.18
    @State private var dither = false

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                VStack {
                    StarterPlacementPreview(
                        image: image,
                        scale: scale,
                        offsetX: offsetX,
                        offsetY: offsetY,
                        bodyStyle: bodyStyle,
                        category: category
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Form {
                    Section("Placement") {
                        LabeledContent("Size") {
                            Slider(value: $scale, in: 0.1...3)
                        }
                        LabeledContent("Horizontal") {
                            Slider(value: $offsetX, in: -200...200)
                        }
                        LabeledContent("Vertical") {
                            Slider(value: $offsetY, in: -200...200)
                        }
                        Button("Reset Placement") {
                            scale = 1
                            offsetX = 0
                            offsetY = 0
                        }
                    }
                    Section("Pixel processing") {
                        Stepper("Palette: \(paletteSize) colors",
                                value: $paletteSize, in: 4...32, step: 4)
                        LabeledContent("Transparency") {
                            Slider(value: $alphaThreshold, in: 0...0.9)
                        }
                        Toggle("Ordered dithering", isOn: $dither)
                        Text("The image is reduced to the \(gridSize)×\(gridSize) outfit grid. You can edit every resulting pixel afterward.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 320)
            }
            .navigationTitle("Image Starter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make Pixel Starter") {
                        apply(OutfitImageProcessor.process(
                            image,
                            gridSize: gridSize,
                            scale: scale,
                            offsetX: offsetX,
                            offsetY: offsetY,
                            paletteSize: paletteSize,
                            alphaThreshold: alphaThreshold,
                            dither: dither
                        ))
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 600)
    }
}

private struct StarterPlacementPreview: View {
    let image: CGImage
    let scale: Double
    let offsetX: Double
    let offsetY: Double
    let bodyStyle: Body
    let category: OutfitCategory

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(red: 0.98, green: 0.97, blue: 0.92)))
            var ghost = context
            ghost.opacity = 0.22
            drawBasicMannequin(
                in: &ghost,
                box: CGRect(origin: .zero, size: size),
                bodyStyle: bodyStyle
            )
            let fit = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
            let width = CGFloat(image.width) * fit * scale
            let height = CGFloat(image.height) * fit * scale
            let rect = CGRect(
                x: (size.width - width) / 2 + CGFloat(offsetX) / 400 * size.width,
                y: (size.height - height) / 2 + CGFloat(offsetY) / 400 * size.height,
                width: width,
                height: height
            )
            context.draw(Image(decorative: image, scale: 1), in: rect)
        }
    }
}

private enum OutfitImageProcessor {
    static func process(
        _ image: CGImage,
        gridSize: Int,
        scale: Double,
        offsetX: Double,
        offsetY: Double,
        paletteSize: Int,
        alphaThreshold: Double,
        dither: Bool
    ) -> [UInt32] {
        let count = gridSize * gridSize
        var bytes = [UInt8](repeating: 0, count: count * 4)
        guard let context = CGContext(
            data: &bytes,
            width: gridSize,
            height: gridSize,
            bitsPerComponent: 8,
            bytesPerRow: gridSize * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [UInt32](repeating: 0, count: count) }
        context.interpolationQuality = .high
        let fit = min(CGFloat(gridSize) / CGFloat(image.width),
                      CGFloat(gridSize) / CGFloat(image.height))
        let width = CGFloat(image.width) * fit * scale
        let height = CGFloat(image.height) * fit * scale
        let rect = CGRect(
            x: (CGFloat(gridSize) - width) / 2 + CGFloat(offsetX) / 400 * CGFloat(gridSize),
            y: (CGFloat(gridSize) - height) / 2 + CGFloat(offsetY) / 400 * CGFloat(gridSize),
            width: width,
            height: height
        )
        context.draw(image, in: rect)

        let threshold = UInt8(max(0, min(255, Int(alphaThreshold * 255))))
        var samples: [(Double, Double, Double)] = []
        let strideBy = max(1, count / 8_000)
        for pixel in Swift.stride(from: 0, to: count, by: strideBy) {
            let index = pixel * 4
            if bytes[index + 3] > threshold {
                samples.append((Double(bytes[index]), Double(bytes[index + 1]),
                                Double(bytes[index + 2])))
            }
        }
        let palette = kMeans(samples, count: max(2, paletteSize))
        let bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        var output = [UInt32](repeating: 0, count: count)
        for pixel in 0..<count {
            let index = pixel * 4
            let alpha = bytes[index + 3]
            guard alpha > threshold else { continue }
            let x = pixel % gridSize
            let y = pixel / gridSize
            let adjustment = dither
                ? (Double(bayer[(y % 4) * 4 + (x % 4)]) / 15 - 0.5) * 26
                : 0
            let color = (
                min(255, max(0, Double(bytes[index]) + adjustment)),
                min(255, max(0, Double(bytes[index + 1]) + adjustment)),
                min(255, max(0, Double(bytes[index + 2]) + adjustment))
            )
            let nearest = palette.min {
                distance(color, $0) < distance(color, $1)
            } ?? color
            output[pixel] = UInt32(nearest.0.rounded()) << 24
                | UInt32(nearest.1.rounded()) << 16
                | UInt32(nearest.2.rounded()) << 8
                | 0xff
        }
        return output
    }

    private static func kMeans(
        _ samples: [(Double, Double, Double)],
        count requested: Int
    ) -> [(Double, Double, Double)] {
        guard !samples.isEmpty else { return [(0, 0, 0)] }
        let k = min(requested, samples.count)
        let sorted = samples.sorted {
            $0.0 * 0.299 + $0.1 * 0.587 + $0.2 * 0.114
                < $1.0 * 0.299 + $1.1 * 0.587 + $1.2 * 0.114
        }
        var centers = (0..<k).map {
            sorted[$0 * max(0, sorted.count - 1) / max(1, k - 1)]
        }
        for _ in 0..<8 {
            var sums = [(Double, Double, Double, Int)](
                repeating: (0, 0, 0, 0),
                count: k
            )
            for sample in samples {
                let best = centers.indices.min {
                    distance(sample, centers[$0]) < distance(sample, centers[$1])
                } ?? 0
                sums[best].0 += sample.0
                sums[best].1 += sample.1
                sums[best].2 += sample.2
                sums[best].3 += 1
            }
            for index in centers.indices where sums[index].3 > 0 {
                let n = Double(sums[index].3)
                centers[index] = (sums[index].0 / n, sums[index].1 / n,
                                  sums[index].2 / n)
            }
        }
        return centers
    }

    private static func distance(
        _ lhs: (Double, Double, Double),
        _ rhs: (Double, Double, Double)
    ) -> Double {
        let r = lhs.0 - rhs.0
        let g = lhs.1 - rhs.1
        let b = lhs.2 - rhs.2
        return r * r * 0.3 + g * g * 0.59 + b * b * 0.11
    }
}

private extension Color {
    init(rgba: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgba >> 24) & 0xff) / 255,
            green: Double((rgba >> 16) & 0xff) / 255,
            blue: Double((rgba >> 8) & 0xff) / 255,
            opacity: Double(rgba & 0xff) / 255
        )
    }

    var rgbaValue: UInt32 {
        #if os(macOS)
        let native = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let red = native.redComponent
        let green = native.greenComponent
        let blue = native.blueComponent
        let alpha = native.alphaComponent
        #else
        let native = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        native.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return UInt32(max(0, min(255, Int(red * 255)))) << 24
            | UInt32(max(0, min(255, Int(green * 255)))) << 16
            | UInt32(max(0, min(255, Int(blue * 255)))) << 8
            | UInt32(max(0, min(255, Int(alpha * 255))))
    }
}

private func pastedImage() -> CGImage? {
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    if let data = pasteboard.data(forType: .png),
       let source = CGImageSourceCreateWithData(data as CFData, nil) {
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    if let data = pasteboard.data(forType: .tiff),
       let source = CGImageSourceCreateWithData(data as CFData, nil) {
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    return nil
    #else
    return UIPasteboard.general.image?.cgImage
    #endif
}

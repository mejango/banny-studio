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
    var instruction: String {
        switch self {
        case .brush:
            "Click or drag to paint with the chosen color, opacity, and brush size."
        case .eraser:
            "Click or drag to remove pixels and reveal the layers underneath."
        case .fill:
            "Click a pixel to recolor its entire connected region."
        case .eyedropper:
            "Click a painted pixel to pick its color and opacity, then return to Brush."
        case .section:
            "Click or drag to select pixels; Shift adds and double-click selects a same-color region."
        }
    }
}

private struct PixelDoubleClickSnapshot {
    var pixels: [UInt32]
    var selection: Set<Int>
}

@MainActor
@Observable
private final class PixelOutfitCanvas {
    private(set) var gridSize: Int
    private(set) var frames: [[UInt32]]
    var activeFrame = 0 {
        didSet {
            undoStack.removeAll()
            redoStack.removeAll()
            selectedPixels.removeAll()
        }
    }
    var pixels: [UInt32] {
        get { frames[activeFrame] }
        set { frames[activeFrame] = newValue }
    }
    var tool: PixelTool = .brush
    var brushSize = 1
    var paintColor: UInt32 = 0x111111ff
    private(set) var selectedPixels: Set<Int> = []

    private var undoStack: [[UInt32]] = []
    private var redoStack: [[UInt32]] = []
    private var strokeStart: [UInt32]?
    private var lastPaintPoint: (x: Int, y: Int)?
    private var selectionBeforeRange: Set<Int> = []
    private struct PixelClipboard {
        var entries: [(x: Int, y: Int, color: UInt32)]
        var sourceOrigin: PixelGridPoint
        var width: Int
        var height: Int
    }
    private var selectionClipboard: PixelClipboard?
    private var selectionDragOriginal: [UInt32]?
    private var selectionDragSource: Set<Int> = []
    private var selectionDragCopies = false

    init(
        gridSize: Int = 100,
        pixels: [UInt32]? = nil,
        frames: [[UInt32]]? = nil
    ) {
        self.gridSize = gridSize
        let expected = gridSize * gridSize
        let validFrames = frames?.prefix(5).filter { $0.count == expected }
        if let validFrames, !validFrames.isEmpty {
            self.frames = Array(validFrames)
        } else {
            self.frames = [pixels?.count == expected
                ? pixels!
                : [UInt32](repeating: 0, count: expected)]
        }
    }

    convenience init(outfit: CustomOutfitBundle?) {
        guard let outfit else {
            self.init()
            return
        }
        let frames = outfit.frames.compactMap { data -> [UInt32]? in
            guard let image = Self.decodePNG(data) else { return nil }
            return Self.rgbaPixels(image: image, size: outfit.manifest.gridSize)
        }
        self.init(gridSize: outfit.manifest.gridSize, frames: frames)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canPasteSelection: Bool { selectionClipboard != nil }
    var isEmpty: Bool { frames.allSatisfy { !$0.contains { ($0 & 0xff) > 0 } } }
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
            selectPixel(atX: x, y: y, addingToSelection: addingToSelection)
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
        let oldSize = gridSize
        frames = frames.map { old in
            var resized = [UInt32](repeating: 0, count: newSize * newSize)
            for y in 0..<newSize {
                for x in 0..<newSize {
                    let ox = min(oldSize - 1, x * oldSize / newSize)
                    let oy = min(oldSize - 1, y * oldSize / newSize)
                    resized[y * newSize + x] = old[oy * oldSize + ox]
                }
            }
            return resized
        }
        gridSize = newSize
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

    func replacePixels(_ replacement: [UInt32], gridSize newSize: Int) {
        guard CustomOutfitManifest.supportedGridSizes.contains(newSize),
              replacement.count == newSize * newSize else { return }
        if gridSize == newSize {
            replacePixels(replacement)
        } else {
            undoStack.removeAll()
            redoStack.removeAll()
            gridSize = newSize
            frames = [replacement]
            activeFrame = 0
            selectedPixels.removeAll()
        }
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
            frames = [replacement]
            activeFrame = 0
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

    func beginRangeSelection(addingToSelection: Bool) {
        selectionBeforeRange = addingToSelection ? selectedPixels : []
    }

    func updateRangeSelection(
        fromX startX: Int,
        y startY: Int,
        toX endX: Int,
        y endY: Int
    ) {
        let minX = max(0, min(startX, endX))
        let maxX = min(gridSize - 1, max(startX, endX))
        let minY = max(0, min(startY, endY))
        let maxY = min(gridSize - 1, max(startY, endY))
        guard minX <= maxX, minY <= maxY else { return }
        var selection = selectionBeforeRange
        for y in minY...maxY {
            for x in minX...maxX {
                let index = y * gridSize + x
                if pixels[index] & 0xff > 0 { selection.insert(index) }
            }
        }
        selectedPixels = selection
    }

    func finishRangeSelection() {
        selectionBeforeRange.removeAll()
    }

    func selectConnected(atX x: Int, y: Int, addingToSelection: Bool) {
        guard x >= 0, y >= 0, x < gridSize, y < gridSize else {
            if !addingToSelection { selectedPixels.removeAll() }
            return
        }
        selectConnectedSection(
            x: x,
            y: y,
            addingToSelection: addingToSelection
        )
    }

    func selectPixel(atX x: Int, y: Int, addingToSelection: Bool) {
        guard x >= 0, y >= 0, x < gridSize, y < gridSize else {
            if !addingToSelection { selectedPixels.removeAll() }
            return
        }
        let index = y * gridSize + x
        guard pixels[index] & 0xff > 0 else {
            if !addingToSelection { selectedPixels.removeAll() }
            return
        }
        if addingToSelection {
            selectedPixels.insert(index)
        } else {
            selectedPixels = [index]
        }
    }

    func selectionContains(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < gridSize, y < gridSize else { return false }
        return selectedPixels.contains(y * gridSize + x)
    }

    @discardableResult
    func copySelection() -> Bool {
        guard !selectedPixels.isEmpty else { return false }
        let xs = selectedPixels.map { $0 % gridSize }
        let ys = selectedPixels.map { $0 / gridSize }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return false }
        selectionClipboard = PixelClipboard(
            entries: selectedPixels.sorted().map { index in
                (index % gridSize - minX, index / gridSize - minY, pixels[index])
            },
            sourceOrigin: PixelGridPoint(x: minX, y: minY),
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        return true
    }

    @discardableResult
    func pasteSelection() -> Bool {
        guard let clipboard = selectionClipboard else { return false }
        var origin = PixelGridPoint(
            x: clipboard.sourceOrigin.x + 1,
            y: clipboard.sourceOrigin.y + 1
        )
        if origin.x + clipboard.width > gridSize {
            origin = PixelGridPoint(x: clipboard.sourceOrigin.x, y: origin.y)
        }
        if origin.y + clipboard.height > gridSize {
            origin = PixelGridPoint(x: origin.x, y: clipboard.sourceOrigin.y)
        }
        let before = pixels
        var pasted: Set<Int> = []
        for entry in clipboard.entries {
            let x = origin.x + entry.x
            let y = origin.y + entry.y
            guard x >= 0, y >= 0, x < gridSize, y < gridSize else { continue }
            let index = y * gridSize + x
            pixels[index] = entry.color
            pasted.insert(index)
        }
        guard pixels != before else {
            selectedPixels = pasted
            return !pasted.isEmpty
        }
        pushUndo(before)
        selectedPixels = pasted
        return !pasted.isEmpty
    }

    func beginSelectionDrag(copying: Bool) {
        guard !selectedPixels.isEmpty, selectionDragOriginal == nil else { return }
        selectionDragOriginal = pixels
        selectionDragSource = selectedPixels
        selectionDragCopies = copying
    }

    func updateSelectionDrag(dx proposedDX: Int, dy proposedDY: Int) {
        guard let original = selectionDragOriginal, !selectionDragSource.isEmpty else { return }
        let xs = selectionDragSource.map { $0 % gridSize }
        let ys = selectionDragSource.map { $0 / gridSize }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return }
        let dx = min(gridSize - 1 - maxX, max(-minX, proposedDX))
        let dy = min(gridSize - 1 - maxY, max(-minY, proposedDY))
        let sourceValues = selectionDragSource.map { ($0, original[$0]) }
        var next = original
        if !selectionDragCopies {
            for (source, _) in sourceValues { next[source] = 0 }
        }
        var destination: Set<Int> = []
        for (source, color) in sourceValues {
            let x = source % gridSize + dx
            let y = source / gridSize + dy
            let index = y * gridSize + x
            next[index] = color
            destination.insert(index)
        }
        pixels = next
        selectedPixels = destination
    }

    func finishSelectionDrag() {
        guard let original = selectionDragOriginal else { return }
        if pixels != original { pushUndo(original) }
        selectionDragOriginal = nil
        selectionDragSource.removeAll()
        selectionDragCopies = false
    }

    /// A macOS double-click begins as an ordinary first click. Restore the
    /// pixels from before that first click and discard only that provisional
    /// stroke before selecting, so selection never changes the artwork.
    func selectConnectedAfterDoubleClick(
        atX x: Int,
        y: Int,
        restoring snapshot: PixelDoubleClickSnapshot,
        addingToSelection: Bool
    ) {
        if snapshot.pixels.count == pixels.count, pixels != snapshot.pixels {
            if undoStack.last == snapshot.pixels { undoStack.removeLast() }
            pixels = snapshot.pixels
            redoStack.removeAll()
        }
        if addingToSelection { selectedPixels = snapshot.selection }
        strokeStart = nil
        lastPaintPoint = nil
        selectConnected(atX: x, y: y, addingToSelection: addingToSelection)
    }

    func moveSelection(dx: Int, dy: Int) {
        guard !selectedPixels.isEmpty, dx != 0 || dy != 0 else { return }
        let moves = selectedPixels.map { source -> (source: Int, destination: Int)? in
            let x = source % gridSize + dx
            let y = source / gridSize + dy
            guard x >= 0, y >= 0, x < gridSize, y < gridSize else { return nil }
            return (source, y * gridSize + x)
        }
        guard moves.allSatisfy({ $0 != nil }) else { return }
        let resolved = moves.compactMap { $0 }
        let before = pixels
        for move in resolved { pixels[move.source] = 0 }
        for move in resolved { pixels[move.destination] = before[move.source] }
        pushUndo(before)
        selectedPixels = Set(resolved.map(\.destination))
    }

    func clearSelection() {
        selectedPixels.removeAll()
    }

    func image() -> CGImage? {
        Self.image(pixels: pixels, size: gridSize)
    }

    func image(frame index: Int) -> CGImage? {
        guard frames.indices.contains(index) else { return nil }
        return Self.image(pixels: frames[index], size: gridSize)
    }

    func addBlankFrame() {
        guard frames.count < 5 else { return }
        frames.append([UInt32](repeating: 0, count: gridSize * gridSize))
        activeFrame = frames.count - 1
    }

    func duplicateFrame() {
        guard frames.count < 5 else { return }
        frames.insert(pixels, at: activeFrame + 1)
        activeFrame += 1
    }

    func deleteFrame() {
        guard frames.count > 1 else { return }
        frames.remove(at: activeFrame)
        activeFrame = min(activeFrame, frames.count - 1)
        undoStack.removeAll()
        redoStack.removeAll()
        selectedPixels.removeAll()
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

    func allPNGData() -> [Data]? {
        var result: [Data] = []
        for index in frames.indices {
            guard let image = image(frame: index) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            result.append(data as Data)
        }
        return result
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

    private func pushUndo(_ snapshot: [UInt32]) {
        undoStack.append(snapshot)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    static func image(pixels: [UInt32], size: Int) -> CGImage? {
        guard pixels.count == size * size else { return nil }
        var bytes = [UInt8](repeating: 0, count: pixels.count * 4)
        for (index, value) in pixels.enumerated() {
            let alpha = UInt32(value & 0xff)
            // PixelOutfitCanvas stores straight RGBA so the chosen paint color
            // is stable as opacity changes. Core Graphics expects premultiplied
            // channels for this bitmap layout.
            bytes[index * 4] = UInt8((((value >> 24) & 0xff) * alpha + 127) / 255)
            bytes[index * 4 + 1] = UInt8((((value >> 16) & 0xff) * alpha + 127) / 255)
            bytes[index * 4 + 2] = UInt8((((value >> 8) & 0xff) * alpha + 127) / 255)
            bytes[index * 4 + 3] = UInt8(alpha)
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
            let alpha = UInt32(bytes[index + 3])
            guard alpha > 0 else { return 0 }
            // CGContext returns premultiplied channels; convert back to the
            // straight RGBA representation used by the paint tools.
            let red = min(255, (UInt32(bytes[index]) * 255 + alpha / 2) / alpha)
            let green = min(255, (UInt32(bytes[index + 1]) * 255 + alpha / 2) / alpha)
            let blue = min(255, (UInt32(bytes[index + 2]) * 255 + alpha / 2) / alpha)
            return red << 24 | green << 16 | blue << 8 | alpha
        }
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
    @State private var mannequinBodyStyle: Body
    @State private var mannequinOutfits: [OutfitCategory: String] = [:]
    @State private var frameDelay: Double
    @State private var previewPlaying = true
    @State private var canvasZoom: CGFloat = 1
    @State private var canvasZoomGestureStart: CGFloat?
    @State private var pendingGridSize: Int?
    @State private var errorMessage: String?
    @FocusState private var canvasHasKeyboardFocus: Bool

    init(
        bodyStyle: Body,
        editing: CustomOutfitBundle? = nil,
        onSave: @escaping (CustomOutfitBundle) -> Void
    ) {
        self.bodyStyle = bodyStyle
        let source = editing
        self.original = editing
        self.onSave = onSave
        _canvas = State(initialValue: PixelOutfitCanvas(outfit: source))
        _name = State(initialValue: source?.manifest.name ?? "")
        _category = State(initialValue: source?.manifest.category ?? .suitTop)
        _mannequinBodyStyle = State(initialValue: bodyStyle)
        _frameDelay = State(initialValue: source?.frameDelay ?? 0.2)
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
                bodyStyle: mannequinBodyStyle,
                initialCategory: category,
                restrictedCategory: original?.manifest.category
            ) { source, pixels in
                copyExistingOutfit(source, pixels: pixels)
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
                    bodyStyle: mannequinBodyStyle,
                    category: category,
                    mannequinOutfits: mannequinOutfits
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
        .onChange(of: category) { _, newCategory in
            mannequinOutfits = mannequinOutfits.filter {
                !outfitCategoriesConflict($0.key, newCategory)
            }
        }
        #if os(macOS)
        .background(
            OutfitEditorShortcutCapture(
                undo: { canvas.undo() },
                redo: { canvas.redo() },
                copy: { canvas.copySelection() },
                paste: { canvas.pasteSelection() }
            )
        )
        #endif
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
                    Picker("Mannequin body", selection: $mannequinBodyStyle) {
                        ForEach(BannyCore.Body.allCases, id: \.self) { body in
                            Text(body.rawValue.capitalized).tag(body)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("outfit-mannequin-body")

                    if !previewWardrobeCategories.isEmpty {
                        DisclosureGroup("Other mannequin outfits") {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Add compatible layers to check how this outfit works with a complete look. Contract-conflicting categories are unavailable.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(previewWardrobeCategories) { previewCategory in
                                    Picker(
                                        previewCategory.displayName,
                                        selection: mannequinOutfitBinding(for: previewCategory)
                                    ) {
                                        Text("None").tag("")
                                        ForEach(
                                            previewOutfitChoices(for: previewCategory),
                                            id: \.name
                                        ) { choice in
                                            Text(choice.label).tag(choice.name)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.caption)
                        .accessibilityIdentifier("outfit-mannequin-wardrobe")
                    }
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
                            .buttonStyle(.borderedProminent)
                            .tint(canvas.tool == tool
                                  ? .orange
                                  : Color.secondary.opacity(0.35))
                            .foregroundStyle(canvas.tool == tool ? .black : .primary)
                            .accessibilityAddTraits(canvas.tool == tool ? .isSelected : [])
                            .accessibilityIdentifier(
                                tool == .section ? "outfit-section-tool" : "outfit-\(tool.rawValue)-tool"
                            )
                        }
                    }
                    Text(canvas.tool.instruction)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("outfit-tool-instruction")
                    ColorPicker("Paint color", selection: colorBinding, supportsOpacity: true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Opacity")
                            Spacer()
                            Text("\(paintOpacityPercent)%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: paintOpacityBinding, in: 0...1, step: 0.01)
                            .accessibilityLabel("Paint opacity")
                            .accessibilityValue("\(paintOpacityPercent) percent")
                            .accessibilityIdentifier("outfit-paint-opacity")
                    }
                    Stepper("Brush size: \(canvas.brushSize)",
                            value: $canvas.brushSize, in: 1...8)
                    if canvas.hasSelection {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "\(canvas.selectedPixels.count) pixels selected",
                                systemImage: "square.dashed"
                            )
                            .font(.caption.bold())
                            .accessibilityIdentifier("outfit-selection-count")
                            Button {
                                canvas.recolorSelection()
                            } label: {
                                Label("Recolor Section", systemImage: "paintpalette")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .accessibilityIdentifier("outfit-recolor-section")
                            HStack {
                                Button {
                                    canvas.copySelection()
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .accessibilityIdentifier("outfit-copy-pixels")
                                Button {
                                    canvas.pasteSelection()
                                } label: {
                                    Label("Paste", systemImage: "doc.on.clipboard")
                                }
                                .disabled(!canvas.canPasteSelection)
                                .accessibilityIdentifier("outfit-paste-pixels")
                            }
                            .buttonStyle(.bordered)
                            Button("Clear Selection") {
                                canvas.clearSelection()
                            }
                            .font(.caption)
                            Text("Shift-click or Shift-drag adds pixels. Drag selected pixels to move; Command-drag copies. Use ⌘C and ⌘P (or ⌘V) to copy and paste.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 7))
                    } else if canvas.tool == .section {
                        Text("Click a pixel or drag across a range. Shift adds to the selection; double-click selects a connected same-color region.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Double-click any painted pixel to select its whole connected same-color region.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button { canvas.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!canvas.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityIdentifier("outfit-undo")
                    Button { canvas.redo() } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!canvas.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .accessibilityIdentifier("outfit-redo")
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
                .accessibilityIdentifier("outfit-clear-canvas")
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
        GeometryReader { geometry in
            let fittedSide = max(
                160,
                min(geometry.size.width - 32, geometry.size.height - 70)
            )

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Paint directly on the mannequin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        canvasZoom = max(0.5, canvasZoom / 1.5)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .disabled(canvasZoom <= 0.5)
                    .accessibilityLabel("Zoom out")
                    .accessibilityIdentifier("outfit-zoom-out")

                    Text("\(Int((canvasZoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 42)
                        .accessibilityIdentifier("outfit-zoom-level")

                    Button {
                        canvasZoom = min(8, canvasZoom * 1.5)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .disabled(canvasZoom >= 8)
                    .accessibilityLabel("Zoom in")
                    .accessibilityIdentifier("outfit-zoom-in")

                    Button("Fit") {
                        canvasZoom = 1
                    }
                    .font(.caption)
                    .disabled(abs(canvasZoom - 1) < 0.001)
                    .accessibilityIdentifier("outfit-zoom-fit")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ScrollView([.horizontal, .vertical]) {
                    PixelDesignSurface(
                        canvas: canvas,
                        bodyStyle: mannequinBodyStyle,
                        category: category,
                        mannequinOutfits: mannequinOutfits,
                        showMannequin: showMannequin,
                        onInteraction: { canvasHasKeyboardFocus = true }
                    )
                    .focusable()
                    .focused($canvasHasKeyboardFocus)
                    .onKeyPress(.leftArrow) {
                        guard canvas.hasSelection else { return .ignored }
                        canvas.moveSelection(dx: -1, dy: 0)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        guard canvas.hasSelection else { return .ignored }
                        canvas.moveSelection(dx: 1, dy: 0)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard canvas.hasSelection else { return .ignored }
                        canvas.moveSelection(dx: 0, dy: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard canvas.hasSelection else { return .ignored }
                        canvas.moveSelection(dx: 0, dy: 1)
                        return .handled
                    }
                    .frame(
                        width: fittedSide * canvasZoom,
                        height: fittedSide * canvasZoom
                    )
                    .padding(16)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Outfit pixel canvas")
                    .accessibilityIdentifier("outfit-pixel-canvas")
                }
                .defaultScrollAnchor(.center)
                .scrollIndicators(.visible)
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { magnification in
                            if canvasZoomGestureStart == nil {
                                canvasZoomGestureStart = canvasZoom
                            }
                            canvasZoom = min(
                                8,
                                max(
                                    0.5,
                                    (canvasZoomGestureStart ?? canvasZoom)
                                        * magnification
                                )
                            )
                        }
                        .onEnded { _ in
                            canvasZoomGestureStart = nil
                        }
                )
                .help("Pinch to zoom. Scroll to move around the enlarged canvas.")
                Divider()
                outfitFrameStrip
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.025))
    }

    private var previewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("LIVE PREVIEW").font(.caption.bold()).foregroundStyle(.secondary)
                TimelineView(.animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: !previewPlaying
                )) { timeline in
                    let index = previewPlaying
                        ? Int(timeline.date.timeIntervalSinceReferenceDate / frameDelay)
                            % canvas.frames.count
                        : canvas.activeFrame
                    OutfitMannequinPreview(
                        part: canvas.image(frame: index),
                        bodyStyle: mannequinBodyStyle,
                        category: category,
                        mannequinOutfits: mannequinOutfits
                    )
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Button {
                    previewPlaying.toggle()
                } label: {
                    Label(
                        previewPlaying ? "Pause animation" : "Play animation",
                        systemImage: previewPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                LabeledContent("Frame time") {
                    Text("\(frameDelay, format: .number.precision(.fractionLength(2))) s")
                        .monospacedDigit()
                }
                Slider(value: $frameDelay, in: 0.04...2, step: 0.01)
                    .accessibilityIdentifier("outfit-frame-delay")
                Text("\(canvas.frames.count) of 5 frames • loops while worn")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    private var paintOpacityBinding: Binding<Double> {
        Binding(
            get: { Double(canvas.paintColor & 0xff) / 255 },
            set: { opacity in
                let alpha = UInt32(max(0, min(255, Int((opacity * 255).rounded()))))
                canvas.paintColor = (canvas.paintColor & 0xffffff00) | alpha
            }
        )
    }

    private var paintOpacityPercent: Int {
        Int((paintOpacityBinding.wrappedValue * 100).rounded())
    }

    private var outfitFrameStrip: some View {
        HStack(spacing: 7) {
            ForEach(Array(canvas.frames.indices), id: \.self) { index in
                Button {
                    canvas.activeFrame = index
                    previewPlaying = false
                } label: {
                    VStack(spacing: 2) {
                        if let image = canvas.image(frame: index) {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        Text("\(index + 1)").font(.caption2.bold())
                    }
                    .frame(width: 54, height: 54)
                    .padding(3)
                    .background(
                        canvas.activeFrame == index
                            ? Color.orange.opacity(0.18)
                            : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(
                        canvas.activeFrame == index ? Color.orange : Color.clear,
                        lineWidth: 2
                    ))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            Button { canvas.addBlankFrame() } label: {
                Label("Blank frame", systemImage: "plus")
            }
            .disabled(canvas.frames.count >= 5)
            Button { canvas.duplicateFrame() } label: {
                Label("Duplicate frame", systemImage: "square.on.square")
            }
            .disabled(canvas.frames.count >= 5)
            Button(role: .destructive) { canvas.deleteFrame() } label: {
                Image(systemName: "trash")
            }
            .disabled(canvas.frames.count <= 1)
        }
        .labelStyle(.iconOnly)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outfit-frame-strip")
    }

    private var previewWardrobeCategories: [OutfitCategory] {
        OutfitCategory.allCases.filter { candidate in
            candidate != category
                && !outfitCategoriesConflict(candidate, category)
                && !previewOutfitChoices(for: candidate).isEmpty
        }
    }

    private func previewOutfitChoices(
        for previewCategory: OutfitCategory
    ) -> [(name: String, label: String)] {
        let catalog = SharedAssets.catalog
        var choices = catalog.outfits(inSlot: previewCategory.rawValue)
        let names: [String]
        switch previewCategory {
        case .eyes: names = catalog.summary().eyes.filter { $0 != "default" }
        case .mouth: names = catalog.summary().mouths.filter { $0 != "default" }
        default: names = []
        }
        choices += names.map {
            ($0, $0.replacingOccurrences(of: "-", with: " ").capitalized)
        }
        return choices.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private func mannequinOutfitBinding(
        for previewCategory: OutfitCategory
    ) -> Binding<String> {
        Binding(
            get: { mannequinOutfits[previewCategory] ?? "" },
            set: { name in
                if name.isEmpty {
                    mannequinOutfits.removeValue(forKey: previewCategory)
                } else {
                    mannequinOutfits = mannequinOutfits.filter {
                        !outfitCategoriesConflict($0.key, previewCategory)
                    }
                    mannequinOutfits[previewCategory] = name
                }
            }
        )
    }

    private func makeBundle() -> CustomOutfitBundle? {
        guard let frames = canvas.allPNGData(), let pngData = frames.first else { return nil }
        return CustomOutfitBundle(
            manifest: CustomOutfitManifest(
                id: id,
                name: name,
                category: category,
                gridSize: canvas.gridSize,
                frameDelay: frameDelay,
                createdAt: createdAt,
                modifiedAt: Date()
            ),
            pngData: pngData,
            framePNGData: frames.count > 1 ? frames : nil
        )
    }

    private func save() {
        guard let proposed = makeBundle() else {
            errorMessage = "The pixel canvas could not be encoded."
            return
        }
        do {
            let saved = try CustomOutfitLibrary.shared.save(proposed)
            onSave(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyExistingOutfit(
        _ source: OutfitCopySource,
        pixels: [UInt32]
    ) {
        category = source.category
        canvas.replacePixels(pixels, gridSize: source.preferredGridSize)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty || cleanName == "My Outfit" {
            name = "\(source.label) Remix"
        }
    }
}

private struct OutfitCopySource: Identifiable {
    let id = UUID()
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
    let onChoose: (OutfitCopySource, [UInt32]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: OutfitCategory
    @State private var sourceToPlace: OutfitCopySource?

    init(
        bodyStyle: Body,
        initialCategory: OutfitCategory,
        restrictedCategory: OutfitCategory?,
        onChoose: @escaping (OutfitCopySource, [UInt32]) -> Void
    ) {
        self.bodyStyle = bodyStyle
        self.restrictedCategory = restrictedCategory
        self.onChoose = onChoose
        _category = State(initialValue: restrictedCategory ?? initialCategory)
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
                                    if let image = choiceThumbnail(choice) {
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
        .sheet(item: $sourceToPlace) { source in
            OutfitImageStarter(
                image: source.image,
                gridSize: source.preferredGridSize,
                bodyStyle: bodyStyle,
                category: source.category,
                preserveSourcePixels: true
            ) { pixels in
                onChoose(source, pixels)
                sourceToPlace = nil
            }
        }
    }

    private var choices: [Choice] {
        let catalog = SharedAssets.catalog
        let staticChoices = catalog.outfits(inSlot: category.rawValue)
            .map { Choice(name: $0.name, label: $0.label) }
        let animatedNames: [String]
        switch category {
        case .eyes: animatedNames = catalog.summary().eyes
        case .mouth: animatedNames = catalog.summary().mouths
        default: animatedNames = []
        }
        let animatedChoices = animatedNames.map {
            Choice(name: $0, label: $0.replacingOccurrences(of: "-", with: " ").capitalized)
        }
        return (animatedChoices + staticChoices).sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private func choose(_ choice: Choice) {
        let catalog = SharedAssets.catalog
        let image: CGImage?
        switch category {
        case .eyes:
            image = catalog.eyesImage(
                option: choice.name,
                expression: .open,
                body: bodyStyle
            )
        case .mouth:
            image = catalog.mouthImage(
                option: choice.name,
                state: .closed,
                body: bodyStyle
            )
        default:
            image = catalog.outfitImage(choice.name, body: bodyStyle)
        }
        guard let image else { return }
        let gridSize = CustomOutfitLibrary.shared
            .bundle(named: choice.name)?
            .manifest.gridSize ?? 100
        sourceToPlace = OutfitCopySource(
            label: choice.label,
            category: category,
            image: image,
            preferredGridSize: gridSize
        )
    }

    private func choiceThumbnail(_ choice: Choice) -> CGImage? {
        let catalog = SharedAssets.catalog
        switch category {
        case .eyes:
            return catalog.eyesThumbnail(
                option: choice.name,
                expression: .open,
                body: bodyStyle
            )
        case .mouth:
            return catalog.mouthThumbnail(
                option: choice.name,
                state: .closed,
                body: bodyStyle
            )
        default:
            return catalog.outfitThumbnail(choice.name, body: bodyStyle)
        }
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

#if os(macOS)
/// A sheet-local command handler keeps undo/redo working while the focusable
/// pixel canvas owns first responder. Text fields retain their native undo
/// stack while they are actively being edited.
private struct OutfitEditorShortcutCapture: NSViewRepresentable {
    let undo: () -> Void
    let redo: () -> Void
    let copy: () -> Bool
    let paste: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(undo: undo, redo: redo, copy: copy, paste: paste)
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(undo: undo, redo: redo, copy: copy, paste: paste)
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private var monitor: Any?
        private var undoAction: () -> Void = {}
        private var redoAction: () -> Void = {}
        private var copyAction: () -> Bool = { false }
        private var pasteAction: () -> Bool = { false }

        func update(
            undo: @escaping () -> Void,
            redo: @escaping () -> Void,
            copy: @escaping () -> Bool,
            paste: @escaping () -> Bool
        ) {
            undoAction = undo
            redoAction = redo
            copyAction = copy
            pasteAction = paste
        }

        func install(on view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let hasCommand = event.modifierFlags.contains(.command)
                let keyCode = event.keyCode
                let isRedo = event.modifierFlags.contains(.shift)
                guard hasCommand, [6, 8, 9, 35].contains(keyCode) else { return event }
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.view?.window === NSApp.keyWindow else { return false }
                    if let text = NSApp.keyWindow?.firstResponder as? NSText,
                       text.superview != nil, !text.isHidden {
                        return false
                    }
                    switch keyCode {
                    case 6:
                        if isRedo { self.redoAction() } else { self.undoAction() }
                        return true
                    case 8:
                        return self.copyAction()
                    case 9, 35:
                        return self.pasteAction()
                    default:
                        return false
                    }
                }
                return handled ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Watches native click counts without taking hit-testing away from SwiftUI's
/// painting drag gesture. The first click is allowed through; on click two the
/// editor restores the pre-click pixels, selects the region, and consumes only
/// that second mouse-down.
private struct OutfitCanvasMouseCapture: NSViewRepresentable {
    let snapshot: () -> PixelDoubleClickSnapshot
    let doubleClick: (PixelDoubleClickSnapshot, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        context.coordinator.update(snapshot: snapshot, doubleClick: doubleClick)
        context.coordinator.install(on: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(snapshot: snapshot, doubleClick: doubleClick)
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private var monitor: Any?
        private var baseline: PixelDoubleClickSnapshot?
        private var snapshotAction: () -> PixelDoubleClickSnapshot = {
            PixelDoubleClickSnapshot(pixels: [], selection: [])
        }
        private var doubleClickAction: (PixelDoubleClickSnapshot, CGPoint) -> Void = { _, _ in }

        func update(
            snapshot: @escaping () -> PixelDoubleClickSnapshot,
            doubleClick: @escaping (PixelDoubleClickSnapshot, CGPoint) -> Void
        ) {
            snapshotAction = snapshot
            doubleClickAction = doubleClick
        }

        func install(on view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self] event in
                let clickCount = event.clickCount
                let locationInWindow = event.locationInWindow
                let eventWindowNumber = event.windowNumber
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let view = self.view,
                          view.window?.windowNumber == eventWindowNumber,
                          view.bounds.width > 0, view.bounds.height > 0 else { return false }
                    let point = view.convert(locationInWindow, from: nil)
                    guard view.bounds.contains(point) else {
                        self.baseline = nil
                        return false
                    }
                    if clickCount == 1 {
                        self.baseline = self.snapshotAction()
                        return false
                    }
                    guard clickCount == 2 else { return false }
                    let topLeftPoint = CGPoint(
                        x: point.x,
                        y: view.bounds.height - point.y
                    )
                    self.doubleClickAction(
                        self.baseline ?? self.snapshotAction(),
                        topLeftPoint
                    )
                    self.baseline = nil
                    return true
                }
                return handled ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
#endif

private struct PixelDesignSurface: View {
    @Bindable var canvas: PixelOutfitCanvas
    let bodyStyle: Body
    let category: OutfitCategory
    let mannequinOutfits: [OutfitCategory: String]
    let showMannequin: Bool
    let onInteraction: () -> Void

    @State private var sectionDragStart: PixelGridPoint?
    @State private var sectionDragMoved = false
    @State private var sectionDragIsAdditive = false
    @State private var selectionMoveStart: PixelGridPoint?

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
                        drawOutfitMannequin(
                            in: &ghost,
                            box: box,
                            bodyStyle: bodyStyle,
                            activeCategory: category,
                            activePart: nil,
                            mannequinOutfits: mannequinOutfits
                        )
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
            #if os(macOS)
            .background(
                OutfitCanvasMouseCapture(
                    snapshot: {
                        PixelDoubleClickSnapshot(
                            pixels: canvas.pixels,
                            selection: canvas.selectedPixels
                        )
                    },
                    doubleClick: { snapshot, point in
                        onInteraction()
                        canvas.selectConnectedAfterDoubleClick(
                            atX: min(
                                canvas.gridSize - 1,
                                max(0, Int(point.x / side * CGFloat(canvas.gridSize)))
                            ),
                            y: min(
                                canvas.gridSize - 1,
                                max(0, Int(point.y / side * CGFloat(canvas.gridSize)))
                            ),
                            restoring: snapshot,
                            addingToSelection: sectionSelectionIsAdditive
                        )
                    }
                )
                .accessibilityHidden(true)
            )
            #endif
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
                        onInteraction()
                        let localX = value.location.x
                        let localY = value.location.y
                        let point = PixelGridPoint(
                            x: min(
                                canvas.gridSize - 1,
                                max(0, Int(localX / side * CGFloat(canvas.gridSize)))
                            ),
                            y: min(
                                canvas.gridSize - 1,
                                max(0, Int(localY / side * CGFloat(canvas.gridSize)))
                            )
                        )
                        if let start = selectionMoveStart {
                            canvas.updateSelectionDrag(
                                dx: point.x - start.x,
                                dy: point.y - start.y
                            )
                            return
                        }
                        if localX >= 0, localY >= 0, localX < side, localY < side,
                           canvas.selectionContains(x: point.x, y: point.y),
                           canvas.tool == .section || selectionDragShouldCopy {
                            selectionMoveStart = point
                            canvas.beginSelectionDrag(copying: selectionDragShouldCopy)
                            return
                        }
                        if canvas.tool == .section {
                            if sectionDragStart == nil,
                               (localX < 0 || localY < 0 || localX >= side || localY >= side) {
                                return
                            }
                            if sectionDragStart == nil {
                                sectionDragStart = point
                                sectionDragIsAdditive = sectionSelectionIsAdditive
                                sectionDragMoved = false
                                canvas.beginRangeSelection(
                                    addingToSelection: sectionDragIsAdditive
                                )
                            }
                            guard let start = sectionDragStart else { return }
                            if point != start { sectionDragMoved = true }
                            canvas.updateRangeSelection(
                                fromX: start.x,
                                y: start.y,
                                toX: point.x,
                                y: point.y
                            )
                            return
                        }
                        canvas.beginStroke()
                        let x = Int(value.location.x / side
                                    * CGFloat(canvas.gridSize))
                        let y = Int(value.location.y / side
                                    * CGFloat(canvas.gridSize))
                        canvas.useTool(
                            atX: x,
                            y: y,
                            addingToSelection: sectionSelectionIsAdditive
                        )
                    }
                    .onEnded { _ in
                        if selectionMoveStart != nil {
                            canvas.finishSelectionDrag()
                            selectionMoveStart = nil
                            return
                        }
                        if canvas.tool == .section {
                            if let start = sectionDragStart, !sectionDragMoved {
                                canvas.selectPixel(
                                    atX: start.x,
                                    y: start.y,
                                    addingToSelection: sectionDragIsAdditive
                                )
                            }
                            canvas.finishRangeSelection()
                            sectionDragStart = nil
                            sectionDragMoved = false
                            return
                        }
                        canvas.endStroke()
                    }
            )
            #if !os(macOS)
            .highPriorityGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        onInteraction()
                        // This gesture is attached to the square drawing
                        // surface, so its coordinates are already local even
                        // when the square is centered in a wider/taller area.
                        let localX = value.location.x
                        let localY = value.location.y
                        guard localX >= 0, localY >= 0,
                              localX < side, localY < side else {
                            canvas.clearSelection()
                            return
                        }
                        canvas.selectConnected(
                            atX: min(
                                canvas.gridSize - 1,
                                Int(localX / side * CGFloat(canvas.gridSize))
                            ),
                            y: min(
                                canvas.gridSize - 1,
                                Int(localY / side * CGFloat(canvas.gridSize))
                            ),
                            addingToSelection: sectionSelectionIsAdditive
                        )
                    }
            )
            #endif
        }
    }
}

private struct PixelGridPoint: Equatable {
    let x: Int
    let y: Int
}

private var sectionSelectionIsAdditive: Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.shift)
    #else
    false
    #endif
}

private var selectionDragShouldCopy: Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.command)
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
    let mannequinOutfits: [OutfitCategory: String]

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(red: 0.98, green: 0.97, blue: 0.92)))
            drawOutfitMannequin(
                in: &context,
                box: CGRect(origin: .zero, size: size),
                bodyStyle: bodyStyle,
                activeCategory: category,
                activePart: part,
                mannequinOutfits: mannequinOutfits
            )
        }
    }
}

private func outfitCategoriesConflict(
    _ lhs: OutfitCategory,
    _ rhs: OutfitCategory
) -> Bool {
    if lhs == rhs { return true }
    let headDependents: Set<OutfitCategory> = [.eyes, .glasses, .mouth, .headTop]
    if lhs == .head { return headDependents.contains(rhs) }
    if rhs == .head { return headDependents.contains(lhs) }
    let suitPieces: Set<OutfitCategory> = [.suitBottom, .suitTop]
    if lhs == .suit { return suitPieces.contains(rhs) }
    if rhs == .suit { return suitPieces.contains(lhs) }
    return false
}

/// Flat mannequin renderer that mirrors the URI resolver's category conflicts.
/// `activeCategory` participates in hiding defaults even when its pixels are
/// omitted, which keeps the design guide from showing default eyes/mouth under
/// artwork for those replacement categories.
private func drawOutfitMannequin(
    in context: inout GraphicsContext,
    box: CGRect,
    bodyStyle: Body,
    activeCategory: OutfitCategory?,
    activePart: CGImage?,
    mannequinOutfits: [OutfitCategory: String]
) {
    let catalog = SharedAssets.catalog
    var parts = mannequinOutfits.reduce(into: [OutfitCategory: CGImage]()) {
        result, entry in
        switch entry.key {
        case .eyes:
            result[entry.key] = catalog.eyesImage(
                option: entry.value,
                expression: .open,
                body: bodyStyle
            )
        case .mouth:
            result[entry.key] = catalog.mouthImage(
                option: entry.value,
                state: .closed,
                body: bodyStyle
            )
        default:
            result[entry.key] = catalog.outfitImage(entry.value, body: bodyStyle)
        }
    }
    if let activeCategory, let activePart {
        parts[activeCategory] = activePart
    }
    func isPresent(_ category: OutfitCategory) -> Bool {
        activeCategory == category || parts[category] != nil
    }
    func draw(_ image: CGImage?) {
        guard let image else { return }
        context.draw(Image(decorative: image, scale: 1).interpolation(.none), in: box)
    }

    draw(parts[.backside])
    draw(catalog.bodyImage(bodyStyle))
    if isPresent(.necklace) { draw(parts[.necklace]) }
    else { draw(catalog.necklaceImage(body: bodyStyle)) }

    let headWorn = isPresent(.head)
    draw(parts[.head])
    if !headWorn {
        if isPresent(.eyes) { draw(parts[.eyes]) }
        else {
            draw(catalog.eyesImage(
                option: "default",
                expression: .open,
                body: bodyStyle
            ))
        }
        draw(parts[.glasses])
        if isPresent(.mouth) { draw(parts[.mouth]) }
        else {
            draw(catalog.mouthImage(
                option: "default",
                state: .closed,
                body: bodyStyle
            ))
        }
    }

    draw(parts[.legs])
    let suitWorn = isPresent(.suit)
    draw(parts[.suit])
    if !suitWorn {
        draw(parts[.suitBottom])
        draw(parts[.suitTop])
    }
    if !headWorn { draw(parts[.headTop]) }
    draw(parts[.hand])
}

private enum StarterProcessingLevel: String, CaseIterable, Identifiable {
    case none
    case fine
    case standard
    case pixelated
    case superPixelated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None (full color)"
        case .fine: "Fine"
        case .standard: "Standard"
        case .pixelated: "Pixelated"
        case .superPixelated: "Super pixelated"
        }
    }

    var paletteSize: Int? {
        switch self {
        case .none: nil
        case .fine: 32
        case .standard: 16
        case .pixelated: 8
        case .superPixelated: 4
        }
    }

    func sampleSize(for gridSize: Int) -> Int {
        switch self {
        case .none, .fine: gridSize
        case .standard: max(1, gridSize / 2)
        case .pixelated: max(1, gridSize / 4)
        case .superPixelated: max(1, gridSize / 8)
        }
    }

    func detail(for gridSize: Int) -> String {
        let samples = sampleSize(for: gridSize)
        guard let paletteSize else {
            return "Keeps full color and samples directly into the \(gridSize)×\(gridSize) outfit grid."
        }
        return "Previews at \(samples)×\(samples) with up to \(paletteSize) colors, then expands into the editable \(gridSize)×\(gridSize) grid."
    }
}

private struct OutfitImageStarter: View {
    let image: CGImage
    let gridSize: Int
    let bodyStyle: Body
    let category: OutfitCategory
    var mannequinOutfits: [OutfitCategory: String] = [:]
    var preserveSourcePixels = false
    let apply: ([UInt32]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    @State private var offsetX = 0.0
    @State private var offsetY = 0.0
    @State private var rotation = 0.0
    @State private var processingLevel: StarterProcessingLevel = .standard
    @State private var alphaThreshold = 0.18
    @State private var dither = false

    private var processedPixels: [UInt32] {
        preserveSourcePixels
            ? OutfitImageProcessor.placeCopy(
                image,
                gridSize: gridSize,
                scale: scale,
                offsetX: offsetX,
                offsetY: offsetY,
                rotation: rotation
            )
            : OutfitImageProcessor.process(
                image,
                gridSize: gridSize,
                scale: scale,
                offsetX: offsetX,
                offsetY: offsetY,
                rotation: rotation,
                level: processingLevel,
                alphaThreshold: alphaThreshold,
                dither: dither
            )
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                VStack {
                    StarterPlacementPreview(
                        processedImage: PixelOutfitCanvas.image(
                            pixels: processedPixels,
                            size: gridSize
                        ),
                        scale: $scale,
                        offsetX: $offsetX,
                        offsetY: $offsetY,
                        rotation: $rotation,
                        bodyStyle: bodyStyle,
                        category: category,
                        mannequinOutfits: mannequinOutfits
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .padding()
                    Text("Drag to position. Pinch to resize. Rotate with a trackpad gesture or the controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Form {
                    Section("Placement") {
                        LabeledContent("Size") {
                            HStack {
                                Slider(value: $scale, in: 0.1...6)
                                    .accessibilityIdentifier("starter-image-scale")
                                Text("\(Int((scale * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 42, alignment: .trailing)
                            }
                        }
                        LabeledContent("Horizontal") {
                            Slider(value: $offsetX, in: -400...400)
                        }
                        LabeledContent("Vertical") {
                            Slider(value: $offsetY, in: -400...400)
                        }
                        LabeledContent("Rotation") {
                            HStack {
                                Slider(value: $rotation, in: -180...180)
                                    .accessibilityIdentifier("starter-image-rotation")
                                Text("\(Int(rotation.rounded()))°")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                        Button("Reset Placement") {
                            scale = 1
                            offsetX = 0
                            offsetY = 0
                            rotation = 0
                        }
                    }
                    if preserveSourcePixels {
                        Section("Copied pixels") {
                            Text("The source outfit’s colors and transparency are preserved. After placing it, every pixel remains editable on the canvas.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Pixel processing") {
                            Picker("Processing", selection: $processingLevel) {
                                ForEach(StarterProcessingLevel.allCases) { level in
                                    Text(level.title).tag(level)
                                }
                            }
                            .accessibilityIdentifier("starter-processing-level")
                            LabeledContent("Transparency") {
                                Slider(value: $alphaThreshold, in: 0...0.9)
                            }
                            Toggle("Ordered dithering", isOn: $dither)
                                .disabled(processingLevel == .none)
                            Text(processingLevel.detail(for: gridSize))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("The preview shows the exact processed pixels that will be placed.")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 320)
            }
            .navigationTitle(preserveSourcePixels ? "Place Copied Outfit" : "Image Starter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(preserveSourcePixels ? "Place Copy" : "Make Pixel Starter") {
                        apply(processedPixels)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("starter-apply")
                }
            }
        }
        .frame(minWidth: 760, minHeight: 600)
    }
}

private struct StarterPlacementPreview: View {
    let processedImage: CGImage?
    @Binding var scale: Double
    @Binding var offsetX: Double
    @Binding var offsetY: Double
    @Binding var rotation: Double
    let bodyStyle: Body
    let category: OutfitCategory
    let mannequinOutfits: [OutfitCategory: String]

    @State private var dragStart: CGSize?
    @State private var scaleStart: Double?
    @State private var rotationStart: Double?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color(red: 0.98, green: 0.97, blue: 0.92)))
                var ghost = context
                ghost.opacity = 0.22
                drawOutfitMannequin(
                    in: &ghost,
                    box: CGRect(origin: .zero, size: size),
                    bodyStyle: bodyStyle,
                    activeCategory: category,
                    activePart: nil,
                    mannequinOutfits: mannequinOutfits
                )
                if let processedImage {
                    context.draw(
                        Image(decorative: processedImage, scale: 1)
                            .interpolation(.none),
                        in: CGRect(origin: .zero, size: size)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = CGSize(
                                width: CGFloat(offsetX),
                                height: CGFloat(offsetY)
                            )
                        }
                        let start = dragStart ?? .zero
                        offsetX = min(
                            400,
                            max(
                                -400,
                                Double(start.width)
                                    + Double(value.translation.width
                                             / max(1, geometry.size.width) * 400)
                            )
                        )
                        offsetY = min(
                            400,
                            max(
                                -400,
                                Double(start.height)
                                    + Double(value.translation.height
                                             / max(1, geometry.size.height) * 400)
                            )
                        )
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { magnification in
                        if scaleStart == nil { scaleStart = scale }
                        scale = min(
                            6,
                            max(
                                0.1,
                                (scaleStart ?? scale) * Double(magnification)
                            )
                        )
                    }
                    .onEnded { _ in scaleStart = nil }
            )
            .simultaneousGesture(
                RotationGesture()
                    .onChanged { angle in
                        if rotationStart == nil { rotationStart = rotation }
                        rotation = normalizedDegrees(
                            (rotationStart ?? rotation) + angle.degrees
                        )
                    }
                    .onEnded { _ in rotationStart = nil }
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.22), lineWidth: 1)
            }
            .accessibilityIdentifier("starter-image-placement")
        }
    }

    private func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}

private enum OutfitImageProcessor {
    static func placeCopy(
        _ image: CGImage,
        gridSize: Int,
        scale: Double,
        offsetX: Double,
        offsetY: Double,
        rotation: Double
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
        context.interpolationQuality = .none
        let fit = min(CGFloat(gridSize) / CGFloat(image.width),
                      CGFloat(gridSize) / CGFloat(image.height))
        let width = CGFloat(image.width) * fit * scale
        let height = CGFloat(image.height) * fit * scale
        let center = CGPoint(
            x: CGFloat(gridSize) / 2
                + CGFloat(offsetX) / 400 * CGFloat(gridSize),
            y: CGFloat(gridSize) / 2
                + CGFloat(offsetY) / 400 * CGFloat(gridSize)
        )
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(rotation * .pi / 180))
        context.draw(
            image,
            in: CGRect(x: -width / 2, y: -height / 2,
                       width: width, height: height)
        )
        return stride(from: 0, to: bytes.count, by: 4).map { index in
            UInt32(bytes[index]) << 24
                | UInt32(bytes[index + 1]) << 16
                | UInt32(bytes[index + 2]) << 8
                | UInt32(bytes[index + 3])
        }
    }

    static func process(
        _ image: CGImage,
        gridSize: Int,
        scale: Double,
        offsetX: Double,
        offsetY: Double,
        rotation: Double,
        level: StarterProcessingLevel,
        alphaThreshold: Double,
        dither: Bool
    ) -> [UInt32] {
        let sampleSize = level.sampleSize(for: gridSize)
        let count = sampleSize * sampleSize
        var bytes = [UInt8](repeating: 0, count: count * 4)
        guard let context = CGContext(
            data: &bytes,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [UInt32](repeating: 0, count: gridSize * gridSize) }
        context.interpolationQuality = .high
        let fit = min(CGFloat(sampleSize) / CGFloat(image.width),
                      CGFloat(sampleSize) / CGFloat(image.height))
        let width = CGFloat(image.width) * fit * scale
        let height = CGFloat(image.height) * fit * scale
        let center = CGPoint(
            x: CGFloat(sampleSize) / 2
                + CGFloat(offsetX) / 400 * CGFloat(sampleSize),
            y: CGFloat(sampleSize) / 2
                + CGFloat(offsetY) / 400 * CGFloat(sampleSize)
        )
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(rotation * .pi / 180))
        context.draw(
            image,
            in: CGRect(x: -width / 2, y: -height / 2,
                       width: width, height: height)
        )
        context.restoreGState()

        let threshold = UInt8(max(0, min(255, Int(alphaThreshold * 255))))
        var palette: [(Double, Double, Double)]?
        if let paletteSize = level.paletteSize {
            var samples: [(Double, Double, Double)] = []
            let strideBy = max(1, count / 8_000)
            for pixel in Swift.stride(from: 0, to: count, by: strideBy) {
                let index = pixel * 4
                if bytes[index + 3] > threshold {
                    samples.append((Double(bytes[index]), Double(bytes[index + 1]),
                                    Double(bytes[index + 2])))
                }
            }
            palette = kMeans(samples, count: max(2, paletteSize))
        }
        let bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        var sampled = [UInt32](repeating: 0, count: count)
        for pixel in 0..<count {
            let index = pixel * 4
            let alpha = bytes[index + 3]
            guard alpha > threshold else { continue }
            guard let palette else {
                sampled[pixel] = UInt32(bytes[index]) << 24
                    | UInt32(bytes[index + 1]) << 16
                    | UInt32(bytes[index + 2]) << 8
                    | UInt32(alpha)
                continue
            }
            let x = pixel % sampleSize
            let y = pixel / sampleSize
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
            sampled[pixel] = UInt32(nearest.0.rounded()) << 24
                | UInt32(nearest.1.rounded()) << 16
                | UInt32(nearest.2.rounded()) << 8
                | 0xff
        }
        guard sampleSize != gridSize else { return sampled }
        var output = [UInt32](repeating: 0, count: gridSize * gridSize)
        for y in 0..<gridSize {
            let sourceY = min(sampleSize - 1, y * sampleSize / gridSize)
            for x in 0..<gridSize {
                let sourceX = min(sampleSize - 1, x * sampleSize / gridSize)
                output[y * gridSize + x] = sampled[sourceY * sampleSize + sourceX]
            }
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

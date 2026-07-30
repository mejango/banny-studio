import SwiftUI
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO
import BannyCore

struct CustomOutfitManager: View {
    let bodyStyle: Body
    var onChoose: ((CustomOutfitBundle) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var library = CustomOutfitLibrary.shared
    @State private var editing: CustomOutfitBundle?
    @State private var creating = false
    @State private var importing = false
    @State private var pendingImport: CustomOutfitBundle?
    @State private var exporting: CustomOutfitFileDocument?
    @State private var exportFilename = "outfit.bannyoutfit"
    @State private var deleting: CustomOutfitBundle?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.outfits.isEmpty {
                    ContentUnavailableView {
                        Label("No Custom Outfits", systemImage: "paintbrush.pointed")
                    } description: {
                        Text("Create pixel art on a Banny mannequin, or import a .bannyoutfit file.")
                    } actions: {
                        Button("Create Outfit") { creating = true }
                            .buttonStyle(.borderedProminent)
                        Button("Import Outfit") { importing = true }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(library.outfits, id: \.manifest.id) { outfit in
                                outfitCard(outfit)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("My Outfits")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { importing = true } label: {
                        Label("Import Outfit", systemImage: "square.and.arrow.down")
                    }
                    Button { creating = true } label: {
                        Label("Create Outfit", systemImage: "plus")
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .sheet(isPresented: $creating) {
            OutfitStudio(bodyStyle: bodyStyle) { outfit in
                onChoose?(outfit)
                creating = false
            }
        }
        .sheet(item: $editing) { outfit in
            OutfitStudio(bodyStyle: bodyStyle, editing: outfit) { saved in
                onChoose?(saved)
                editing = nil
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.bannyOutfit, .json, .data]
        ) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let outfit = try JSONDecoder()
                    .decode(CustomOutfitBundle.self, from: data)
                    .validated()
                if library.contains(id: outfit.manifest.id) {
                    pendingImport = outfit
                } else {
                    let saved = try library.importBundle(outfit, strategy: .replace)
                    onChoose?(saved)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "This outfit is already in your library",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Replace Existing") { finishPendingImport(.replace) }
            Button("Keep Both") { finishPendingImport(.keepBoth) }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("Replace it with the imported version, or create an independent copy.")
        }
        .fileExporter(
            isPresented: Binding(
                get: { exporting != nil },
                set: { if !$0 { exporting = nil } }
            ),
            document: exporting,
            contentType: .bannyOutfit,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
            exporting = nil
        }
        .confirmationDialog(
            "Delete \(deleting?.manifest.name ?? "outfit")?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete from My Outfits", role: .destructive) {
                guard let deleting else { return }
                do {
                    try library.delete(id: deleting.manifest.id)
                    self.deleting = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Projects already using it keep their embedded copy.")
        }
        .alert(
            "Outfit error",
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

    private func outfitCard(_ outfit: CustomOutfitBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OutfitMannequinCard(
                outfit: outfit,
                bodyStyle: bodyStyle
            )
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Text(outfit.manifest.name)
                .font(.subheadline.bold())
                .lineLimit(1)
            Label(outfit.manifest.category.displayName,
                  systemImage: outfit.manifest.category.iconName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if onChoose != nil {
                    Button("Wear") {
                        onChoose?(outfit)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Menu {
                    Button("Edit") { editing = outfit }
                    Button("Export…") { prepareExport(outfit) }
                    Divider()
                    Button("Delete", role: .destructive) { deleting = outfit }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .contextMenu {
            Button("Edit") { editing = outfit }
            Button("Export…") { prepareExport(outfit) }
            Button("Delete", role: .destructive) { deleting = outfit }
        }
    }

    private func prepareExport(_ outfit: CustomOutfitBundle) {
        let stem = outfit.manifest.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        exportFilename = "\(stem.isEmpty ? "outfit" : stem).bannyoutfit"
        exporting = CustomOutfitFileDocument(outfit: outfit)
    }

    private func finishPendingImport(_ strategy: CustomOutfitLibrary.ImportStrategy) {
        guard let pendingImport else { return }
        do {
            let saved = try library.importBundle(pendingImport, strategy: strategy)
            onChoose?(saved)
            self.pendingImport = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct OutfitMannequinCard: View {
    let outfit: CustomOutfitBundle
    let bodyStyle: Body

    var body: some View {
        let image = PixelImageDecoder.decode(outfit.pngData)
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(red: 0.98, green: 0.97, blue: 0.92)))
            let box = CGRect(origin: .zero, size: size)
            let catalog = SharedAssets.catalog
            func draw(_ cgImage: CGImage?) {
                guard let cgImage else { return }
                context.draw(
                    Image(decorative: cgImage, scale: 1).interpolation(.none),
                    in: box
                )
            }
            if outfit.manifest.category == .backside { draw(image) }
            draw(catalog.bodyImage(bodyStyle))
            if outfit.manifest.category == .necklace {
                draw(image)
            } else {
                draw(catalog.necklaceImage(body: bodyStyle))
            }
            if outfit.manifest.category == .head {
                draw(image)
            } else {
                draw(catalog.eyesImage(option: "default", expression: .open,
                                       body: bodyStyle))
                if outfit.manifest.category == .glasses { draw(image) }
                draw(catalog.mouthImage(option: "default", state: .closed,
                                        body: bodyStyle))
                if [.legs, .suit, .suitBottom, .suitTop, .headTop]
                    .contains(outfit.manifest.category) {
                    draw(image)
                }
            }
            if outfit.manifest.category == .hand { draw(image) }
        }
    }
}

private enum PixelImageDecoder {
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

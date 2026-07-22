import SwiftUI
import BannyCore
import BannyRender
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An intentionally quiet escape hatch for people who know the show schema.
/// Nothing changes until valid JSON is applied, and an apply is one undo step.
struct AdvancedJSONSection: View {
    @Bindable var model: StudioModel
    var file: ShowDocumentFile?
    let characterIndex: Int
    @State private var presented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ADVANCED").font(.caption.bold()).foregroundStyle(.secondary)
            Button {
                model.pause()
                presented = true
            } label: {
                Label("Edit JSON…", systemImage: "curlybraces")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("edit-advanced-json")
            Text("Edit this character directly, or switch to the entire show. Changes are checked before they can be applied.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $presented) {
            AdvancedJSONEditor(model: model, file: file,
                               characterIndex: characterIndex)
        }
    }
}

private struct AdvancedJSONEditor: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case character = "Character"
        case show = "Entire show"
        var id: Self { self }
    }

    @Bindable var model: StudioModel
    var file: ShowDocumentFile?
    let characterIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .character
    @State private var text = ""
    @State private var baseline = ""
    @State private var errors: [String] = []
    @State private var warnings: [String] = []
    @State private var decodedCharacter: Character?
    @State private var decodedDocument: ShowDocument?
    @State private var confirmDiscard = false
    @FocusState private var editorFocused: Bool

    private var dirty: Bool { text != baseline }
    private var canApply: Bool {
        dirty && errors.isEmpty
            && (scope == .character ? decodedCharacter != nil : decodedDocument != nil)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { item in Text(item.rawValue).tag(item) }
                }
                .pickerStyle(.segmented)
                .disabled(dirty)
                .accessibilityHint(dirty ? "Apply or revert this draft before changing scope" : "")

                HStack(spacing: 6) {
                    Image(systemName: scope == .character ? "person.crop.circle" : "doc.text")
                    Text(scopeDescription)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                    if dirty {
                        Text("Draft")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)

                if scope == .show {
                    Label("This replaces show.json, including every track, cue, asset reference, export range, and setting.",
                          systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($editorFocused)
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(errors.isEmpty ? Color.primary.opacity(0.16)
                                               : Color.red.opacity(0.7), lineWidth: 1))
                    .accessibilityIdentifier("advanced-json-editor")

                diagnostics

                HStack {
                    Button("Format") { formatDraft() }
                        .disabled(decodedCharacter == nil && decodedDocument == nil)
                    Button("Copy") { copyDraft() }
                    Button("Revert") { loadScope() }
                        .disabled(!dirty)
                    Spacer()
                    if dirty {
                        Text("Apply or revert before switching scope")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            .padding(14)
            .navigationTitle("Advanced JSON")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { requestClose() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { applyDraft() }
                        .disabled(!canApply)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 580)
        #else
        .presentationDetents([.large])
        #endif
        .interactiveDismissDisabled(dirty)
        .onAppear {
            loadScope()
            editorFocused = true
        }
        .onChange(of: scope) { _, _ in loadScope() }
        .onChange(of: text) { _, _ in validateDraft() }
        .alert("Discard JSON draft?", isPresented: $confirmDiscard) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { dismiss() }
        } message: {
            Text("Your unapplied JSON changes will be lost.")
        }
    }

    @ViewBuilder private var diagnostics: some View {
        if !errors.isEmpty || !warnings.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, message in
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, message in
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .frame(maxHeight: 90)
        } else {
            Label("Valid JSON", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var scopeDescription: String {
        switch scope {
        case .character:
            let name = model.scene.characters[safe: characterIndex]?.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "show.json › stage › characters[\(characterIndex)]"
                + ((name?.isEmpty == false) ? " › \(name!)" : "")
        case .show:
            return "show.json"
        }
    }

    private func loadScope() {
        do {
            switch scope {
            case .character:
                guard let character = model.scene.characters[safe: characterIndex] else {
                    errors = ["This character no longer exists."]
                    return
                }
                text = try ShowJSONCodec.encode(character: character)
            case .show:
                text = try ShowJSONCodec.encode(document: model.document)
            }
            baseline = text
            validateDraft()
        } catch {
            errors = [ShowJSONCodec.readableMessage(for: error)]
        }
    }

    private func validateDraft() {
        decodedCharacter = nil
        decodedDocument = nil
        warnings = []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errors = ["JSON cannot be empty."]
            return
        }
        do {
            let candidate: ShowDocument
            switch scope {
            case .character:
                guard model.scene.characters.indices.contains(characterIndex) else {
                    errors = ["This character no longer exists."]
                    return
                }
                let character = try ShowJSONCodec.decodeCharacter(text)
                decodedCharacter = character
                var document = model.document
                document.stage.characters[characterIndex] = character
                candidate = document
            case .show:
                let document = try ShowJSONCodec.decodeDocument(text)
                decodedDocument = document
                candidate = document
            }

            let structureErrors = structuralErrors(in: candidate)
            let diagnostics = ShowLint.check(
                document: candidate,
                audioIDs: file.map { Set($0.audio.keys) } ?? audioIDs(in: candidate),
                assetFileIDs: file.map { Set($0.assetsMedia.keys) }
                    ?? Set(candidate.assets.map(\.id)),
                catalog: SharedAssets.catalog)
            errors = structureErrors + diagnostics
                .filter { $0.severity == .error }
                .map(\.message)
            warnings = diagnostics
                .filter { $0.severity == .warning }
                .map(\.message)
        } catch {
            errors = [ShowJSONCodec.readableMessage(for: error)]
        }
    }

    private func structuralErrors(in document: ShowDocument) -> [String] {
        var result: [String] = []
        if document.version != 3 {
            result.append("The editable show schema version must remain 3.")
        }
        if document.stage.backgroundTracks.count != 1 {
            result.append("The show must contain exactly one Scenes track.")
        }
        func duplicateMessage(_ values: [String], _ label: String) {
            let duplicates = Dictionary(grouping: values.filter { !$0.isEmpty }, by: { $0 })
                .filter { $0.value.count > 1 }.keys.sorted()
            if !duplicates.isEmpty {
                result.append("Duplicate \(label) identifiers: \(duplicates.joined(separator: ", ")).")
            }
            if values.contains("") { result.append("\(label.capitalized) identifiers cannot be empty.") }
        }
        duplicateMessage(document.assets.map(\.id), "asset")
        duplicateMessage(document.stage.audioTracks.map(\.id)
                         + document.stage.imageTracks.map(\.id)
                         + document.stage.lightTracks.map(\.id)
                         + document.stage.backgroundTracks.map(\.id), "track")
        let clipIDs = document.stage.characters.flatMap(\.clips).map(\.id)
            + document.stage.audioTracks.flatMap(\.clips).map(\.id)
        if clipIDs.contains("") { result.append("Audio clip identifiers cannot be empty.") }
        let visualIDs = document.stage.imageTracks.flatMap(\.cues).map(\.id)
            + document.stage.audioTracks.flatMap(\.cues).map(\.id)
        duplicateMessage(visualIDs, "visual cue")
        duplicateMessage(document.stage.backgroundTracks.flatMap(\.cues).map(\.id),
                         "scene cue")
        duplicateMessage(document.stage.lightTracks.flatMap(\.cues).map(\.id),
                         "light cue")
        return result
    }

    private func audioIDs(in document: ShowDocument) -> Set<String> {
        Set(document.stage.characters.flatMap(\.clips).map(\.id)
            + document.stage.audioTracks.flatMap(\.clips).map(\.id))
    }

    private func formatDraft() {
        do {
            switch scope {
            case .character:
                guard let decodedCharacter else { return }
                text = try ShowJSONCodec.encode(character: decodedCharacter)
            case .show:
                guard let decodedDocument else { return }
                text = try ShowJSONCodec.encode(document: decodedDocument)
            }
        } catch {
            errors = [ShowJSONCodec.readableMessage(for: error)]
        }
    }

    private func copyDraft() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func requestClose() {
        if dirty { confirmDiscard = true } else { dismiss() }
    }

    private func applyDraft() {
        guard canApply else { return }
        switch scope {
        case .character:
            guard let decodedCharacter else { return }
            model.applyAdvancedJSON(character: decodedCharacter, at: characterIndex)
        case .show:
            guard let decodedDocument else { return }
            model.applyAdvancedJSON(document: decodedDocument,
                                    preferredCharacter: characterIndex)
        }
        dismiss()
    }
}

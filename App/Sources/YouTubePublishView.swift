import SwiftUI
import BannyCore
import BannyMedia
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private enum YouTubePublishQuality: String, CaseIterable, Identifiable {
    case p720
    case p1080
    case p2160

    var id: String { rawValue }
    var label: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p2160: "4K"
        }
    }
    var options: ShowExporter.Options {
        switch self {
        case .p720: .p720
        case .p1080: .p1080
        case .p2160: .p2160
        }
    }
}

private enum YouTubeAudience: String, CaseIterable, Identifiable {
    case notMadeForKids
    case madeForKids

    var id: String { rawValue }
    var label: String {
        switch self {
        case .notMadeForKids: "No, not made for kids"
        case .madeForKids: "Yes, made for kids"
        }
    }
}

private enum YouTubePublishPhase: String {
    case rendering = "Rendering video"
    case uploading = "Uploading to YouTube"
    case finishing = "Adding finishing touches"
}

private final class YouTubePublishCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

struct YouTubePublishView: View {
    @Bindable var model: StudioModel
    let file: ShowDocumentFile
    let suggestedTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var account = YouTubeAccount()
    @State private var title: String
    @State private var videoDescription = ""
    @State private var quality = YouTubePublishQuality.p1080
    @State private var privacy = YouTubePrivacyStatus.private
    @State private var audience = YouTubeAudience.notMadeForKids
    @State private var schedule = false
    @State private var publishAt = Date().addingTimeInterval(86_400)
    @State private var includeChapters = true
    @State private var includeCaptions = true
    @State private var captionLanguage = Locale.current.language.languageCode?.identifier ?? "en"
    @State private var useThumbnail = true
    @State private var showAdvanced = false
    @State private var containsSyntheticMedia = false

    @State private var phase: YouTubePublishPhase?
    @State private var progress = 0.0
    @State private var publishTask: Task<Void, Never>?
    @State private var cancellation: YouTubePublishCancellation?
    @State private var errorMessage: String?
    @State private var result: YouTubeUploadResult?
    @State private var warnings: [String] = []
    @State private var channelError: String?
    @State private var isLoadingChannel = false

    init(model: StudioModel, file: ShowDocumentFile, suggestedTitle: String) {
        self.model = model
        self.file = file
        self.suggestedTitle = suggestedTitle
        _title = State(initialValue: suggestedTitle)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let result {
                success(result)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        accountSection
                        metadataSection
                        finishingSection
                        if showAdvanced { advancedSection }
                    }
                    .padding(20)
                }
                Divider()
                footer
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 700)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .interactiveDismissDisabled(isPublishing)
        .task {
            guard account.isConnected, account.channel == nil else { return }
            await refreshChannel()
        }
        .onDisappear {
            cancellation?.cancel()
            publishTask?.cancel()
        }
        .alert("YouTube publishing", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var header: some View {
        HStack {
            Label("Publish to YouTube", systemImage: "play.rectangle.fill")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .disabled(isPublishing)
            .accessibilityLabel("Close")
        }
        .padding(16)
    }

    private var accountSection: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: channelIcon)
                    .font(.title2)
                    .foregroundStyle(account.channel != nil ? .green
                                     : channelError != nil ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.channel?.title
                         ?? (account.isConnected
                             ? (isLoadingChannel ? "Checking YouTube channel…"
                                : "YouTube channel unavailable")
                             : "Connect a YouTube channel"))
                        .fontWeight(.semibold)
                    Text(channelError
                         ?? (account.isConnected
                             ? "Authorization is stored securely in Keychain."
                             : "Banny Studio requests Google's video-upload and caption-management permissions."))
                        .font(.caption)
                        .foregroundStyle(
                            channelError == nil ? Color.secondary : Color.orange)
                }
                Spacer()
                if account.isConnected {
                    if account.channel == nil {
                        Button("Retry") {
                            Task { await refreshChannel() }
                        }
                        .disabled(isLoadingChannel || isPublishing)
                    }
                    Button("Disconnect") {
                        do {
                            try account.disconnect()
                            channelError = nil
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(isPublishing)
                } else {
                    Button(account.isAuthorizing ? "Connecting…" : "Connect") {
                        Task {
                            do {
                                channelError = nil
                                try await account.connect()
                            } catch {
                                channelError = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!account.isConfigured || account.isAuthorizing || isPublishing)
                }
            }
            if !account.isConfigured {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(account.configurationError
                         ?? "This build needs its YouTube OAuth client ID.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Link("Setup guide", destination: URL(
                        string: "https://github.com/mejango/banny-studio/blob/main/docs/YOUTUBE_PUBLISHING.md")!)
                        .font(.caption)
                }
                .padding(.top, 8)
            }
        } label: {
            Text("Channel")
        }
    }

    private var metadataSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title")
                        .font(.subheadline)
                    TextField("Video title", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.subheadline)
                    TextEditor(text: $videoDescription)
                        .font(.body)
                        .frame(minHeight: 90)
                        .padding(5)
                        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(.secondary.opacity(0.25)))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        Picker("Quality", selection: $quality) {
                            ForEach(YouTubePublishQuality.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        Picker("Visibility", selection: $privacy) {
                            ForEach(YouTubePrivacyStatus.allCases, id: \.rawValue) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                    }
                    VStack {
                        Picker("Quality", selection: $quality) {
                            ForEach(YouTubePublishQuality.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        Picker("Visibility", selection: $privacy) {
                            ForEach(YouTubePrivacyStatus.allCases, id: \.rawValue) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                    }
                }
                Picker("Audience", selection: $audience) {
                    ForEach(YouTubeAudience.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                Toggle("Schedule publication", isOn: $schedule)
                if schedule {
                    DatePicker("Publish at", selection: $publishAt,
                               in: Date().addingTimeInterval(300)...)
                    Text("Scheduled videos upload as private, then YouTube publishes them at this time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("Video")
        }
    }

    private var finishingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $includeChapters) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Named sections as chapters")
                        Text(chapters.isEmpty
                             ? "Needs at least 3 sections, each 10 seconds or longer."
                             : "\(chapters.count) chapters will be added to the description.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(chapters.isEmpty)

                Toggle(isOn: $includeCaptions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upload captions")
                        Text(captions == nil
                             ? "There are no captions inside this export range."
                             : "Timed captions become an editable YouTube subtitle track.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(captions == nil)
                if includeCaptions, captions != nil {
                    LabeledContent("Caption language") {
                        TextField("en", text: $captionLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                }
                Toggle("Use the current frame as thumbnail", isOn: $useThumbnail)
            }
        } label: {
            Text("Finishing")
        }
    }

    private var advancedSection: some View {
        GroupBox {
            Toggle(isOn: $containsSyntheticMedia) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Realistic altered or synthetic content")
                    Text("Turn this on only when YouTube's realistic-content disclosure applies; animation alone does not require it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text("Disclosure")
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let phase {
                HStack {
                    Text(phase.rawValue)
                        .font(.caption)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                }
                ProgressView(value: progress)
            }
            HStack {
                Button(showAdvanced ? "Hide advanced" : "Advanced") {
                    showAdvanced.toggle()
                }
                .disabled(isPublishing)
                Spacer()
                if isPublishing {
                    Button("Cancel", role: .cancel) {
                        cancellation?.cancel()
                        publishTask?.cancel()
                    }
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Publish") { publish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canPublish)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
    }

    private func success(_ result: YouTubeUploadResult) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("Published to YouTube")
                .font(.title2.bold())
            Text(title)
                .foregroundStyle(.secondary)
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(warnings, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding()
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    Button("Copy link") { copy(result.watchURL.absoluteString) }
                    Link("View video", destination: result.watchURL)
                    Link("Finish in YouTube Studio", destination: result.studioURL)
                        .buttonStyle(.borderedProminent)
                }
                VStack {
                    Link("Finish in YouTube Studio", destination: result.studioURL)
                        .buttonStyle(.borderedProminent)
                    HStack {
                        Button("Copy link") { copy(result.watchURL.absoluteString) }
                        Link("View video", destination: result.watchURL)
                    }
                }
            }
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(24)
    }

    private var chapters: [YouTubePublishPlan.Chapter] {
        YouTubePublishPlan.chapters(for: model.document, firstTitle: title)
    }

    private var captions: String? {
        YouTubePublishPlan.webVTT(for: model.document)
    }

    private var isPublishing: Bool { phase != nil }
    private var canPublish: Bool {
        account.channel != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!schedule || publishAt > Date())
            && !isPublishing
    }

    private var channelIcon: String {
        if account.channel != nil { return "checkmark.circle.fill" }
        if channelError != nil { return "exclamationmark.triangle.fill" }
        return "person.crop.circle"
    }

    @MainActor
    private func refreshChannel() async {
        guard account.isConnected, !isLoadingChannel else { return }
        isLoadingChannel = true
        channelError = nil
        defer { isLoadingChannel = false }
        do {
            try await account.refreshChannel()
        } catch {
            channelError = error.localizedDescription
        }
    }

    private func publish() {
        let document = model.document
        let audio = file.audio
        let assetMedia = file.assetsMedia
        if let preflight = ShippingSupport.preflight(
            document: document,
            availableAudioIDs: Set(audio.keys),
            availableAssetIDs: Set(assetMedia.keys)) {
            errorMessage = preflight
            return
        }

        model.pause()
        warnings = []
        progress = 0
        phase = .rendering
        let cancellation = YouTubePublishCancellation()
        self.cancellation = cancellation
        let renderOptions = quality.options.fitted(aspect: document.settings.frameAspect)
        let exportRange = YouTubePublishPlan.exportRange(for: document)
        let thumbnailTime = min(
            max(model.time, exportRange.from),
            max(exportRange.from, exportRange.to - 1 / Double(renderOptions.fps)))
        let finalDescription = includeChapters
            ? YouTubePublishPlan.description(
                videoDescription, appendingChaptersFrom: document, firstTitle: title)
            : YouTubePublishPlan.videoDescription(videoDescription)
        let metadata = YouTubeVideoMetadata(
            title: title,
            description: finalDescription,
            privacy: privacy,
            madeForKids: audience == .madeForKids,
            publishAt: schedule ? publishAt : nil,
            containsSyntheticMedia: containsSyntheticMedia)
        let captionText = includeCaptions ? captions : nil
        let language = normalizedLanguage
        let shouldUseThumbnail = useThumbnail

        publishTask = Task {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("banny-youtube-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                _ = try await account.validAccessToken() // fail before an expensive render
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let media = try ShippingSupport.materialize(
                        audio: audio, assets: assetMedia, in: directory)
                    let movie = directory.appendingPathComponent("banny-show.mp4")
                    try ShowExporter.export(
                        document: document,
                        assets: SharedAssets.catalog,
                        audioURL: { media.audioURLs[$0] },
                        assetURL: { media.assetURLs[$0] },
                        options: renderOptions,
                        to: movie,
                        progress: { renderProgress in
                            Task { @MainActor in
                                progress = renderProgress * 0.62
                            }
                        },
                        shouldCancel: { cancellation.isCancelled })
                    let thumbnail = shouldUseThumbnail
                        ? try? ShowPreview.thumbnailJPEG(
                            document: document,
                            assets: SharedAssets.catalog,
                            assetURL: { media.assetURLs[$0] },
                            at: thumbnailTime)
                        : nil
                    return (movie, thumbnail)
                }.value

                try Task.checkCancellation()
                phase = .uploading
                let accessToken = try await account.validAccessToken()
                let client = YouTubeUploadClient()
                let uploadResult = try await client.uploadVideo(
                    fileURL: prepared.0,
                    metadata: metadata,
                    accessToken: accessToken,
                    progress: { uploadProgress in
                        Task { @MainActor in
                            progress = 0.62 + uploadProgress * 0.34
                        }
                    })
                phase = .finishing
                progress = 0.97

                var finishingWarnings: [String] = []
                if let captionText {
                    do {
                        try await client.uploadCaptions(
                            webVTT: captionText,
                            videoID: uploadResult.videoID,
                            language: language,
                            accessToken: accessToken)
                    } catch {
                        finishingWarnings.append(
                            "The video is live, but captions need another try in YouTube Studio.")
                    }
                }
                if shouldUseThumbnail {
                    if let thumbnail = prepared.1 {
                        do {
                            try await client.setThumbnail(
                                data: thumbnail,
                                mimeType: "image/jpeg",
                                videoID: uploadResult.videoID,
                                accessToken: accessToken)
                        } catch {
                            finishingWarnings.append(
                                "The video is live, but YouTube kept its generated thumbnail.")
                        }
                    } else {
                        finishingWarnings.append(
                            "The video is live, but Banny Studio could not render the chosen thumbnail.")
                    }
                }

                warnings = finishingWarnings
                progress = 1
                phase = nil
                self.cancellation = nil
                publishTask = nil
                result = uploadResult
            } catch ShowExporter.ExportError.cancelled {
                resetAfterCancellation()
            } catch is CancellationError {
                resetAfterCancellation()
            } catch {
                phase = nil
                progress = 0
                self.cancellation = nil
                publishTask = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private var normalizedLanguage: String {
        let value = captionLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
        let result = String(String.UnicodeScalarView(allowed))
        return result.isEmpty ? "en" : String(result.prefix(15))
    }

    private func resetAfterCancellation() {
        phase = nil
        progress = 0
        cancellation = nil
        publishTask = nil
    }

    private func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

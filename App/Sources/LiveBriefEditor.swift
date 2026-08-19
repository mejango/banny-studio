// Live mode is macOS only; see LiveMode.swift.
#if os(macOS)
import SwiftUI
import BannyCore
import BannyRender

/// The scene and the cast, reopened partway through.
///
/// What a scene is about and who is in it are answers a director changes their
/// mind about after watching thirty seconds of it. Appending a note handles
/// "less shouting"; this handles "actually, she is his sister" — and whatever
/// the set proposed on your behalf is sitting right here, in your words, ready
/// to be rewritten.
struct LiveBriefEditor: View {
    @Binding var brief: LiveBrief
    var catalog: AssetCatalog?
    var onApply: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Scene & cast").font(.title2.weight(.semibold))
                Text("Changing these rewrites the section you are watching.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("The scene")
                        TextField("What kind of place this is, and what is happening",
                                  text: $brief.premise, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .lineLimit(3...8)
                            .padding(8)
                            .background(.quaternary.opacity(0.25),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.quaternary))
                            .accessibilityIdentifier("revise-premise")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel("Cast")
                            Spacer()
                            Button {
                                let n = brief.cast.count
                                brief.cast.append(LiveCastMember(
                                    name: "Banny \(n + 1)",
                                    body: BannyCore.Body.allCases[n % BannyCore.Body.allCases.count],
                                    outfit: LiveCastMember.defaultOutfit(n)))
                            } label: { Label("Add", systemImage: "plus") }
                        }
                        ForEach(brief.cast.indices, id: \.self) { i in
                            LiveCastRow(member: $brief.cast[i],
                                        sceneDresses: brief.mayDressCast,
                                        catalog: catalog) {
                                brief.cast.remove(at: i)
                            }
                            .accessibilityIdentifier("revise-cast-row-\(i)")
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("The sections before this one are untouched.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Rewrite this section", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("revise-apply")
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}
#endif

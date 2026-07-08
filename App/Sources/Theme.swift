import SwiftUI

/// Studio chrome theme (stage/timeline surfaces). Content colors (marks, clips,
/// waveforms, cue art) are shared across themes.
struct Theme {
    var header: Color
    var surface: Color        // timeline scroll background
    var ruler: Color          // ruler + transport bar
    var scrub: Color
    var gutterBase: Color
    var gutterCell: Color
    var gutterDivider: Color
    var ccRow: Color
    var newTrack: Color
    var dividerBar: Color     // stage/timeline divider
    var labelText: Color      // unselected track names
    var stripTint: Color      // presence strip wash
    var shade: Color          // hidden-span overlay
    var mutedText: Color      // ruler numbers, eyes, CC label
    var chipStroke: Color     // caption chip outline

    static let dark = Theme(
        header: Color(red: 0.04, green: 0.04, blue: 0.065),
        surface: Color(red: 0.078, green: 0.078, blue: 0.11),
        ruler: Color(red: 0.055, green: 0.055, blue: 0.086),
        scrub: Color(red: 0.09, green: 0.09, blue: 0.15),
        gutterBase: Color(red: 0.1, green: 0.1, blue: 0.135),
        gutterCell: Color(red: 0.115, green: 0.115, blue: 0.155),
        gutterDivider: Color(red: 0.24, green: 0.24, blue: 0.33),
        ccRow: Color(red: 0.09, green: 0.085, blue: 0.06),
        newTrack: Color(red: 0.09, green: 0.11, blue: 0.09),
        dividerBar: Color(red: 0.16, green: 0.16, blue: 0.22),
        labelText: Color(white: 0.7),
        stripTint: Color.white.opacity(0.025),
        shade: Color.black.opacity(0.55),
        mutedText: Color(white: 0.55),
        chipStroke: Color.black.opacity(0.25))

    static let light = Theme(
        header: Color(red: 0.93, green: 0.92, blue: 0.88),
        surface: Color(red: 0.89, green: 0.88, blue: 0.85),
        ruler: Color(red: 0.84, green: 0.83, blue: 0.79),
        scrub: Color(red: 0.8, green: 0.79, blue: 0.76),
        gutterBase: Color(red: 0.86, green: 0.85, blue: 0.81),
        gutterCell: Color(red: 0.92, green: 0.91, blue: 0.87),
        gutterDivider: Color(red: 0.6, green: 0.6, blue: 0.55),
        ccRow: Color(red: 0.87, green: 0.85, blue: 0.78),
        newTrack: Color(red: 0.85, green: 0.88, blue: 0.83),
        dividerBar: Color(red: 0.7, green: 0.7, blue: 0.66),
        labelText: Color(white: 0.25),
        stripTint: Color.black.opacity(0.03),
        shade: Color.black.opacity(0.22),
        mutedText: Color(white: 0.35),
        chipStroke: Color.black.opacity(0.35))
}

/// Sun/moon toggle for the header.
struct ThemeToggle: View {
    @AppStorage("studioLightMode") private var lightMode = false

    var body: some View {
        Button {
            lightMode.toggle()
        } label: {
            Image(systemName: lightMode ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 12))
                .foregroundStyle(lightMode ? Color.orange : Color(white: 0.75))
        }
        .buttonStyle(.borderless)
        .help("Switch light/dark studio theme")
    }
}

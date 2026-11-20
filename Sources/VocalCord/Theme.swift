import SwiftUI

/// The design's values: a near-black graphite palette, one off-white primary, amber only for warnings, red only for
/// Record. Surfaces are flat; elevation is lightness, never glass or shadow. See `.planning/ui-refresh/UI-SPEC.md`.
enum Theme {
    /// The window, the toolbar band, the sidebar and the side columns.
    static let base = Color(hex: 0x070809)
    /// The work surface: tables, the Read view, the timeline, the terminal, sheets. Never darker than the chrome.
    static let content = Color(hex: 0x0E0F10)
    /// The one selection colour: selected segment, sidebar row, playing row, selected clip, a toggle that's on.
    static let selection = Color(hex: 0x2C2F33)
    /// A row or ghost control under the pointer.
    static let hover = Color.white.opacity(0.04)
    /// Quiet fills: segmented tracks, clip bodies, drop zones, banners.
    static let fill = Color.white.opacity(0.06)
    /// Secondary buttons and the transport play button, at rest, hovered and pressed.
    static let control = Color.white.opacity(0.08)
    static let controlHover = Color.white.opacity(0.12)
    static let controlPressed = Color.white.opacity(0.16)
    static let primary = Color(hex: 0xE8E9EA)
    static let onPrimary = Color(hex: 0x0E0F10)
    static let text = Color(hex: 0xF1F3F0)
    static let secondary = Color(hex: 0x9A9EA3)
    /// Chevrons, placeholders, pause labels. 4.7:1 on the surfaces; never on `selection` (3.3:1), use `secondary` there.
    static let tertiary = Color(hex: 0x7A7E84)
    /// Pane dividers, header rules, card borders.
    static let line = Color.white.opacity(0.09)
    /// Table row separator: fainter than `line`, so a table reads as rows, not a grid.
    static let rule = Color(hex: 0x1E2023)
    /// Text-field borders, dashed drop zones, minor ticks.
    static let stroke = Color.white.opacity(0.14)
    /// Major ticks, a divider being dragged, gap dashes.
    static let strong = Color.white.opacity(0.32)
    /// Kept for borders that must read at 3:1 (text fields, dashed zones on hover).
    static let outline = strong
    /// The keyboard focus ring.
    static let focus = Color.white.opacity(0.7)
    static let amber = Color(hex: 0xF2B544)
}

/// Corner radii. Panes have none: they run edge to edge and the window clips them. Radius follows height
/// (about a quarter of it), and a shape inside another is concentric: inner = outer − inset.
enum Radius {
    /// Banners, the video frame and drop zone, boxes inside sheets.
    static let card = 8.0
    /// Selection and hover fills in lists (sidebar, Outputs, agent tabs).
    static let row = 6.0
    /// Script command chips in rows, badges.
    static let chip = 4.0
    /// Timeline clips.
    static let clip = 4.0

    /// A control `height` tall: 24 → 5, 28 → 6, 32–48 → 7, larger → 8.
    static func control(_ height: Double) -> Double {
        switch height {
        case ..<26: 5
        case ..<30: 6
        case ..<50: 7
        default: 8
        }
    }
}

/// Control sizes: S in panel headers, tables, banners and the inspector; M in the toolbar and sheet footers; L for an
/// empty state's call to action.
enum VCSize {
    case s, m, l

    var height: Double {
        switch self {
        case .s: 24
        case .m: 28
        case .l: 32
        }
    }

    var radius: Double { Radius.control(height) }

    var padding: Double {
        switch self {
        case .s: 8
        case .m: 12
        case .l: 16
        }
    }
}

/// Four sizes, two weights.
extension Font {
    /// Column headers (semibold), metadata, ruler and clip labels, chips, keyboard hints.
    static let vcCaption = Font.system(size: 11)
    static let vcCaptionBold = Font.system(size: 11, weight: .semibold)
    /// All UI text, table cells, buttons, menus.
    static let vcBody = Font.system(size: 13)
    /// Panel titles, selected segments, primary buttons, flagged scores.
    static let vcBodyBold = Font.system(size: 13, weight: .semibold)
    /// Sheet titles, empty-state headings, the inspector's clip title.
    static let vcTitle = Font.system(size: 15, weight: .semibold)
    /// The Read view and recording prompts.
    static let vcDisplay = Font.system(size: 26)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Amber triangle and label, shown only when there is a problem.
struct Warning: View {
    let text: String
    var body: some View {
        Label {
            Text(text).foregroundStyle(Theme.text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
        }
        .font(.vcBody)
    }
}

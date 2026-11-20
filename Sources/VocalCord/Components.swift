import SwiftUI

// The app's shared controls and layout pieces, drawn flat: rounded rectangles sized by `VCSize`, no glass, no
// capsules. See `.planning/ui-refresh/UI-SPEC.md`.

// MARK: Buttons

enum ButtonKind { case primary, secondary, ghost }

/// Text buttons. Primary: the one off-white action on a screen. Secondary: a quiet filled button. Ghost: no fill until
/// the pointer is over it. `selected` fills a secondary or ghost button with the selection grey (a toggle that's on).
struct VCButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var height: Double = 28
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, height: height, selected: selected)
    }

    private struct Styled: View {
        let configuration: Configuration
        let kind: ButtonKind
        let height: Double
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let radius = Radius.control(height)
            configuration.label
                .font(font)
                .foregroundStyle(kind == .primary ? Theme.onPrimary : Theme.text)
                .padding(.horizontal, padding)
                .frame(height: height)
                .background(background, in: .rect(cornerRadius: radius))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.rect(cornerRadius: radius))
                .onHover { hovered = $0 }
        }

        private var font: Font {
            let weight: Font.Weight = kind == .primary ? .semibold : .regular
            if height > 50 { return .system(size: 26, weight: .semibold) }
            if height > 34 { return .system(size: 15, weight: weight) }
            return .system(size: 13, weight: weight)
        }

        private var padding: Double {
            switch height {
            case 50...: 40
            case 34...: 24
            case 30...: 16
            case 26...: 12
            default: 8
            }
        }

        private var background: Color {
            let hot = hovered && isEnabled
            switch kind {
            case .primary:
                return Theme.primary.opacity(configuration.isPressed ? 0.8 : hot ? 0.92 : 1)
            case .secondary:
                return configuration.isPressed ? Theme.controlPressed : selected ? Theme.selection : hot ? Theme.controlHover : Theme.control
            case .ghost:
                return configuration.isPressed ? Theme.fill : selected ? Theme.selection : hot ? Theme.hover : .clear
            }
        }
    }
}

extension ButtonStyle where Self == VCButtonStyle {
    static func vc(_ kind: ButtonKind, _ size: VCSize = .m, selected: Bool = false) -> VCButtonStyle {
        VCButtonStyle(kind: kind, height: size.height, selected: selected)
    }

}

/// An icon-only button: a square `size` tall, the glyph grey until the pointer is over it. `filled` gives it the
/// secondary fill at rest (the transport's play button); `selected` the selection grey.
struct IconButtonStyle: ButtonStyle {
    var size: VCSize = .s
    var filled = false
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, size: size, filled: filled, selected: selected)
    }

    private struct Styled: View {
        let configuration: Configuration
        let size: VCSize
        let filled: Bool
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        /// The button's own keyboard focus, drawn as a quiet outline where the system ring is turned off.
        @Environment(\.isFocused) private var focused
        @State private var hovered = false

        var body: some View {
            let hot = hovered && isEnabled
            configuration.label
                .font(.system(size: size == .s ? 13 : 15))
                .foregroundStyle(filled || selected || hot ? Theme.text : Theme.secondary)
                .frame(width: size.height, height: size.height)
                .background(background(hot), in: .rect(cornerRadius: size.radius))
                .overlay { if focused { RoundedRectangle(cornerRadius: size.radius).strokeBorder(Theme.stroke) } }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.rect(cornerRadius: size.radius))
                .onHover { hovered = $0 }
        }

        private func background(_ hot: Bool) -> Color {
            if configuration.isPressed { return filled ? Theme.controlPressed : Theme.fill }
            if selected { return Theme.selection }
            if filled { return hot ? Theme.controlHover : Theme.control }
            return hot ? Theme.hover : .clear
        }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
    static func icon(_ size: VCSize, filled: Bool = false, selected: Bool = false) -> IconButtonStyle {
        IconButtonStyle(size: size, filled: filled, selected: selected)
    }
}

/// Play and pause for a transport: a filled square button, the same everywhere the voiceover or a take plays.
struct TransportPlayButton: View {
    let playing: Bool
    var size: VCSize = .m
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size == .s ? 10 : 12))
        }
        .buttonStyle(.icon(size, filled: true))
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

// MARK: Segmented control

/// Equal segments on a quiet track: the selected one in the selection grey and semibold, so its state shows by
/// weight as well as fill. Drawn here because the system's segmented control in a toolbar always sits on a glass
/// capsule. VoiceOver gets a real segmented picker.
struct SegmentedTabs<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    let segmentWidth: Double
    var size: VCSize = .m
    /// Each segment's help tag, e.g. "Clone (⌘1)".
    var help: ((Option) -> String)? = nil
    /// What VoiceOver calls the control.
    var label = "View"

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Segment(title: title(option), selected: option == selection, width: segmentWidth, size: size) { selection = option }
                    .help(help?(option) ?? "")
            }
        }
        .padding(2)
        .background(Theme.fill, in: .rect(cornerRadius: size.radius))
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private struct Segment: View {
        let title: String
        let selected: Bool
        let width: Double
        let size: VCSize
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    // The selected label stays bright in a background window too, so the mode still reads at a glance.
                    .foregroundStyle(selected || hovered ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                    .frame(width: width, height: size.height - 4)
                    .background(selected ? Theme.selection : hovered ? Theme.hover : .clear,
                                in: .rect(cornerRadius: size.radius - 2))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
    }
}

extension Mode {
    var title: String {
        switch self {
        case .clone: "Clone"
        case .generate: "Generate"
        case .timeline: "Timeline"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .clone: "1"
        case .generate: "2"
        case .timeline: "3"
        }
    }
}

/// Clone · Generate · Timeline, in the middle of the toolbar.
struct ModeSwitcher: View {
    @Binding var mode: Mode

    var body: some View {
        SegmentedTabs(selection: $mode, options: Mode.allCases, title: \.title, segmentWidth: 84, size: .m,
                      help: { "\($0.title) (⌘\($0.key.character))" }, label: "Mode")
    }
}

// MARK: Table and list pieces

/// The label of a pop-up inside a table row (voice, tone): borderless text and a chevron, a fill only under the
/// pointer, so a table of them doesn't read as a grid of boxes.
struct InlinePopupLabel: View {
    let title: String
    var dim = false
    @State private var hovered = false

    var body: some View {
        // The chevron right after the value, so it reads as this pop-up's and not the next column's; the label still
        // fills the cell, so the whole cell opens the menu.
        HStack(spacing: 4) {
            Text(title).lineLimit(1).foregroundStyle(dim ? Theme.secondary : Theme.text)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovered ? Theme.secondary : Theme.tertiary)
        }
        .font(.vcBody)
        .padding(.horizontal, 6)
        .frame(height: VCSize.s.height)
        .background(hovered ? Theme.hover : .clear, in: .rect(cornerRadius: VCSize.s.radius))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { hovered = $0 }
    }
}

/// A row in a sidebar list: icon, name, the selection grey when chosen.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 13)).foregroundStyle(selected ? Theme.text : Theme.secondary).frame(width: 16)
            Text(title).font(.vcBody).foregroundStyle(Theme.text).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(selected ? Theme.selection : hovered ? Theme.hover : .clear, in: .rect(cornerRadius: Radius.row))
        .contentShape(.rect)
        .onHover { hovered = $0 }
    }
}

/// A thin vertical bar beside a line's text that marks its state (not rendered, changed, flagged).
struct StatusBar: View {
    let color: Color
    var body: some View { RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2) }
}

/// A centred heading, a sentence of what to do, and optionally the button that does it.
struct EmptyState<Action: View>: View {
    let title: String
    var message: String?
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(title).font(.vcTitle).foregroundStyle(Theme.text)
                if let message {
                    Text(message).font(.vcBody).foregroundStyle(Theme.secondary).frame(maxWidth: 320)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.center)
            action
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(title: String, message: String? = nil) {
        self.init(title: title, message: message) { EmptyView() }
    }
}

// MARK: Panes

/// The 1 pt line between panes; `highlighted` while it's being resized or hovered.
struct PaneDivider: View {
    /// `.vertical` for a line between panes side by side, `.horizontal` for one between stacked panes.
    var axis: Axis = .vertical
    var highlighted = false

    var body: some View {
        let color = highlighted ? Theme.strong : Theme.line
        if axis == .vertical { color.frame(width: 1) } else { color.frame(height: 1) }
    }
}

extension View {
    /// The work surface: tables, the Read view, the timeline. Flat; panes meet at 1 pt dividers.
    func panel() -> some View {
        // Not into the safe area: the toolbar band stays one colour above the panes.
        background(Theme.content, ignoresSafeAreaEdges: [])
    }

    /// A side column (Preview and Outputs, Inspector, Pronunciations) on the window's colour; `fill` stretches it to the
    /// column's full height.
    func sidePanel(fill: Bool = true) -> some View {
        frame(maxHeight: fill ? .infinity : nil, alignment: .top)
            .background(Theme.base, ignoresSafeAreaEdges: [])
    }
}

/// A pane's title row, its actions on the right, and the hairline under it.
struct PanelHeader<Title: View, Actions: View>: View {
    @ViewBuilder let title: Title
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            title.font(.vcBodyBold).lineLimit(1)
            Spacer(minLength: 8)
            actions
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 40)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

extension PanelHeader where Title == Text {
    init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.init(title: { Text(title) }, actions: actions)
    }
}

/// The chevron in a side column's header that folds the column away.
struct FoldButton: View {
    /// What is folded, for VoiceOver: "Hide pronunciations".
    let label: String
    /// Towards the edge the pane folds to: right for a side column, down for a strip under the work.
    var systemImage = "chevron.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(.icon)
            .help("Hide (⌥⌘0)")
            .accessibilityLabel("Hide \(label)")
    }
}

/// A pane's 1 pt divider that drags to resize it, lit under the pointer and while dragged. `edge` is the side of the pane
/// it sits on: `.top` for a pane under the work, `.leading` for a column on its right. Dragging away from the pane grows it.
struct ResizeDivider: View {
    let edge: Edge
    @Binding var size: Double
    let range: ClosedRange<Double>
    /// For VoiceOver: "Resize terminal".
    let label: String
    @State private var dragStart: Double?
    @State private var hovered = false

    var body: some View {
        let column = edge == .leading
        PaneDivider(axis: column ? .vertical : .horizontal, highlighted: hovered || dragStart != nil)
            .overlay {
                // 8 pt across, centred on the 1 pt line, so the edge is easy to grab.
                Color.clear
                    .frame(width: column ? 8 : nil, height: column ? nil : 8)
                    .contentShape(.rect)
                    .pointerStyle(.frameResize(position: column ? .leading : .top))
                    .onHover { hovered = $0 }
                    .gesture(DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? size
                            dragStart = start
                            size = (start - (column ? value.translation.width : value.translation.height)).clamped(range)
                        }
                        .onEnded { _ in dragStart = nil })
                    .accessibilityElement()
                    .accessibilityLabel(label)
                    .accessibilityValue("\(Int(size)) points")
                    .accessibilityAdjustableAction { direction in
                        size = (size + (direction == .increment ? 40 : -40)).clamped(range)
                    }
            }
            .zIndex(1)
    }
}

/// A folded strip under the work: a slim full-width bar whose chevron opens it again.
struct FoldedBottomPanel: View {
    let title: String
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PaneDivider(axis: .horizontal)
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.up")
                    Text(title)
                }
                .font(.vcCaption)
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("\(title) (⌥⌘0)")
            .accessibilityLabel("Show \(title.lowercased())")
        }
        .background(Theme.base)
    }
}

/// A folded side column: a slim full-height strip whose chevron opens it again, so the column never leaves a hole.
struct FoldedSidePanel: View {
    /// The column's title, shown on hover and read by VoiceOver.
    let title: String
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) { Image(systemName: "chevron.left") }
                .buttonStyle(.icon)
                .help("\(title) (⌥⌘0)")
                .accessibilityLabel("Show \(title.lowercased())")
                .frame(height: 40)
            Spacer(minLength: 0)
        }
        .frame(width: 28)
        .frame(maxHeight: .infinity)
        .background(Theme.base)
    }
}

/// A mode's sidebar on the window's colour, resizable from the divider on its edge, beside the mode's own panes.
/// Not NavigationSplitView: its sidebar splits into two boxes in full screen and opened at 148 pt on a first launch.
struct SidebarLayout<Sidebar: View, Detail: View>: View {
    // A new key: widths saved before the refresh (220 or more) would squeeze the script table at 1200 pt.
    @AppStorage("sidebarWidthFlat") private var width = 200.0
    @State private var dragStart: Double?
    @State private var hovered = false
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail

    private static var range: ClosedRange<Double> { 180...320 }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: clamp(width))
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.base)
            PaneDivider(highlighted: hovered || dragStart != nil)
                .overlay { handle }
                .zIndex(1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, Self.range.lowerBound), Self.range.upperBound) }

    private var handle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .trailing))
            .onHover { hovered = $0 }
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? clamp(width)
                    dragStart = start
                    width = clamp(start + value.translation.width)
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityElement()
            .accessibilityLabel("Resize sidebar")
            .accessibilityValue("\(Int(clamp(width))) points")
            .accessibilityAdjustableAction { direction in width = clamp(clamp(width) + (direction == .increment ? 20 : -20)) }
    }
}

// MARK: Toolbar

/// The gear, last in every mode's toolbar so it stays in the same corner.
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button { openSettings() } label: { Image(systemName: "gearshape") }
            .buttonStyle(.icon(.m))
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
    }
}

/// Opens and closes the Terminal panel; filled grey while it's open.
struct TerminalToggle: View {
    @AppStorage("terminalOpen") private var open = false
    var enabled = true

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text("Terminal")
            }
        }
        .buttonStyle(.vc(.ghost, .m, selected: open && enabled))
        .disabled(!enabled)
        .help(open ? "Hide Terminal (⌃`)" : "Show Terminal (⌃`)")
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// Every mode's trailing toolbar: the mode's own actions (Render, Export), then Terminal and the gear, which stay at
/// the same place in every mode. No glass behind any of it.
struct WorkspaceToolbar<Actions: View>: ToolbarContent {
    var terminalEnabled = true
    @ViewBuilder let actions: Actions

    init(terminalEnabled: Bool = true, @ViewBuilder actions: () -> Actions) {
        self.terminalEnabled = terminalEnabled
        self.actions = actions()
    }

    var body: some ToolbarContent {
        if Actions.self != EmptyView.self {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) { actions }
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                TerminalToggle(enabled: terminalEnabled)
                SettingsButton()
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

extension WorkspaceToolbar where Actions == EmptyView {
    init(terminalEnabled: Bool = true) {
        self.init(terminalEnabled: terminalEnabled) { EmptyView() }
    }
}

// MARK: Menu commands

extension FocusedValues {
    /// Set by the mode on screen, for the menu bar's commands.
    @Entry var renderAction: (() -> Void)?
    @Entry var exportAction: (() -> Void)?
    @Entry var newItemAction: (() -> Void)?
    /// "New Project" or "New Voice…".
    @Entry var newItemTitle: String?
    @Entry var toggleSidePanel: (() -> Void)?
    /// False while the Terminal can't open (during a clone flow, or with no voice).
    @Entry var terminalAvailable: Bool?
}

/// Every toolbar item as a menu command, with its shortcut.
struct WorkspaceCommands: Commands {
    @AppStorage("mode") private var mode = Mode.clone
    @AppStorage("terminalOpen") private var terminalOpen = false
    @FocusedValue(\.renderAction) private var render
    @FocusedValue(\.exportAction) private var export
    @FocusedValue(\.newItemAction) private var newItem
    @FocusedValue(\.newItemTitle) private var newItemTitle
    @FocusedValue(\.toggleSidePanel) private var toggleSidePanel
    @FocusedValue(\.terminalAvailable) private var terminalAvailable

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(newItemTitle ?? "New") { newItem?() }
                .keyboardShortcut("n")
                .disabled(newItem == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Render") { render?() }
                .keyboardShortcut("r")
                .disabled(render == nil)
            Button("Export…") { export?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(export == nil)
        }
        CommandGroup(before: .toolbar) {
            ForEach(Mode.allCases, id: \.self) { item in
                Button(item.title) { mode = item }.keyboardShortcut(item.key)
            }
            Divider()
            Button(terminalOpen ? "Hide Terminal" : "Show Terminal") { terminalOpen.toggle() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(terminalAvailable == false)
            Button("Toggle Side Panel") { toggleSidePanel?() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(toggleSidePanel == nil)
            Divider()
        }
    }
}

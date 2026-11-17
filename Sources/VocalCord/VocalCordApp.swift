import SwiftUI

@main
struct VocalCordApp: App {
    @State private var store: VoiceStore
    @State private var projects: ProjectStore
    @State private var player: Player
    @State private var preview: Preview
    @State private var waveforms = Waveforms()
    @State private var terminals: Terminals
    @State private var jev: Jev
    @State private var setup: Setup

    init() {
        // The design is grey: a graphite accent turns focus rings, selections and checkboxes grey whatever the system
        // accent. The argument domain outranks the user's global setting and is never saved.
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleAccentColor"] = -1
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        // A downloaded copy marks every file as quarantined. Opening the app clears the check for the app itself,
        // not for the helpers it starts (uv, and vocalcord-mcp, which the terminal agents launch), so drop the
        // mark on those. It fails quietly when the app isn't writable, e.g. when run straight from the DMG.
        let helpers = Bundle.main.executableURL!.deletingLastPathComponent()
        for name in ["uv", "vocalcord-mcp"] {
            removexattr(helpers.appending(path: name).path, "com.apple.quarantine", 0)
        }
        // A dev engine runs as it is; otherwise the app installs its own on first run.
        let dev = EngineLocation.dev
        let engine = EngineClient(location: dev ?? EngineInstall.standard.location)
        _setup = State(initialValue: Setup(engine: engine, install: dev == nil ? .standard : nil))
        let store = VoiceStore(engine: engine)
        let projects = ProjectStore()
        let player = Player()
        let jev = Jev()
        _store = State(initialValue: store)
        _projects = State(initialValue: projects)
        _player = State(initialValue: player)
        _preview = State(initialValue: Preview(player: player))
        _jev = State(initialValue: jev)
        // The agents' tools act on the project open in Generate and the voice selected in Clone.
        let tools = ToolBridge(projects: projects, voices: store, jev: jev,
                               projectID: { UserDefaults.standard.string(forKey: "project") },
                               voiceID: { UserDefaults.standard.string(forKey: "voice") })
        _terminals = State(initialValue: Terminals(tools: tools))
    }

    var body: some Scene {
        Window("VocalCord", id: "main") {
            RootView()
                .environment(store)
                .environment(projects)
                .environment(player)
                .environment(preview)
                .environment(waveforms)
                .environment(terminals)
                .environment(jev)
                .environment(setup)
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView().environment(jev).environment(setup).preferredColorScheme(.dark)
        }
    }
}

enum Mode: String { case clone, generate }

struct RootView: View {
    @Environment(VoiceStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @Environment(Setup.self) private var setup
    @AppStorage("mode") private var mode = Mode.clone

    var body: some View {
        Group {
            if setup.done { modes } else { SetupView() }
        }
        // Wide enough for every script column beside the sidebar and an open side column.
        .frame(minWidth: 1200, minHeight: 640)
        // The blue focus ring clashes with the grey design; text fields turn it back on.
        .focusEffectDisabled()
        .containerBackground(Theme.base, for: .window)
        // The toolbar sits on the window's colour; the panels below give the structure.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .preferredColorScheme(.dark)
        .foregroundStyle(Theme.text)
        .alert(store.error ?? "", isPresented: Binding(present: Bindable(store).error)) {
            Button("OK") {}
        }
        .alert(projects.error ?? "", isPresented: Binding(present: Bindable(projects).error)) {
            Button("OK") {}
        }
    }

    private var modes: some View {
        Group {
            switch mode {
            case .clone: CloneView()
            case .generate: GenerateView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $mode) {
                    Text("Clone").tag(Mode.clone)
                    Text("Generate").tag(Mode.generate)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .focusEffectDisabled()
            }
        }
    }
}

/// The gear, last in each mode's toolbar so it stays in the same corner.
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings", systemImage: "gearshape") { openSettings() }
    }
}

/// A mode's sidebar as one glass panel, resizable from its edge, beside the mode's own panels. Every column sits on the
/// window's base colour with 8 pt between them. Not NavigationSplitView: its sidebar splits into two boxes in full
/// screen and opened at 148 pt on a first launch.
struct SidebarLayout<Sidebar: View, Detail: View>: View {
    @AppStorage("sidebarWidth") private var width = 220.0
    @State private var dragStart: Double?
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail

    private static var range: ClosedRange<Double> { 220...360 }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: clamp(width))
                .frame(maxHeight: .infinity, alignment: .top)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .padding(8)
                .overlay(alignment: .trailing) { handle }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 8)
                .padding(.trailing, 8)
        }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, Self.range.lowerBound), Self.range.upperBound) }

    private var handle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .trailing))
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

struct SettingsView: View {
    @Environment(Setup.self) private var setup
    @AppStorage(EngineSettings.modelKey) private var model = EngineSettings.defaultModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    // A model's first choice downloads it; the switch happens once it's ready.
                    Picker("Model", selection: Binding(get: { setup.switching ?? model }, set: { setup.choose($0) })) {
                        ForEach(["8bit", "4bit"], id: \.self) { Text(EngineSettings.titles[$0]!).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(!setup.done || setup.switching != nil)
                    if setup.done, let progress = setup.progress {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ProgressView(value: progress.fraction)
                                Button("Cancel", action: setup.cancel)
                            }
                            Text("\(progress.step): \(progress.detail)").monospacedDigit().foregroundStyle(Theme.secondary)
                        }
                        .padding(.top, 8)
                    }
                    if setup.done, let error = setup.error {
                        Warning(text: error).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }
                }
                .padding(24)
                .frame(width: 440)
            }
            Tab("Plugins", systemImage: "puzzlepiece.extension") { PluginSettings() }
        }
    }
}

/// Add Jev: the API key is checked with TypeSafe, then kept in the Keychain.
struct PluginSettings: View {
    @Environment(Jev.self) private var jev
    @State private var adding = false
    @State private var key = ""
    @State private var validating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Jev").font(.system(size: 15, weight: .semibold))
                    Text("Checks that each line reads as speech, fits its tone, and keeps its meaning after a rewrite. "
                        + "Only line text and tones are sent to TypeSafe.")
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if jev.added {
                    Text("Added").foregroundStyle(Theme.secondary).frame(height: 30)
                    Button("Remove") {
                        do { try jev.remove() } catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.outline)
                } else if !adding {
                    Button("Add Jev") { adding = true }.buttonStyle(.outline)
                }
            }
            if adding, !jev.added {
                SecureField("TypeSafe API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel") {
                        adding = false
                        key = ""
                        error = nil
                    }
                    .buttonStyle(.outline)
                    .disabled(validating)
                    Button(validating ? "Checking key…" : "Add", action: add)
                        .buttonStyle(.primary(height: 30))
                        .disabled(validating || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error { Warning(text: error) }
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(width: 440, alignment: .topLeading)
    }

    private func add() {
        guard !validating else { return }
        validating = true
        error = nil
        Task {
            defer { validating = false }
            do {
                try await jev.add(key: key)
                key = ""
                adding = false
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

enum Theme {
    static let base = Color(hex: 0x070809)
    static let content = Color(hex: 0x0E0F10)
    static let selection = Color(hex: 0x2C2F33)
    /// A row under the pointer: fainter than `selection`.
    static let hover = Color.white.opacity(0.035)
    static let primary = Color(hex: 0xE8E9EA)
    static let onPrimary = Color(hex: 0x0E0F10)
    static let text = Color(hex: 0xF1F3F0)
    static let secondary = Color(hex: 0x9A9EA3)
    static let line = Color.white.opacity(0.09)
    /// Table row separator: fainter than `line`, so a table reads as rows, not a grid.
    static let rule = Color(hex: 0x1E2023)
    static let outline = Color.white.opacity(0.32)
    static let amber = Color(hex: 0xF2B544)
}

extension View {
    /// The main column: solid, so text and tables read on a flat surface.
    func panel() -> some View {
        background(Theme.content)
            .clipShape(.rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
    }

    /// A side column's glass panel; `fill` stretches it to the column's full height.
    func sidePanel(fill: Bool = true) -> some View {
        frame(maxHeight: fill ? .infinity : nil, alignment: .top)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// The chevron in a side column's header that folds the column away.
struct FoldButton: View {
    /// What is folded, for VoiceOver: "Hide pronunciations".
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "chevron.right").padding(6).contentShape(.rect) }
            .buttonStyle(.plain)
            .help("Hide")
            .accessibilityLabel("Hide \(label)")
    }
}

/// A folded side column: a slim full-height strip whose chevron opens it again, so the column never leaves a hole.
struct FoldedSidePanel: View {
    /// The column's title, shown on hover and read by VoiceOver.
    let title: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) { Image(systemName: "chevron.left").padding(8).contentShape(.rect) }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel("Show \(title.lowercased())")
            .frame(width: 44, height: 52)
            .sidePanel()
    }
}

/// A panel's title row, its actions on the right, and the hairline under it.
struct PanelHeader<Title: View, Actions: View>: View {
    @ViewBuilder let title: Title
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            title.font(.system(size: 17, weight: .bold)).lineLimit(1)
            Spacer(minLength: 8)
            actions
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1).padding(.horizontal, 8) }
    }
}

extension PanelHeader where Title == Text {
    init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.init(title: { Text(title) }, actions: actions)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Binding where Value == Bool {
    /// True while the optional has a value; setting false clears it.
    init<T: Sendable>(present: Binding<T?>) {
        self.init(get: { present.wrappedValue != nil }, set: { if !$0 { present.wrappedValue = nil } })
    }
}

/// The one off-white action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, height: height)
    }

    private struct Styled: View {
        let configuration: Configuration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: height > 50 ? 26 : 14, weight: .semibold))
                .foregroundStyle(Theme.onPrimary)
                .padding(.horizontal, height > 50 ? 40 : 16)
                .frame(height: height)
                .background(Theme.primary.opacity(configuration.isPressed ? 0.8 : 1),
                            in: .rect(cornerRadius: height > 50 ? 20 : 9))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.rect)
        }
    }
}

/// Every other button: a thin outline.
struct OutlineButtonStyle: ButtonStyle {
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, height: height)
    }

    private struct Styled: View {
        let configuration: Configuration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: height > 40 ? 17 : 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, height > 40 ? 26 : 12)
                .frame(height: height)
                .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0), in: .rect(cornerRadius: height > 40 ? 11 : 8))
                .overlay(RoundedRectangle(cornerRadius: height > 40 ? 11 : 8).strokeBorder(Theme.outline))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.rect)
        }
    }
}

/// The off-white action in the toolbar: a capsule at the height of the native toolbar buttons beside it. Drawn here,
/// not as tinted glass, so it stays off-white when the window is in the background.
struct ToolbarPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.onPrimary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Theme.primary.opacity(configuration.isPressed ? 0.8 : 1), in: .capsule)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(.capsule)
        }
    }
}

extension ButtonStyle where Self == ToolbarPrimaryButtonStyle {
    static var toolbarPrimary: ToolbarPrimaryButtonStyle { ToolbarPrimaryButtonStyle() }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static func primary(height: CGFloat) -> PrimaryButtonStyle { PrimaryButtonStyle(height: height) }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
    static func outline(height: CGFloat) -> OutlineButtonStyle { OutlineButtonStyle(height: height) }
}

/// Red dot used on every Record button.
struct RecordDot: View {
    var size: CGFloat = 9
    var body: some View { Circle().fill(.red).frame(width: size, height: size) }
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
        .font(.system(size: 13, weight: .medium))
    }
}

func formatTime(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
}

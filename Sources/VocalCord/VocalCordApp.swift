import SwiftUI

@main
struct VocalCordApp: App {
    @State private var store = VoiceStore(engine: EngineClient())
    @State private var projects = ProjectStore()
    @State private var player = Player()
    @State private var waveforms = Waveforms()

    var body: some Scene {
        Window("VocalCord", id: "main") {
            RootView()
                .environment(store)
                .environment(projects)
                .environment(player)
                .environment(waveforms)
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView().preferredColorScheme(.dark)
        }
    }
}

enum Mode: String { case clone, generate }

struct RootView: View {
    @Environment(VoiceStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    @Environment(\.openSettings) private var openSettings
    @AppStorage("mode") private var mode = Mode.clone

    var body: some View {
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
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") { openSettings() }
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        // The blue focus ring clashes with the grey design; text fields turn it back on.
        .focusEffectDisabled()
        .containerBackground(Theme.base, for: .window)
        .preferredColorScheme(.dark)
        .foregroundStyle(Theme.text)
        .alert(store.error ?? "", isPresented: Binding(present: Bindable(store).error)) {
            Button("OK") {}
        }
        .alert(projects.error ?? "", isPresented: Binding(present: Bindable(projects).error)) {
            Button("OK") {}
        }
    }
}

struct SettingsView: View {
    @AppStorage(EngineSettings.modelKey) private var model = EngineSettings.defaultModel

    var body: some View {
        Form {
            Picker("Model", selection: $model) {
                Text("Best quality (8-bit)").tag("8bit")
                Text("Fast (4-bit)").tag("4bit")
            }
            .pickerStyle(.radioGroup)
        }
        .padding(24)
        .frame(width: 340)
    }
}

enum Theme {
    static let base = Color(hex: 0x070809)
    static let content = Color(hex: 0x0E0F10)
    static let selection = Color(hex: 0x2C2F33)
    static let primary = Color(hex: 0xE8E9EA)
    static let onPrimary = Color(hex: 0x0E0F10)
    static let text = Color(hex: 0xF1F3F0)
    static let secondary = Color(hex: 0x9A9EA3)
    static let line = Color.white.opacity(0.09)
    static let outline = Color.white.opacity(0.32)
    static let amber = Color(hex: 0xF2B544)
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

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
        Task { await store.checkCutOff() }
        let projects = ProjectStore()
        let player = Player()
        let jev = Jev()
        _store = State(initialValue: store)
        _projects = State(initialValue: projects)
        _player = State(initialValue: player)
        _preview = State(initialValue: Preview(player: player))
        _jev = State(initialValue: jev)
        // The agents' tools act on the project open in Generate and Timeline, and the voice selected in Clone.
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
        // A slim bar without the app's name (it's in the Dock and the Window menu): the switcher and actions only.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { WorkspaceCommands() }

        Settings {
            SettingsView().environment(jev).environment(setup).preferredColorScheme(.dark)
        }
    }
}

enum Mode: String, CaseIterable { case clone, generate, timeline }

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
            case .timeline: EditView()
            }
        }
        // The hairline between the toolbar band and the panes.
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .toolbar {
            ToolbarItem(placement: .principal) { ModeSwitcher(mode: $mode) }
                .sharedBackgroundVisibility(.hidden)
        }
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
                    .buttonStyle(.vc(.secondary))
                } else if !adding {
                    Button("Add Jev") { adding = true }.buttonStyle(.vc(.secondary))
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
                    .buttonStyle(.vc(.secondary))
                    .disabled(validating)
                    Button(validating ? "Checking key…" : "Add", action: add)
                        .buttonStyle(.vc(.primary))
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

extension Binding where Value == Bool {
    /// True while the optional has a value; setting false clears it.
    init<T: Sendable>(present: Binding<T?>) {
        self.init(get: { present.wrappedValue != nil }, set: { if !$0 { present.wrappedValue = nil } })
    }
}

func formatTime(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return "\(total / 60):" + String(format: "%02d", total % 60)
}

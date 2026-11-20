import AppKit
import SwiftUI
import Testing
@testable import VocalCord

// Clone's other states drawn off-screen: no voices, the Terminal panel, the clone flows, the sheets and first-run setup.
// Images go to WINDOW_SNAPSHOTS, or VocalCordSnapshots in the temporary folder, next to WindowSnapshotTests' captures.
//
// Every setting a view reads with @AppStorage comes from a private defaults suite, not UserDefaults.standard: test runs
// in other checkouts share the standard domain, and a Terminal panel opened here must never open in one of them with
// real agents. The Terminal here is handed its agents, so it neither looks for them nor starts a process.

private let hasWindowServer = CGSessionCopyCurrentDictionary() != nil
private let snapshots = URL(filePath: ProcessInfo.processInfo.environment["WINDOW_SNAPSHOTS"]
    ?? FileManager.default.temporaryDirectory.appending(path: "VocalCordSnapshots").path)

/// A voice with takes in three tones (two scored by an audition), and two pronunciations.
@MainActor private func cloneFixture(scored: Bool = true) throws -> (VoiceStore, String) {
    let root = try tempFolder()
    let voices = VoiceStore(root: root, engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Maya")
    // The first is too long for two lines, to show the ellipsis.
    let takes = [("Neutral", "I record a few lines in my normal voice, the way I'd explain something to a friend over coffee on a slow "
                    + "Sunday morning, with nowhere to be and nothing to prove, and the kettle just starting to sing in the kitchen."),
                 ("Neutral", "This is my second take, a little slower, so the model hears how I pause."),
                 ("Happy", "Honestly, this is the part I was most excited to show you."),
                 ("Confident", "It works offline, it's private, and it sounds like you.")]
    for (tone, transcript) in takes {
        let file = try tempFolder().appending(path: "take.wav")
        try writeWAV(speechLike(seconds: 12, amplitude: 0.5, floor: 0.01)[...], rate: 24000, to: file)
        try voices.addTake(voiceID, file: file, tone: tone, transcript: transcript, issues: [])
    }
    voices.addPronunciation(word: "Kuber", respelling: "Koo-ber", voiceID: voiceID)
    voices.addPronunciation(word: "Gnocchi", respelling: "Nyok-ee", voiceID: voiceID)
    guard scored else { return (voices, voiceID) }
    // What an audition leaves: a score on some takes. Written as the app saves it, then read back.
    let index = root.appending(path: "voices.json")
    var saved = try JSONDecoder().decode([Voice].self, from: Data(contentsOf: index))
    saved[0].takes[0].score = 0.87
    saved[0].takes[2].score = 0.91
    try JSONEncoder().encode(saved).write(to: index)
    return (VoiceStore(root: root, engine: FakeEngine(delay: .zero)), voiceID)
}

/// A defaults suite of its own for one capture, removed afterwards.
private final class IsolatedDefaults {
    let name = testSuite("VocalCordTests.clone")
    let defaults: UserDefaults

    init(_ values: [String: Any]) {
        defaults = UserDefaults(suiteName: name)!
        for (key, value) in values { defaults.set(value, forKey: key) }
    }

    deinit { dropDefaults(name) }
}

/// The app's root view with its environments and the private settings.
@MainActor private func root(voices: VoiceStore, terminals: (ToolBridge) throws -> Terminals, setup: Setup? = nil,
                             settings: IsolatedDefaults, projects given: ProjectStore? = nil) throws -> some View {
    let projects = try given ?? ProjectStore(root: try tempFolder(), exportsRoot: try tempFolder())
    let player = Player()
    let jev = Jev(keys: MemoryKeys(nil))
    let tools = ToolBridge(projects: projects, voices: voices, jev: jev, projectID: { nil })
    let engine = EngineClient(location: EngineLocation(python: URL(filePath: "/nonexistent"), source: URL(filePath: "/nonexistent")))
    return RootView()
        .environment(voices)
        .environment(projects)
        .environment(player)
        .environment(Preview(player: player))
        .environment(Waveforms())
        .environment(try terminals(tools))
        .environment(jev)
        .environment(setup ?? Setup(engine: engine, install: nil))
        .defaultAppStorage(settings.defaults)
}

/// Draws `view` in an off-screen window into `<name>.png`: with the toolbar when `toolbar`, else just the view.
@MainActor private func capture(_ view: some View, size: NSSize, name: String, toolbar: Bool = true) async throws {
    _ = NSApplication.shared
    let controller = NSHostingController(rootView: view)
    if toolbar { controller.sceneBridgingOptions = [.toolbars, .title] }
    let style: NSWindow.StyleMask = toolbar ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "VocalCord"
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = NSColor(Theme.base)
    window.contentViewController = controller
    if toolbar {
        // What the scene's `.windowToolbarStyle(.unifiedCompact(showsTitle: false))` sets on the real window.
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
    }
    window.setContentSize(size)
    // Far off any screen, so it never shows; ordered in so the toolbar lays out.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.orderFrontRegardless()
    for _ in 0..<24 {
        window.layoutIfNeeded()
        // Suspends, so the views' tasks (waveforms) get the main actor; the run loop draws meanwhile.
        try await Task.sleep(for: .milliseconds(50))
    }
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    let out = snapshots.appending(path: "\(name).png")
    defer { window.orderOut(nil); window.close() }
    if toolbar, CGPreflightScreenCaptureAccess() {
        let screencapture = Process()
        screencapture.executableURL = URL(filePath: "/usr/sbin/screencapture")
        screencapture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.path]
        try screencapture.run()
        screencapture.waitUntilExit()
        if screencapture.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) { return }
    }
    let frame = try #require(toolbar ? window.contentView?.superview : window.contentView)
    let base = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.bounds.width * 2), pixelsHigh: Int(frame.bounds.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: base.colorSpaceName, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = frame.bounds.size
    frame.cacheDisplay(in: frame.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: out)
}

@MainActor @Test func handedAgentsAreNeverLookedForOrStarted() async throws {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let projects = ProjectStore(root: try tempFolder(), exportsRoot: try tempFolder())
    let tools = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys(nil)), projectID: { nil })
    let terminals = Terminals(tools: tools, support: try tempFolder(), found: [.codex: "/nonexistent/codex", .claude: "/nonexistent/claude"])
    #expect(terminals.installed == [.codex: "/nonexistent/codex", .claude: "/nonexistent/claude"])
    #expect(terminals.selected == .claude)
    await terminals.detect()
    #expect(terminals.installed?.count == 2)
    let session = terminals.session(.claude)
    #expect(session.process.running == false)
    // None found: still no shell to look for them.
    let none = Terminals(tools: tools, support: try tempFolder(), found: [:])
    await none.detect()
    #expect(none.installed == [:] && none.selected == nil)
}

@MainActor @Test(.enabled(if: hasWindowServer, "Needs a window server to draw."))
func snapshotsOfCloneStates() async throws {
    // Short, like GenerateScriptTests': a socket path in the temporary folder is longer than a socket allows. One per
    // Terminals, removed at the end.
    var supports: [URL] = []
    defer { for folder in supports { try? FileManager.default.removeItem(at: folder) } }
    let handed: (ToolBridge) throws -> Terminals = { tools in
        let support = URL(filePath: "/tmp/vc-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        supports.append(support)
        return Terminals(tools: tools, support: support, found: [.claude: "/nonexistent/claude", .codex: "/nonexistent/codex"])
    }

    // No voices yet: the empty state's New voice, at the narrowest window.
    let empty = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let emptySettings = IsolatedDefaults(["mode": Mode.clone.rawValue, "terminalOpen": false, "pronunciationsOpen": true])
    try await capture(try root(voices: empty, terminals: handed, settings: emptySettings), size: NSSize(width: 1200, height: 700),
                      name: "window-clone-empty")

    // The Terminal panel under the takes, its session ended; scores show the Like you column; pronunciations listed.
    let (voices, voiceID) = try cloneFixture()
    let terminalSettings = IsolatedDefaults(["mode": Mode.clone.rawValue, "voice": voiceID, "terminalOpen": true,
                                             "terminalWidth": 360.0, "pronunciationsOpen": true])
    var terminals: Terminals?
    let terminalRoot = try root(voices: voices, terminals: { tools in
        let made = try handed(tools)
        terminals = made
        return made
    }, settings: terminalSettings)
    let session = try #require(terminals).session(.claude)
    session.feed(text: "\u{1B}[2mVocalCord's voiceover director\u{1B}[0m\r\n\r\n> Fix the transcript of the second Neutral take.\r\n")
    terminals?.processTerminated(source: session, exitCode: 0)
    try await capture(terminalRoot, size: NSSize(width: 1280, height: 800), name: "window-clone-terminal")

    // Generate with the Terminal as a column on the right, Preview and Outputs under the script.
    let film = ProjectStore(root: try tempFolder(), exportsRoot: try tempFolder())
    let projectID = film.create(name: "Launch film")
    film.addLines(["Meet the next chapter of your voice.", "Everything is ready."], to: projectID, voices: voices)
    let generateSettings = IsolatedDefaults(["mode": Mode.generate.rawValue, "project": projectID, "terminalOpen": true,
                                             "terminalWidth": 360.0])
    var generateTerminals: Terminals?
    let generateRoot = try root(voices: voices, terminals: { tools in
        let made = try handed(tools)
        generateTerminals = made
        return made
    }, settings: generateSettings, projects: film)
    let generateSession = try #require(generateTerminals).session(.claude)
    generateSession.feed(text: "\u{1B}[2mVocalCord's voiceover director\u{1B}[0m\r\n\r\n> Review the pace of my script.\r\n")
    try await capture(generateRoot, size: NSSize(width: 1280, height: 800), name: "window-generate-terminal")

    // The voice page with Pronunciations folded, at the narrowest window.
    let foldedSettings = IsolatedDefaults(["mode": Mode.clone.rawValue, "voice": voiceID, "terminalOpen": false,
                                           "pronunciationsOpen": false])
    try await capture(try root(voices: voices, terminals: handed, settings: foldedSettings), size: NSSize(width: 1200, height: 700),
                      name: "window-clone-folded")

    // First-run setup.
    let folder = try tempFolder()
    let install = EngineInstall(folder: folder.appending(path: "Engine"), source: folder.appending(path: "engine"),
                                uv: URL(filePath: "/missing/uv"), cache: folder.appending(path: "cache"))
    let setup = Setup(engine: EngineClient(location: install.location), install: install)
    try #require(!setup.done)
    let setupSettings = IsolatedDefaults(["mode": Mode.clone.rawValue])
    try await capture(try root(voices: empty, terminals: handed, setup: setup, settings: setupSettings),
                      size: NSSize(width: 1200, height: 700), name: "window-setup")

    // The clone flows as the work pane draws them (759 pt wide beside the sidebar at 1200).
    let flowSettings = IsolatedDefaults([:])
    let projects = ProjectStore(root: try tempFolder(), exportsRoot: try tempFolder())
    func pane(_ view: some View) -> some View {
        view.panel()
            .environment(voices)
            .environment(Player())
            .environment(Waveforms())
            .environment(projects)
            .defaultAppStorage(flowSettings.defaults)
            .preferredColorScheme(.dark)
            .foregroundStyle(Theme.text)
    }
    try await capture(pane(FileCloneView(name: "Narrator") { _ in }), size: NSSize(width: 759, height: 760), name: "clone-flow-file",
                      toolbar: false)
    try await capture(pane(FileCloneView(name: "Narrator", script: false) { _ in }), size: NSSize(width: 759, height: 760),
                      name: "clone-flow-any-file", toolbar: false)

    // The sheets.
    try await capture(pane(NewVoiceSheet { _ in }), size: NSSize(width: 520, height: 300), name: "sheet-new-voice", toolbar: false)
    let voice = try #require(voices.voice(voiceID))
    try await capture(pane(VoiceCheckSheet(voice: voice)), size: NSSize(width: 820, height: 400), name: "sheet-voice-check",
                      toolbar: false)
}

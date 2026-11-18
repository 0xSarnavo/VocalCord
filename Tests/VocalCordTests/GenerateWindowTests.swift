import AppKit
import SwiftUI
import Testing
@testable import VocalCord

// Generate's states the whole-window captures in WindowSnapshotTests don't reach: lines waiting to render, a render
// running, no projects, the side column folded, the widest sidebar. Each window keeps its settings in a defaults suite
// of its own, so another test process writing the shared defaults (the mode, the project) can't change it mid-capture.
// Images go to WINDOW_SNAPSHOTS, or VocalCordSnapshots in the temporary folder, as `window-generate-<name>.png`.

private let hasWindowServer = CGSessionCopyCurrentDictionary() != nil
private let snapshots = URL(filePath: ProcessInfo.processInfo.environment["WINDOW_SNAPSHOTS"]
    ?? FileManager.default.temporaryDirectory.appending(path: "VocalCordSnapshots").path)

/// A voice with a take, and a project of six lines of which the first `rendered` have a render; the rest wait for one.
/// The engine takes `delay` for each call, so a long one keeps a render running.
@MainActor private func generateFixture(rendered: Int, delay: Duration) throws -> (VoiceStore, ProjectStore, String) {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: delay))
    let voiceID = voices.createVoice(name: "Maya", fullClone: false)
    let take = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 6, amplitude: 0.5, floor: 0.01)[...], rate: 24000, to: take)
    try voices.addTake(voiceID, file: take, tone: "Neutral", transcript: "A take in my own voice.", issues: [])

    let texts = ["Meet the next chapter of your voice.", "Everything is ready. [pause 0.4] Just press record.",
                 "This is where it begins, with a [stress]simple[/stress] step forward.", "Make every moment count.",
                 "Your story, your voice, shapes what's next.", "Ready when you are."]
    let root = try tempFolder()
    var project = Project(name: "Launch film", lines: [])
    let renders = root.appending(path: "\(project.id)/renders", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
    for (index, text) in texts.enumerated() {
        var line = Line(text: text, voiceID: voiceID)
        if index < rendered {
            let words = Marks.parse(text).spokenTokens.indices.map { WordTime(start: 0.3 + Double($0) * 0.38, end: 0.6 + Double($0) * 0.38) }
            let duration = (words.last?.end ?? 2) + 0.3
            let scores = Scores(likeYou: [87, 89, 62, 88, 91, 86][index], human: [4.1, 4.2, 3.1, 4.3, 4.4, 4.0][index], words: 98,
                                heard: Marks.plain(text), referencePace: 2.4)
            let version = Version(id: UUID().uuidString, text: text, voiceID: voiceID, tone: "Neutral", direction: false, seed: 1,
                                  duration: duration, createdAt: .now, scores: scores, words: words)
            try writeWAV(speechLike(seconds: duration, amplitude: 0.5, floor: 0.005)[...], rate: 24000,
                         to: renders.appending(path: "\(version.id).wav"))
            line.versions = [version]
            line.chosen = version.id
        }
        project.lines.append(line)
    }
    try JSONEncoder().encode(project).write(to: root.appending(path: "\(project.id)/project.json"))
    return (voices, ProjectStore(root: root, exportsRoot: try tempFolder()), project.id)
}

/// The app's root view in a titled window with its toolbar, its settings in `defaults`, drawn into
/// `window-generate-<name>.png`. `prepare` runs once the window shows, before the capture.
@MainActor private func capture(_ name: String, voices: VoiceStore, projects: ProjectStore, defaults: [String: Any],
                                size: NSSize = NSSize(width: 1280, height: 800), prepare: () -> Void = {}) async throws {
    _ = NSApplication.shared
    let suiteName = "VocalCordTests.GenerateWindow.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    suite.set(Mode.generate.rawValue, forKey: "mode")
    suite.set(false, forKey: "terminalOpen")
    for (key, value) in defaults { suite.set(value, forKey: key) }

    let player = Player()
    let preview = Preview(player: player)
    let jev = Jev(keys: MemoryKeys(nil))
    let tools = ToolBridge(projects: projects, voices: voices, jev: jev, projectID: { suite.string(forKey: "project") })
    let engine = EngineClient(location: EngineLocation(python: URL(filePath: "/nonexistent"), source: URL(filePath: "/nonexistent")))
    let root = RootView()
        .defaultAppStorage(suite)
        .environment(voices)
        .environment(projects)
        .environment(player)
        .environment(preview)
        .environment(Waveforms())
        .environment(Terminals(tools: tools, support: try tempFolder()))
        .environment(jev)
        .environment(Setup(engine: engine, install: nil))
    let controller = NSHostingController(rootView: root)
    controller.sceneBridgingOptions = [.toolbars, .title]
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "VocalCord"
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = NSColor(Theme.base)
    window.contentViewController = controller
    window.toolbarStyle = .unifiedCompact
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.setContentSize(size)
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.close() }
    let deadline = Date.now + 5
    while Date.now < deadline && !projects.projects.isEmpty && preview.timeline.duration == 0 {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }
    prepare()
    for _ in 0..<20 {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    let out = snapshots.appending(path: "window-generate-\(name).png")
    if CGPreflightScreenCaptureAccess() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) { return }
    }
    let frame = try #require(window.contentView?.superview)
    let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
    frame.cacheDisplay(in: frame.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: out)
}

@MainActor @Test(.enabled(if: hasWindowServer, "Needs a window server to draw."))
func snapshotsOfGenerateStates() async throws {
    // Two lines wait for a render: Render shows the count; Outputs lists the four renders.
    let (voices, projects, id) = try generateFixture(rendered: 4, delay: .seconds(120))
    let base: [String: Any] = ["project": id, "scriptView": ScriptViewMode.table.rawValue, "generateSideOpen": true,
                               "sidebarWidthFlat": 200.0]
    try await capture("to-render", voices: voices, projects: projects, defaults: base, size: NSSize(width: 1200, height: 700))
    #expect(projects.project(id)?.lines.count(where: \.needsRender) == 2)

    // A render running: its progress and Cancel in Render's place, the toolbar otherwise where it was.
    try await capture("rendering", voices: voices, projects: projects, defaults: base, size: NSSize(width: 1200, height: 700)) {
        projects.renderNeeded(id, voices: voices)
    }
    #expect(projects.progress != nil)
    projects.cancel()

    // Preview and Outputs folded, in Read: the footer gets the play button and the time back.
    var folded = base
    folded["generateSideOpen"] = false
    folded["scriptView"] = ScriptViewMode.read.rawValue
    try await capture("read-folded", voices: voices, projects: projects, defaults: folded)

    // The widest sidebar in the narrowest window: the script table's last columns give way, never the text.
    var wide = base
    wide["sidebarWidthFlat"] = 320.0
    try await capture("wide-sidebar", voices: voices, projects: projects, defaults: wide, size: NSSize(width: 1200, height: 700))

    // No projects at all.
    let empty = ProjectStore(root: try tempFolder(), exportsRoot: try tempFolder())
    try await capture("empty", voices: voices, projects: empty, defaults: ["project": ""], size: NSSize(width: 1200, height: 700))
}

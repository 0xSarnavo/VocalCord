import AppKit
import SwiftUI
import Testing
@testable import VocalCord

// The whole window, toolbar included, in each mode, drawn off-screen from fixture data, to check the design as a
// whole. Images go to WINDOW_SNAPSHOTS, or VocalCordSnapshots in the temporary folder.

private let hasWindowServer = CGSessionCopyCurrentDictionary() != nil
private let snapshots = URL(filePath: ProcessInfo.processInfo.environment["WINDOW_SNAPSHOTS"]
    ?? FileManager.default.temporaryDirectory.appending(path: "VocalCordSnapshots").path)

/// A voice with takes in three tones, and a project of rendered lines, saved as the app saves them.
@MainActor private func windowFixture() throws -> (VoiceStore, ProjectStore) {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Maya")
    let takes = [("Neutral", "I record a few lines in my normal voice, the way I'd explain something to a friend."),
                 ("Neutral", "This is my second take, a little slower, so the model hears how I pause."),
                 ("Happy", "Honestly, this is the part I was most excited to show you."),
                 ("Confident", "It works offline, it's private, and it sounds like you.")]
    for (tone, transcript) in takes {
        let file = try tempFolder().appending(path: "take.wav")
        try writeWAV(speechLike(seconds: 12, amplitude: 0.5, floor: 0.01)[...], rate: 24000, to: file)
        try voices.addTake(voiceID, file: file, tone: tone, transcript: transcript, issues: [])
    }
    UserDefaults.standard.set(voiceID, forKey: "voice")

    let texts = [("Meet the next chapter of your voice.", "Neutral"), ("Everything is ready. [pause 0.4] Just press record.", "Confident"),
                 ("This is where it begins, with a [stress]simple[/stress] step forward.", "Neutral"),
                 ("Make every moment count.", "Happy"), ("Your story, your voice, shapes what's next.", "Neutral"),
                 ("Ready when you are.", "Confident")]
    let root = try tempFolder()
    var project = Project(name: "Launch film", lines: [])
    let renders = root.appending(path: "\(project.id)/renders", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
    for (index, (text, tone)) in texts.enumerated() {
        var line = Line(text: text, voiceID: voiceID)
        line.tone = tone
        let words = Marks.parse(text).spokenTokens.indices.map { WordTime(start: 0.3 + Double($0) * 0.38, end: 0.6 + Double($0) * 0.38) }
        let duration = (words.last?.end ?? 2) + 0.3
        let scores = Scores(likeYou: [87, 89, 62, 88, 91, 86][index], human: [4.1, 4.2, 3.1, 4.3, 4.4, 4.0][index], words: 98,
                            heard: Marks.plain(text), referencePace: 2.4)
        let version = Version(id: UUID().uuidString, text: text, voiceID: voiceID, tone: tone, direction: false, seed: 1,
                              duration: duration, createdAt: .now, scores: scores, words: words)
        try writeWAV(speechLike(seconds: duration, amplitude: 0.5, floor: 0.005)[...], rate: 24000,
                     to: renders.appending(path: "\(version.id).wav"))
        // Names and tags on a few takes; the first line has a second take, the last isn't rendered yet, so its row
        // offers Render.
        var named = version
        named.name = index == 0 ? "Opening" : nil
        named.tag = [0: "Intro", 1: "Intro", 3: "Hook", 4: "Hook"][index]
        if index < texts.count - 1 {
            line.versions = [named]
            line.chosen = version.id
        }
        if index == 0 {
            var second = version
            second.id = UUID().uuidString
            second.scores?.likeYou = 91
            try FileManager.default.copyItem(at: renders.appending(path: "\(version.id).wav"), to: renders.appending(path: "\(second.id).wav"))
            line.versions.append(second)
        }
        project.lines.append(line)
    }
    try JSONEncoder().encode(project).write(to: root.appending(path: "\(project.id)/project.json"))
    for name in ["Product tour", "Shorts"] {
        let other = Project(name: name, lines: [])
        try FileManager.default.createDirectory(at: root.appending(path: other.id), withIntermediateDirectories: true)
        try JSONEncoder().encode(other).write(to: root.appending(path: "\(other.id)/project.json"))
    }
    UserDefaults.standard.set(project.id, forKey: "project")
    return (voices, ProjectStore(root: root, exportsRoot: try tempFolder()))
}

/// The app's root view in a titled window with its toolbar, drawn at 2x into `window-<name>.png`.
@MainActor private func windowSnapshot(_ mode: Mode, voices: VoiceStore, projects: ProjectStore, size: NSSize, name: String,
                                       read: Bool = false) async throws {
    _ = NSApplication.shared
    UserDefaults.standard.set(mode.rawValue, forKey: "mode")
    UserDefaults.standard.set(false, forKey: "terminalOpen")
    UserDefaults.standard.set(read ? ScriptViewMode.read.rawValue : ScriptViewMode.table.rawValue, forKey: "scriptView")
    let player = Player()
    let preview = Preview(player: player)
    let jev = Jev(keys: MemoryKeys(nil))
    let tools = ToolBridge(projects: projects, voices: voices, jev: jev, projectID: { UserDefaults.standard.string(forKey: "project") })
    let engine = EngineClient(location: EngineLocation(python: URL(filePath: "/nonexistent"), source: URL(filePath: "/nonexistent")))
    let root = RootView()
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
    // What the scene's `.windowToolbarStyle(.unifiedCompact(showsTitle: false))` sets on the real window.
    window.toolbarStyle = .unifiedCompact
    window.titleVisibility = .hidden
    // What RootView's `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` does in the app's own window.
    window.titlebarAppearsTransparent = true
    window.setContentSize(size)
    // Far off any screen, so it never shows; ordered in so the toolbar lays out.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.orderFrontRegardless()
    // Until the voiceover has loaded (Clone has none), then a little more for waveforms and layout to settle.
    let deadline = Date.now + 5
    while Date.now < deadline && mode != .clone && preview.timeline.duration == 0 {
        window.layoutIfNeeded()
        // Suspends, so the views' tasks (loading the voiceover) get the main actor; the run loop draws meanwhile.
        try await Task.sleep(for: .milliseconds(50))
    }
    for _ in 0..<20 {
        window.layoutIfNeeded()
        // Suspends, so the views' tasks (loading the voiceover) get the main actor; the run loop draws meanwhile.
        try await Task.sleep(for: .milliseconds(50))
    }
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    let out = snapshots.appending(path: "window-\(name).png")
    defer { window.orderOut(nil); window.close() }
    // The window server's own picture, the only one with Liquid Glass drawn; needs screen recording permission.
    if CGPreflightScreenCaptureAccess() {
        let capture = Process()
        capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) { return }
    }
    let frame = try #require(window.contentView?.superview)
    let base = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.bounds.width * 2), pixelsHigh: Int(frame.bounds.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: base.colorSpaceName, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = frame.bounds.size
    frame.cacheDisplay(in: frame.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: out)
}

@MainActor @Test(.enabled(if: hasWindowServer, "Needs a window server to draw."))
func snapshotsOfTheWholeWindow() async throws {
    let (voices, projects) = try windowFixture()
    for mode in [Mode.clone, .generate, .timeline] {
        try await windowSnapshot(mode, voices: voices, projects: projects, size: NSSize(width: 1280, height: 800), name: mode.rawValue)
    }
    try await windowSnapshot(.generate, voices: voices, projects: projects, size: NSSize(width: 1280, height: 800), name: "generate-read", read: true)
    // The narrowest window.
    try await windowSnapshot(.generate, voices: voices, projects: projects, size: NSSize(width: 1200, height: 700), name: "generate-1200")
    try await windowSnapshot(.timeline, voices: voices, projects: projects, size: NSSize(width: 1200, height: 700), name: "timeline-1200")
    try await windowSnapshot(.clone, voices: voices, projects: projects, size: NSSize(width: 1200, height: 700), name: "clone-1200")
}

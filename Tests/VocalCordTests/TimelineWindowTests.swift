import AppKit
import SwiftUI
import Testing
@testable import VocalCord

// The Timeline tab in a real titled window with its toolbar, in the states the whole-window snapshots don't reach: a
// clip selected with the Inspector open, a new render waiting, the timeline emptied, and a project not rendered yet.
// Images go to WINDOW_SNAPSHOTS, or VocalCordSnapshots in the temporary folder, as `timeline-window-<name>.png`.

private let folder = URL(filePath: ProcessInfo.processInfo.environment["WINDOW_SNAPSHOTS"]
    ?? FileManager.default.temporaryDirectory.appending(path: "VocalCordSnapshots").path)

/// `EditView` in an off-screen window `size` big, with the app's toolbar style, its settings read from `store`.
@MainActor private func timelineWindow(_ view: EditView, projects: ProjectStore, voices: VoiceStore, preview: VocalCord.Preview,
                                       store: UserDefaults, size: NSSize, name: String, waitForAudio: Bool = true) async throws {
    _ = NSApplication.shared
    let controller = NSHostingController(rootView: view.environment(projects).environment(voices).environment(preview)
        .defaultAppStorage(store).preferredColorScheme(.dark))
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
    // Far off any screen, so it never shows; ordered in so the toolbar lays out and the views' tasks run.
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.close() }
    let deadline = Date.now + 5
    while waitForAudio && Date.now < deadline && preview.timeline.duration == 0 {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }
    // Then a little more for the waveforms and layout to settle.
    for _ in 0..<20 {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let out = folder.appending(path: "timeline-window-\(name).png")
    if CGPreflightScreenCaptureAccess() {
        let capture = Process()
        capture.executableURL = URL(filePath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", out.path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) { return }
    }
    let frame = try #require(window.contentView?.superview)
    let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
    frame.cacheDisplay(in: frame.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: out)
}

/// Settings of their own, so the tests leave the app's alone: the project open, the Inspector open, the Terminal shut.
private func settings(project: String) throws -> (UserDefaults, String) {
    let suite = "VocalCordTests-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))
    store.set(project, forKey: "project")
    store.set(Mode.timeline.rawValue, forKey: "mode")
    store.set(false, forKey: "terminalOpen")
    store.set(true, forKey: "timelineSideOpen")
    return (store, suite)
}

@MainActor @Suite(.serialized, .enabled(if: canDrawOffscreen, "Needs a window server to draw."))
struct TimelineWindowSnapshots {
    @Test func selectedClipWithANewRender() async throws {
        let (projects, voices, preview, _, id) = try await readFixture([
            "Meet the next chapter of your voice.",
            "Everything is ready. Just press record.",
            "This is where it begins, with a simple step forward.",
            "Make every moment count.",
        ])
        #expect(projects.error == nil)
        projects.startEdit(id)
        let clips = try #require(projects.project(id)?.edit?.clips)
        #expect(clips.count == 4)
        // The first clip faded in and out, the second chosen, the third re-rendered since it went on the timeline.
        #expect(projects.setClipFades(fadeIn: 0.6, fadeOut: 0.4, clip: clips[0].id, in: id))
        let third = try #require(projects.project(id)?.lines[2].id)
        _ = try await projects.renderLine(third, in: id, voices: voices)?.value
        #expect(projects.newRenders(id)[third] != nil)

        let (store, suite) = try settings(project: id)
        defer { store.removePersistentDomain(forName: suite) }
        try await timelineWindow(EditView(selected: clips[1].id), projects: projects, voices: voices, preview: preview, store: store,
                                 size: NSSize(width: 1280, height: 800), name: "selected")
        try await timelineWindow(EditView(selected: clips[1].id), projects: projects, voices: voices, preview: preview, store: store,
                                 size: NSSize(width: 1200, height: 700), name: "selected-1200")
        // The Inspector folded to its strip, giving the track the width.
        store.set(false, forKey: "timelineSideOpen")
        try await timelineWindow(EditView(selected: clips[1].id), projects: projects, voices: voices, preview: preview, store: store,
                                 size: NSSize(width: 1200, height: 700), name: "folded-1200")
    }

    @Test func emptyTimelineAndNothingRendered() async throws {
        let (projects, voices, preview, _, id) = try await readFixture(["Meet the next chapter of your voice.", "Make every moment count."])
        projects.startEdit(id)
        for clip in try #require(projects.project(id)?.edit?.clips) { #expect(projects.deleteClip(clip.id, in: id)) }
        #expect(projects.project(id)?.edit?.clips.isEmpty == true)
        // Deleting every clip leaves each line off the timeline, so each has its card above the empty state.
        #expect(projects.linesNotOnTimeline(id).count == 2)

        let (store, suite) = try settings(project: id)
        defer { store.removePersistentDomain(forName: suite) }
        try await timelineWindow(EditView(), projects: projects, voices: voices, preview: preview, store: store,
                                 size: NSSize(width: 1200, height: 700), name: "empty", waitForAudio: false)

        // A project whose lines aren't rendered yet.
        let fresh = projects.create(name: "Not rendered")
        projects.addLines(["A line still to render."], to: fresh, voices: voices)
        store.set(fresh, forKey: "project")
        try await timelineWindow(EditView(), projects: projects, voices: voices, preview: preview, store: store,
                                 size: NSSize(width: 1200, height: 700), name: "not-rendered", waitForAudio: false)
    }
}

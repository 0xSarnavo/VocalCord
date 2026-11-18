import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VocalCord

// The Read view's math as plain values, then the view itself drawn off-screen for a look.

private func version(_ id: String, _ text: String, duration: Double = 2) -> Version {
    Version(id: id, text: text, voiceID: "v", tone: "Neutral", direction: false, seed: 0, duration: duration, createdAt: .now)
}

/// A line whose chosen version is `<id>1`, reading its text, unless it isn't rendered.
private func line(_ id: String, _ text: String, rendered: Bool = true) -> Line {
    var line = Line(id: id, text: text, voiceID: "v")
    if rendered {
        line.versions = [version(id + "1", text)]
        line.chosen = id + "1"
    }
    return line
}

private func near(_ a: Double?, _ b: Double, _ within: Double = 1e-9) -> Bool { a.map { abs($0 - b) <= within } ?? false }

/// a 0–2, b 2.5–4.5, c 5–7, then d, not rendered, as a 1 s silent gap at 7.5–8.5. Each line pauses 0.5 s after.
private let project = Project(id: "p", name: "P", lines: [line("a", "One two three."), line("b", "Four five six."),
                                                          line("c", "Seven eight."), line("d", "Nine.", rendered: false)])
private let script = Timeline(project) { URL(filePath: "/tmp/\($0.id).wav") }

@MainActor @Test func paragraphsLightLikeATeleprompter() {
    func lit(_ playing: LitWord?, at position: Double?, in project: Project = project) -> [Int?] {
        project.lines.map { ReadLayout.lit($0, playing: playing, position: position, timeline: script, in: project) }
    }
    let all = ReadLayout.allWords
    let midB = LitWord(lineID: "b", versionID: "b1", token: 1)
    // Partway through b: a played, b lit to its second word, c and d still to come.
    #expect(lit(midB, at: 3.4) == [all, 1, nil, nil])
    // Before b's first word, b is playing with nothing lit yet.
    #expect(lit(LitWord(lineID: "b", versionID: "b1", token: -1), at: 2.5) == [all, -1, nil, nil])
    // In the silent gap for d, which has no words to light: everything before it played.
    #expect(lit(nil, at: 8) == [all, all, all, nil])
    // Nothing playing: every line grey.
    #expect(lit(nil, at: nil) == [nil, nil, nil, nil])
    // A take playing on its own lights its own line only.
    #expect(lit(midB, at: nil) == [nil, 1, nil, nil])

    // b's text changed since its render: the words heard aren't the words shown, so none light while it plays.
    var edited = project
    edited.lines[1].text = "Four five six seven."
    #expect(lit(midB, at: 3.4, in: edited) == [all, nil, nil, nil])
    // A line off the timeline is never played.
    var extra = project
    extra.lines.append(line("e", "Off the end."))
    #expect(lit(nil, at: 100, in: extra) == [all, all, all, all, nil])
}

@MainActor @Test func readAlongFollowsThePreviewWhenItShould() {
    func position(_ at: Double, playing: Bool, take: Bool = false, timeline: Timeline = script) -> Double? {
        ReadLayout.position(timeline, at: at, isPlaying: playing, takePlaying: take, in: project)
    }
    #expect(position(3, playing: true) == 3)
    #expect(position(3, playing: false) == 3)                  // paused partway keeps the place
    #expect(position(0, playing: false) == nil)                // nothing played yet
    #expect(position(3, playing: false, take: true) == nil)    // a row's take plays on its own
    var other = script
    other.projectID = "another"
    #expect(position(3, playing: true, timeline: other) == nil)
}

@MainActor @Test func clickingAWordSeeksToItOnTheTimeline() {
    let b = project.lines[1], lead = ReadAlong.lead
    let times = [WordTime(start: 0.1, end: 0.5), WordTime(start: 0.7, end: 1.1), WordTime(start: 1.3, end: 1.9)]
    // On the script's timeline b starts at 2.5 and plays its file from the start.
    #expect(near(ReadLayout.seekTime(token: 1, in: b, times: times, timeline: script), 2.5 + 0.7 - lead))
    #expect(near(ReadLayout.seekTime(token: 2, in: b, times: times, timeline: script), 2.5 + 1.3 - lead))
    // A first word right at the file's start can't start earlier than the line.
    let early = [WordTime(start: 0.02, end: 0.4)] + times.dropFirst()
    #expect(ReadLayout.seekTime(token: 0, in: b, times: early, timeline: script) == 2.5)
    // Untimed, out of range, or the text changed since the render: the line's start.
    #expect(ReadLayout.seekTime(token: 1, in: b, times: nil, timeline: script) == 2.5)
    #expect(ReadLayout.seekTime(token: 7, in: b, times: times, timeline: script) == 2.5)
    #expect(ReadLayout.seekTime(token: -1, in: b, times: times, timeline: script) == 2.5)
    var changed = b
    changed.text = "Four five six seven."
    #expect(ReadLayout.seekTime(token: 1, in: changed, times: times, timeline: script) == 2.5)
    // A line without a render plays its silent gap; one off the timeline can't play.
    #expect(ReadLayout.seekTime(token: 0, in: project.lines[3], times: nil, timeline: script) == 7.5)
    #expect(ReadLayout.seekTime(token: 0, in: line("e", "Off the end."), times: times, timeline: script) == nil)

    // A timeline clip of b's render from 0.5 s at 1.25×, at 10 s; then the rest of it, split off, at 20 s.
    var edit = Timeline()
    edit.projectID = "p"
    edit.segments = [
        Timeline.Segment(lineID: "b", audio: nil, start: 10, duration: 0.4, clipID: "x", versionID: "b1", renderStart: 0.5, tempo: 1.25),
        Timeline.Segment(lineID: "b", audio: nil, start: 20, duration: 1, clipID: "y", versionID: "b1", renderStart: 1, tempo: 1),
    ]
    // The word's time in the render, from the clip's trim and at its speed.
    #expect(near(ReadLayout.seekTime(token: 1, in: b, times: times, timeline: edit), 10 + (0.7 - lead - 0.5) / 1.25))
    #expect(near(ReadLayout.seekTime(token: 2, in: b, times: times, timeline: edit), 20 + (1.3 - lead - 1)))
    // The first word was trimmed away: the line's first clip.
    #expect(ReadLayout.seekTime(token: 0, in: b, times: times, timeline: edit) == 10)
}

@MainActor @Test func pausesWidenTheGapAfterAParagraph() {
    #expect(ReadLayout.gap(after: 0) == 18 && ReadLayout.gap(after: 0.5) == 28 && ReadLayout.gap(after: 1) == 38)
    #expect(ReadLayout.gap(after: 3) == 78 && ReadLayout.gap(after: 9) == 78 && ReadLayout.gap(after: -1) == 18)
}

@MainActor @Test func hintsSayWhenTheAudioDoesntPlayTheText() {
    #expect(ReadLayout.hint(project.lines[0]) == nil)
    #expect(ReadLayout.hint(project.lines[3]) == "Not rendered")
    var changed = project.lines[0]
    changed.text = "One two."
    #expect(ReadLayout.hint(changed) == "Changed since its render")
    changed.proposal = Proposal(changed)
    #expect(ReadLayout.hint(changed) == "Change proposed. Review it in Table.")
}

@MainActor @Test func lineNumbersSitOnTheFirstBaseline() {
    // 26 pt type at 1.3× line height: the baseline is well below the cap height, and inside the first line.
    let line = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 26)) * 1.3)
    #expect(ReadLayout.firstBaseline > 20 && ReadLayout.firstBaseline < line)
}

// MARK: Off-screen snapshots

/// Drawing needs a window server; without one (a headless CI runner) these skip.
let canDrawOffscreen = CGSessionCopyCurrentDictionary() != nil

/// Snapshots go here, or to $SCRIPTTEXT_SNAPSHOTS, as ScriptTextViewTests' do.
let offscreenFolder = URL(filePath: ProcessInfo.processInfo.environment["SCRIPTTEXT_SNAPSHOTS"]
    ?? FileManager.default.temporaryDirectory.appending(path: "VocalCordSnapshots").path)

/// A store whose project has `lines` rendered by the fake engine (each a copy of a 3 s take, its words timed evenly),
/// and a preview and player that never play.
@MainActor
func readFixture(_ lines: [String]) async throws -> (projects: ProjectStore, voices: VoiceStore, preview: VocalCord.Preview, player: Player, id: String) {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Me", fullClone: false)
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 3, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let projects = ProjectStore(root: try tempFolder(), exportsRoot: try tempFolder())
    let id = projects.create(name: "Read")
    projects.addLines(lines, to: id, voices: voices)
    projects.renderNeeded(id, voices: voices)
    for _ in 0..<1000 where projects.progress != nil || !projects.applying.isEmpty || !projects.queued.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    let player = Player()
    return (projects, voices, VocalCord.Preview(player: player), player, id)
}

/// Draws `view` in an off-screen window at `width` × `height` and saves it as `<name>.png` in the snapshot folder.
/// SwiftUI doesn't run views' tasks there, so anything loaded in one (a clip's waveform) draws empty.
@MainActor
func drawOffscreen(_ view: some View, width: Double, height: Double, name: String) throws {
    _ = NSApplication.shared
    try FileManager.default.createDirectory(at: offscreenFolder, withIntermediateDirectories: true)
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let hosting = NSHostingView(rootView: view.frame(width: width, height: height).background(Theme.content).environment(\.colorScheme, .dark))
    hosting.frame = frame
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    defer { window.close() }
    // Turns the run loop a few times so SwiftUI lays out, runs its geometry and change actions, and draws.
    for _ in 0..<6 {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.1)
    }
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try #require(rep.representation(using: .png, properties: [:])).write(to: offscreenFolder.appending(path: "\(name).png"))
}

@MainActor @Suite(.serialized, .enabled(if: canDrawOffscreen, "Needs a window server to draw."))
struct ReadViewSnapshots {
    @Test func readViewMidLine() async throws {
        let (projects, voices, preview, player, id) = try await readFixture([
            "Welcome to VocalCord, the voice studio that lives on your Mac.",
            "Write a line, pick a tone, and [pause 0.5] hear it in your own voice.",
            "Then [stress]shape[/stress] every word until it sounds [speed 85%]just right[/speed].",
        ])
        #expect(projects.error == nil)
        projects.addLines(["Export it when you\u{2019}re happy, with captions to match."], to: id, voices: voices)
        var project = try #require(projects.project(id))
        projects.setPause(1.5, line: project.lines[1].id, in: id)
        project = try #require(projects.project(id))
        #expect(project.lines.prefix(3).allSatisfy { $0.chosenVersion.flatMap(projects.displayTimes) != nil })

        // Paused partway through line 2, so it lights to the word there, line 1 shows played and the rest to come.
        await preview.load(Timeline(project) { projects.audioURL($0, projectID: id) })
        let second = try #require(preview.timeline.segments.first { $0.lineID == project.lines[1].id })
        preview.seek(to: second.start + second.duration * 0.45)
        let lit = try #require(ReadAlong.lit(preview.timeline, at: preview.position, in: project, projects: projects))
        #expect(lit.lineID == project.lines[1].id && lit.token > 0)

        let view = ReadView(project: project).environment(projects).environment(voices).environment(preview).environment(player)
        try drawOffscreen(view, width: 900, height: 640, name: "read-mid")
        try drawOffscreen(view, width: 560, height: 700, name: "read-narrow")
        let empty = projects.create(name: "Empty")
        try drawOffscreen(ReadView(project: try #require(projects.project(empty))).environment(projects).environment(voices)
            .environment(preview).environment(player), width: 600, height: 300, name: "read-empty")
    }
}

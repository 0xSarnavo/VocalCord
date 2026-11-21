import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VocalCord

// The Generate tab's Script panel: pace notes, the read-along word for a row, the row's status and the Pace menu,
// then the panel itself drawn off-screen.

private func version(_ id: String, text: String, words: [WordTime]? = nil, referencePace: Double? = nil, raw: Bool? = nil,
                     source: String? = nil) -> Version {
    let scores = Scores(likeYou: 82, human: 3.9, words: 100, heard: Marks.plain(text), referencePace: referencePace)
    return Version(id: id, text: text, voiceID: "me", tone: "Neutral", direction: false, seed: 1, duration: words?.last?.end ?? 2,
                   createdAt: .now, scores: scores, words: words, raw: raw, source: source)
}

private func tokens(_ text: String) -> [ParsedLine.Token] { Marks.parse(text).tokens }

// MARK: Pace notes

@Test func phraseTrimsEndPunctuationAndShortensLongStretches() {
    let words = tokens("Try it in your own voice, and it's [stress]free[/stress], no account needed.")
    #expect(PaceNote.phrase(6...8, in: words) == "and it's free")
    #expect(PaceNote.phrase(5...5, in: words) == "voice")
    #expect(PaceNote.phrase(4...6, in: words) == "own voice, and")          // inner punctuation stays
    #expect(PaceNote.phrase(0...7, in: words) == "Try it in your own voice, and it's")
    #expect(PaceNote.phrase(0...11, in: words) == "Try it in your … no account needed")
    #expect(PaceNote.phrase(9...40, in: words) == "no account needed")      // clamped to the words there are
    #expect(PaceNote.phrase(20...30, in: words) == "")
    #expect(PaceNote.phrase(0...2, in: []) == "")
}

@Test func paceNotesNameTheWordsAndTheirFix() throws {
    let words = tokens("Try it in your own voice, and it's free, no account needed.")
    let report = PaceReport(wordsPerMinute: 190, target: 140, rushed: [6...8], dragging: [0...4], gaps: [.init(after: 5, seconds: 1.44)],
                            verdict: "190 words a minute, 36% faster than your usual 140.")
    let notes = PaceNote.notes(report, tokens: words)
    // In the order they're said, gaps after stretches, at most two.
    #expect(notes.map(\.text) == ["Slow: \u{201C}Try it in your own\u{201D} · Speed up", "Rushed: \u{201C}and it's free\u{201D} · Slow down"])
    #expect(notes.map(\.range) == [0...4, 6...8] && notes.map(\.fix) == [.speedUp, .slowDown])
    #expect(notes[1].key == "Rushed:" && notes[1].fixLabel == "Slow down \u{201C}and it's free\u{201D}")

    var gapOnly = report
    gapOnly.rushed = []
    gapOnly.dragging = []
    let gap = try #require(PaceNote.notes(gapOnly, tokens: words).first)
    #expect(gap.text == "1.4 s gap after \u{201C}voice\u{201D}" && gap.fix == nil && gap.fixLabel == nil && gap.key == "1.4 s gap")

    // On pace overall, a fast stretch still shows; with nothing particular it stays quiet.
    var onPace = report
    onPace.verdict = nil
    #expect(PaceNote.notes(onPace, tokens: words).map(\.range) == [0...4, 6...8])
    onPace.rushed = []
    onPace.dragging = []
    onPace.gaps = []
    #expect(PaceNote.notes(onPace, tokens: words).isEmpty)

    // Off pace with nothing more particular: the verdict itself.
    let short = PaceReport(wordsPerMinute: 80, target: 150, rushed: [], dragging: [], gaps: [], verdict: "80 words a minute, 47% slower than your usual 150.")
    #expect(PaceNote.notes(short, tokens: tokens("One two three four.")).map(\.text) == ["Slow: 80 words a minute, 47% slower than your usual 150."])

    // A range from another text that no longer fits is left out.
    let stale = PaceReport(wordsPerMinute: 200, target: 100, rushed: [30...34], dragging: [], gaps: [], verdict: "Fast.")
    #expect(PaceNote.notes(stale, tokens: words).map(\.text) == ["Rushed: Fast."])
}

@Test func paceMenuTitles() {
    #expect(PaceChoice.title(nil) == "Pace: take" && PaceChoice.title(150) == "Pace: 150" && PaceChoice.title(163.6) == "Pace: 164")
    #expect(!PaceChoice.isCustom(nil) && !PaceChoice.isCustom(170) && PaceChoice.isCustom(163))
}

// MARK: Rows

@MainActor @Test func aRowLightsOnlyWhileItsOwnTextPlays() {
    let text = "Hello [pause 0.3] there."
    var line = Line(text: text, voiceID: "me")
    line.versions = [version("a", text: text), version("b", text: "Hello there.")]
    #expect(LineRow.lit(LitWord(lineID: line.id, versionID: "a", token: 1), in: line) == 1)
    #expect(LineRow.lit(LitWord(lineID: line.id, versionID: "a", token: -1), in: line) == -1)
    #expect(LineRow.lit(nil, in: line) == nil)
    #expect(LineRow.lit(LitWord(lineID: "other", versionID: "a", token: 1), in: line) == nil)
    // A version of other words: its word numbers don't match the row's.
    #expect(LineRow.lit(LitWord(lineID: line.id, versionID: "b", token: 1), in: line) == nil)
    #expect(LineRow.lit(LitWord(lineID: line.id, versionID: "gone", token: 1), in: line) == nil)
    line.text = "Hello there, edited."
    #expect(LineRow.lit(LitWord(lineID: line.id, versionID: "a", token: 1), in: line) == nil)
}

@MainActor @Test func rowStatusFollowsTheQueue() {
    let plain = "One two three."
    var line = Line(text: plain, voiceID: "me")
    line.versions = [version("v", text: plain, words: [WordTime(start: 0, end: 0.5), WordTime(start: 0.6, end: 1), WordTime(start: 1.1, end: 1.5)])]
    line.chosen = "v"
    #expect(LineRow.status(line, rendering: [], queued: [], applying: []) == .render)
    #expect(LineRow.status(line, rendering: [line.id], queued: [], applying: []) == .rendering)
    #expect(LineRow.status(line, rendering: ["other"], queued: ["x", line.id], applying: []) == .waiting)
    #expect(LineRow.status(line, rendering: [], queued: [], applying: [line.id]) == .applying)
    // A pause added: only marks to apply. New words: the voice.
    line.text = "One [pause 0.3] two three."
    #expect(line.needsRender && !line.needsVoice)
    #expect(LineRow.status(line, rendering: [], queued: [], applying: []) == .apply)
    line.text = "One two three four."
    #expect(LineRow.status(line, rendering: [], queued: [], applying: []) == .render)
}

@MainActor @Test func rowMarksSayWhatNeedsAttention() {
    let plain = "One two three."
    var line = Line(text: plain, voiceID: "me")
    // No render yet: the grey bar, and VoiceOver hears why.
    #expect(LineRow.mark(line) == .stale && LineRow.mark(line).color != nil)
    #expect(LineRow.accessibilityLabel(line, number: 3) == "Line 3, not rendered")
    line.versions = [version("v", text: plain)]
    line.chosen = "v"
    #expect(LineRow.mark(line) == .current && LineRow.mark(line).color == nil)
    #expect(LineRow.accessibilityLabel(line, number: 3) == "Line 3")
    line.text = "One two three four."
    #expect(LineRow.mark(line) == .stale)
    #expect(LineRow.accessibilityLabel(line, number: 3) == "Line 3, changed since render")
    // A chosen version that failed a check: amber.
    line.text = plain
    line.versions[0].scores?.words = 60
    #expect(!line.versions[0].flags.isEmpty)
    #expect(LineRow.mark(line) == .flagged && LineRow.mark(line).color == Theme.amber)
    #expect(LineRow.accessibilityLabel(line, number: 3) == "Line 3, failed a check")
    // An empty line needs nothing.
    #expect(LineRow.mark(Line(text: "  ", voiceID: "me")) == .current)
}

/// The narrowest window (1200 pt) with the default sidebar (200) gives the script the whole width, Preview and Outputs
/// being under it; with the Terminal column open at its narrowest, every column still fits, Jev's too, with room for a
/// scroll bar that takes space.
@Test func theScriptTableFitsTheNarrowestWindow() {
    let detail = 1200.0 - 200 - 1
    let script = detail - 1 - TerminalPanel.minWidth
    #expect(script == 698)
    // The tone column's 88 pt only while tones show.
    let tone = Tone.enabled ? 0.0 : 88
    #expect(ScriptColumn.minimumWidth(jev: false) == 738 - tone && ScriptColumn.minimumWidth(jev: true) == 770 - tone)
    #expect(ScriptColumn.minimumWidth(jev: true) + 16 <= script || Tone.enabled)
}

@MainActor @Test func rowsCompareWithoutTheirClosure() {
    let line = Line(text: "Hi.", voiceID: "me")
    let row = LineRow(projectID: "p", line: line, number: 1, isLast: true, lit: nil, paceTarget: nil, onCompare: {})
    #expect(row == LineRow(projectID: "p", line: line, number: 1, isLast: true, lit: nil, paceTarget: nil, onCompare: { print("other") }))
    #expect(row != LineRow(projectID: "p", line: line, number: 1, isLast: true, lit: 0, paceTarget: nil, onCompare: {}))
    #expect(row != LineRow(projectID: "p", line: line, number: 1, isLast: true, lit: nil, paceTarget: 150, onCompare: {}))
}

// MARK: The panel, drawn

/// Drawing needs a window server; without one (a headless CI runner) these tests skip.
private let hasWindowServer = CGSessionCopyCurrentDictionary() != nil

/// Snapshots go here, or to $GENERATE_SNAPSHOTS.
private let snapshots = URL(filePath: ProcessInfo.processInfo.environment["GENERATE_SNAPSHOTS"]
    ?? FileManager.default.temporaryDirectory.appending(path: "VocalCordSnapshots").path)

/// Evenly spoken words: `count` words of `each` seconds from `start`, with a short breath between them.
private func spoken(_ count: Int, each: Double, from start: Double) -> [WordTime] {
    (0..<count).map { WordTime(start: start + Double($0) * each, end: start + Double($0) * each + each * 0.8) }
}

/// A project saved to disk as the app saves it, with renders already timed: a line that rushes at the end, one that
/// drags with a long gap, plain lines, and optionally two changes an agent proposed.
@MainActor private func panelFixture(proposals: Bool) throws -> (ProjectStore, VoiceStore, Project) {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Me")
    func line(_ text: String, _ versions: [Version], chosen: String?) -> Line {
        var line = Line(text: text, voiceID: voiceID)
        line.versions = versions.map { var version = $0; version.voiceID = voiceID; return version }
        line.chosen = chosen
        return line
    }

    // Slow words, the asked-for pause, then the rest twice as fast: rushed against a 120 words a minute take.
    let rushedText = "Record a take [pause 0.4] and hear [stress]yourself[/stress] read it back."
    let slow = spoken(3, each: 0.8, from: 0)
    let rushedWords = slow + spoken(6, each: 0.2, from: slow[2].end + 0.5)
    let rushed = line(rushedText, [version("raw", text: rushedText, words: rushedWords, referencePace: 2, raw: true),
                                   version("final", text: rushedText, words: rushedWords, referencePace: 2, source: "raw")], chosen: "final")

    // Dragging, with a 1.4 s gap no pause asked for, against a 180 words a minute take.
    let slowText = "It sounds like you, every single time."
    let first = spoken(4, each: 0.6, from: 0)
    let dragging = line(slowText, [version("slow", text: slowText, words: first + spoken(3, each: 0.3, from: first[3].end + 1.4),
                                           referencePace: 3)], chosen: "slow")

    let plainText = "No studio, [speed 90%]no retakes[/speed], just [say Vo-kal-cord]VocalCord[/say]."
    let plain = line(plainText, [version("p1", text: plainText, words: spoken(6, each: 0.4, from: 0), referencePace: 2.1)], chosen: "p1")

    var changed = line("Then share it anywhere.", [], chosen: nil)
    var added = line("", [], chosen: nil)
    if proposals {
        changed.proposal = Proposal(text: "Then share it [pause 0.3] anywhere.", tone: "Neutral", pauseAfter: 0.5)
        added.added = true
        added.proposal = Proposal(text: "Try it today.", tone: "Happy", pauseAfter: 0.8)
    }
    let project = Project(name: "Launch", lines: [rushed, dragging, plain, changed] + (proposals ? [added] : []))

    let root = try tempFolder()
    let folder = root.appending(path: project.id, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try JSONEncoder().encode(project).write(to: folder.appending(path: "project.json"))
    let projects = ProjectStore(root: root, exportsRoot: try tempFolder())
    return (projects, voices, try #require(projects.project(project.id)))
}

/// `view` drawn at 2x into `name`.png, at `width` and its own height (up to `maxHeight`).
@MainActor private func snapshot(_ view: some View, width: CGFloat, height: CGFloat, name: String) throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Theme.base).preferredColorScheme(.dark))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    // SwiftUI lays out and draws on the next turns of the run loop.
    for _ in 0..<5 {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.05)
    }
    let base = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: base.colorSpaceName,
                                            bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: rep)
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    try #require(rep.representation(using: .png, properties: [:])).write(to: snapshots.appending(path: "generate-\(name).png"))
    window.close()
}

@MainActor private func panel(_ projects: ProjectStore, _ voices: VoiceStore, _ project: Project, jev: Bool) -> some View {
    let player = Player()
    let keys = MemoryKeys(jev ? "key" : nil)
    let jevStore = Jev(keys: keys)
    let tools = ToolBridge(projects: projects, voices: voices, jev: jevStore, projectID: { project.id })
    let support = URL(filePath: "/tmp/vc-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    return ScriptPane(project: project)
        .environment(voices)
        .environment(projects)
        .environment(jevStore)
        .environment(player)
        .environment(Preview(player: player))
        .environment(Terminals(tools: tools, support: support))
        .panel()
}

@MainActor @Test(.enabled(if: hasWindowServer, "Needs a window server to draw."))
func snapshotsOfTheScriptPanel() throws {
    let (projects, voices, project) = try panelFixture(proposals: false)
    // The fixture says what it's meant to: the first two rows get notes, and raw renders aren't counted.
    let first = project.lines[0], second = project.lines[1]
    #expect(first.visibleVersions.map(\.id) == ["final"])
    let rushed = try #require(projects.paceReport(line: first.id, in: project.id))
    #expect(rushed.verdict != nil && !rushed.rushed.isEmpty)
    let slow = try #require(projects.paceReport(line: second.id, in: project.id))
    #expect(slow.verdict != nil && !slow.dragging.isEmpty && !slow.gaps.isEmpty)

    // 742 pt: the script pane in the narrowest window with the default sidebar.
    try snapshot(panel(projects, voices, project, jev: false), width: 742, height: 420, name: "rows")
    projects.setPaceTarget(150, in: project.id)
    try snapshot(panel(projects, voices, try #require(projects.project(project.id)), jev: false), width: 1400, height: 420, name: "rows-1400")
}

/// The header with everything it can show (Jev added, two pending changes) at each width the panel can have: 622 pt is
/// the narrowest (a 1200 pt window, the widest sidebar and the side column open), 742 the narrowest window with the
/// default sidebar.
@MainActor @Test(.enabled(if: hasWindowServer, "Needs a window server to draw."))
func snapshotsOfTheHeader() throws {
    let (projects, voices, project) = try panelFixture(proposals: true)
    for width: CGFloat in [622, 742, 1000, 1400] {
        try snapshot(panel(projects, voices, project, jev: true), width: width, height: 150, name: "header-\(Int(width))")
    }
    let (plainProjects, plainVoices, plainProject) = try panelFixture(proposals: false)
    try snapshot(panel(plainProjects, plainVoices, plainProject, jev: false), width: 622, height: 150, name: "header-622-plain")
    // The Pace menu's Custom… popover, which a menu can't open off-screen.
    try snapshot(CustomPacePopover(value: 163) { _ in }.background(Theme.selection), width: 260, height: 130, name: "pace-custom")
}

/// Narrower than its columns (the widest sidebar at 1200 pt), the table keeps every column and scrolls sideways, so
/// Version and the render buttons stay reachable; at 742 pt it fits and doesn't.
@MainActor @Test(.enabled(if: hasWindowServer, "Needs a window server to lay out."))
func aNarrowTableScrollsSidewaysInsteadOfCuttingColumns() throws {
    let (projects, voices, project) = try panelFixture(proposals: false)
    func widestDocument(at width: CGFloat) -> CGFloat {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: panel(projects, voices, project, jev: false).frame(width: width, height: 420))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now + 0.05)
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        return scrollViews(host).compactMap { $0.documentView?.frame.width }.max() ?? 0
    }
    let minimum = ScriptColumn.minimumWidth(jev: false)
    #expect(widestDocument(at: 622) >= minimum)
    #expect(widestDocument(at: 742) <= 742)
}

import Foundation
import Synchronization
import Testing
@testable import VocalCord

// MARK: Engine client

/// A stand-in worker: answers out of order, holds `split` until cancelled, and dies on `score`.
private let fakeWorker = #"""
import json, sys

def send(**message):
    print(json.dumps(message), flush=True)

first = held = None
for raw in sys.stdin:
    m = json.loads(raw)
    i, cmd = m["id"], m["cmd"]
    if cmd == "transcribe":
        if first is None and m["audio"] != "/c":
            first = (i, m["audio"])
        else:
            send(id=i, event="result", text="heard " + m["audio"])
            if first:
                send(id=first[0], event="result", text="heard " + first[1])
                first = None
    elif cmd == "split":
        held = i
        send(id=i, event="progress", stage="transcribe", done=1, total=4)
    elif cmd == "cancel":
        send(id=i, event="result", cancelled=m["target"] == held)
        send(id=m["target"], event="error", code="cancelled", message="Cancelled")
    elif cmd == "check_audio":
        send(id=i, event="error", code="invalid", message="File not found: " + m["audio"])
    elif cmd == "score":
        print("RuntimeError: boom", file=sys.stderr, flush=True)
        sys.exit(1)
"""#

private func fakeEngineFolder() throws -> URL {
    let folder = try tempFolder()
    let bin = folder.appending(path: ".venv/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appending(path: "vocalcord_engine"), withIntermediateDirectories: true)
    try fakeWorker.write(to: folder.appending(path: "vocalcord_engine/__main__.py"), atomically: true, encoding: .utf8)
    let python = bin.appending(path: "python")
    try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    return folder
}

@Test func engineClientMatchesRepliesCancelsAndRestarts() async throws {
    let client = EngineClient(location: .dev(try fakeEngineFolder()))

    // Replies arrive in the opposite order; each caller still gets its own.
    async let a = client.transcribe(URL(filePath: "/a"))
    async let b = client.transcribe(URL(filePath: "/b"))
    #expect(try await [a, b] == ["heard /a", "heard /b"])

    await #expect(throws: EngineError.self) { try await client.checkAudio(URL(filePath: "/missing")) }

    let progress = Mutex<Double>(0)
    let split = Task {
        try await client.split(URL(filePath: "/x"), minSeconds: 3, maxSeconds: 20, into: URL(filePath: "/tmp")) { value in
            progress.withLock { $0 = value }
        }
    }
    try await Task.sleep(for: .milliseconds(500))
    #expect(progress.withLock { $0 } == 0.25)
    split.cancel()
    await #expect(throws: CancellationError.self) { try await split.value }

    // The worker dies: the waiting call fails, and the next call starts a new worker.
    await #expect(throws: EngineError.self) {
        try await client.score(URL(filePath: "/r"), reference: URL(filePath: "/t"), text: "Hi", hints: [])
    }
    #expect(try await client.transcribe(URL(filePath: "/c")) == "heard /c")
}

@Test func missingEngineThrows() async {
    let client = EngineClient(location: .dev(URL(filePath: "/nonexistent")))
    await #expect(throws: EngineError.self) { try await client.transcribe(URL(filePath: "/a")) }
}

// MARK: Projects

/// Each line with text rendered on its own, one take per line, for fixtures that want every line's render to be the
/// whole reference take. The app's Render reads the script as one take (`renderScript`).
@MainActor func renderEachLine(_ projects: ProjectStore, _ id: String, voices: VoiceStore) async throws {
    for line in projects.project(id)?.lines ?? [] where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try await projects.rerender(line.id, in: id, voices: voices)?.value
    }
}

@MainActor private func waitForRender(_ projects: ProjectStore) async throws {
    while projects.progress != nil { try await Task.sleep(for: .milliseconds(20)) }
}

@MainActor @Test func renderBatchesScoresAndKeepsVersions() async throws {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Me")
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    voices.addPronunciation(word: "Kuber", respelling: "Koo-ber", voiceID: voiceID)

    let root = try tempFolder()
    let projects = ProjectStore(root: root)
    let id = projects.create(name: " ")
    projects.addLines(["Kuber is ready.", "Let's go."], to: id, voices: voices)
    var lines = try #require(projects.project(id)).lines
    #expect(projects.project(id)?.name == "Untitled project")
    #expect(lines.allSatisfy { $0.voiceID == voiceID && $0.tone == "Neutral" && $0.needsRender })
    projects.setTone("Happy", line: lines[1].id, in: id)

    projects.renderScript(id, voices: voices)
    try await waitForRender(projects)
    #expect(projects.error == nil)
    lines = try #require(projects.project(id)).lines
    let first = try #require(lines[0].chosenVersion), second = try #require(lines[1].chosenVersion)
    // While tones are hidden every line reads in Neutral, from the Neutral take.
    let happy = Tone.enabled ? "Happy" : "Neutral"
    #expect(!first.direction && second.direction == Tone.enabled && second.tone == happy)
    #expect(first.scores != nil && first.referenceHuman == 3.5)
    #expect(voices.voice(voiceID)?.takes.first?.human == 3.5)
    #expect(FileManager.default.fileExists(atPath: projects.audioURL(first, projectID: id).path))
    #expect(lines.filter(\.needsRender).isEmpty)

    projects.setText("Kuber is live.", line: lines[0].id, in: id)
    #expect(projects.project(id)?.lines[0].needsRender == true)
    projects.rerender(lines[1].id, in: id, voices: voices)
    try await waitForRender(projects)
    projects.compare([lines[1].id], tones: ["Confident", "Sad"], in: id, voices: voices)
    try await waitForRender(projects)
    let line = try #require(projects.project(id)?.lines[1])
    #expect(line.versions.map(\.tone) == [happy, happy, "Confident", "Sad"])
    #expect(line.chosen == line.versions[1].id)
    #expect(line.versions.allSatisfy { $0.scores != nil })

    // Autosaved: a fresh store reads the same projects.
    #expect(ProjectStore(root: root).projects == projects.projects)
}

/// Counts the scores asked for each text, so a fake engine can fail the first few.
final class ScoreCounter: Sendable {
    private let counts = Mutex([String: Int]())
    func next(_ text: String) -> Int { counts.withLock { $0[text, default: 0] += 1; return $0[text]! } }
}

@Test func checksCatchPitchPaceAndGaps() {
    var version = Version(id: "v", text: "One two three four five six.", voiceID: "x", tone: "Neutral", direction: false, seed: 1,
                          duration: 8, createdAt: .now)
    #expect(!version.passes)                                  // not scored yet
    version.scores = Scores(likeYou: 90, human: 3.8, words: 100, heard: "", pitchHz: 108, referencePitchHz: 103,
                            longestPause: 0.6, pace: 2.6, referencePace: 2.5)
    #expect(version.passes && version.flags.isEmpty)
    version.scores?.pitchHz = 140                             // the Happy direction's kind of drift
    #expect(version.pitchFlag == "Pitch 5.3 semitones above the take")
    version.scores?.pitchHz = 108
    version.scores?.pace = 3.5
    #expect(version.paceFlag == "Pace 40% faster than the take")
    version.duration = 4                                      // too short to judge pace
    #expect(version.paceFlag == nil)
    version.duration = 8
    version.scores?.longestPause = 1.6
    #expect(version.gapFlag == "A 1.6 s gap mid-line" && !version.passes)
    version.tone = "Hesitant"                                 // meant to pause and slow down
    #expect(version.passes)
    // Older scores without these measurements pass on the score floors alone.
    version.scores = Scores(likeYou: 90, human: 3.8, words: 100, heard: "")
    #expect(version.passes)

    let take = Take(id: "t", tone: "Neutral", transcript: "One two three four five six seven eight nine ten.", duration: 5, score: nil,
                    issues: [], createdAt: .now)
    let paced = Scores(likeYou: 90, human: 3.8, words: 100, heard: "").paced(text: "Hello there [pause 1.0] friend. (sigh)", duration: 3, take: take)
    #expect(paced.pace == 1.5 && paced.referencePace == 2)
}

@MainActor @Test func renderMakesOneVersionPerLineEvenWhenItFails() async throws {
    let engine = FakeEngine(delay: .zero, scores: { _, text in
        guard text != "Hello." else { return nil }            // the take's own Human score
        return Scores(likeYou: text.hasPrefix("Never") ? 50 : 95, human: 3.6, words: 100, heard: text)
    })
    let voices = VoiceStore(root: try tempFolder(), engine: engine)
    let voiceID = voices.createVoice(name: "Me")
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 4, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)   // long enough to judge Like you
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let projects = ProjectStore(root: try tempFolder())
    let id = projects.create(name: "Once")
    projects.addLines(["First time lucky.", "Never good enough."], to: id, voices: voices)

    try await renderEachLine(projects, id, voices: voices)
    try await waitForRender(projects)
    var lines = try #require(projects.project(id)?.lines)
    #expect(lines[0].versions.count == 1 && lines[0].chosen == lines[0].versions[0].id && lines[0].chosenVersion?.passes == true)
    // A flagged line keeps its one version and its flag; nothing renders again until the user asks.
    #expect(lines[1].versions.count == 1 && lines[1].chosen == lines[1].versions[0].id && lines[1].chosenVersion?.passes == false)
    #expect(projects.error == nil)

    // Render again: one more version, chosen.
    let again = try #require(projects.rerender(lines[1].id, in: id, voices: voices))
    try await again.value
    lines = try #require(projects.project(id)?.lines)
    #expect(lines[1].versions.count == 2 && lines[1].chosen == lines[1].versions[1].id)
}

@MainActor @Test func anEditWaitsForRenderButMarksApplyAtOnce() async throws {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Me")
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 4, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let projects = ProjectStore(root: try tempFolder())
    let id = projects.create(name: "Edits")
    projects.addLines(["Say it once."], to: id, voices: voices)
    var line = try #require(projects.project(id)?.lines.first)

    // New words without Render: nothing renders and nothing waits.
    #expect(projects.commitLine(line.id, in: id, voices: voices, render: false) == nil)
    #expect(projects.progress == nil && projects.queued.isEmpty && projects.project(id)?.lines[0].versions.isEmpty == true)

    // Render renders it once.
    _ = try await #require(projects.commitLine(line.id, in: id, voices: voices, render: true)).value
    line = try #require(projects.project(id)?.lines.first)
    #expect(line.versions.count == 1 && !line.needsRender)

    // A pause alone applies without Render, from that version.
    projects.setText("Say it [pause 0.5] once.", line: line.id, in: id)
    let url = try await #require(projects.commitLine(line.id, in: id, voices: voices, render: false)).value
    line = try #require(projects.project(id)?.lines.first)
    #expect(url != nil && !line.needsRender && line.chosenVersion?.source == line.versions[0].id)

    // New words wait again.
    projects.setText("Say it twice.", line: line.id, in: id)
    #expect(projects.commitLine(line.id, in: id, voices: voices, render: false) == nil)
    #expect(projects.project(id)?.lines[0].needsRender == true)
}

@MainActor @Test func unreadableProjectIsNeverOverwritten() throws {
    let root = try tempFolder()
    let broken = root.appending(path: "broken/project.json")
    try FileManager.default.createDirectory(at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: broken)
    let projects = ProjectStore(root: root)
    #expect(projects.error != nil && projects.projects.isEmpty)
    let id = projects.create(name: "New")
    projects.rename(id, to: "Renamed")
    #expect(try Data(contentsOf: broken) == Data("{ not json".utf8))
}

@Test func lowScoresAreFlagged() {
    var version = Version(id: "v", text: "Hi", voiceID: "me", tone: "Neutral", direction: false, seed: 1, duration: 3,
                          createdAt: .now, scores: Scores(likeYou: 70, human: 3.1, words: 90, heard: "Hi"), referenceHuman: 3.6)
    #expect(version.likeYouFlag == nil && version.wordsFlag == nil && version.humanFlag == nil)
    version.scores = Scores(likeYou: 62, human: 3.0, words: 80, heard: "Hey")
    #expect(version.likeYouJudged && version.likeYouFlag != nil && version.humanFlag == "Human 0.6 below the take's 3.6")
    #expect(version.wordsFlag?.contains("Hey") == true)
    // Under 3 s, Like you isn't judged.
    version.duration = 1.4
    #expect(!version.likeYouJudged && version.likeYouFlag == nil && version.wordsFlag != nil)
}

/// The preview's waveform is one continuous shape: the loudest peak under each column, holes where a line has no
/// render, and never thinner than a line.
@Test func waveformEnvelopeIsContinuous() {
    #expect(WaveformEnvelope.columns([0.1, 0.9, 0.2, 0.4], count: 2) == [0.9, 0.4])
    #expect(WaveformEnvelope.columns([0.5], count: 3) == [0.5, 0.5, 0.5])
    #expect(WaveformEnvelope.columns([], count: 3).isEmpty && WaveformEnvelope.columns([1], count: 0).isEmpty)
    let columns: [Float] = [0, 1, 1, 0, 0, 1]
    let whole = WaveformEnvelope.path(columns, middle: 10, half: 8)
    #expect(whole.boundingRect == CGRect(x: 0, y: 2, width: 6, height: 16))
    // Silence still draws a 1 pt line, not nothing.
    let quiet = WaveformEnvelope.path([0, 0], middle: 10, half: 8).boundingRect
    #expect(quiet.height == 1 && quiet.width == 2)
    // A hole for columns 3 and 4: two separate shapes, nothing drawn between them.
    let holed = WaveformEnvelope.path(columns, middle: 10, half: 8) { !(3...4).contains($0) }
    #expect(!holed.contains(CGPoint(x: 3.5, y: 10)) && !holed.contains(CGPoint(x: 4.5, y: 10)))
    #expect(holed.contains(CGPoint(x: 1.5, y: 10)) && holed.contains(CGPoint(x: 5.5, y: 10)))
    // The playhead's head: flat on top, its point at the bottom.
    let head = WaveformEnvelope.head(at: 20, width: 9, height: 8)
    #expect(head.boundingRect == CGRect(x: 15.5, y: 0, width: 9, height: 8))
    #expect(head.contains(CGPoint(x: 16, y: 0.5)) && head.contains(CGPoint(x: 24, y: 0.5)) && !head.contains(CGPoint(x: 16, y: 7.5)))
}

/// An output's second line: format, length and the date with its year, so no column truncates the name.
@MainActor @Test func outputDetailsIncludeTheYear() {
    let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 18))!
    let output = Output(id: "o", name: "Line 6 · v1", url: URL(filePath: "/tmp/o.wav"), duration: 2.4, date: date)
    let details = OutputsPane.details(output)
    #expect(details.hasPrefix("WAV · 0:02 · "))
    #expect(details.contains("2026") && details.contains("18"))
}

@Test func timelineKeepsPausesAndGaps() {
    func version(_ id: String, _ duration: Double) -> Version {
        Version(id: id, text: "x", voiceID: "me", tone: "Neutral", direction: false, seed: 1, duration: duration, createdAt: .now)
    }
    var project = Project(name: "P")
    project.lines = [
        Line(id: "a", text: "One.", voiceID: "me", pauseAfter: 0.5, versions: [version("a1", 1), version("a2", 1.5)], chosen: "a2"),
        Line(id: "b", text: String(repeating: "x", count: 30), voiceID: "me", pauseAfter: 0.25),
        Line(id: "blank", text: " ", voiceID: "me"),
        Line(id: "c", text: "Three.", voiceID: "me", pauseAfter: 2, versions: [version("c1", 2)], chosen: "c1"),
    ]
    let timeline = Timeline(project) { URL(filePath: "/r/\($0.id).wav") }
    #expect(timeline.segments.map(\.lineID) == ["a", "b", "c"])
    #expect(timeline.segments.map(\.start) == [0, 2, 4.25])
    #expect(timeline.segments.map(\.audio?.lastPathComponent) == ["a2.wav", nil, "c1.wav"])
    #expect(timeline.duration == 6.25)  // the last pause is left off
    #expect(timeline.line(at: 1.8) == "a" && timeline.line(at: 2) == "b" && timeline.line(at: 6) == "c")
}

@MainActor @Test func exportListsOutputsAndKeepsChosenTakes() async throws {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Me")
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let root = try tempFolder(), movies = try tempFolder()
    let projects = ProjectStore(root: root, exportsRoot: movies)
    let id = projects.create(name: "Launch/film")
    projects.addLines(["One.", "Two."], to: id, voices: voices)
    projects.renderScript(id, voices: voices)
    try await waitForRender(projects)

    let options = ExportOptions(format: "m4a", srt: true)
    let first = try await projects.export(id, options: options, voices: voices)
    let second = try await projects.export(id, options: options, voices: voices)
    #expect(first.files.map(\.path) == [movies.appending(path: "Launch-film/Launch-film.m4a").path])
    #expect(second.files[0].lastPathComponent == "Launch-film 2.m4a")

    let outputs = projects.outputs(id)
    #expect(outputs.map(\.name) == ["Launch-film 2", "Launch-film", "Line 2 · v1", "Line 1 · v1"])
    #expect(outputs.map(\.format) == ["M4A", "M4A", "WAV", "WAV"])
    #expect(outputs.map(\.usedBy) == [nil, nil, 2, 1])

    // A line's chosen take can't be deleted.
    projects.deleteOutput(outputs[3].id, in: id)
    #expect(projects.project(id)?.lines[0].versions.count == 1)
    #expect(ProjectStore(root: root, exportsRoot: movies).project(id)?.exports?.count == 2)
}

// MARK: Script import

@Test func markdownSplitsIntoLines() {
    let markdown = """
    # Launch film

    Meet the **next** chapter. Everything is *ready*, see [the docs](https://example.com).
    It took a_long_time.

    - First point
    - Second point [pause 0.3]

    ```swift
    let code = 1
    ```
    > Quoted line.
    """
    let plain = Script.plainText(markdown)
    #expect(Script.lines(plain, by: .paragraphs) == [
        "Launch film", "Meet the next chapter. Everything is ready, see the docs. It took a_long_time.",
        "First point", "Second point [pause 0.3]", "Quoted line.",
    ])
    #expect(Script.lines(plain, by: .sentences) == [
        "Launch film", "Meet the next chapter.", "Everything is ready, see the docs.", "It took a_long_time.",
        "First point", "Second point [pause 0.3]", "Quoted line.",
    ])
    #expect(Script.lines(Script.plainText("One.\r\nTwo.\r\n\r\nThree."), by: .paragraphs) == ["One. Two.", "Three."])
}

@Test func scriptRulesAComputerCanCheck() {
    #expect(Script.warnings("Every voice app wanted the same thing. My money, and my voice.") == [])
    // Tags don't count: one pause is fine, and (sigh) is speech.
    #expect(Script.warnings("Weeks went by. [pause 0.3] Nothing worked. (sigh)") == [])
    // Pauses are added after the render, so several are fine.
    let warnings = Script.warnings("It costs $4.99 [pause 0.2] and [pause 0.3] takes 10 minutes.")
    #expect(warnings == ["Write numbers and symbols as spoken words: \u{201C}$4.99\u{201D}, \u{201C}10\u{201D}."])
    let long = Array(repeating: "word", count: 30).joined(separator: " ") + "."
    #expect(Script.warnings(long) == ["A 30-word sentence. Break it up; keep sentences under 25 words."])
    let paragraph = Array(repeating: "A short sentence here.", count: 30).joined(separator: " ")
    #expect(Script.warnings(paragraph).first?.hasPrefix("Over 600 characters") == true)
}

// MARK: Real engine

/// Exports the user's "Scratch" project as M4A at −16 LUFS with captions, through ProjectStore.export and the real
/// engine. It is listed in that project's Outputs. Opt in: `VOCALCORD_E2E_EXPORT=1 swift test --filter realExport`.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["VOCALCORD_E2E_EXPORT"] != nil))
func realExportOfScratch() async throws {
    let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let voicesCopy = try tempFolder().appending(path: "Voices")
    try FileManager.default.copyItem(at: VoiceStore.defaultRoot, to: voicesCopy)
    let voices = VoiceStore(root: voicesCopy, engine: EngineClient(location: .dev(repo.appending(path: "engine"))))
    let projects = ProjectStore()
    let scratch = try #require(projects.projects.first { $0.name == "Scratch" })
    let result = try await projects.export(scratch.id, options: ExportOptions(format: "m4a", lufs: -16, srt: true), voices: voices)
    for file in result.files {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        print("EXPORT \(file.path) \(size) bytes")
    }
    print("EXPORT duration \(result.duration) s, measured \(result.lufs.map { String($0) } ?? "–") LUFS")
    #expect(result.files.map(\.pathExtension) == ["m4a", "srt"])
    #expect(abs((result.lufs ?? 0) + 16) <= 1)
    #expect(projects.outputs(scratch.id).first?.url == result.files[0])
}

/// Renders and scores two lines in "My voice" with the real engine. Opt in: `VOCALCORD_E2E=1 swift test --filter realEngine`.
/// Reads a copy of the user's voices; `VOCALCORD_E2E_PROJECTS` sets where the scratch project goes (default: a temp folder).
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["VOCALCORD_E2E"] != nil), .timeLimit(.minutes(30)))
func realEngineRendersAndScoresTwoLines() async throws {
    let environment = ProcessInfo.processInfo.environment
    let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let voicesCopy = try tempFolder().appending(path: "Voices")
    try FileManager.default.copyItem(at: VoiceStore.defaultRoot, to: voicesCopy)
    let voices = VoiceStore(root: voicesCopy, engine: EngineClient(location: .dev(repo.appending(path: "engine"))))
    let voice = try #require(voices.voices.first { $0.name == "My voice" })
    let projects = ProjectStore(root: try environment["VOCALCORD_E2E_PROJECTS"].map { URL(filePath: $0) } ?? tempFolder())
    let id = projects.create(name: "Scratch")
    projects.addLines(["Meet the next chapter.", "Everything is ready."], to: id, voices: voices)
    #expect(projects.project(id)?.lines.allSatisfy { $0.voiceID == voice.id } == true)

    // Progress steps: each render 10, each score 1, out of 22.
    let clock = ContinuousClock(), start = clock.now
    var marks: [Duration] = []
    projects.renderScript(id, voices: voices)
    while let progress = projects.progress {
        if marks.count < 2, progress >= Double(marks.count + 1) * 10 / 22 - 0.001 { marks.append(clock.now - start) }
        try await Task.sleep(for: .milliseconds(50))
    }
    let total = clock.now - start
    #expect(projects.error == nil, "\(projects.error ?? "")")
    let lines = try #require(projects.project(id)).lines
    print("E2E model \(EngineSettings.model): line 1 (with load) \(marks.first ?? .zero), line 2 \(marks.count > 1 ? marks[1] - marks[0] : .zero), "
          + "scoring \(total - (marks.last ?? .zero)), total \(total)")
    for (index, line) in lines.enumerated() {
        let version = try #require(line.chosenVersion)
        let scores = try #require(version.scores)
        print("E2E line \(index + 1): \(String(format: "%.2f", version.duration)) s, like you \(scores.likeYou)%, "
              + "human \(scores.human) (take \(version.referenceHuman ?? 0)), words \(scores.words)%, heard \"\(scores.heard)\"")
    }
}

@Test func consistencyNotesTheLineThatSoundsUnlikeTheRest() {
    func line(_ id: String, pitch: Double = 110, pace: Double = 3, like: Int = 75, seconds: Double = 5) -> Line {
        let version = Version(id: "v\(id)", text: "Hi there.", voiceID: "me", tone: "Neutral", direction: false, seed: 1,
                              duration: seconds, createdAt: .now,
                              scores: Scores(likeYou: like, human: 3.5, words: 100, heard: "Hi there.", pitchHz: pitch, pace: pace))
        return Line(id: id, text: "Hi there.", voiceID: "me", versions: [version], chosen: version.id)
    }
    // Two lines have no "rest" to compare with.
    #expect(Consistency.notes([line("a"), line("b", pitch: 160)]).isEmpty)

    let notes = Consistency.notes([line("a"), line("b", pitch: 112), line("c", pace: 3.3), line("d", like: 78),
                                   line("e", pitch: 140, pace: 4.2, like: 55), line("short", like: 40, seconds: 2)])
    #expect(notes.keys.sorted() == ["e"])
    #expect(notes["e"] == ["Pitch 4.2 semitones higher than the other lines", "40% faster than the other lines",
                           "Like you 55%, against 75% for the other lines"])

    // A short line's pitch still counts; its pace and Like you don't.
    #expect(Consistency.notes([line("a"), line("b"), line("c"), line("short", pitch: 85, pace: 6, like: 30, seconds: 2)])
        == ["short": ["Pitch 4.5 semitones lower than the other lines"]])
}

@MainActor @Test func renderReadsTheScriptAsOneTakeAndCutsItIntoLines() async throws {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Me")
    let wav = try tempFolder().appending(path: "take.wav")
    // Three bursts of "speech" with silence between them, so the cuts have quiet places to land.
    let burst = (0..<24000).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / 24000)) }
    let gap = [Float](repeating: 0, count: 12000)
    try writeWAV((gap + burst + gap + burst + gap + burst + gap)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let other = voices.createVoice(name: "Narrator")
    try writeWAV((gap + burst + gap)[...], rate: 24000, to: wav)
    try voices.addTake(other, file: wav, tone: "Neutral", transcript: "Hi.", issues: [])
    let projects = ProjectStore(root: try tempFolder())
    let id = projects.create(name: "One take")
    projects.addLines(["One.", "Two.", "Three.", "Four."], to: id, voices: voices)
    let ids = try #require(projects.project(id)?.lines.map(\.id))
    projects.setVoice(other, line: ids[3], in: id)
    let engine = try #require(voices.engine as? FakeEngine)

    try await #require(projects.renderScript(id, voices: voices)).value
    // Lines 1-3 share a voice: one render, timed once, cut in three. Line 4's voice is another take.
    #expect(engine.calls.all.filter { $0.hasPrefix("render:") } == ["render: One. Two. Three.", "render: Four."])
    #expect(engine.calls.count("timeWords") == 1)
    let lines = try #require(projects.project(id)?.lines)
    #expect(lines.allSatisfy { $0.versions.count == 1 && $0.chosen == $0.versions[0].id && $0.chosenVersion?.scores != nil })
    let pieces = lines.prefix(3).map { $0.versions[0].duration }
    // Each piece is about its own burst, with the silence between lines left out.
    #expect(pieces.allSatisfy { $0 > 0.9 && $0 < 1.4 }, "\(pieces)")
    #expect(Set(lines.prefix(3).map { $0.versions[0].seed }).count == 1)

    // Render again: a new take for every line, the old versions kept.
    try await #require(projects.renderScript(id, voices: voices)).value
    #expect(try #require(projects.project(id)?.lines).allSatisfy { $0.versions.count == 2 && $0.chosen == $0.versions[1].id })
}

@Test func consistencyComparesOnlyLinesInTheSameVoice() {
    func line(_ id: String, voice: String, pitch: Double) -> Line {
        let version = Version(id: "v\(id)", text: "Hi there.", voiceID: voice, tone: "Neutral", direction: false, seed: 1,
                              duration: 5, createdAt: .now,
                              scores: Scores(likeYou: 75, human: 3.5, words: 100, heard: "Hi there.", pitchHz: pitch, pace: 3))
        return Line(id: id, text: "Hi there.", voiceID: voice, versions: [version], chosen: version.id)
    }
    // A low voice and a high one are each steady: nothing to note.
    let lines = ["a", "b", "c"].map { line($0, voice: "low", pitch: 110) } + ["d", "e", "f"].map { line($0, voice: "high", pitch: 200) }
    #expect(Consistency.notes(lines).isEmpty)
    #expect(Consistency.notes(lines + [line("g", voice: "high", pitch: 260)]).keys.sorted() == ["g"])
}

@MainActor @Test func renderKeepsTheEarlierVersionOfALineWithMarks() async throws {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Me")
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let projects = ProjectStore(root: try tempFolder())
    let id = projects.create(name: "Marks")
    projects.addLines(["One [pause 0.3] two."], to: id, voices: voices)
    try await #require(projects.renderScript(id, voices: voices)).value
    let first = try #require(projects.project(id)?.lines[0].chosenVersion)
    try await #require(projects.renderScript(id, voices: voices)).value
    let line = try #require(projects.project(id)?.lines[0])
    // Both renders' marked versions stay listed, the new one chosen; the old file is still there.
    #expect(line.visibleVersions.count == 2 && line.chosen != first.id && line.visibleVersions.contains { $0.id == first.id })
    #expect(FileManager.default.fileExists(atPath: projects.audioURL(first, projectID: id).path))
}

@Test func lengthIsMeasuredAgainstOneTake() {
    func line(_ text: String) -> Line { Line(text: text, voiceID: "me") }
    // 299 + 1 space + 300 characters of speech = exactly one take; tags and empty lines don't count.
    let full = [line(String(repeating: "a", count: 299) + " [pause 1]"), line(""), line(String(repeating: "b", count: 300))]
    #expect(OneTake.length(full).share == 1 && OneTake.length(full).seconds == 35)
    let over = full + [line(String(repeating: "c", count: 299))]
    #expect(OneTake.length(over).share > 1 && OneTake.length(over).seconds == 53)
    #expect(OneTake.length([]).seconds == 0)
}

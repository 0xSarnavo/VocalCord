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

@MainActor private func waitForRender(_ projects: ProjectStore) async throws {
    while projects.progress != nil { try await Task.sleep(for: .milliseconds(20)) }
}

@MainActor @Test func renderBatchesScoresAndKeepsVersions() async throws {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Me", fullClone: false)
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

    projects.renderNeeded(id, voices: voices)
    try await waitForRender(projects)
    #expect(projects.error == nil)
    lines = try #require(projects.project(id)).lines
    let first = try #require(lines[0].chosenVersion), second = try #require(lines[1].chosenVersion)
    #expect(!first.direction && second.direction && second.tone == "Happy")
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
    #expect(line.versions.map(\.tone) == ["Happy", "Happy", "Confident", "Sad"])
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

@MainActor @Test func renderRetriesUntilALinePassesAndKeepsTheBest() async throws {
    let counter = ScoreCounter()
    let engine = FakeEngine(delay: .zero, scores: { _, text in
        guard text != "Hello." else { return nil }            // the take's own Human score
        let fails = text.hasPrefix("Never") || counter.next(text) <= 2
        return Scores(likeYou: fails ? 50 : 95, human: 3.6, words: 100, heard: text)
    })
    let voices = VoiceStore(root: try tempFolder(), engine: engine)
    let voiceID = voices.createVoice(name: "Me", fullClone: false)
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 4, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)   // long enough to judge Like you
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let projects = ProjectStore(root: try tempFolder())
    let id = projects.create(name: "Retry")
    projects.addLines(["Third time lucky.", "Never good enough."], to: id, voices: voices)

    projects.renderNeeded(id, voices: voices)
    try await waitForRender(projects)
    let lines = try #require(projects.project(id)?.lines)
    #expect(lines[0].versions.count == 3 && lines[0].chosen == lines[0].versions[2].id && lines[0].chosenVersion?.passes == true)
    #expect(lines[1].versions.count == Version.tries && lines[1].chosenVersion?.passes == false)
    #expect(projects.error?.hasPrefix("Line 2 still has a flag after \(Version.tries) tries") == true)
    #expect(projects.renderTry == nil)
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
    let voiceID = voices.createVoice(name: "Me", fullClone: false)
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let root = try tempFolder(), movies = try tempFolder()
    let projects = ProjectStore(root: root, exportsRoot: movies)
    let id = projects.create(name: "Launch/film")
    projects.addLines(["One.", "Two."], to: id, voices: voices)
    projects.renderNeeded(id, voices: voices)
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
    let warnings = Script.warnings("It costs $4.99 [pause 0.2] and [pause 0.3] takes 10 minutes.")
    #expect(warnings.count == 2)
    #expect(warnings[0].hasPrefix("2 [pause] tags"))
    #expect(warnings[1] == "Write numbers and symbols as spoken words: \u{201C}$4.99\u{201D}, \u{201C}10\u{201D}.")
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
    projects.renderNeeded(id, voices: voices)
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

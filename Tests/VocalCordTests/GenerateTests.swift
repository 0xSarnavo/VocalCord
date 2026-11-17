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
    let client = EngineClient(directory: try fakeEngineFolder())

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
    let client = EngineClient(directory: URL(filePath: "/nonexistent"))
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
    var version = Version(id: "v", text: "Hi", voiceID: "me", tone: "Neutral", direction: false, seed: 1, duration: 1,
                          createdAt: .now, scores: Scores(likeYou: 70, human: 3.1, words: 90, heard: "Hi"), referenceHuman: 3.6)
    #expect(version.likeYouFlag == nil && version.wordsFlag == nil && version.humanFlag == nil)
    version.scores = Scores(likeYou: 62, human: 3.0, words: 80, heard: "Hey")
    #expect(version.likeYouFlag != nil && version.humanFlag == "Human 0.6 below the take's 3.6")
    #expect(version.wordsFlag?.contains("Hey") == true)
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

// MARK: Real engine

/// Renders and scores two lines in "My voice" with the real engine. Opt in: `VOCALCORD_E2E=1 swift test --filter realEngine`.
/// Reads a copy of the user's voices; `VOCALCORD_E2E_PROJECTS` sets where the scratch project goes (default: a temp folder).
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["VOCALCORD_E2E"] != nil), .timeLimit(.minutes(30)))
func realEngineRendersAndScoresTwoLines() async throws {
    let environment = ProcessInfo.processInfo.environment
    let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let voicesCopy = try tempFolder().appending(path: "Voices")
    try FileManager.default.copyItem(at: VoiceStore.defaultRoot, to: voicesCopy)
    let voices = VoiceStore(root: voicesCopy, engine: EngineClient(directory: repo.appending(path: "engine")))
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

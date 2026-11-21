import Foundation
import Testing
@testable import VocalCord

// Script marks through the store: raw renders, versions made by applying marks, commits and their queue, word times
// and pace. The fake engine's renders are a copy of the 2 s take, and its word times share the audio evenly.

/// A voice with one 2 s take whose transcript is one word, so the take's pace is 30 words a minute.
@MainActor private func marksFixture(delay: Duration = .zero, lines: [String]) throws -> (ProjectStore, VoiceStore, FakeEngine, String) {
    let engine = FakeEngine(delay: delay)
    let voices = VoiceStore(root: try tempFolder(), engine: engine)
    let voiceID = voices.createVoice(name: "Me")
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let projects = ProjectStore(root: try tempFolder(), exportsRoot: try tempFolder())
    let id = projects.create(name: "Marks")
    projects.addLines(lines, to: id, voices: voices)
    return (projects, voices, engine, id)
}

/// Waits for renders and mark runs to finish.
@MainActor private func settle(_ projects: ProjectStore) async throws {
    for _ in 0..<1000 {
        if projects.progress == nil && projects.applying.isEmpty && projects.queued.isEmpty { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Still rendering")
}

@MainActor private func lineIn(_ projects: ProjectStore, _ id: String, _ index: Int = 0) throws -> Line {
    try #require(projects.project(id)?.lines[index])
}

private func near(_ a: Double, _ b: Double, _ within: Double = 0.01) -> Bool { abs(a - b) <= within }

// MARK: Rendering

@MainActor @Test func renderWithMarksKeepsARawSourceAndChoosesTheMarkedVersion() async throws {
    let (projects, voices, engine, id) = try marksFixture(lines: ["Hello there [pause 0.5] my friend."])
    projects.renderScript(id, voices: voices)
    try await settle(projects)
    #expect(projects.error == nil)
    let line = try lineIn(projects, id)
    #expect(engine.calls.all == ["render: Hello there my friend.", "applyMarks: \(line.versions[0].id).wav"])
    #expect(line.versions.count == 2)
    let raw = line.versions[0], final = line.versions[1]
    #expect(raw.raw == true && raw.source == nil && raw.text == line.text && raw.words?.count == 4 && raw.matched == 1)
    #expect(final.raw == nil && final.source == raw.id && final.text == line.text && line.chosen == final.id)
    #expect(final.scores == raw.scores && final.referenceHuman == raw.referenceHuman && final.seed == raw.seed && final.tone == raw.tone)
    #expect(near(final.duration, raw.duration + 0.5))
    // The pause goes in the middle of the gap between "there" and "my": the words after it move by 0.5 s.
    let words = try #require(final.words), before = try #require(raw.words)
    #expect(words.count == 4 && words[1] == before[1] && near(words[2].start, before[2].start + 0.5))
    #expect(projects.displayTimes(final)?.count == 4)
    #expect(!line.needsRender && !line.needsVoice)

    // The raw version is a hidden source: not listed among the takes, never chosen.
    #expect(line.visibleVersions == [final] && line.title(final) == "Take 1")
    projects.choose(raw.id, line: line.id, in: id)
    #expect(try lineIn(projects, id).chosen == final.id)

    // Captions read the words without tags.
    #expect(try await projects.exportLines(id, voices: voices).map(\.text) == ["Hello there my friend."])
}

@MainActor @Test func renderWithoutMarksMakesOneVersionAsBefore() async throws {
    let (projects, voices, engine, id) = try marksFixture(lines: ["Hello there."])
    projects.renderScript(id, voices: voices)
    try await settle(projects)
    let line = try lineIn(projects, id)
    #expect(engine.calls.all == ["render: Hello there."])
    #expect(line.versions.count == 1 && line.chosen == line.versions[0].id)
    let version = line.versions[0]
    #expect(version.raw == nil && version.source == nil && version.words?.count == 2 && version.scores != nil)
    #expect(version.words == [WordTime(start: 0, end: 1), WordTime(start: 1, end: 2)])
}

@MainActor @Test func aMarksOnlyEditIsAppliedWithoutRendering() async throws {
    let (projects, voices, engine, id) = try marksFixture(lines: ["One two three."])
    projects.renderScript(id, voices: voices)
    try await settle(projects)
    let plain = try #require(try lineIn(projects, id).chosenVersion)

    // From a render whose text had no marks.
    projects.setText("One [pause 0.3] two three.", line: try lineIn(projects, id).id, in: id)
    var line = try lineIn(projects, id)
    #expect(line.needsRender && !line.needsVoice && line.markSource?.id == plain.id)
    let url = try #require(projects.commitLine(line.id, in: id, voices: voices, render: true))
    let played = try await url.value
    line = try lineIn(projects, id)
    let marked = try #require(line.chosenVersion)
    #expect(played == projects.audioURL(marked, projectID: id))
    #expect(engine.calls.count("render") == 1 && engine.calls.count("applyMarks") == 1)
    #expect(marked.source == plain.id && marked.text == line.text && near(marked.duration, plain.duration + 0.3))
    #expect(!line.needsRender && line.visibleVersions.count == 2)
    // The plain render is still listed, but it stays while a version is made from it.
    #expect(projects.whyKept(plain.id, in: id) != nil)
    projects.deleteTake(plain.id, in: id)
    #expect(try lineIn(projects, id).versions.count == 2)

    // Taking the marks out again chooses the plain render; nothing is made.
    projects.setText("One two three.", line: line.id, in: id)
    #expect(projects.commitLine(line.id, in: id, voices: voices, render: true) != nil)
    #expect(try lineIn(projects, id).chosen == plain.id && engine.calls.count("applyMarks") == 1)
    // Nothing needed: no task.
    #expect(projects.commitLine(line.id, in: id, voices: voices, render: true) == nil)

    // The toolbar's Render reads the script again (one take), then puts the marks on the new render.
    projects.setText("One two [breath] three.", line: line.id, in: id)
    projects.renderScript(id, voices: voices)
    try await settle(projects)
    #expect(engine.calls.all.suffix(2) == ["render: One two three.", "applyMarks: \(try lineIn(projects, id).versions.last { $0.raw == true }!.id).wav"])
    #expect(try lineIn(projects, id).chosenVersion?.text == "One two [breath] three.")
}

@MainActor @Test func aSayOrStressChangeRenders() async throws {
    let (projects, voices, engine, id) = try marksFixture(lines: ["Meet Kuber today."])
    projects.renderScript(id, voices: voices)
    try await settle(projects)
    let lineID = try lineIn(projects, id).id

    projects.setText("Meet [say Koo-ber]Kuber[/say] today.", line: lineID, in: id)
    #expect(try lineIn(projects, id).needsVoice)
    _ = try await #require(projects.commitLine(lineID, in: id, voices: voices, render: true)).value
    #expect(engine.calls.all.last == "render: Meet Koo-ber today.")
    var line = try lineIn(projects, id)
    #expect(line.chosenVersion?.raw == nil && line.chosenVersion?.text == line.text && !line.needsRender)

    // Stress changes what the voice is told, then lifts the words after the render.
    projects.setText("Meet [say Koo-ber]Kuber[/say] [stress]today.[/stress]", line: lineID, in: id)
    #expect(try lineIn(projects, id).needsVoice)
    _ = try await #require(projects.commitLine(lineID, in: id, voices: voices, render: true)).value
    #expect(engine.calls.count("render") == 3)
    #expect(engine.calls.all.suffix(2).first == "render: Meet Koo-ber today. | stress: today")
    line = try lineIn(projects, id)
    #expect(line.chosenVersion?.source == line.versions.last { $0.raw == true }?.id)
    #expect(engine.calls.all.last?.hasPrefix("applyMarks:") == true)
}

@Test func oldStyleVersionsAreNotMarkSources() {
    func version(_ id: String, _ text: String, raw: Bool? = nil, source: String? = nil, tone: String = "Neutral") -> Version {
        Version(id: id, text: text, voiceID: "me", tone: tone, direction: false, seed: 1, duration: 2, createdAt: .now, raw: raw, source: source)
    }
    // Rendered with the engine splitting the line at the pause, before marks existed: it still plays its text.
    var line = Line(text: "Wait [pause 0.5] for it.", voiceID: "me", versions: [version("old", "Wait [pause 0.5] for it.")], chosen: "old")
    #expect(!line.needsRender && !line.versions[0].isMarkSource)
    line.text = "Wait [pause 0.8] for it."
    #expect(line.needsRender && line.needsVoice && line.markSource == nil)

    // A raw render of the same words is a source; a version made by applying marks, or in another tone, isn't.
    line.versions += [version("made", "Wait [pause 0.3] for it.", source: "raw"), version("sad", "Wait for it.", tone: "Sad")]
    #expect(line.needsVoice)
    line.versions.append(version("raw", "Wait [pause 0.3] for it.", raw: true))
    #expect(line.markSource?.id == "raw" && !line.needsVoice && line.needsRender)
    // A raw version never counts as playing the text, even when it has it.
    line.text = "Wait [pause 0.3] for it."
    #expect(!line.reads(line.versions[3]) && line.reads(line.versions[1]) && !line.needsRender)
    #expect(line.visibleVersions.map(\.id) == ["old", "made", "sad"])

    // A raw version's audio has none of its pauses, so they aren't left out of its pace.
    let take = Take(id: "t", tone: "Neutral", transcript: "One two.", duration: 1, score: nil, issues: [], createdAt: .now)
    let scores = Scores(likeYou: 90, human: 3.8, words: 100, heard: "")
    #expect(scores.paced(text: "Hello there [pause 1.0] friend.", duration: 3, take: take, raw: true).pace == 1)
    #expect(near(scores.paced(text: "Hello there [breath] friend.", duration: 3.4, take: take).pace ?? 0, 1))
}

// MARK: Word times

@MainActor @Test func wordTimesAreBackfilledQuietly() async throws {
    let root = try tempFolder()
    let folder = root.appending(path: "old")
    try FileManager.default.createDirectory(at: folder.appending(path: "renders"), withIntermediateDirectories: true)
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: folder.appending(path: "renders/v1.wav"))
    // Saved before word times existed; line 2's render file is gone.
    try Data(#"""
        {"createdAt": 700000000, "id": "old", "name": "Old film", "lines": [
          {"id": "l1", "text": "Hello there.", "voiceID": "me", "tone": "Neutral", "pauseAfter": 0.5, "chosen": "v1",
           "versions": [{"id": "v1", "text": "Hello there.", "voiceID": "me", "tone": "Neutral", "direction": false, "seed": 7,
                         "duration": 2, "createdAt": 700000000}]},
          {"id": "l2", "text": "Gone.", "voiceID": "me", "tone": "Neutral", "pauseAfter": 0.5, "chosen": "v2",
           "versions": [{"id": "v2", "text": "Gone.", "voiceID": "me", "tone": "Neutral", "direction": false, "seed": 7,
                         "duration": 2, "createdAt": 700000000}]}]}
        """#.utf8).write(to: folder.appending(path: "project.json"))
    let engine = FakeEngine(delay: .zero)
    let voices = VoiceStore(root: try tempFolder(), engine: engine)
    let projects = ProjectStore(root: root)
    #expect(projects.project("old")?.lines[0].chosenVersion?.words == nil)

    projects.timeWordsIfNeeded("old", voices: voices)
    projects.timeWordsIfNeeded("old", voices: voices)   // already timing: ignored
    for _ in 0..<500 where projects.project("old")?.lines[0].chosenVersion?.words == nil { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(50))
    let version = try #require(projects.project("old")?.lines[0].chosenVersion)
    #expect(version.words == [WordTime(start: 0, end: 1), WordTime(start: 1, end: 2)] && version.matched == 1)
    #expect(projects.displayTimes(version)?.count == 2)
    #expect(projects.project("old")?.lines[1].chosenVersion?.words == nil && projects.error == nil)
    #expect(engine.calls.count("timeWords") == 1)
    #expect(ProjectStore(root: root).project("old")?.lines[0].chosenVersion?.words == version.words)

    // Nothing left to time.
    projects.timeWordsIfNeeded("old", voices: voices)
    try await Task.sleep(for: .milliseconds(50))
    #expect(engine.calls.count("timeWords") == 1)
}

// MARK: Pruning

@MainActor @Test func aReplacedMarkedVersionIsDroppedUnlessSomethingUsesIt() async throws {
    let (projects, voices, engine, id) = try marksFixture(lines: ["One [pause 0.3] two three."])
    projects.renderScript(id, voices: voices)
    try await settle(projects)
    let lineID = try lineIn(projects, id).id
    let raw = try lineIn(projects, id).versions[0], first = try #require(try lineIn(projects, id).chosenVersion)
    fillTimeline(projects, id)   // the timeline plays the first marked version

    projects.setText("One [pause 0.6] two three.", line: lineID, in: id)
    #expect(try await projects.applyMarks(line: lineID, in: id, voices: voices))
    let second = try #require(try lineIn(projects, id).chosenVersion)
    #expect(second.source == raw.id)
    #expect(try lineIn(projects, id).versions.map(\.id) == [raw.id, first.id, second.id])

    projects.setText("One [pause 0.9] two three.", line: lineID, in: id)
    #expect(try await projects.applyMarks(line: lineID, in: id, voices: voices))
    let third = try #require(try lineIn(projects, id).chosenVersion)
    // The second was only a step: gone, file and all. The first stays while the timeline uses it.
    #expect(try lineIn(projects, id).versions.map(\.id) == [raw.id, first.id, third.id])
    #expect(!FileManager.default.fileExists(atPath: projects.audioURL(second, projectID: id).path))
    #expect(engine.calls.count("render") == 1)

    // The raw render stays while a version is made from it; deleting a marked version leaves it.
    projects.deleteTake(raw.id, in: id)
    #expect(try lineIn(projects, id).versions.contains { $0.id == raw.id })
    for clip in projects.project(id)?.edit?.clips ?? [] { projects.deleteClip(clip.id, in: id) }
    projects.deleteTake(first.id, in: id)
    #expect(try lineIn(projects, id).versions.map(\.id) == [raw.id, third.id])
    #expect(FileManager.default.fileExists(atPath: projects.audioURL(raw, projectID: id).path))
    #expect(try lineIn(projects, id).visibleVersions.map(\.id) == [third.id])
}

// MARK: Committing

@MainActor @Test func commitsQueueBehindTheRenderInOrder() async throws {
    let (projects, voices, engine, id) = try marksFixture(delay: .milliseconds(40), lines: ["Line A.", "Line B.", "Line C."])
    let ids = try #require(projects.project(id)?.lines.map(\.id))
    let a = try #require(projects.commitLine(ids[0], in: id, voices: voices, render: true))
    let b = try #require(projects.commitLine(ids[1], in: id, voices: voices, render: true))
    let c = try #require(projects.commitLine(ids[2], in: id, voices: voices, render: true))
    let again = try #require(projects.commitLine(ids[1], in: id, voices: voices, render: true))
    #expect(projects.queued == [ids[1], ids[2]])   // one entry per line

    let urls = [try await a.value, try await b.value, try await c.value, try await again.value]
    #expect(projects.queued.isEmpty)
    #expect(engine.calls.all == ["render: Line A.", "render: Line B.", "render: Line C."])
    #expect(urls == [ids[0], ids[1], ids[2], ids[1]].map { projects.chosenAudio(line: $0, in: id) })
    #expect(urls.allSatisfy { $0 != nil })
    try await settle(projects)
}

@MainActor @Test func cancelClearsTheQueue() async throws {
    let (projects, voices, engine, id) = try marksFixture(delay: .milliseconds(400), lines: ["Line A.", "Line B.", "Line C."])
    let ids = try #require(projects.project(id)?.lines.map(\.id))
    let tasks = try ids.map { try #require(projects.commitLine($0, in: id, voices: voices, render: true)) }
    #expect(projects.queued == [ids[1], ids[2]])
    try await Task.sleep(for: .milliseconds(50))
    projects.cancel()
    #expect(projects.queued.isEmpty)
    for task in tasks { await #expect(throws: CancellationError.self) { try await task.value } }
    try await settle(projects)
    #expect(engine.calls.count("render") <= 1)
    #expect(projects.project(id)?.lines.allSatisfy { $0.chosen == nil } == true)
}

// MARK: Pace

@MainActor @Test func paceTargetIsClamped() throws {
    let root = try tempFolder()
    let projects = ProjectStore(root: root)
    let id = projects.create(name: "Pace")
    #expect(projects.project(id)?.paceTarget == nil)
    projects.setPaceTarget(40, in: id)
    #expect(projects.project(id)?.paceTarget == 80)
    projects.setPaceTarget(400, in: id)
    #expect(projects.project(id)?.paceTarget == 260)
    projects.setPaceTarget(.nan, in: id)
    #expect(projects.project(id)?.paceTarget == 260)
    projects.setPaceTarget(150, in: id)
    #expect(ProjectStore(root: root).project(id)?.paceTarget == 150)
    projects.setPaceTarget(nil, in: id)
    #expect(projects.project(id)?.paceTarget == nil)
}

@MainActor @Test func paceReportAndFix() async throws {
    let (projects, voices, engine, id) = try marksFixture(lines: ["One two three four five six seven eight."])
    let lineID = try lineIn(projects, id).id
    #expect(projects.paceReport(line: lineID, in: id) == nil)   // no render yet
    projects.renderScript(id, voices: voices)
    try await settle(projects)
    let plain = try #require(try lineIn(projects, id).chosenVersion)

    // 8 words in 2 s against the take's 1 word in 2 s.
    let report = try #require(projects.paceReport(line: lineID, in: id))
    #expect(near(report.wordsPerMinute, 240) && near(report.target, 30) && report.rushed == [0...7] && report.dragging.isEmpty)
    #expect(report.verdict == "240 words a minute, 700% faster than your usual 30.")
    projects.setPaceTarget(240, in: id)
    #expect(projects.paceReport(line: lineID, in: id)?.verdict == nil && projects.paceReport(line: lineID, in: id)?.rushed == [])
    projects.setPaceTarget(nil, in: id)

    // A rushed stretch is slowed to 85% and applied at once.
    #expect(try await projects.fixPace(line: lineID, range: 0...3, in: id, voices: voices))
    var line = try lineIn(projects, id)
    #expect(line.text == "[speed 85%]One two three four[/speed] five six seven eight.")
    let slowed = try #require(line.chosenVersion)
    #expect(slowed.source == plain.id && near(slowed.duration, 1 / 0.85 + 1, 0.002) && engine.calls.count("render") == 1)

    // Again: on top of the speed already there.
    #expect(try await projects.fixPace(line: lineID, range: 0...3, in: id, voices: voices))
    line = try lineIn(projects, id)
    #expect(line.text == "[speed 72%]One two three four[/speed] five six seven eight.")
    #expect(line.chosenVersion?.source == plain.id && line.versions.count == 2)   // the 85% step was dropped

    // At 200 words a minute every stretch is on pace (183 to 223), so nothing is changed.
    projects.setPaceTarget(200, in: id)
    let onPace = try #require(projects.paceReport(line: lineID, in: id))
    #expect(onPace.rushed.isEmpty && onPace.dragging.isEmpty && onPace.verdict == nil)
    await #expect(throws: AppError.self) { try await projects.fixPace(line: lineID, range: 0...1, in: id, voices: voices) }
    #expect(try lineIn(projects, id).text == "[speed 72%]One two three four[/speed] five six seven eight.")
}

// MARK: Timeline and script

@MainActor @Test func segmentsNameTheirVersion() async throws {
    let (projects, voices, _, id) = try marksFixture(lines: ["One.", "Two.", "Not yet."])
    try await renderEachLine(projects, id, voices: voices)
    try await settle(projects)
    projects.setText("Not yet, changed.", line: try lineIn(projects, id, 2).id, in: id)
    var project = try #require(projects.project(id))
    project.lines[2].chosen = nil
    project.lines[2].versions = []
    let script = Timeline(project) { projects.audioURL($0, projectID: id) }
    #expect(script.segments.map(\.versionID) == [project.lines[0].chosen, project.lines[1].chosen, nil])
    #expect(script.segments[0].renderTime(at: 1) == 1 && script.segments[2].renderTime(at: script.segments[2].start) == nil)

    fillTimeline(projects, id)
    let clips = try #require(projects.project(id)?.edit?.clips)
    #expect(projects.trimClip(clips[1].id, start: 0.5, end: 2, in: id))
    #expect(projects.setClipEffects(VoiceEffects(tempo: 2), clip: clips[1].id, in: id))
    let edit = try #require(projects.project(id)?.edit)
    let timeline = try await projects.playbackTimeline(id, engine: voices.engine)
    #expect(timeline.segments.map(\.versionID) == edit.clips.map(\.versionID))
    let second = timeline.segments[1]
    #expect(second.renderStart == 0.5 && second.tempo == 2 && second.start == 2.5)
    #expect(second.renderTime(at: 2.75) == 1 && second.renderTime(at: 2.4) == nil)
    #expect(timeline.segment(at: 2.6)?.clipID == edit.clips[1].id)
}

@Test func scriptWarningsReportTagProblems() {
    #expect(Script.warnings("Say it [speed 80%]slowly.") == ["A [speed] isn't closed."])
    #expect(Script.warnings("Wait [pause 20] then go.") == ["Pause must be 0.05 to 10 seconds."])
    // A [say] spells the number out for the voice.
    #expect(Script.warnings("It costs [say four ninety-nine]$4.99[/say] today.") == [])
    #expect(Script.warnings("It costs $4.99 today.").count == 1)
    #expect(JevSubject(text: "Hello [pause 0.5] [say Koo-ber]Kuber[/say]!", tone: "Neutral").text == "Hello Kuber!")
}

// MARK: Engine client

/// A worker that checks the fields of `score` with tokens, `time_words`, `apply_marks` and `render` with stress.
private let marksWorker = #"""
import json, sys

def reply(m, **fields):
    print(json.dumps({"id": m["id"], "event": "result", **fields}), flush=True)

def fail(m, message):
    print(json.dumps({"id": m["id"], "event": "error", "code": "invalid", "message": message}), flush=True)

for raw in sys.stdin:
    m = json.loads(raw)
    cmd = m["cmd"]
    if cmd == "score":
        if m.get("tokens") != ["Koo-ber", "is", "here."]:
            fail(m, "tokens: %r" % m.get("tokens"))
        else:
            reply(m, like_you=90, human=3.6, words=100, heard="Kuber is here.", similarity=0.8,
                  word_times=[[0.1, 0.5], [0.5, 0.7], [0.7, 1.2]], matched=0.667)
    elif cmd == "time_words":
        if set(m) != {"id", "cmd", "audio", "tokens", "hints"} or m["hints"] != ["Kuber"]:
            fail(m, "fields: %r" % sorted(m))
        else:
            reply(m, word_times=[[0, 0.4], [0.4, 0.9]], heard="Hi there.", matched=1.0)
    elif cmd == "apply_marks":
        marks = m.get("marks", {})
        if set(m) != {"id", "cmd", "audio", "out", "word_times", "marks"} or set(marks) != {"pauses", "speeds", "stresses"} \
                or marks["pauses"] != [{"after": 0, "seconds": 0.5}] or m["word_times"] != [[0, 0.4], [0.4, 0.9]]:
            fail(m, "fields: %r" % m)
        else:
            reply(m, path=m["out"], duration=1.4, word_times=[[0, 0.4], [0.9, 1.4]])
    elif cmd == "render":
        line = m["lines"][0]
        if line.get("stress") != ["today"]:
            fail(m, "stress: %r" % line.get("stress"))
        else:
            reply(m, path=m["output"], duration=2.0, lines=[])
"""#

@Test func engineClientSendsWordTimesAndMarks() async throws {
    let folder = try tempFolder()
    let bin = folder.appending(path: ".venv/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appending(path: "vocalcord_engine"), withIntermediateDirectories: true)
    try marksWorker.write(to: folder.appending(path: "vocalcord_engine/__main__.py"), atomically: true, encoding: .utf8)
    let python = bin.appending(path: "python")
    try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    let client = EngineClient(location: .dev(folder))

    let scored = try await client.score(URL(filePath: "/r.wav"), reference: URL(filePath: "/t.wav"), text: "Kuber is here.", hints: ["Kuber"],
                                        tokens: ["Koo-ber", "is", "here."])
    #expect(scored.scores.likeYou == 90 && scored.matched == 0.667)
    #expect(scored.words == [WordTime(start: 0.1, end: 0.5), WordTime(start: 0.5, end: 0.7), WordTime(start: 0.7, end: 1.2)])

    let timed = try await client.timeWords(URL(filePath: "/r.wav"), tokens: ["Hi", "there."], hints: ["Kuber"])
    #expect(timed.words == [WordTime(start: 0, end: 0.4), WordTime(start: 0.4, end: 0.9)] && timed.heard == "Hi there." && timed.matched == 1)

    let marks = Marks.parse("Hi [pause 0.5] there.").marks
    let applied = try await client.applyMarks(URL(filePath: "/r.wav"), words: timed.words, marks: marks, to: URL(filePath: "/o.wav"))
    #expect(applied.duration == 1.4 && applied.words == [WordTime(start: 0, end: 0.4), WordTime(start: 0.9, end: 1.4)])

    let line = RenderLine(text: "Meet me today.", tone: "Neutral", reference: URL(filePath: "/t.wav"), referenceText: "Hi.", pronunciations: [:],
                          stress: ["today"])
    #expect(try await client.render(line, to: URL(filePath: "/o.wav")) { _ in } == 2)
}

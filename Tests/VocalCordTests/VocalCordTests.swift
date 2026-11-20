import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import VocalCord

func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "VocalCordTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Half-second bursts of a tone at `amplitude`, separated by noise at `floor`.
/// Half-second bursts of tone with gaps. Silent edges leave a quarter second without tone at each end, like a recording
/// that starts and stops in silence.
func speechLike(seconds: Double, amplitude: Float, floor: Float, rate: Double = 24000, silentEdges: Bool = true) -> [Float] {
    (0..<Int(seconds * rate)).map { index in
        let time = Double(index) / rate
        let talking = Int(time * 2) % 2 == 0 && (!silentEdges || (0.25..<seconds - 0.25).contains(time))
        let noise = Float.random(in: -floor...floor)
        return talking ? min(1, max(-1, amplitude * Float(sin(2 * .pi * 220 * time)))) + noise : noise
    }
}

private func issues(_ samples: [Float]) -> [AudioIssue] {
    var analyzer = LevelAnalyzer()
    analyzer.add(samples, sampleRate: 24000)
    return analyzer.issues
}

@Test func levelChecks() {
    #expect(issues(speechLike(seconds: 4, amplitude: 0.3, floor: 0.0003)) == [])
    #expect(issues(speechLike(seconds: 4, amplitude: 0.003, floor: 0.0003)) == [.quiet])
    #expect(issues(speechLike(seconds: 4, amplitude: 1.5, floor: 0.0003)) == [.clipped])
    #expect(issues(speechLike(seconds: 4, amplitude: 0.3, floor: 0.03)) == [.noisy])
    #expect(issues(speechLike(seconds: 4, amplitude: 0.3, floor: 0.0003, silentEdges: false)) == [.cutOff])
}

@Test func voiceCheckLinesFollowTheScriptRules() {
    for test in VoiceTest.allCases {
        #expect(test.lines.count == 10)
        for line in test.lines { #expect(Script.warnings(line.text) == [], "\(line.text)") }
        let minutes = test.estimate(model: "4bit")
        #expect(minutes.lowerBound >= 1 && minutes.lowerBound < minutes.upperBound)
    }
    #expect(Set(VoiceTest.range.lines.map(\.tone)) == Set(Tone.shown))
    #expect(VoiceTest.long.estimate(model: "8bit").lowerBound > VoiceTest.long.estimate(model: "4bit").lowerBound)
}

@MainActor @Test func voiceCheckRendersEachLineOnceAndReplacesTheLastCheck() async throws {
    let counter = ScoreCounter()
    let engine = FakeEngine(delay: .zero, scores: { _, text in
        guard text != "Hello." else { return nil }
        return Scores(likeYou: counter.next(text) == 1 ? 50 : 95, human: 3.6, words: 100, heard: text)   // a text's first render fails
    })
    let store = VoiceStore(root: try tempFolder(), engine: engine)
    let id = store.createVoice(name: "Me")
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 4, amplitude: 0.3, floor: 0.0003)[...], rate: 24000, to: wav)
    try store.addTake(id, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])

    try await store.check(id, test: .range)
    var report = try #require(store.voice(id)?.lastCheck)
    // Each line renders once, so each first render's flag stays: nothing renders again.
    #expect(report.test == .range && report.lines.count == 10 && report.passed == 0)
    #expect(report.lines.allSatisfy { $0.version.tone == "Neutral" && !$0.version.direction })   // tones are hidden
    let folder = store.folder(id).appending(path: "check")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 10)

    // The same line ten times, its first render already done above, and the new check replaces the last one's files.
    try await store.check(id, test: .consistency)
    report = try #require(store.voice(id)?.lastCheck)
    #expect(report.test == .consistency && report.passed == 10)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 10)
    #expect(report.lines.allSatisfy { FileManager.default.fileExists(atPath: store.checkURL($0.version, voiceID: id).path) })
}

@MainActor @Test func takesSavedBeforeTheCutOffCheckGetIt() async throws {
    let store = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let id = store.createVoice(name: "Me")
    for silentEdges in [true, false] {
        let wav = try tempFolder().appending(path: "take.wav")
        try writeWAV(speechLike(seconds: 4, amplitude: 0.3, floor: 0.0003, silentEdges: silentEdges)[...], rate: 24000, to: wav)
        try store.addTake(id, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    }
    await store.checkCutOff()
    #expect(store.voice(id)?.takes.map(\.issues) == [[], [.cutOff]])
    await store.checkCutOff()   // a take already flagged isn't flagged again
    #expect(store.voice(id)?.takes[1].issues == [.cutOff])
}

@MainActor @Test func migratesOldLibraryWithoutTouchingIt() throws {
    let root = try tempFolder()
    let takeID = "D98EF0AE-0B01-44EF-A37C-B0770E6663E2", voiceID = "73EA671D-0F1B-4E9C-9EE7-178F1AC2B9E9"
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: root.appending(path: "\(takeID).wav"))
    let library = root.appending(path: "library.json")
    try Data("""
    [{"createdAt": 816537425.48, "currentTakeID": "\(takeID)", "id": "\(voiceID)", "name": "My voice",
      "takes": [{"createdAt": 816537425.48, "id": "\(takeID)", "name": "Introduction",
                 "style": "Neutral", "transcript": "Thanks for having me."}]}]
    """.utf8).write(to: library)
    let before = try Data(contentsOf: library)

    let store = VoiceStore(root: root, engine: FakeEngine(delay: .zero))
    let voice = try #require(store.voices.first)
    #expect(store.voices.count == 1 && voice.name == "My voice")
    #expect(voice.takes.map(\.transcript) == ["Thanks for having me."])
    #expect(abs(voice.takes[0].duration - 2) < 0.01)
    #expect(voice.mainTake("Neutral")?.id == takeID)
    #expect(FileManager.default.fileExists(atPath: store.audioURL(voice.takes[0], voiceID: voiceID).path))
    #expect(try Data(contentsOf: library) == before)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(takeID).wav").path))

    // Deleting the migrated take keeps its audio and leaves the original alone.
    store.removeTakes([takeID], from: voiceID)
    #expect(FileManager.default.fileExists(atPath: store.rawFolder(voiceID).appending(path: "\(takeID).wav").path))
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "\(takeID).wav").path))
    #expect(VoiceStore(root: root, engine: FakeEngine()).voices == store.voices)
}

@Test func fakeEngineSplitsAtPauses() async throws {
    let folder = try tempFolder()
    let source = folder.appending(path: "long.wav")
    try writeWAV(speechLike(seconds: 30, amplitude: 0.3, floor: 0.0003)[...], rate: 24000, to: source)
    let clips = try await FakeEngine(delay: .zero).split(source, minSeconds: 3, maxSeconds: 12, into: folder) { _ in }
    #expect(clips.count >= 3)
    #expect(clips.allSatisfy { $0.duration <= 12.01 && FileManager.default.fileExists(atPath: $0.url.path) })
    #expect(abs(clips.reduce(0) { $0 + $1.duration } - 30) < 0.2)
    #expect(try await FakeEngine(delay: .zero).checkAudio(clips[0].url).issues == [])
}

@MainActor @Test func uploadKeepsOriginalAndAuditionPicksMains() async throws {
    let root = try tempFolder()
    let upload = try tempFolder().appending(path: "talk.wav")
    try writeWAV(speechLike(seconds: 25, amplitude: 0.3, floor: 0.0003)[...], rate: 24000, to: upload)
    let store = VoiceStore(root: root, engine: FakeEngine(delay: .zero))
    let voiceID = store.createVoice(name: " ")
    let ids = try await store.importMedia(upload, voiceID: voiceID, tone: "Neutral") { _ in }
    let voice = try #require(store.voice(voiceID))
    #expect(voice.name == "Untitled voice")
    #expect(ids.count >= 2 && voice.takes("Neutral").count == ids.count)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.rawFolder(voiceID).path).count == 1)
    #expect(FileManager.default.fileExists(atPath: upload.path))

    try await store.audition(voiceID) { _ in }
    let auditioned = try #require(store.voice(voiceID))
    let scored = auditioned.takes.filter { $0.score != nil }
    #expect(scored.count == min(5, ids.count))
    #expect(auditioned.mains["Neutral"] == scored.max { $0.score! < $1.score! }?.id)
}

@Test func fileClipsWithWarningsOrOddLengthsArentKept() {
    let clip = { (seconds: Double) in Clip(url: URL(filePath: "/clip.wav"), duration: seconds, transcript: "Hi.") }
    #expect(FileClip(clip(8), issues: []).keep)
    #expect(!FileClip(clip(8), issues: [.noisy]).keep)
    #expect(!FileClip(clip(2.5), issues: []).keep)
    #expect(!FileClip(clip(21), issues: []).keep)
}

@MainActor @Test func fromAFileKeepsSourcesAndClipsAndMakesKeptTakes() async throws {
    let upload = try tempFolder().appending(path: "podcast.wav")
    try writeWAV(speechLike(seconds: 40, amplitude: 0.3, floor: 0.0003)[...], rate: 24000, to: upload)
    let store = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero, speakers: 2))
    let folder = try tempFolder()
    let clips = try await store.cutFiles([upload], into: folder) { _ in }
    let groups = try await store.groupBySpeaker(clips) { _ in }
    #expect(groups.count == 2 && groups.joined().count == clips.count)

    var chosen = try #require(groups.first { $0.count >= 2 })
    chosen[0].keep = false
    chosen[1].keep = true
    let id = try store.createVoice(name: "Podcast", from: folder, clips: chosen)
    let voice = try #require(store.voice(id))
    #expect(voice.takes.count == chosen.filter(\.keep).count && voice.takes("Neutral").count == voice.takes.count)
    let kept = store.rawFolder(id).appending(path: folder.lastPathComponent)
    #expect(FileManager.default.fileExists(atPath: kept.appending(path: "sources/1 podcast.wav").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: kept.appending(path: "clips-1").path).count == clips.count)
    #expect(!FileManager.default.fileExists(atPath: folder.path) && FileManager.default.fileExists(atPath: upload.path))

    try await store.audition(id) { _ in }
    let auditioned = try #require(store.voice(id))
    #expect(auditioned.mains["Neutral"] == auditioned.takes.filter { $0.score != nil }.max { $0.score! < $1.score! }?.id)
}

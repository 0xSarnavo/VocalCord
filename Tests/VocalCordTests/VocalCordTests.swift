import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import VocalCord

private func tempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "VocalCordTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Half-second bursts of a tone at `amplitude`, separated by noise at `floor`.
private func speechLike(seconds: Double, amplitude: Float, floor: Float, rate: Double = 24000) -> [Float] {
    (0..<Int(seconds * rate)).map { index in
        let time = Double(index) / rate
        let talking = Int(time * 2) % 2 == 0
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
}

@MainActor @Test func migratesOldLibraryWithoutTouchingIt() throws {
    let root = try tempFolder()
    let takeID = "D98EF0AE-0B01-44EF-A37C-B0770E6663E2", voiceID = "73EA671D-0F1B-4E9C-9EE7-178F1AC2B9E9"
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: root.appending(path: "\(takeID).wav"))
    let library = root.appending(path: "library.json")
    try Data("""
    [{"createdAt": 816537425.48, "currentTakeID": "\(takeID)", "id": "\(voiceID)", "name": "My voice",
      "takes": [{"createdAt": 816537425.48, "id": "\(takeID)", "name": "Reference take",
                 "style": "Neutral", "transcript": "Every voice tells a story."}]}]
    """.utf8).write(to: library)
    let before = try Data(contentsOf: library)

    let store = VoiceStore(root: root, engine: FakeEngine(delay: .zero))
    let voice = try #require(store.voices.first)
    #expect(store.voices.count == 1 && voice.name == "My voice")
    #expect(voice.takes.map(\.transcript) == ["Every voice tells a story."])
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

/// Feeds a WAV through the microphone's write-and-measure path.
@Test func recordingPathWritesWAVAndLevels() throws {
    let folder = try tempFolder()
    let source = folder.appending(path: "in.wav"), output = folder.appending(path: "out.wav")
    try writeWAV(speechLike(seconds: 3, amplitude: 0.3, floor: 0.0003)[...], rate: 24000, to: source)
    let file = try AVAudioFile(forReading: source)
    let blocks = Mutex<[BlockLevel]>([])
    let capture = MicCapture()
    try capture.open(writingTo: output, sampleRate: 24000) { block in blocks.withLock { $0.append(block) } }
    while file.framePosition < file.length {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        try file.read(into: buffer, frameCount: 4096)
        capture.process(buffer)
    }
    capture.close()
    #expect(abs(audioDuration(output) - 3) < 0.01)
    var analyzer = LevelAnalyzer()
    blocks.withLock { $0.forEach { analyzer.add($0) } }
    #expect(abs(analyzer.seconds - 3) < 0.01)
    #expect(analyzer.issues == [])
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

@Test func fullCloneSessionSteps() {
    var session = Session()
    session = FullClone.next(session, previous: [])
    #expect(session.step == 1 && session.index == 0)
    session = FullClone.back(session)
    #expect(session.step == 0)
    session = FullClone.skip(Session(step: 3, index: 7))
    #expect(session.step == 3 && session.index == 12)
    session = FullClone.skip(Session(step: 3, index: 40))
    #expect(session.step == 4)
}

@MainActor @Test func uploadKeepsOriginalAndAuditionPicksMains() async throws {
    let root = try tempFolder()
    let upload = try tempFolder().appending(path: "talk.wav")
    try writeWAV(speechLike(seconds: 25, amplitude: 0.3, floor: 0.0003)[...], rate: 24000, to: upload)
    let store = VoiceStore(root: root, engine: FakeEngine(delay: .zero))
    let voiceID = store.createVoice(name: " ", fullClone: true)
    let ids = try await store.importMedia(upload, voiceID: voiceID, tone: "Happy") { _ in }
    let voice = try #require(store.voice(voiceID))
    #expect(voice.name == "Untitled voice" && voice.session == Session())
    #expect(ids.count >= 2 && voice.takes("Happy").count == ids.count)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.rawFolder(voiceID).path).count == 1)
    #expect(FileManager.default.fileExists(atPath: upload.path))

    try await store.audition(voiceID) { _ in }
    let auditioned = try #require(store.voice(voiceID))
    let scored = auditioned.takes.filter { $0.score != nil }
    #expect(scored.count == min(5, ids.count))
    #expect(auditioned.mains["Happy"] == scored.max { $0.score! < $1.score! }?.id)
}

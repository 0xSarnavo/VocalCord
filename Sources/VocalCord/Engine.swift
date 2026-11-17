import Foundation

struct AudioCheck: Sendable {
    var duration: Double
    var issues: [AudioIssue]
}

struct Clip: Sendable {
    var url: URL
    var duration: Double
    var transcript: String
}

/// What Clone needs from the speech engine. Each call maps to one command in `engine/PROTOCOL.md`;
/// the process client is wired up once the engine lands.
protocol Engine: Sendable {
    /// `transcribe`: Whisper transcript of a clip.
    func transcribe(_ audio: URL) async throws -> String
    /// `check_audio`: too quiet, clipped and noisy warnings for any audio or video file.
    func checkAudio(_ media: URL) async throws -> AudioCheck
    /// `split`: cuts audio or video into WAV clips at natural pauses, with their transcripts.
    func split(_ media: URL, minSeconds: Double, maxSeconds: Double, into folder: URL,
               progress: @escaping @Sendable (Double) -> Void) async throws -> [Clip]
    /// `render` with one line: `text` in `tone`, cloned from one reference take.
    func renderAuditionLine(_ text: String, tone: String, reference: URL, referenceText: String,
                            pronunciations: [String: String], to output: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws
    /// `score`: how much a render sounds like its reference take, from 0 to 1 (`like_you` / 100).
    func score(_ render: URL, reference: URL, text: String) async throws -> Double
}

/// Stands in for the engine until it lands: real audio checks and splitting, made-up transcripts, renders and scores.
struct FakeEngine: Engine {
    var delay = Duration.milliseconds(500)

    private static let lines = [
        "I'll send the file in a minute.", "The meeting starts at ten.", "Let me double-check that.",
        "We can ship this today.", "That's great news, thanks for letting me know.",
        "I think the second option makes more sense for us.", "Give me a moment to find the notes.",
    ]

    /// Stable across launches, unlike hashValue.
    private func pick(_ url: URL) -> Int { url.lastPathComponent.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } }

    func transcribe(_ audio: URL) async throws -> String {
        try await Task.sleep(for: delay)
        return Self.lines[pick(audio) % Self.lines.count]
    }

    func checkAudio(_ media: URL) async throws -> AudioCheck {
        let samples = try await loadSamples(media)
        var analyzer = LevelAnalyzer()
        analyzer.add(samples, sampleRate: 24000)
        return AudioCheck(duration: analyzer.seconds, issues: analyzer.issues)
    }

    func split(_ media: URL, minSeconds: Double, maxSeconds: Double, into folder: URL,
               progress: @escaping @Sendable (Double) -> Void) async throws -> [Clip] {
        let rate = 24000.0, block = 2400
        let samples = try await loadSamples(media, rate: rate)
        let energy = stride(from: 0, to: samples.count, by: block).map { start in
            samples[start..<min(start + block, samples.count)].reduce(0) { $0 + $1 * $1 }
        }
        // Cut at the quietest 100 ms block between min and max seconds, leaving at least 2 s after it.
        let longest = Int(maxSeconds * 10), shortest = Int(minSeconds * 10)
        var cuts = [0]
        while energy.count - cuts.last! > longest {
            let low = cuts.last! + shortest, high = min(cuts.last! + longest, energy.count - 20)
            guard low < high, let cut = (low..<high).min(by: { energy[$0] < energy[$1] }) else { break }
            cuts.append(cut)
        }
        cuts.append(energy.count)
        var clips: [Clip] = []
        for (number, (start, end)) in zip(cuts, cuts.dropFirst()).enumerated() {
            let slice = samples[(start * block)..<min(end * block, samples.count)]
            guard Double(slice.count) / rate >= 1 else { continue }
            let url = folder.appending(path: "clip-\(number + 1).wav")
            try writeWAV(slice, rate: rate, to: url)
            clips.append(Clip(url: url, duration: Double(slice.count) / rate, transcript: Self.lines[(pick(media) + number) % Self.lines.count]))
            progress(Double(number + 1) / Double(cuts.count - 1))
            try await Task.sleep(for: delay / 5)
        }
        return clips
    }

    func renderAuditionLine(_ text: String, tone: String, reference: URL, referenceText: String,
                            pronunciations: [String: String], to output: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        for step in 1...4 {
            try await Task.sleep(for: delay / 4)
            progress(Double(step) / 4)
        }
        try FileManager.default.copyItem(at: reference, to: output)
    }

    func score(_ render: URL, reference: URL, text: String) async throws -> Double {
        try await Task.sleep(for: delay / 4)
        return 0.88 + Double(pick(render) % 11) / 100
    }
}

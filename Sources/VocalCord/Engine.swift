import Foundation
import Synchronization

struct AudioCheck: Sendable {
    var duration: Double
    var issues: [AudioIssue]
}

struct Clip: Sendable {
    var url: URL
    var duration: Double
    var transcript: String
}

/// One line for `render`: `text` in `tone` (a tone name or a free direction), cloned from one reference take.
struct RenderLine: Sendable {
    var text: String
    var tone: String
    var reference: URL
    var referenceText: String
    var pronunciations: [String: String]
    var seed: Int?
}

/// The engine's `score` result.
struct Scores: Codable, Hashable, Sendable {
    /// Speaker similarity, 0–100.
    var likeYou: Int
    /// Naturalness, 1.0–5.0.
    var human: Double
    /// (1 − WER) × 100 against the script.
    var words: Int
    /// What Whisper heard.
    var heard: String
    /// Median pitch in Hz of the render and of its take (0 when nothing is voiced). Nil in scores saved before the
    /// engine measured them, and those aren't checked.
    var pitchHz: Double?
    var referencePitchHz: Double?
    /// The longest gap inside the render, in seconds.
    var longestPause: Double?
    /// Words a second in the render and in its take, set by the app (`paced`).
    var pace: Double?
    var referencePace: Double?
}

extension Scores {
    /// With the pace check's inputs: words a second in the render (its [pause] seconds left out) and in its take.
    func paced(text: String, duration: Double, take: Take) -> Scores {
        func words(_ text: String) -> Double {
            Double(text.replacing(/\[[^\]]*\]|\([^)]*\)/, with: " ").split(whereSeparator: \.isWhitespace).count)
        }
        let pauses = text.matches(of: /\[\s*pause\s+(\d+(?:\.\d+)?)\s*\]/.ignoresCase()).reduce(0.0) { $0 + (Double($1.output.1) ?? 0) }
        var scores = self
        scores.pace = duration - pauses > 0.5 ? words(text) / (duration - pauses) : nil
        scores.referencePace = take.duration > 0 ? words(take.transcript) / take.duration : nil
        return scores
    }
}

/// Seconds of rendering per second of audio on this Mac, per model, learned from recent renders. For time estimates.
enum RenderSpeed {
    /// Until a render is measured: 4-bit on an 8 GB M1, and 8-bit about 3.5 times slower.
    static let initial = ["4bit": 6.0, "8bit": 20.0]

    static func factor(_ model: String = EngineSettings.model) -> Double {
        let saved = UserDefaults.standard.double(forKey: "renderSpeed." + model)
        return saved > 0 ? saved : initial[model] ?? 10
    }

    static func record(rendering seconds: Double, audio: Double, model: String = EngineSettings.model) {
        guard audio > 0.5, seconds > 0 else { return }
        let measured = seconds / audio
        UserDefaults.standard.set(factor(model) * 0.7 + measured * 0.3, forKey: "renderSpeed." + model)
    }
}

/// One line of an export: a render and where it sits in the script.
struct MixLine: Sendable {
    var audio: URL
    var text: String
    var voice: String
    var pauseAfter: Double
    var number: Int
}

struct MixRequest: Sendable {
    var lines: [MixLine]
    var folder: URL
    var name: String
    var options: ExportOptions
}

/// The engine's `mix` result: the files written, the mix first.
struct MixResult: Sendable {
    var files: [URL]
    var duration: Double
    /// Measured on the written mix.
    var lufs: Double?
}

/// One clip for `edit_clip`: a stretch of a render with its gain, fades (seconds after the tempo change) and voice tools.
struct ClipRequest: Sendable, Hashable {
    var audio: URL
    var start: Double
    var end: Double
    var gain = 0.0
    var fadeIn = 0.0, fadeOut = 0.0
    var effects = VoiceEffects()
}

extension ClipRequest {
    init(_ clip: EditClip, audio: URL) {
        self.init(audio: audio, start: clip.start, end: clip.end, gain: clip.gain, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, effects: clip.effects)
    }
}

/// What the app needs from the speech engine. Each call maps to one command in `engine/PROTOCOL.md`.
protocol Engine: Sendable {
    /// `transcribe`: Whisper transcript of a clip.
    func transcribe(_ audio: URL) async throws -> String
    /// `check_audio`: too quiet, clipped and noisy warnings for any audio or video file.
    func checkAudio(_ media: URL) async throws -> AudioCheck
    /// `split`: cuts audio or video into WAV clips at natural pauses, with their transcripts.
    func split(_ media: URL, minSeconds: Double, maxSeconds: Double, into folder: URL,
               progress: @escaping @Sendable (Double) -> Void) async throws -> [Clip]
    /// `group_speakers`: clips grouped by who speaks, largest group first, stray clips left out.
    func groupSpeakers(_ clips: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> [[URL]]
    /// `render` with one line. Returns the duration in seconds.
    func render(_ line: RenderLine, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Double
    /// `score`: the three line scores. `hints` are words Whisper should expect, such as respelled names.
    func score(_ render: URL, reference: URL, text: String, hints: [String]) async throws -> Scores
    /// `mix`: the export.
    func mix(_ request: MixRequest) async throws -> MixResult
    /// `edit_clip`: writes one timeline clip's audio. Runs while a render is busy. Returns the duration in seconds.
    func editClip(_ request: ClipRequest, to output: URL) async throws -> Double
}

enum EngineSettings {
    static let modelKey = "model"
    /// Breeze 4-bit until the user decides otherwise.
    static let defaultModel = "4bit"
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
    static let titles = ["8bit": "Best quality (8-bit)", "4bit": "Fast (4-bit)"]
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Where the engine runs from: its Python, the folder holding `vocalcord_engine`, and extra environment.
struct EngineLocation: Sendable {
    var python: URL
    var source: URL
    var environment: [String: String] = [:]

    /// A checkout's `engine/` folder with its own `.venv`.
    static func dev(_ folder: URL) -> EngineLocation {
        EngineLocation(python: folder.appending(path: ".venv/bin/python"), source: folder)
    }

    /// `VOCALCORD_ENGINE_DIR`, else `engine/` next to VocalCord.app if it has a `.venv`. Nil means the installed engine.
    static var dev: EngineLocation? {
        if let override = ProcessInfo.processInfo.environment["VOCALCORD_ENGINE_DIR"], !override.isEmpty {
            return .dev(URL(filePath: override, directoryHint: .isDirectory))
        }
        let checkout = EngineLocation.dev(Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "engine", directoryHint: .isDirectory))
        return FileManager.default.isExecutableFile(atPath: checkout.python.path) ? checkout : nil
    }
}

/// The Python worker, launched on first use and kept running: JSON lines over stdin/stdout.
/// Replies are matched to requests by id; a cancelled task cancels its job; a worker that dies fails every
/// waiting request and is started again on the next one.
actor EngineClient: Engine {
    nonisolated let location: EngineLocation
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: Pending] = [:]
    private var counter = 0
    /// The last stderr lines, for the error when the worker dies.
    private var log: [String] = []

    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let progress: (@Sendable (Reply) -> Void)?
    }

    struct Reply: Decodable, Sendable {
        var id: String?
        var event: String
        var code: String?
        var message: String?
        var stage: String?
        var done: Double?
        var total: Double?
    }

    init(location: EngineLocation) {
        self.location = location
    }

    /// `prepare`: downloads what `model` needs. Progress is bytes done of the bytes missing at the start.
    func prepare(model: String, progress: @escaping @Sendable (_ done: Double, _ total: Double) -> Void) async throws {
        struct Result: Decodable { var downloaded: Double }
        _ = try await call("prepare", ["model": model], as: Result.self) { reply in
            if let done = reply.done, let total = reply.total, total > 0 { progress(done, total) }
        }
    }

    // MARK: Engine

    func transcribe(_ audio: URL) async throws -> String {
        struct Result: Decodable { var text: String }
        return try await call("transcribe", ["audio": audio.path], as: Result.self).text
    }

    func checkAudio(_ media: URL) async throws -> AudioCheck {
        struct Result: Decodable { var duration: Double; var warnings: [String] }
        let result = try await call("check_audio", ["audio": media.path], as: Result.self)
        return AudioCheck(duration: result.duration, issues: result.warnings.compactMap(AudioIssue.init(rawValue:)))
    }

    func split(_ media: URL, minSeconds: Double, maxSeconds: Double, into folder: URL,
               progress: @escaping @Sendable (Double) -> Void) async throws -> [Clip] {
        struct Result: Decodable {
            struct Item: Decodable { var path: String; var duration: Double; var text: String }
            var clips: [Item]
        }
        let result = try await call("split", ["audio": media.path, "out_dir": folder.path, "min_s": minSeconds, "max_s": maxSeconds],
                                    as: Result.self) { reply in
            if let done = reply.done, let total = reply.total, total > 0 { progress(done / total) }
        }
        return result.clips.map { Clip(url: URL(filePath: $0.path), duration: $0.duration, transcript: $0.text) }
    }

    func groupSpeakers(_ clips: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> [[URL]] {
        struct Result: Decodable { var groups: [[String]] }
        let result = try await call("group_speakers", ["clips": clips.map(\.path)], as: Result.self) { reply in
            if let done = reply.done, let total = reply.total, total > 0 { progress(done / total) }
        }
        return result.groups.map { $0.map { URL(filePath: $0) } }
    }

    func render(_ line: RenderLine, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        struct Result: Decodable { var duration: Double }
        var item: [String: Any] = [
            "text": line.text, "tone": line.tone,
            "voice": ["audio": line.reference.path, "text": line.referenceText, "pronunciations": line.pronunciations],
        ]
        item["seed"] = line.seed
        let result = try await call("render", ["model": EngineSettings.model, "output": output.path, "lines": [item]],
                                    as: Result.self) { reply in
            if reply.stage == "load" { progress(0.1) }
            if let done = reply.done, let total = reply.total, total > 0 { progress(done / total) }
        }
        return result.duration
    }

    func score(_ render: URL, reference: URL, text: String, hints: [String]) async throws -> Scores {
        try await call("score", ["audio": render.path, "reference": reference.path, "text": text, "hints": hints], as: Scores.self)
    }

    func mix(_ request: MixRequest) async throws -> MixResult {
        struct Result: Decodable { var files: [String]; var duration: Double; var lufs: Double? }
        let options = request.options
        let lines: [[String: Any]] = request.lines.map {
            ["audio": $0.audio.path, "text": $0.text, "voice": $0.voice, "pause_after": $0.pauseAfter, "number": $0.number]
        }
        let result = try await call("mix", [
            "out_dir": request.folder.path, "name": request.name, "format": options.format, "lufs": options.lufs, "lines": lines,
            "per_line": options.perLine, "per_voice": options.perVoice, "srt": options.srt, "timing": options.timing,
        ], as: Result.self)
        return MixResult(files: result.files.map { URL(filePath: $0) }, duration: result.duration, lufs: result.lufs)
    }

    func editClip(_ request: ClipRequest, to output: URL) async throws -> Double {
        struct Result: Decodable { var duration: Double }
        let effects = request.effects
        return try await call("edit_clip", [
            "audio": request.audio.path, "out": output.path, "start": request.start, "end": request.end,
            "tempo": effects.tempo, "pitch": effects.pitch, "warmth": effects.warmth, "brightness": effects.brightness,
            "denoise": effects.denoise, "gain_db": request.gain, "fade_in": request.fadeIn, "fade_out": request.fadeOut,
        ], as: Result.self).duration
    }

    // MARK: Worker

    private func call<T: Decodable>(_ cmd: String, _ arguments: [String: Any], as type: T.Type,
                            progress: (@Sendable (Reply) -> Void)? = nil) async throws -> T {
        let data = try await send(cmd, arguments, progress: progress)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private func send(_ cmd: String, _ arguments: [String: Any], progress: (@Sendable (Reply) -> Void)?) async throws -> Data {
        try Task.checkCancellation()
        let input = try running()
        counter += 1
        let id = String(counter)
        var message = arguments
        message["id"] = id
        message["cmd"] = cmd
        let line = try JSONSerialization.data(withJSONObject: message) + Data("\n".utf8)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(continuation: continuation, progress: progress)
                do { try input.write(contentsOf: line) } catch {
                    pending.removeValue(forKey: id)?.continuation.resume(throwing: stopped)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Tells the worker to drop the job and returns at once; a render finishing its current line is ignored.
    private func cancel(_ id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        let message = #"{"id": "cancel-\#(id)", "cmd": "cancel", "target": "\#(id)"}"# + "\n"
        try? input?.write(contentsOf: Data(message.utf8))
        request.continuation.resume(throwing: CancellationError())
    }

    private func running() throws -> FileHandle {
        if let process, process.isRunning, let input { return input }
        guard FileManager.default.isExecutableFile(atPath: location.python.path) else {
            throw EngineError(message: "Engine not found at \(location.python.path).")
        }
        let process = Process()
        process.executableURL = location.python
        process.arguments = ["-m", "vocalcord_engine"]
        process.currentDirectoryURL = location.source
        process.environment = ProcessInfo.processInfo.environment.merging(location.environment) { $1 }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // A write to a worker that just died must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        log = []
        Task {
            for await line in Self.lines(stderr.fileHandleForReading) { logged(line) }
        }
        Task {
            for await line in Self.lines(stdout.fileHandleForReading) { receive(line) }
            ended(process)
        }
        return stdin.fileHandleForWriting
    }

    /// Lines from a pipe until it closes. FileHandle.bytes would block the actor's thread in read().
    static func lines(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = Mutex(Data())
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                buffer.withLock { buffer in
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        continuation.yield(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                        buffer.removeSubrange(buffer.startIndex...newline)
                    }
                }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                }
            }
        }
    }

    private func receive(_ line: String) {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: Data(line.utf8)), let id = reply.id,
              let request = pending[id] else { return }
        switch reply.event {
        case "progress":
            request.progress?(reply)
        case "result":
            pending[id] = nil
            request.continuation.resume(returning: Data(line.utf8))
        default:
            pending[id] = nil
            request.continuation.resume(throwing: reply.code == "cancelled"
                ? CancellationError() : EngineError(message: reply.message ?? "The engine failed."))
        }
    }

    private func logged(_ line: String) {
        FileHandle.standardError.write(Data("engine: \(line)\n".utf8))
        log = Array((log + [line]).suffix(20))
    }

    private var stopped: EngineError {
        let detail = log.last { !$0.contains(" INFO ") }.map { " \($0)" } ?? ""
        return EngineError(message: "The engine stopped. Try again.\(detail)")
    }

    /// stdout closed: the worker exited. Waiting requests fail; the next request starts a new worker.
    private func ended(_ process: Process) {
        guard process === self.process else { return }
        self.process = nil
        input = nil
        let waiting = pending.values
        pending = [:]
        for request in waiting { request.continuation.resume(throwing: stopped) }
    }
}

/// Real audio checks and splitting, made-up transcripts, renders and scores. For tests.
struct FakeEngine: Engine {
    var delay = Duration.milliseconds(500)
    var speakers = 1
    /// Scores to return instead of the made-up ones, such as a failing score for a test of the retry loop.
    var scores: (@Sendable (_ render: URL, _ text: String) -> Scores?)?

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
        // Cut at the quietest 100 ms block between min and max seconds, leaving at least 2 s after it. Smoothed with its
        // neighbours, like the engine's `quietest`, so the cut lands mid-pause and no clip starts or ends on a word.
        let quiet = { (index: Int) in energy[max(index - 1, 0)...min(index + 1, energy.count - 1)].reduce(0, +) }
        let longest = Int(maxSeconds * 10), shortest = Int(minSeconds * 10)
        var cuts = [0]
        while energy.count - cuts.last! > longest {
            let low = cuts.last! + shortest, high = min(cuts.last! + longest, energy.count - 20)
            guard low < high, let cut = (low..<high).min(by: { quiet($0) < quiet($1) }) else { break }
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

    /// One speaker, unless `speakers` splits the clips in turn between that many.
    func groupSpeakers(_ clips: [URL], progress: @escaping @Sendable (Double) -> Void) async throws -> [[URL]] {
        progress(1)
        return (0..<min(speakers, clips.count)).map { speaker in
            clips.enumerated().filter { $0.offset % speakers == speaker }.map(\.element)
        }
    }

    func render(_ line: RenderLine, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        for step in 1...4 {
            try await Task.sleep(for: delay / 4)
            progress(Double(step) / 4)
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: line.reference, to: output)
        return audioDuration(output)
    }

    func score(_ render: URL, reference: URL, text: String, hints: [String]) async throws -> Scores {
        try await Task.sleep(for: delay / 4)
        return scores?(render, text) ?? Scores(likeYou: 88 + pick(render) % 11, human: 3.5, words: 100, heard: text)
    }

    /// The first line's audio as the mix, never overwriting.
    func mix(_ request: MixRequest) async throws -> MixResult {
        try FileManager.default.createDirectory(at: request.folder, withIntermediateDirectories: true)
        let url = (1...).lazy.map { request.folder.appending(path: "\(request.name)\($0 == 1 ? "" : " \($0)").\(request.options.format)") }
            .first { !FileManager.default.fileExists(atPath: $0.path) }!
        try FileManager.default.copyItem(at: request.lines[0].audio, to: url)
        return MixResult(files: [url], duration: request.lines.reduce(0) { $0 + audioDuration($1.audio) + $1.pauseAfter }, lufs: Double(request.options.lufs))
    }

    /// The trim, gain and fades for real. Tempo only changes the length (samples are dropped or repeated, so the pitch
    /// moves too); the other voice tools need ffmpeg and are left out.
    func editClip(_ request: ClipRequest, to output: URL) async throws -> Double {
        let rate = 24000.0
        let samples = try await loadSamples(request.audio, rate: rate)
        let from = min(max(Int(request.start * rate), 0), samples.count), to = min(max(Int(request.end * rate), from), samples.count)
        let tempo = request.effects.tempo.clamped(VoiceEffects.tempos), count = Int(Double(to - from) / tempo)
        let gain = Float(pow(10, request.gain / 20)), length = Double(count) / rate
        let out = (0..<count).map { index in
            let time = Double(index) / rate
            let fadeIn = request.fadeIn > 0 ? min(1, time / request.fadeIn) : 1
            let fadeOut = request.fadeOut > 0 ? min(1, (length - time) / request.fadeOut) : 1
            return samples[min(from + Int(Double(index) * tempo), to - 1)] * gain * Float(fadeIn * fadeOut)
        }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeWAV(out[...], rate: rate, to: output)
        return length
    }
}

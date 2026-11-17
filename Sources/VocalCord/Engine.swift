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
    /// `render` with one line. Returns the duration in seconds.
    func render(_ line: RenderLine, to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Double
    /// `score`: the three line scores. `hints` are words Whisper should expect, such as respelled names.
    func score(_ render: URL, reference: URL, text: String, hints: [String]) async throws -> Scores
}

enum EngineSettings {
    static let modelKey = "model"
    /// Breeze 8-bit until the user decides otherwise.
    static let defaultModel = "8bit"
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The Python worker in `engine/`, launched on first use and kept running: JSON lines over stdin/stdout.
/// Replies are matched to requests by id; a cancelled task cancels its job; a worker that dies fails every
/// waiting request and is started again on the next one.
actor EngineClient: Engine {
    nonisolated let directory: URL
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

    init(directory: URL = EngineClient.defaultDirectory) {
        self.directory = directory
    }

    /// `VOCALCORD_ENGINE_DIR`, else `engine/` next to VocalCord.app.
    /// shortcut: needs the repo checkout; milestone 9 bundles the engine.
    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["VOCALCORD_ENGINE_DIR"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "engine", directoryHint: .isDirectory)
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
        let python = directory.appending(path: ".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EngineError(message: "Engine not found at \(directory.path).")
        }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "vocalcord_engine"]
        process.currentDirectoryURL = directory
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
    private static func lines(_ handle: FileHandle) -> AsyncStream<String> {
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
        return Scores(likeYou: 88 + pick(render) % 11, human: 3.5, words: 100, heard: text)
    }
}

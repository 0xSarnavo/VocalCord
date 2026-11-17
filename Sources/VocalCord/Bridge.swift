import Foundation
import Synchronization

/// The local socket the terminal agents' MCP bridge (`vocalcord-mcp`) connects to. A client must run as this
/// user and send the per-launch token as its first line; after that each line is a JSON-RPC message, and each
/// reply from `handle` is written back as a line as soon as it is ready, in any order.
final class BridgeServer: Sendable {
    let path: String
    private let source: DispatchSourceRead

    init(path: String, token: String, handle: @escaping @Sendable (Data) async -> Data?) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw AppError("The socket path is too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError("Couldn't open the agent socket. \(String(cString: strerror(errno)))") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw AppError("Couldn't open the agent socket at \(path). \(message)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.path = path
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            Thread.detachNewThread { Self.serve(client, token: Data(token.utf8), handle: handle) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        signal(SIGPIPE, SIG_IGN)
    }

    func stop() {
        source.cancel()
        unlink(path)
    }

    /// Reads one client's lines until it disconnects.
    private static func serve(_ fd: Int32, token: Data, handle: @escaping @Sendable (Data) async -> Data?) {
        // Cleared on disconnect, so a late reply never writes to a reused descriptor.
        let output = Output(fd)
        defer { output.fd.withLock { if let fd = $0 { close(fd) }; $0 = nil } }
        var peer = uid_t(), group = gid_t()
        guard getpeereid(fd, &peer, &group) == 0, peer == getuid() else { return }
        var buffer = Data(), authenticated = false
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard authenticated else {
                    guard sameBytes(line, token) else { return }
                    authenticated = true
                    continue
                }
                guard !line.isEmpty else { continue }
                Task {
                    guard let reply = await handle(line) else { return }
                    let data = reply + Data("\n".utf8)
                    output.fd.withLock { fd in
                        guard let fd else { return }
                        var sent = 0
                        while sent < data.count {
                            let written = data[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                            guard written > 0 else { return }
                            sent += written
                        }
                    }
                }
            }
            if !authenticated, buffer.count > 1024 { return }
        }
    }

    private final class Output: Sendable {
        let fd: Mutex<Int32?>
        init(_ fd: Int32) { self.fd = Mutex(fd) }
    }

    /// Constant-time comparison, so the token can't be guessed byte by byte.
    static func sameBytes(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Answers the agents' MCP JSON-RPC: the VocalCord tools, acting on the project open in Generate and the voice
/// selected in Clone.
@MainActor
final class ToolBridge {
    let projects: ProjectStore
    let voices: VoiceStore
    let jev: Jev
    /// The project open in Generate.
    let projectID: @MainActor () -> String?
    /// The voice selected in Clone.
    let voiceID: @MainActor () -> String?

    init(projects: ProjectStore, voices: VoiceStore, jev: Jev, projectID: @escaping @MainActor () -> String?,
         voiceID: @escaping @MainActor () -> String? = { nil }) {
        self.projects = projects
        self.voices = voices
        self.jev = jev
        self.projectID = projectID
        self.voiceID = voiceID
    }

    /// check_script is listed only while the Jev plugin is added. An agent session started before Jev was added sees
    /// it after a restart.
    var tools: [[String: Any]] { Self.scriptTools + (jev.added ? [Self.checkTool] : []) + Self.takeTools }

    static let scriptTools: [[String: Any]] = [
        tool("get_voices", "Every voice with its takes per tone and its pronunciations. A tone with no takes still renders, from a written direction."),
        tool("get_script", "The script of the project open in VocalCord: each line's number, text, voice, tone, pause after it in seconds, chosen version with scores and flags, and any pending change."),
        tool("update_script", "Propose changes to lines. Nothing is applied: each changed line waits in the script for the user to accept or reject it. Fields left out keep their pending or current value.",
             properties: ["changes": [
                 "type": "array",
                 "items": ["type": "object", "required": ["line"], "properties": [
                     "line": ["type": "integer", "description": "Line number, from 1"],
                     "text": ["type": "string"],
                     "tone": ["type": "string", "enum": Tone.all],
                     "pause": ["type": "number", "minimum": 0, "maximum": 10, "description": "Seconds of silence after the line"],
                 ]],
             ]], required: ["changes"]),
        tool("render_line", "Render one line with VocalCord's engine, then score it; can take a few minutes. A line with a pending change renders that change as a new version, chosen only once the user accepts it.",
             properties: lineProperty, required: ["line"]),
        tool("get_scores", "Every version of a line with its scores: like_you (speaker similarity, %), human (naturalness, 1 to 5), words (% of words right) and heard (what Whisper heard), plus flags for low scores.",
             properties: lineProperty, required: ["line"]),
    ]

    static let checkTool = tool("check_script", "Jev checks of each line: spoken (reads like something a person would say aloud), fits_tone (suits its tone) and, "
        + "after an agent rewrite, keeps_meaning (keeps the original's meaning). Each is yes, no or unsettled. A line with a pending "
        + "change is checked as proposed. Unchanged lines reuse their last result.")

    static let takeTools: [[String: Any]] = [
        tool("get_takes", "The takes of the voice selected in Clone: each take's number, tone, transcript, length in seconds, like_you "
             + "(its last audition score, %), whether it is its tone's main take, warnings and any pending change; plus the voice's "
             + "pronunciations and pending ones."),
        tool("propose_take_changes", "Propose transcript fixes, tone labels, main takes and pronunciations for the voice selected in Clone. "
             + "Nothing is applied: each change waits in the takes table for the user to accept or reject it. Fields left out keep their "
             + "pending or current value.",
             properties: [
                 "changes": [
                     "type": "array",
                     "items": ["type": "object", "required": ["take"], "properties": [
                         "take": ["type": "integer", "description": "Take number, from 1"],
                         "transcript": ["type": "string", "description": "The words spoken in the take, exactly"],
                         "tone": ["type": "string", "enum": Tone.all],
                         "main": ["type": "boolean", "enum": [true], "description": "Make this the main take of its tone"],
                     ]],
                 ],
                 "pronunciations": [
                     "type": "array",
                     "items": ["type": "object", "required": ["word", "say_as"], "properties": [
                         "word": ["type": "string"],
                         "say_as": ["type": "string", "description": "A respelling the voice says correctly, such as Koo-ber"],
                     ]],
                 ],
             ]),
        tool("audition", "Render a test line from up to 5 candidate takes per tone of the voice selected in Clone, score each, and propose "
             + "the best as its tone's main take; can take several minutes. Scores are saved; the main takes wait for the user to accept."),
    ]

    private static let lineProperty: [String: Any] = ["line": ["type": "integer", "description": "Line number, from 1"]]

    private static func tool(_ name: String, _ description: String, properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    /// One JSON-RPC message in; the reply, or nil for a notification.
    func handle(_ data: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return reply(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch message["method"] as? String {
        case "initialize":
            response["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                                  "capabilities": ["tools": [String: Any]()],
                                  "serverInfo": ["name": "vocalcord", "version": "1.0"]]
        case "ping":
            response["result"] = [String: Any]()
        case "tools/list":
            response["result"] = ["tools": tools]
        case "tools/call":
            let result = await call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            response["result"] = ["content": [["type": "text", "text": result.text]], "isError": result.isError]
        default:
            response["error"] = ["code": -32601, "message": "Method not found"]
        }
        return reply(response)
    }

    private func reply(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object) }

    func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, isError: Bool) {
        do {
            switch name {
            case "get_voices": return (try json(voiceList()), false)
            case "get_script": return (try json(script(currentProject())), false)
            case "update_script": return (try json(propose(arguments, in: currentProject())), false)
            case "render_line": return (try json(await render(arguments, in: currentProject())), false)
            case "get_scores": return (try json(scores(arguments, in: currentProject())), false)
            case "check_script":
                guard jev.added else { return ("Jev plugin not added", false) }
                return (try json(await check(currentProject())), false)
            case "get_takes": return (try json(takes(currentVoice())), false)
            case "propose_take_changes": return (try json(proposeTakes(arguments, for: currentVoice())), false)
            case "audition": return (try json(await audition(currentVoice())), false)
            default: throw AppError("Unknown tool \(name).")
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }

    // MARK: Tools

    private struct VoiceInfo: Encodable {
        var name: String
        var takesPerTone: [String: Int]
        var pronunciations: [String: String]
    }

    private struct LineInfo: Encodable {
        var line: Int
        var text: String
        var voice: String
        var tone: String
        var pause: Double
        var chosenVersion: VersionInfo?
        var pendingChange: Proposal?
    }

    private struct VersionInfo: Encodable {
        var version: Int
        var of: Int
        var text: String
        var tone: String
        var chosen: Bool
        var seconds: Double
        var scores: Scores?
        var flags: [String]
    }

    private struct ScriptInfo: Encodable {
        var project: String
        var tones: [String]
        var lines: [LineInfo]
    }

    private struct ProposeResult: Encodable {
        var proposed: [Int] = []
        var unchanged: [Int] = []
        var errors: [String] = []
        var note = "The user accepts or rejects each proposed line in the script."
    }

    private struct ScoresResult: Encodable {
        var line: Int
        var versions: [VersionInfo]
    }

    private struct CheckInfo: Encodable {
        var line: Int
        /// pass, fail, unsettled or error.
        var result: String
        var pendingChange: Bool?
        var spoken: Verdict?
        var fitsTone: Verdict?
        var keepsMeaning: Verdict?
        var notes: [String]?
        var error: String?
    }

    private struct TakeInfo: Encodable {
        var take: Int
        var tone: String
        var transcript: String
        var seconds: Double
        var likeYou: Int?
        var main: Bool
        var warnings: [String]
        var pendingChange: TakeProposal?
    }

    private struct TakesInfo: Encodable {
        var voice: String
        var tones: [String]
        var takes: [TakeInfo]
        var pronunciations: [String: String]
        var pendingPronunciations: [String: String]
    }

    private struct TakeChangesResult: Encodable {
        var proposed: [Int] = []
        var unchanged: [Int] = []
        var pronunciationsProposed: [String] = []
        var pronunciationsUnchanged: [String] = []
        var errors: [String] = []
        var note = "The user accepts or rejects each change in the takes table and the pronunciations list."
    }

    private struct AuditionResult: Encodable {
        struct Best: Encodable {
            var tone: String
            var take: Int
            var likeYou: Int?
        }
        var best: [Best]
        var proposed: [Int]
        var note = "Each tone's best take waits in the takes table as a proposed main take for the user to accept or reject."
    }

    private func currentVoice() throws -> Voice {
        guard let voice = voices.voice(voiceID()) else { throw AppError("Select a voice in Clone first.") }
        return voice
    }

    private func currentProject() throws -> Project {
        guard let project = projects.project(projectID()) else { throw AppError("Open a project in Generate first.") }
        return project
    }

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func voiceList() -> [VoiceInfo] {
        voices.voices.map { voice in
            VoiceInfo(name: voice.name,
                      takesPerTone: Dictionary(grouping: voice.takes, by: \.tone).mapValues(\.count),
                      pronunciations: voice.pronunciationMap)
        }
    }

    private func versionInfo(_ version: Version, in line: Line) -> VersionInfo {
        var flags = [version.likeYouFlag, version.humanFlag, version.wordsFlag].compactMap(\.self)
        if version.scores != nil, !version.likeYouJudged { flags.append("Like you not judged: under \(Int(Version.likeYouMinSeconds)) s") }
        return VersionInfo(version: (line.versions.firstIndex(of: version) ?? 0) + 1, of: line.versions.count, text: version.text,
                           tone: version.tone, chosen: line.chosen == version.id, seconds: (version.duration * 100).rounded() / 100,
                           scores: version.scores, flags: flags)
    }

    private func script(_ project: Project) -> ScriptInfo {
        ScriptInfo(project: project.name, tones: Tone.all, lines: project.lines.enumerated().map { index, line in
            LineInfo(line: index + 1, text: line.text, voice: voices.voice(line.voiceID)?.name ?? "None", tone: line.tone,
                     pause: line.pauseAfter, chosenVersion: line.chosenVersion.map { versionInfo($0, in: line) },
                     pendingChange: line.proposal)
        })
    }

    private func line(_ arguments: [String: Any], in project: Project) throws -> (number: Int, line: Line) {
        guard let number = (arguments["line"] as? NSNumber)?.intValue, project.lines.indices.contains(number - 1) else {
            throw AppError(project.lines.isEmpty ? "The script has no lines." : "line must be from 1 to \(project.lines.count).")
        }
        return (number, project.lines[number - 1])
    }

    private func propose(_ arguments: [String: Any], in project: Project) throws -> ProposeResult {
        guard let changes = arguments["changes"] as? [[String: Any]], !changes.isEmpty else {
            throw AppError("changes must be a list of {line, text, tone, pause}.")
        }
        var result = ProposeResult()
        for change in changes {
            guard let (number, line) = try? line(change, in: project) else {
                result.errors.append("No line \(change["line"].map { "\($0)" } ?? "given").")
                continue
            }
            var proposal = line.proposal ?? Proposal(line)
            if let value = change["text"] {
                guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    result.errors.append("Line \(number): text can't be empty.")
                    continue
                }
                proposal.text = text
            }
            if let value = change["tone"] {
                guard let tone = Tone.all.first(where: { $0.caseInsensitiveCompare(value as? String ?? "") == .orderedSame }) else {
                    result.errors.append("Line \(number): tone must be one of \(Tone.all.joined(separator: ", ")).")
                    continue
                }
                proposal.tone = tone
            }
            if let value = change["pause"] {
                guard let pause = (value as? NSNumber)?.doubleValue, (0...10).contains(pause) else {
                    result.errors.append("Line \(number): pause must be 0 to 10 seconds.")
                    continue
                }
                proposal.pauseAfter = pause
            }
            if projects.propose(proposal, line: line.id, in: project.id) { result.proposed.append(number) } else { result.unchanged.append(number) }
        }
        return result
    }

    private func render(_ arguments: [String: Any], in project: Project) async throws -> VersionInfo {
        let (number, line) = try line(arguments, in: project)
        guard projects.progress == nil, voices.auditioning == nil, let task = projects.renderLine(line.id, in: project.id, voices: voices) else {
            throw AppError("A render or audition is running. Try again when it finishes.")
        }
        do { try await task.value } catch is CancellationError { throw AppError("The render was cancelled.") }
        guard let updated = projects.project(project.id)?.lines.first(where: { $0.id == line.id }), let version = updated.versions.last else {
            throw AppError("Line \(number) is gone.")
        }
        return versionInfo(version, in: updated)
    }

    /// Runs Jev on every line with text; empty lines are left out.
    private func check(_ project: Project) async throws -> [CheckInfo] {
        let subjects = project.lines.map(JevSubject.init)
        await jev.check(subjects)
        let lines = zip(project.lines, subjects).enumerated().compactMap { index, pair -> CheckInfo? in
            let (line, subject) = pair
            guard !subject.text.isEmpty else { return nil }
            var info = CheckInfo(line: index + 1, result: "error", pendingChange: line.proposal == nil ? nil : true)
            if let result = jev.results[subject] {
                info.result = switch result.status { case .yes: "pass"; case .no: "fail"; case .unsettled: "unsettled" }
                let verdicts = result.answers.mapValues(JevQuestions.verdict)
                info.spoken = verdicts[.spoken]
                info.fitsTone = verdicts[.fitsTone]
                info.keepsMeaning = verdicts[.keepsMeaning]
                info.notes = result.status == .yes ? nil : result.notes(tone: subject.tone)
            } else {
                info.error = jev.failures[subject] ?? "Not checked."
            }
            return info
        }
        if !lines.isEmpty, lines.allSatisfy({ $0.error != nil }) { throw AppError("Jev check failed. \(lines[0].error ?? "")") }
        return lines
    }

    private func scores(_ arguments: [String: Any], in project: Project) throws -> ScoresResult {
        let (number, line) = try line(arguments, in: project)
        return ScoresResult(line: number, versions: line.versions.map { versionInfo($0, in: line) })
    }

    // MARK: Takes

    private func percent(_ score: Double?) -> Int? { score.map { Int(($0 * 100).rounded()) } }

    private func takes(_ voice: Voice) -> TakesInfo {
        TakesInfo(voice: voice.name, tones: Tone.all, takes: voice.takes.enumerated().map { index, take in
            TakeInfo(take: index + 1, tone: take.tone, transcript: take.transcript, seconds: (take.duration * 100).rounded() / 100,
                     likeYou: percent(take.score), main: voice.mainTake(take.tone)?.id == take.id,
                     warnings: take.issues.map(\.label) + (take.duration < 3 ? ["Too short"] : take.duration > 20 ? ["Too long"] : []),
                     pendingChange: take.proposal)
        }, pronunciations: voice.pronunciationMap,
           pendingPronunciations: Dictionary((voice.proposedPronunciations ?? []).map { ($0.word, $0.respelling) }) { first, _ in first })
    }

    private func proposeTakes(_ arguments: [String: Any], for voice: Voice) throws -> TakeChangesResult {
        let changes = arguments["changes"] as? [[String: Any]] ?? []
        let words = arguments["pronunciations"] as? [[String: Any]] ?? []
        guard !changes.isEmpty || !words.isEmpty else {
            throw AppError("Give changes as a list of {take, transcript, tone, main}, pronunciations as a list of {word, say_as}, or both.")
        }
        var result = TakeChangesResult()
        for change in changes {
            guard let number = (change["take"] as? NSNumber)?.intValue, voice.takes.indices.contains(number - 1) else {
                result.errors.append("No take \(change["take"].map { "\($0)" } ?? "given").")
                continue
            }
            var proposal = TakeProposal()
            if let value = change["transcript"] {
                guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    result.errors.append("Take \(number): transcript can't be empty.")
                    continue
                }
                proposal.transcript = text
            }
            if let value = change["tone"] {
                guard let tone = Tone.all.first(where: { $0.caseInsensitiveCompare(value as? String ?? "") == .orderedSame }) else {
                    result.errors.append("Take \(number): tone must be one of \(Tone.all.joined(separator: ", ")).")
                    continue
                }
                proposal.tone = tone
            }
            if let value = change["main"] {
                guard value as? Bool == true else {
                    result.errors.append("Take \(number): main can only be true.")
                    continue
                }
                proposal.main = true
            }
            if voices.propose(proposal, take: voice.takes[number - 1].id, voiceID: voice.id) {
                result.proposed.append(number)
            } else {
                result.unchanged.append(number)
            }
        }
        for item in words {
            guard let word = (item["word"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty,
                  let respelling = (item["say_as"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !respelling.isEmpty else {
                result.errors.append("Each pronunciation needs a word and say_as.")
                continue
            }
            if voices.proposePronunciation(word: word, respelling: respelling, voiceID: voice.id) {
                result.pronunciationsProposed.append(word)
            } else {
                result.pronunciationsUnchanged.append(word)
            }
        }
        return result
    }

    private func audition(_ voice: Voice) async throws -> AuditionResult {
        guard !voice.takes.isEmpty else { throw AppError("\u{201C}\(voice.name)\u{201D} has no takes. Add one in Clone.") }
        guard voices.auditioning == nil, projects.progress == nil else {
            throw AppError("A render or audition is running. Try again when it finishes.")
        }
        let best: [String: String]
        do { best = try await voices.audition(voice.id, proposing: true) { _ in } } catch is CancellationError {
            throw AppError("The audition was cancelled.")
        }
        guard let updated = voices.voice(voice.id) else { throw AppError("\u{201C}\(voice.name)\u{201D} is gone.") }
        let rows = Tone.all.compactMap { tone -> AuditionResult.Best? in
            guard let id = best[tone], let index = updated.takes.firstIndex(where: { $0.id == id }) else { return nil }
            return AuditionResult.Best(tone: tone, take: index + 1, likeYou: percent(updated.takes[index].score))
        }
        return AuditionResult(best: rows, proposed: rows.map(\.take).filter { updated.takes[$0 - 1].proposal?.main == true })
    }
}

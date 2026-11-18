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
    var tools: [[String: Any]] { Self.scriptTools + (jev.added ? [Self.checkTool] : []) + Self.timelineTools + Self.takeTools }

    static let scriptTools: [[String: Any]] = [
        tool("get_voices", "Every voice with its takes per tone and its pronunciations. A tone with no takes still renders, from a written direction."),
        tool("get_script", "The script of the project open in VocalCord: each line's number, text with any tags, voice, tone, pause after it in seconds, chosen version with scores and flags, and any pending change. A pending new line has no text until the user accepts it."),
        tool("update_script", "Propose changes to lines. Nothing is applied: each changed line waits in the script for the user to accept or reject it. Fields left out keep their pending or current value. "
             + "Text can direct delivery with tags: [pause 0.5], [breath], [speed 80%]…[/speed], [stress]…[/stress] and [say Koo-ber]Kuber[/say]; "
             + "any other [label] is a tone direction. A line whose tags have problems isn't proposed: its problems come back in errors, to fix and send again.",
             properties: ["changes": [
                 "type": "array",
                 "items": ["type": "object", "required": ["line"], "properties": [
                     "line": ["type": "integer", "description": "Line number, from 1"],
                     "text": ["type": "string", "description": "The whole line, with any tags"],
                     "tone": ["type": "string", "enum": Tone.all],
                     "pause": ["type": "number", "minimum": 0, "maximum": 10, "description": "Seconds of silence after the line"],
                 ]],
             ]], required: ["changes"]),
        tool("add_lines", "Propose new lines, such as a whole script for an empty project. Nothing is applied: each new line waits in the script for the user to accept or reject it, and a rejected one is removed. "
             + "Text takes the same tags as update_script; a line whose tags have problems isn't added: its problems come back in errors.",
             properties: [
                 "after": ["type": "integer", "minimum": 0, "description": "Add after this line number; 0 for the top. Left out: at the end."],
                 "lines": [
                     "type": "array",
                     "items": ["type": "object", "required": ["text"], "properties": [
                         "text": ["type": "string", "description": "The whole line, with any tags"],
                         "voice": ["type": "string", "description": "A voice name from get_voices. Left out: the last line's voice"],
                         "tone": ["type": "string", "enum": Tone.all],
                         "pause": ["type": "number", "minimum": 0, "maximum": 10, "description": "Seconds of silence after the line"],
                     ]],
                 ],
             ], required: ["lines"]),
        tool("render_line", "Render one line with VocalCord's engine, then score it; can take a few minutes. A line with a pending change renders that change as a new version, chosen only once the user accepts it.",
             properties: lineProperty, required: ["line"]),
        tool("get_scores", "Every version of a line with its scores: like_you (speaker similarity, %), human (naturalness, 1 to 5), words (% of words right) and heard (what Whisper heard), plus flags for low scores and for pitch, pace or gaps that drift from the take.",
             properties: lineProperty, required: ["line"]),
        tool("get_pacing", "How each line of the open project is paced, from its chosen render: its text with tags and plain, each word "
             + "with its start and end in seconds, words_per_minute against target (target_from: project when set_pace_target set one, "
             + "else take, the speaker's pace in the take), a verdict, rushed and dragging stretches, gaps over 1.2 s the script didn't "
             + "ask for, and any tag problems. Word numbers count the words without tags, from 1. Times come from Whisper and are about "
             + "0.1 s either way; matched is the share of words Whisper heard (0 to 1), so trust the times less when it's low. Pauses "
             + "and breaths in the text don't count as speaking time. A line with no render or no times yet says so in note."),
        tool("set_pace_target", "Set the words a minute get_pacing judges the open project against, 80 to 260; null or left out goes "
             + "back to each line's take. It's a project setting, not script content, so it changes at once, with no proposal.",
             properties: ["words_per_minute": ["type": "number", "minimum": Project.paceTargets.lowerBound,
                                               "maximum": Project.paceTargets.upperBound,
                                               "description": "About 150 is a normal pace. Null or left out: each line's take"]]),
    ]

    static let checkTool = tool("check_script", "Jev checks of each line: spoken (reads like something a person would say aloud), fits_tone (suits its tone) and, "
        + "after an agent rewrite, keeps_meaning (keeps the original's meaning). Each is yes, no or unsettled. A line with a pending "
        + "change is checked as proposed. Unchanged lines reuse their last result.")

    static let timelineTools: [[String: Any]] = [
        tool("get_timeline", "The Timeline tab's track for the open project, in seconds: each clip's number, its script line and "
             + "the render's words, its start and duration on the timeline, the part of its render it plays (render_start to render_end), the "
             + "gap after it, volume, fades and voice tools, and whether a newer render of its line waits to be swapped in; plus rendered "
             + "lines not on the timeline and the changes of any pending proposal."),
        tool("propose_timeline_edits", "Propose edits to the timeline. Nothing is applied: the edits wait in the Timeline tab for the user "
             + "to accept or reject together, and each call replaces any earlier proposal, so send every edit in one call. Clip numbers are "
             + "get_timeline's from before the call, even after a split, move or delete in it; a split's second half gets a number in the "
             + "next get_timeline. An edit that fails is skipped and the rest still apply.",
             properties: ["edits": [
                 "type": "array", "minItems": 1,
                 "items": ["type": "object", "required": ["op"], "properties": [
                     "op": ["type": "string", "enum": ["split", "trim", "delete", "move", "gap", "volume", "fade", "voice", "swap_in", "add_line"],
                            "description": "split {clip, at}, trim {clip, start, end}, delete {clip}, move {clip, to}, gap {clip, seconds}, "
                                + "volume {clip, db}, fade {clip, in, out}, voice {clip, speed, pitch, warmth, brightness, denoise}: the "
                                + "fields of trim, fade and voice left out keep their value. swap_in {line}: the line's chosen render, "
                                + "whole, in place of its clips. add_line {line}: a rendered line that isn't on the timeline."],
                     "clip": ["type": "integer", "minimum": 1, "description": "Clip number from get_timeline"],
                     "line": ["type": "integer", "minimum": 1, "description": "Script line number"],
                     "at": ["type": "number", "minimum": 0, "description": "Seconds into the clip on the timeline"],
                     "start": ["type": "number", "minimum": 0, "description": "Seconds into the render where the clip starts"],
                     "end": ["type": "number", "minimum": 0, "description": "Seconds into the render where the clip ends"],
                     "to": ["type": "integer", "minimum": 1, "description": "The clip number whose place it takes: it goes before that "
                            + "clip when moving earlier, after it when moving later"],
                     "seconds": ["type": "number", "minimum": 0, "maximum": Edit.longest, "description": "Silence after the clip"],
                     "db": ["type": "number", "minimum": Edit.gains.lowerBound, "maximum": Edit.gains.upperBound,
                            "description": "Volume against the render; 0 is as rendered"],
                     "in": ["type": "number", "minimum": 0, "maximum": Edit.longest, "description": "Fade-in seconds"],
                     "out": ["type": "number", "minimum": 0, "maximum": Edit.longest, "description": "Fade-out seconds"],
                     "speed": ["type": "number", "minimum": VoiceEffects.tempos.lowerBound, "maximum": VoiceEffects.tempos.upperBound,
                               "description": "1 is as rendered; pitch stays"],
                     "pitch": ["type": "number", "minimum": VoiceEffects.semitones.lowerBound, "maximum": VoiceEffects.semitones.upperBound,
                               "description": "Semitones; 0 is as rendered"],
                     "warmth": ["type": "number", "minimum": VoiceEffects.shelves.lowerBound, "maximum": VoiceEffects.shelves.upperBound,
                                "description": "dB of low end; 0 is as rendered"],
                     "brightness": ["type": "number", "minimum": VoiceEffects.shelves.lowerBound, "maximum": VoiceEffects.shelves.upperBound,
                                    "description": "dB of high end; 0 is as rendered"],
                     "denoise": ["type": "boolean", "description": "Remove background noise"],
                 ]],
             ]], required: ["edits"]),
    ]

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
            case "add_lines": return (try json(add(arguments, in: currentProject())), false)
            case "render_line": return (try json(await render(arguments, in: currentProject())), false)
            case "get_scores": return (try json(scores(arguments, in: currentProject())), false)
            case "get_pacing": return (try json(pacing(currentProject())), false)
            case "set_pace_target": return (try json(setPaceTarget(arguments, in: currentProject())), false)
            case "check_script":
                guard jev.added else { return ("Jev plugin not added", false) }
                return (try json(await check(currentProject())), false)
            case "get_timeline": return (try json(timeline(currentProject())), false)
            case "propose_timeline_edits": return (try json(proposeEdits(arguments, in: currentProject())), false)
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
        var pendingNewLine: Bool?
        /// Script rule warnings for the pending text if any, else the line's own.
        var warnings: [String]?
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
        var warnings: [String] = []
        var note = "The user accepts or rejects each proposed line in the script."
    }

    private struct AddResult: Encodable {
        var proposed: [Int] = []
        var errors: [String] = []
        var warnings: [String] = []
        var note = "The user accepts or rejects each new line in the script; a rejected one is removed."
    }

    private struct ScoresResult: Encodable {
        var line: Int
        var versions: [VersionInfo]
    }

    private struct PacingInfo: Encodable {
        var project: String
        var paceTarget: Double?
        var lines: [PacingLine]
    }

    /// Word numbers are 1-based display words of the chosen render's text.
    private struct PacingLine: Encodable {
        struct Word: Encodable {
            var word: String
            var start: Double
            var end: Double
        }
        struct Stretch: Encodable {
            var fromWord: Int
            var toWord: Int
            var text: String
        }
        struct Gap: Encodable {
            var afterWord: Int
            var seconds: Double
        }
        var line: Int
        var text: String
        var plain: String
        var timed = false
        var words: [Word]?
        var wordsPerMinute: Int?
        var target: Int?
        /// project or take.
        var targetFrom: String?
        var verdict: String?
        var rushed: [Stretch]?
        var dragging: [Stretch]?
        var gaps: [Gap]?
        var matched: Double?
        var problems: [String]
        var note: String?
    }

    private struct PaceTargetResult: Encodable {
        var paceTarget: Double?
        var note: String
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

    private struct ClipInfo: Encodable {
        var clip: Int
        /// Left out if the line has left the script.
        var line: Int?
        var text: String
        var start: Double
        var duration: Double
        var renderStart: Double
        var renderEnd: Double
        var renderDuration: Double
        var gapAfter: Double
        var volumeDb: Double
        var fadeIn: Double
        var fadeOut: Double
        var speed: Double
        var pitch: Double
        var warmth: Double
        var brightness: Double
        var denoise: Bool
        var newRenderWaiting: Bool
    }

    private struct TimelineInfo: Encodable {
        struct Pending: Encodable { var changes: [String] }
        var project: String
        var clips: [ClipInfo]
        var duration: Double
        var linesNotOnTimeline: [Int]
        var pendingProposal: Pending?
    }

    private struct EditsResult: Encodable {
        var proposed = 0
        var errors: [String] = []
        var changes: [String] = []
        var note = "Nothing is applied: the user accepts or rejects these changes in the Timeline tab."
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
        var flags = version.flags
        if version.scores != nil, !version.likeYouJudged { flags.append("Like you not judged: under \(Int(Version.likeYouMinSeconds)) s") }
        // Raw renders are hidden sources: never counted or listed.
        let versions = line.visibleVersions
        return VersionInfo(version: (versions.firstIndex(of: version) ?? 0) + 1, of: versions.count, text: version.text,
                           tone: version.tone, chosen: line.chosen == version.id, seconds: (version.duration * 100).rounded() / 100,
                           scores: version.scores, flags: flags)
    }

    private func script(_ project: Project) -> ScriptInfo {
        ScriptInfo(project: project.name, tones: Tone.all, lines: project.lines.enumerated().map { index, line in
            LineInfo(line: index + 1, text: line.text, voice: voices.voice(line.voiceID)?.name ?? "None", tone: line.tone,
                     pause: line.pauseAfter, chosenVersion: line.chosenVersion.map { versionInfo($0, in: line) },
                     pendingChange: line.proposal, pendingNewLine: line.added,
                     warnings: Optional(Script.warnings(line.proposal?.text ?? line.text)).flatMap { $0.isEmpty ? nil : $0 })
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
                if let problem = Self.tagProblems(text) {
                    result.errors.append("Line \(number) not proposed: \(problem)")
                    continue
                }
                proposal.text = text
            }
            if let value = change["tone"] {
                guard let tone = Self.tone(value) else {
                    result.errors.append("Line \(number): tone must be one of \(Tone.all.joined(separator: ", ")).")
                    continue
                }
                proposal.tone = tone
            }
            if let value = change["pause"] {
                guard let pause = Self.pause(value) else {
                    result.errors.append("Line \(number): pause must be 0 to 10 seconds.")
                    continue
                }
                proposal.pauseAfter = pause
            }
            if projects.propose(proposal, line: line.id, in: project.id) { result.proposed.append(number) } else { result.unchanged.append(number) }
            result.warnings += Script.warnings(proposal.text).map { "Line \(number): \($0)" }
        }
        return result
    }

    /// The tags' problems as one message for the agent to fix, or nil when every tag can be read.
    private static func tagProblems(_ text: String) -> String? {
        let problems = Marks.parse(text).problems
        return problems.isEmpty ? nil : problems.joined(separator: " ") + " Fix the tags and send it again."
    }

    private static func tone(_ value: Any) -> String? {
        Tone.all.first { $0.caseInsensitiveCompare(value as? String ?? "") == .orderedSame }
    }

    private static func pause(_ value: Any) -> Double? {
        (value as? NSNumber).map(\.doubleValue).flatMap { (0...10).contains($0) ? $0 : nil }
    }

    /// New lines go in as pending; ones with errors are left out and the rest are added in order.
    private func add(_ arguments: [String: Any], in project: Project) throws -> AddResult {
        guard let items = arguments["lines"] as? [[String: Any]], !items.isEmpty else {
            throw AppError("lines must be a list of {text, voice, tone, pause}.")
        }
        var after = project.lines.count
        if let value = arguments["after"] {
            guard let number = (value as? NSNumber)?.intValue, (0...project.lines.count).contains(number) else {
                throw AppError("after must be from 0 to \(project.lines.count).")
            }
            after = number
        }
        let lastVoice = projects.defaultVoice(project.id, voices: voices)
        var result = AddResult()
        var lines: [(proposal: Proposal, voiceID: String)] = []
        for (index, item) in items.enumerated() {
            let label = "New line \(index + 1)"
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                result.errors.append("\(label): text can't be empty.")
                continue
            }
            if let problem = Self.tagProblems(text) {
                result.errors.append("\(label) not added: \(problem)")
                continue
            }
            var voiceID = lastVoice
            if let value = item["voice"] {
                guard let voice = voices.voices.first(where: { $0.name.caseInsensitiveCompare(value as? String ?? "") == .orderedSame }) else {
                    result.errors.append("\(label): voice must be one of \(voices.voices.map(\.name).joined(separator: ", ")).")
                    continue
                }
                voiceID = voice.id
            }
            var proposal = Proposal(text: text, tone: "Neutral", pauseAfter: 0.5)
            if let value = item["tone"] {
                guard let tone = Self.tone(value) else {
                    result.errors.append("\(label): tone must be one of \(Tone.all.joined(separator: ", ")).")
                    continue
                }
                proposal.tone = tone
            }
            if let value = item["pause"] {
                guard let pause = Self.pause(value) else {
                    result.errors.append("\(label): pause must be 0 to 10 seconds.")
                    continue
                }
                proposal.pauseAfter = pause
            }
            lines.append((proposal, voiceID))
        }
        projects.proposeLines(lines, at: after, in: project.id)
        result.proposed = lines.indices.map { after + $0 + 1 }
        for (index, line) in lines.enumerated() {
            result.warnings += Script.warnings(line.proposal.text).map { "Line \(after + index + 1): \($0)" }
        }
        return result
    }

    private func render(_ arguments: [String: Any], in project: Project) async throws -> VersionInfo {
        let (number, line) = try line(arguments, in: project)
        guard projects.progress == nil, voices.busy == nil, let task = projects.renderLine(line.id, in: project.id, voices: voices) else {
            throw AppError("A render or audition is running. Try again when it finishes.")
        }
        do { try await task.value } catch is CancellationError { throw AppError("The render was cancelled.") }
        guard let updated = projects.project(project.id)?.lines.first(where: { $0.id == line.id }), let version = updated.visibleVersions.last else {
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
        return ScoresResult(line: number, versions: line.visibleVersions.map { versionInfo($0, in: line) })
    }

    // MARK: Pace

    /// Each line's pace from its chosen version's word times. Lines whose chosen version isn't timed yet are timed in
    /// the background, for the next call.
    private func pacing(_ project: Project) -> PacingInfo {
        var untimed = false
        let lines = project.lines.enumerated().map { index, line -> PacingLine in
            var info = PacingLine(line: index + 1, text: line.text, plain: Marks.plain(line.text), problems: Marks.parse(line.text).problems)
            guard let version = line.chosenVersion else {
                info.note = line.added == true ? "A pending new line: nothing to time until the user accepts it and it's rendered."
                    : line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No text." : "Not rendered yet."
                return info
            }
            guard let times = projects.displayTimes(version) else {
                untimed = true
                info.note = "Its words aren't timed yet. VocalCord times them in the background, after any render; try again in a minute."
                return info
            }
            let tokens = Marks.parse(version.text).tokens
            func stretch(_ range: ClosedRange<Int>) -> PacingLine.Stretch {
                .init(fromWord: range.lowerBound + 1, toWord: range.upperBound + 1, text: tokens[range].map(\.text).joined(separator: " "))
            }
            info.timed = true
            info.words = zip(tokens, times).map { .init(word: $0.text, start: Self.rounded($1.start), end: Self.rounded($1.end)) }
            info.matched = version.matched.map(Self.rounded)
            var notes: [String] = []
            if version.text != line.text {
                notes.append("Timed from the chosen render, made before the text changed: \u{201C}\(Marks.plain(version.text))\u{201D}. "
                    + "Word numbers are its words.")
            }
            if let report = projects.paceReport(line: line.id, in: project.id) {
                info.wordsPerMinute = Int(report.wordsPerMinute.rounded())
                info.target = Int(report.target.rounded())
                info.targetFrom = project.paceTarget.map { $0.isFinite && $0 > 0 } == true ? "project" : "take"
                info.verdict = report.verdict ?? "On pace."
                info.rushed = report.rushed.map(stretch)
                info.dragging = report.dragging.map(stretch)
                info.gaps = report.gaps.map { .init(afterWord: $0.after + 1, seconds: Self.rounded($0.seconds)) }
            } else if tokens.count < 4 {
                notes.append("Under 4 words: too short to judge its pace.")
            } else if Pace.target(projectOverride: project.paceTarget, referencePace: version.scores?.referencePace) == nil {
                notes.append("No pace target: its take's pace isn't known. Set one with set_pace_target.")
            } else {
                notes.append("Its pace can't be judged from these times.")
            }
            info.note = notes.isEmpty ? nil : notes.joined(separator: " ")
            return info
        }
        if untimed { projects.timeWordsIfNeeded(project.id, voices: voices) }
        return PacingInfo(project: project.name, paceTarget: project.paceTarget, lines: lines)
    }

    /// A project setting, so it changes at once rather than waiting as a proposal.
    private func setPaceTarget(_ arguments: [String: Any], in project: Project) throws -> PaceTargetResult {
        let value = arguments["words_per_minute"]
        guard let value, !(value is NSNull) else {
            projects.setPaceTarget(nil, in: project.id)
            return PaceTargetResult(note: "Cleared: get_pacing judges each line against the pace of its take.")
        }
        let range = Project.paceTargets
        guard !(value is Bool), let number = (value as? NSNumber)?.doubleValue, number.isFinite, range.contains(number) else {
            throw AppError("words_per_minute must be a number from \(Self.plain(range.lowerBound)) to \(Self.plain(range.upperBound)), or null.")
        }
        projects.setPaceTarget(number, in: project.id)
        let target = projects.project(project.id)?.paceTarget ?? number
        return PaceTargetResult(paceTarget: target, note: "Set: get_pacing judges every line against \(Self.plain(target)) words a minute.")
    }

    // MARK: Timeline

    /// Seconds and dB to 2 decimals, without a negative zero.
    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 + 0 }

    /// The same for the user: 1.4, not 1.40.
    private static func plain(_ value: Double) -> String { String(format: "%g", rounded(value)) }

    /// The project's timeline, opened first so its clips keep the same IDs, and so numbers, between calls.
    private func openTimeline(_ project: Project) throws -> (project: Project, edit: Edit) {
        guard project.edit?.clips.isEmpty == false || project.lines.contains(where: { $0.chosenVersion != nil }) else {
            throw AppError("This project has no renders yet. Render its lines first: the timeline is made from them.")
        }
        projects.startEdit(project.id)
        guard let project = projects.project(project.id), let edit = project.edit else { throw AppError("This project no longer exists.") }
        return (project, edit)
    }

    /// Line ID → its number in the script.
    private func lineNumbers(_ project: Project) -> [String: Int] {
        Dictionary(project.lines.enumerated().map { ($1.id, $0 + 1) }) { first, _ in first }
    }

    private func timeline(_ project: Project) throws -> TimelineInfo {
        let (project, edit) = try openTimeline(project)
        let numbers = lineNumbers(project), waiting = projects.newRenders(project.id)
        let clips = zip(edit.clips, edit.starts).enumerated().map { index, pair in
            let (clip, start) = pair, render = project.version(clip.versionID), effects = clip.effects
            return ClipInfo(clip: index + 1, line: numbers[clip.lineID], text: render.map { Marks.plain($0.text) } ?? "", start: Self.rounded(start),
                            duration: Self.rounded(clip.duration), renderStart: Self.rounded(clip.start), renderEnd: Self.rounded(clip.end),
                            renderDuration: Self.rounded(render?.duration ?? 0), gapAfter: Self.rounded(clip.gapAfter),
                            volumeDb: Self.rounded(clip.gain), fadeIn: Self.rounded(clip.fadeIn), fadeOut: Self.rounded(clip.fadeOut),
                            speed: Self.rounded(effects.tempo), pitch: Self.rounded(effects.pitch), warmth: Self.rounded(effects.warmth),
                            brightness: Self.rounded(effects.brightness), denoise: effects.denoise, newRenderWaiting: waiting[clip.lineID] != nil)
        }
        return TimelineInfo(project: project.name, clips: clips, duration: Self.rounded(edit.duration),
                            linesNotOnTimeline: projects.linesNotOnTimeline(project.id).compactMap { numbers[$0] },
                            pendingProposal: project.editProposal.map { .init(changes: $0.changes) })
    }

    /// Applies the edits in order to a copy of the timeline as it is, not to an earlier proposal, which the result replaces.
    /// An edit that fails is skipped and the rest still apply.
    private func proposeEdits(_ arguments: [String: Any], in project: Project) throws -> EditsResult {
        guard let edits = arguments["edits"] as? [[String: Any]], !edits.isEmpty else {
            throw AppError("edits must be a list of {op, clip, …}.")
        }
        let (project, current) = try openTimeline(project)
        let numbers = lineNumbers(project)
        // Each number names the same clip for the whole call, whatever the edits before it do to the order.
        let clips = current.clips.enumerated().map { index, clip in
            (id: clip.id, name: "clip \(index + 1)" + (numbers[clip.lineID].map { " (line \($0))" } ?? ""))
        }
        var proposed = current, result = EditsResult()
        for (index, item) in edits.enumerated() {
            do {
                var next = proposed
                result.changes.append(try apply(item, to: &next, clips: clips, project: project))
                proposed = next
            } catch {
                let label = [item["op"] as? String, item["clip"].map { "clip \($0)" } ?? item["line"].map { "line \($0)" }]
                    .compactMap(\.self).joined(separator: " ")
                result.errors.append("Edit \(index + 1)\(label.isEmpty ? "" : " (\(label))"): \(error.localizedDescription)")
            }
        }
        if result.changes.isEmpty {
            result.note = "Nothing was proposed; any earlier proposal still waits."
        } else if projects.proposeEdit(EditProposal(edit: proposed, changes: result.changes), in: project.id) {
            result.proposed = result.changes.count
        } else {
            result.changes = []
            result.note = "These edits leave the timeline as it is, so nothing is pending."
        }
        return result
    }

    /// One edit on `edit`, and how it reads to the user. `clips` are the timeline's clips by number as the call found it.
    private func apply(_ item: [String: Any], to edit: inout Edit, clips: [(id: String, name: String)], project: Project) throws -> String {
        func double(_ key: String, _ range: ClosedRange<Double>? = nil, or kept: Double? = nil) throws -> Double {
            if let kept, item[key] == nil { return kept }
            guard let value = (item[key] as? NSNumber)?.doubleValue, value.isFinite else { throw AppError("\(key) must be a number.") }
            if let range, !range.contains(value) {
                throw AppError("\(key) must be from \(Self.plain(range.lowerBound)) to \(Self.plain(range.upperBound)).")
            }
            return value
        }
        func clip(_ key: String = "clip") throws -> (id: String, name: String) {
            guard let number = (item[key] as? NSNumber)?.intValue, clips.indices.contains(number - 1) else {
                throw AppError(clips.isEmpty ? "The timeline has no clips." : "\(key) must be a clip number from 1 to \(clips.count).")
            }
            return clips[number - 1]
        }
        func scriptLine() throws -> (number: Int, line: Line, render: Version) {
            guard let number = (item["line"] as? NSNumber)?.intValue, project.lines.indices.contains(number - 1) else {
                throw AppError("line must be from 1 to \(project.lines.count).")
            }
            guard let render = project.lines[number - 1].chosenVersion else { throw AppError("Line \(number) has no render yet.") }
            return (number, project.lines[number - 1], render)
        }
        func capitalized(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

        switch item["op"] as? String {
        case "split":
            let (id, name) = try clip(), at = try double("at")
            try edit.split(clip: id, at: at)
            return "Split \(name) at \(Self.plain(at)) s"
        case "trim":
            let (id, name) = try clip()
            guard item["start"] != nil || item["end"] != nil else { throw AppError("Give start, end or both.") }
            let old = edit.clips[try edit.index(of: id)]
            guard let render = project.version(old.versionID) else { throw AppError("This clip's render no longer exists.") }
            try edit.trim(clip: id, start: double("start", or: old.start), end: double("end", or: old.end), renderDuration: render.duration)
            let new = edit.clips[try edit.index(of: id)]
            return "Trim \(name) to " + String(format: "%.2f–%.2f s", new.start, new.end) + " of its render"
        case "delete":
            let (id, name) = try clip()
            try edit.delete(clip: id)
            return "Delete \(name)"
        case "move":
            // It takes the place of the clip `to` named, wherever that clip is now.
            let (id, name) = try clip(), (target, place) = try clip("to")
            guard id != target else { throw AppError("A clip can't take its own place.") }
            let from = try edit.index(of: id)
            guard let to = edit.clips.firstIndex(where: { $0.id == target }) else { throw AppError("\(capitalized(place)) is no longer on the timeline.") }
            try edit.move(clip: id, to: to)
            return "Move \(name) \(from < to ? "after" : "before") \(place)"
        case "gap":
            let (id, name) = try clip(), seconds = try double("seconds", 0...Edit.longest)
            let old = edit.clips[try edit.index(of: id)].gapAfter
            try edit.setGap(clip: id, to: seconds)
            return "\(seconds < old ? "Shorten" : seconds > old ? "Lengthen" : "Set") the gap after \(name) to \(Self.plain(seconds)) s"
        case "volume":
            let (id, name) = try clip(), db = try double("db", Edit.gains)
            let old = edit.clips[try edit.index(of: id)].gain
            try edit.setGain(clip: id, to: db)
            guard db != old else { return "Keep \(name) at \(Self.plain(db)) dB" }
            return "Make \(name) \(Self.plain(abs(db - old))) dB \(db < old ? "quieter" : "louder")" + (old == 0 ? "" : ", to \(Self.plain(db)) dB")
        case "fade":
            let (id, name) = try clip()
            guard item["in"] != nil || item["out"] != nil else { throw AppError("Give in, out or both.") }
            let old = edit.clips[try edit.index(of: id)]
            try edit.setFades(clip: id, fadeIn: double("in", 0...Edit.longest, or: old.fadeIn),
                              fadeOut: double("out", 0...Edit.longest, or: old.fadeOut))
            let new = edit.clips[try edit.index(of: id)]
            return "Fade \(name): " + [new.fadeIn > 0 ? "in over \(Self.plain(new.fadeIn)) s" : "no fade in",
                                       new.fadeOut > 0 ? "out over \(Self.plain(new.fadeOut)) s" : "no fade out"].joined(separator: ", ")
        case "voice":
            let (id, name) = try clip()
            let keys = ["speed", "pitch", "warmth", "brightness", "denoise"].filter { item[$0] != nil }
            guard !keys.isEmpty else { throw AppError("Give speed, pitch, warmth, brightness or denoise.") }
            var effects = edit.clips[try edit.index(of: id)].effects
            effects.tempo = try double("speed", VoiceEffects.tempos, or: effects.tempo)
            effects.pitch = try double("pitch", VoiceEffects.semitones, or: effects.pitch)
            effects.warmth = try double("warmth", VoiceEffects.shelves, or: effects.warmth)
            effects.brightness = try double("brightness", VoiceEffects.shelves, or: effects.brightness)
            if let flag = item["denoise"] {
                guard let denoise = flag as? Bool else { throw AppError("denoise must be true or false.") }
                effects.denoise = denoise
            }
            try edit.setEffects(clip: id, to: effects)
            let parts = keys.map { key in
                switch key {
                case "speed": effects.tempo == 1 ? "normal speed"
                    : "\(effects.tempo > 1 ? "speed up" : "slow down") to \(Int((effects.tempo * 100).rounded()))%"
                case "pitch": effects.pitch == 0 ? "original pitch"
                    : "pitch \(effects.pitch > 0 ? "up" : "down") \(Self.plain(abs(effects.pitch))) semitone\(abs(effects.pitch) == 1 ? "" : "s")"
                case "warmth": effects.warmth == 0 ? "original warmth"
                    : "\(Self.plain(abs(effects.warmth))) dB \(effects.warmth > 0 ? "warmer" : "less warm")"
                case "brightness": effects.brightness == 0 ? "original brightness"
                    : "\(Self.plain(abs(effects.brightness))) dB \(effects.brightness > 0 ? "brighter" : "duller")"
                default: effects.denoise ? "background noise removed" : "no noise removal"
                }
            }
            return capitalized(name) + ": " + parts.joined(separator: ", ")
        case "swap_in":
            let (number, line, render) = try scriptLine()
            let new = !edit.clips.contains { $0.lineID == line.id && $0.versionID == render.id }
            try edit.swapIn(line: line.id, version: render.id, duration: render.duration)
            return new ? "Swap in line \(number)'s new render" : "Put line \(number)'s render back whole"
        case "add_line":
            let (number, line, render) = try scriptLine()
            try edit.insert(line: line.id, version: render.id, duration: render.duration, gapAfter: line.pauseAfter,
                            script: project.lines.map(\.id))
            return "Add line \(number) to the timeline"
        default:
            throw AppError("op must be one of split, trim, delete, move, gap, volume, fade, voice, swap_in, add_line.")
        }
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
        guard voices.busy == nil, projects.progress == nil else {
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

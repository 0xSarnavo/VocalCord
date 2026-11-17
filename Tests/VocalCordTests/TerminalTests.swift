import Foundation
import Testing
@testable import VocalCord

// MARK: Socket

/// Connects to a Unix socket; returns the descriptor.
private func connectSocket(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { throw AppError("connect failed") }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return fd
}

private func send(_ fd: Int32, _ text: String) {
    let bytes = Array(text.utf8)
    _ = write(fd, bytes, bytes.count)
}

/// Reads until `count` lines arrive or the peer closes.
private func readLines(_ fd: Int32, count: Int) -> [String] {
    var data = Data(), chunk = [UInt8](repeating: 0, count: 4096)
    while data.filter({ $0 == 0x0A }).count < count {
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { break }
        data.append(contentsOf: chunk[..<n])
    }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

@Test func bridgeServerNeedsTheTokenAndAnswersEachLine() async throws {
    let path = FileManager.default.temporaryDirectory.appending(path: "vc-\(UUID().uuidString.prefix(8)).sock").path
    // Echoes the line back, the "slow" one after the others; notifications get no reply.
    let server = try BridgeServer(path: path, token: "secret") { line in
        let text = String(decoding: line, as: UTF8.self)
        if text == "note" { return nil }
        if text == "slow" { try? await Task.sleep(for: .milliseconds(300)) }
        return Data("re:\(text)".utf8)
    }
    defer { server.stop() }
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    #expect(mode == 0o600)

    let wrong = try connectSocket(path)
    send(wrong, "guess\nhello\n")
    #expect(readLines(wrong, count: 1).isEmpty)
    close(wrong)

    let client = try connectSocket(path)
    send(client, "secret\nslow\nnote\nfast\n")
    #expect(readLines(client, count: 2) == ["re:fast", "re:slow"])
    close(client)

    #expect(BridgeServer.sameBytes(Data("abc".utf8), Data("abc".utf8)))
    #expect(!BridgeServer.sameBytes(Data("abc".utf8), Data("abd".utf8)) && !BridgeServer.sameBytes(Data("ab".utf8), Data("abc".utf8)))
}

// MARK: Tools

@MainActor private func scriptFixture() throws -> (ProjectStore, VoiceStore, String) {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Sarnavo", fullClone: false)
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let projects = ProjectStore(root: try tempFolder())
    let id = projects.create(name: "Launch film")
    projects.addLines(["Meet the next chapter.", "Let's take a closer look."], to: id, voices: voices)
    return (projects, voices, id)
}

@MainActor private func rpc(_ bridge: ToolBridge, _ method: String, _ params: [String: Any] = [:], id: Int? = 1) async throws -> [String: Any]? {
    var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
    message["id"] = id
    guard let reply = await bridge.handle(try JSONSerialization.data(withJSONObject: message)) else { return nil }
    return try JSONSerialization.jsonObject(with: reply) as? [String: Any]
}

@MainActor private func callTool(_ bridge: ToolBridge, _ name: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
    let result = try #require(try await rpc(bridge, "tools/call", ["name": name, "arguments": arguments])?["result"] as? [String: Any])
    let content = try #require(result["content"] as? [[String: Any]])
    return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
}

@MainActor @Test func toolBridgeSpeaksMCPAndProposesChanges() async throws {
    let (projects, voices, id) = try scriptFixture()
    var open: String? = nil
    let bridge = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send)) { open }

    let initialize = try #require(try await rpc(bridge, "initialize", ["protocolVersion": "2025-06-18"]))
    #expect((initialize["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    #expect(try await rpc(bridge, "notifications/initialized", id: nil) == nil)
    // check_script is listed only once Jev is added.
    let tools = try #require((try await rpc(bridge, "tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String }
        == ["get_voices", "get_script", "update_script", "add_lines", "render_line", "get_scores", "get_takes", "propose_take_changes", "audition"])
    let withJev = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys("k"), send: FakeTypeSafe([:]).send)) { open }
    let jevTools = try #require((try await rpc(withJev, "tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(jevTools.compactMap { $0["name"] as? String }.contains("check_script"))
    #expect((try await rpc(bridge, "resources/list")?["error"] as? [String: Any])?["code"] as? Int == -32601)

    #expect(try await callTool(bridge, "get_script") == ("Open a project in Generate first.", true))
    open = id
    let voicesText = try await callTool(bridge, "get_voices").text
    #expect(voicesText.contains("\"name\":\"Sarnavo\"") && voicesText.contains("\"takes_per_tone\":{\"Neutral\":1}"))
    let script = try await callTool(bridge, "get_script").text
    #expect(script.contains("\"project\":\"Launch film\"") && script.contains("\"text\":\"Let's take a closer look.\""))
    #expect(try await callTool(bridge, "check_script") == ("Jev plugin not added", false))

    let update = try await callTool(bridge, "update_script", ["changes": [
        ["line": 2, "text": "Now, let us take a closer look together.", "tone": "happy"],
        ["line": 1, "text": "Meet the next chapter."],
        ["line": 9, "text": "Nope."],
        ["line": 1, "tone": "Furious"],
    ]])
    #expect(!update.isError)
    #expect(update.text.contains("\"proposed\":[2]") && update.text.contains("\"unchanged\":[1]"))
    #expect(update.text.contains("No line 9.") && update.text.contains("Line 1: tone must be one of"))
    let line = try #require(projects.project(id)?.lines[1])
    // Proposed only: the line itself is unchanged until the user accepts.
    #expect(line.text == "Let's take a closer look." && line.tone == "Neutral")
    #expect(line.proposal == Proposal(text: "Now, let us take a closer look together.", tone: "Happy", pauseAfter: 0.5))

    // A later change to the same line keeps the fields it leaves out.
    _ = try await callTool(bridge, "update_script", ["changes": [["line": 2, "pause": 0.8]]])
    #expect(projects.project(id)?.lines[1].proposal?.tone == "Happy" && projects.project(id)?.lines[1].proposal?.pauseAfter == 0.8)

    // render_line renders the pending change as an unchosen version, then scores it.
    let render = try await callTool(bridge, "render_line", ["line": 2])
    #expect(!render.isError, "\(render.text)")
    #expect(render.text.contains("\"chosen\":false") && render.text.contains("\"like_you\":") && render.text.contains("\"tone\":\"Happy\""))
    let scores = try await callTool(bridge, "get_scores", ["line": 2])
    #expect(scores.text.contains("\"heard\":\"Now, let us take a closer look together.\""))
    #expect(try await callTool(bridge, "get_scores", ["line": 0]).isError)
}

@MainActor @Test func addLinesProposesNewLinesEvenIntoAnEmptyProject() async throws {
    let (projects, voices, _) = try scriptFixture()
    let other = voices.createVoice(name: "Narrator", fullClone: false)
    let id = projects.create(name: "Origin story")
    let bridge = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send)) { id }

    let added = try await callTool(bridge, "add_lines", ["lines": [
        ["text": "Every voice app wanted the same thing.", "tone": "angry", "pause": 0.6],
        ["text": "  "],
        ["text": "I called it VocalCord.", "voice": "narrator"],
        ["text": "Always.", "voice": "Nobody"],
    ]])
    #expect(!added.text.contains("\"warnings\":[\""))   // these lines follow the script rules
    #expect(!added.isError, "\(added.text)")
    #expect(added.text.contains("\"proposed\":[1,2]") && added.text.contains("New line 2: text can't be empty."))
    #expect(added.text.contains("New line 4: voice must be one of"))
    var lines = try #require(projects.project(id)?.lines)
    // Pending only: empty until accepted, with the tone, pause and voice already set.
    #expect(lines.map(\.text) == ["", ""] && lines.allSatisfy { $0.added == true })
    #expect(lines[0].proposal == Proposal(text: "Every voice app wanted the same thing.", tone: "Angry", pauseAfter: 0.6))
    #expect(lines[0].tone == "Angry" && lines[0].pauseAfter == 0.6 && lines[1].voiceID == other)
    #expect(try await callTool(bridge, "get_script").text.contains("\"pending_new_line\":true"))

    // after inserts in place; out of range is an error.
    _ = try await callTool(bridge, "add_lines", ["after": 1, "lines": [["text": "Upload your recordings, they said."]]])
    #expect(projects.project(id)?.lines.map { $0.proposal?.text } == ["Every voice app wanted the same thing.", "Upload your recordings, they said.", "I called it VocalCord."])
    #expect(try await callTool(bridge, "add_lines", ["after": 9, "lines": [["text": "Nope."]]]).isError)
    // Lines that break a rule a computer can check come back with a warning to fix, and get_script shows it.
    let digits = try await callTool(bridge, "add_lines", ["lines": [["text": "It took 3 weeks."]]])
    #expect(digits.text.contains("Line 4: Write numbers and symbols as spoken words"))
    #expect(try await callTool(bridge, "get_script").text.contains("\"warnings\":[\"Write numbers"))
    projects.reject([try #require(projects.project(id)?.lines.last?.id)], in: id)

    // Accepting keeps a new line; rejecting removes it.
    lines = try #require(projects.project(id)?.lines)
    projects.accept([lines[0].id], in: id)
    projects.reject([lines[1].id], in: id)
    lines = try #require(projects.project(id)?.lines)
    #expect(lines.count == 2 && lines[0].text == "Every voice app wanted the same thing." && lines[0].added == nil && lines[0].proposal == nil)
    #expect(lines[1].added == true)
}

// MARK: Take tools

/// A voice with two Neutral takes, one Happy take and a pronunciation.
@MainActor private func voiceFixture(delay: Duration = .zero) throws -> (VoiceStore, String) {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: delay))
    let id = voices.createVoice(name: "Sarnavo", fullClone: false)
    for (tone, text, seconds) in [("Neutral", "I'll send the file in a minute.", 4.0), ("Neutral", "The meeting starts at ten.", 2.0),
                                  ("Happy", "That's great news!", 4.0)] {
        let wav = try tempFolder().appending(path: "take.wav")
        try writeWAV(speechLike(seconds: seconds, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
        try voices.addTake(id, file: wav, tone: tone, transcript: text, issues: [])
    }
    voices.addPronunciation(word: "Kuber", respelling: "Koo-ber", voiceID: id)
    return (voices, id)
}

@MainActor @Test func takeToolsProposeChangesForTheSelectedVoice() async throws {
    let (voices, id) = try voiceFixture()
    var selected: String? = nil
    let bridge = ToolBridge(projects: ProjectStore(root: try tempFolder()), voices: voices,
                            jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send), projectID: { nil }, voiceID: { selected })
    #expect(try await callTool(bridge, "get_takes") == ("Select a voice in Clone first.", true))
    selected = id

    let takes = try #require(try JSONSerialization.jsonObject(with: Data(try await callTool(bridge, "get_takes").text.utf8)) as? [String: Any])
    #expect(takes["voice"] as? String == "Sarnavo" && takes["pronunciations"] as? [String: String] == ["Kuber": "Koo-ber"])
    let rows = try #require(takes["takes"] as? [[String: Any]])
    #expect(rows.map { $0["take"] as? Int } == [1, 2, 3] && rows.map { $0["main"] as? Bool } == [true, false, true])
    #expect(rows[1]["warnings"] as? [String] == ["Too short"] && rows[0]["seconds"] as? Double == 4)

    let result = try await callTool(bridge, "propose_take_changes", [
        "changes": [
            ["take": 1, "transcript": " I'll send the file in a minute, OK? "],
            ["take": 2, "tone": "happy", "main": true],
            ["take": 3, "transcript": "That's great news!"],
            ["take": 9, "tone": "Sad"],
            ["take": 1, "tone": "Furious"],
            ["take": 3, "main": false],
        ],
        "pronunciations": [["word": "Avalanche", "say_as": "Av-uh-lanch"], ["word": "kuber", "say_as": "Koo-ber"], ["word": "Nope"]],
    ])
    #expect(!result.isError)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    #expect(json["proposed"] as? [Int] == [1, 2] && json["unchanged"] as? [Int] == [3])
    #expect(json["pronunciations_proposed"] as? [String] == ["Avalanche"] && json["pronunciations_unchanged"] as? [String] == ["kuber"])
    #expect(json["errors"] as? [String] == ["No take 9.", "Take 1: tone must be one of Neutral, Confident, Happy, Sad, Angry, Soft, Slow, Hesitant.",
                                            "Take 3: main can only be true.", "Each pronunciation needs a word and say_as."])

    // Proposed only: the takes are unchanged until the user accepts.
    var voice = try #require(voices.voice(id))
    #expect(voice.takes[0].transcript == "I'll send the file in a minute." && voice.takes[1].tone == "Neutral" && voice.mains.isEmpty)
    #expect(voice.takes[0].proposal == TakeProposal(transcript: "I'll send the file in a minute, OK?"))
    #expect(voice.takes[1].proposal == TakeProposal(tone: "Happy", main: true) && voice.takes[2].proposal == nil)
    #expect(voice.proposedPronunciations?.map(\.word) == ["Avalanche"])
    #expect(try await callTool(bridge, "get_takes").text.contains("\"pending_change\":{\"main\":true,\"tone\":\"Happy\"}"))

    // A main take proposed for a tone replaces any other pending there; one already main isn't a change.
    #expect(voices.propose(TakeProposal(main: true), take: voice.takes[2].id, voiceID: id) == false)
    #expect(voices.propose(TakeProposal(tone: "Happy", main: true), take: voice.takes[0].id, voiceID: id))
    voice = try #require(voices.voice(id))
    #expect(voice.takes[0].proposal == TakeProposal(transcript: "I'll send the file in a minute, OK?", tone: "Happy", main: true))
    #expect(voice.takes[1].proposal == TakeProposal(tone: "Happy"))

    voices.rejectTakes([voice.takes[0].id], voiceID: id)
    voices.acceptTakes([voice.takes[1].id], voiceID: id)
    voices.acceptPronunciations(voice.proposedPronunciations?.map(\.id) ?? [], voiceID: id)
    voice = try #require(voices.voice(id))
    #expect(voice.takes[0].proposal == nil && voice.takes[0].transcript == "I'll send the file in a minute.")
    #expect(voice.takes[1].tone == "Happy" && voice.takes[1].proposal == nil && voice.takes("Happy").count == 2)
    #expect(voice.pronunciationMap == ["Kuber": "Koo-ber", "Avalanche": "Av-uh-lanch"] && voice.proposedPronunciations == nil)
    // An accepted pronunciation replaces the voice's own for that word.
    voices.proposePronunciation(word: "KUBER", respelling: "Koo-burr", voiceID: id)
    voices.acceptPronunciations(voices.voice(id)?.proposedPronunciations?.map(\.id) ?? [], voiceID: id)
    #expect(voices.voice(id)?.pronunciationMap == ["Avalanche": "Av-uh-lanch", "KUBER": "Koo-burr"])
    // Saved with the voice.
    #expect(VoiceStore(root: voices.root, engine: FakeEngine()).voices == voices.voices)
}

@MainActor @Test func auditionToolProposesTheBestTakePerTone() async throws {
    let (voices, id) = try voiceFixture(delay: .milliseconds(80))
    let projects = ProjectStore(root: try tempFolder())
    let bridge = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send),
                            projectID: { nil }, voiceID: { id })
    let result = try await callTool(bridge, "audition")
    #expect(!result.isError, "\(result.text)")
    let voice = try #require(voices.voice(id))
    // Scores are saved; the main takes are only proposed.
    #expect(voice.takes.allSatisfy { $0.score != nil } && voice.mains.isEmpty)
    let neutral = voice.takes("Neutral")
    let best = try #require(neutral.max { $0.score! < $1.score! })
    let bestNumber = try #require(voice.takes.firstIndex(of: best)) + 1
    let json = try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    let rows = try #require(json["best"] as? [[String: Any]])
    #expect(rows.map { $0["tone"] as? String } == ["Neutral", "Happy"] && rows[0]["take"] as? Int == bestNumber)
    // The first take is already Neutral's main, and the only Happy take is Happy's.
    #expect(json["proposed"] as? [Int] == (bestNumber == 1 ? [] : [bestNumber]))
    #expect(best.proposal == (bestNumber == 1 ? nil : TakeProposal(main: true)) && voice.takes[2].proposal == nil)

    // One audition at a time, and none while a render runs.
    let first = Task { try await voices.audition(id) { _ in } }
    while voices.auditioning == nil { await Task.yield() }
    await #expect(throws: AppError.self) { try await voices.audition(id) { _ in } }
    #expect(try await callTool(bridge, "audition") == ("A render or audition is running. Try again when it finishes.", true))
    _ = try await first.value
}

// MARK: Proposals

@MainActor @Test func acceptingAppliesTheChangeAndRejectingDropsIt() async throws {
    let (projects, voices, id) = try scriptFixture()
    let lines = try #require(projects.project(id)).lines
    projects.renderNeeded(id, voices: voices)
    while projects.progress != nil { try await Task.sleep(for: .milliseconds(20)) }

    // A proposal equal to the line is no proposal.
    #expect(!projects.propose(Proposal(lines[0]), line: lines[0].id, in: id))
    #expect(projects.propose(Proposal(text: "Meet the new chapter.", tone: "Confident", pauseAfter: 1), line: lines[0].id, in: id))
    #expect(projects.propose(Proposal(text: "Take a look.", tone: "Neutral", pauseAfter: 0.5), line: lines[1].id, in: id))

    projects.reject([lines[1].id], in: id)
    var line = try #require(projects.project(id)?.lines[1])
    #expect(line.proposal == nil && line.text == "Let's take a closer look.")

    projects.accept([lines[0].id], in: id)
    line = try #require(projects.project(id)?.lines[0])
    #expect(line.proposal == nil && line.text == "Meet the new chapter." && line.tone == "Confident" && line.pauseAfter == 1)
    #expect(line.needsRender)

    // Accepting a change that was already rendered chooses that render.
    #expect(projects.propose(Proposal(text: "Have a look.", tone: "Happy", pauseAfter: 0.5), line: lines[1].id, in: id))
    try await #require(projects.renderLine(lines[1].id, in: id, voices: voices)).value
    line = try #require(projects.project(id)?.lines[1])
    #expect(line.versions.count == 2 && line.chosen == line.versions[0].id)
    projects.accept([lines[1].id], in: id)
    line = try #require(projects.project(id)?.lines[1])
    #expect(line.chosen == line.versions[1].id && !line.needsRender)
    // Saved with the project.
    #expect(ProjectStore(root: projects.root).projects == projects.projects)
}

// MARK: Agents

@Test func agentDetectionUsesTheLoginShellPath() async throws {
    let home = try tempFolder(), bin = try tempFolder()
    for name in ["claude", "opencode"] {
        let file = bin.appending(path: name)
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    // The fake PATH is set in the profile, as an installer would, not inherited.
    try "export PATH=\"\(bin.path):$PATH\"\n".write(to: home.appending(path: ".zshrc"), atomically: true, encoding: .utf8)
    let found = await Agent.detect(environment: ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "/usr/bin:/bin"])
    #expect(found == [.claude: bin.appending(path: "claude").path, .opencode: bin.appending(path: "opencode").path])
}

@Test func detectionOutputIgnoresShellNoise() {
    let output = "Welcome!\n\nVOCALCORD\tclaude\t/u/bin/claude\n\nVOCALCORD\tcodex\t\nVOCALCORD\tvim\t/usr/bin/vim\nVOCALCORD\topencode\talias\n"
    #expect(Agent.parse(output) == [.claude: "/u/bin/claude"])
}

@Test func launchesAreRestricted() throws {
    let support = try tempFolder()
    let claude = try Agent.claude.launch(path: "/bin/claude", bridge: "/App/vocalcord-mcp", socket: "/s.sock", support: support)
    #expect(claude.command.hasPrefix("exec '/bin/claude' '--setting-sources' '' '--tools' ''"))
    #expect(claude.command.contains("'--strict-mcp-config' '--allowedTools' 'mcp__vocalcord__*'"))
    #expect(claude.command.contains("I only help with voiceover scripts."))
    #expect(!claude.folder.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    let mcp = try String(contentsOf: support.appending(path: "claude-mcp.json"), encoding: .utf8)
    #expect(mcp.contains("\"command\" : \"/App/vocalcord-mcp\"") && mcp.contains("\"/s.sock\""))

    let codexConfig = support.appending(path: "config.toml")
    try """
        model = "secret-model"
        [mcp_servers.railway]
        command = "railway"
        [mcp_servers.node_repl.env]
        TOKEN = "x"
        [mcp_servers."computer-use"] # quoted
        [[mcp_servers.list]]
        [plugins."browser@openai-bundled"]
        enabled = true
        [plugins."odd.name@x"]
        [projects."/Users/me/plugins"]
        """.write(to: codexConfig, atomically: true, encoding: .utf8)
    #expect(Agent.codexOverrides(try String(contentsOf: codexConfig, encoding: .utf8)) == [
        "mcp_servers.railway.enabled=false", "mcp_servers.node_repl.enabled=false", "mcp_servers.computer-use.enabled=false",
        "plugins.browser@openai-bundled.enabled=false",
    ])
    let codex = try Agent.codex.launch(path: "/bin/codex", bridge: "/App/vocalcord-mcp", socket: "/s.sock", support: support, codexConfig: codexConfig)
    #expect(!codex.command.contains("CODEX_HOME") && !codex.command.contains("secret-model") && codex.command.contains("'--sandbox' 'read-only'"))
    #expect(codex.command.contains("'-c' 'mcp_servers.railway.enabled=false'") && codex.command.contains("'-c' 'notify=[]'"))
    #expect(codex.command.contains("'-c' 'projects.\(codex.folder.path).trust_level=\"trusted\"'"))
    #expect(codex.command.contains("'mcp_servers.vocalcord.command=\"/App/vocalcord-mcp\"'"))
    #expect(codex.command.contains("developer_instructions=\"You are VocalCord'\\''s"))

    let opencode = try Agent.opencode.launch(path: "/bin/opencode", bridge: "/App/vocalcord-mcp", socket: "/s.sock", support: support)
    #expect(opencode.command.hasSuffix("'/bin/opencode' '--pure'") && opencode.command.contains("'XDG_CONFIG_HOME="))
    let config = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: support.appending(path: "opencode.json"))) as? [String: Any])
    let agents = try #require(config["agent"] as? [String: [String: Any]])
    #expect(agents["vocalcord"]?["tools"] as? [String: Bool] == ["*": false, "vocalcord_*": true])
    #expect(agents["build"]?["disable"] as? Bool == true && config["default_agent"] as? String == "vocalcord")
}

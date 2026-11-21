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
    let voiceID = voices.createVoice(name: "Sarnavo")
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
        == ["get_voices", "get_script", "update_script", "add_lines", "render_line", "get_scores", "get_pacing", "set_pace_target",
            "get_timeline", "propose_timeline_edits", "get_takes", "propose_take_changes", "audition"])
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
    #expect(render.text.contains("\"chosen\":false") && render.text.contains("\"like_you\":") && render.text.contains("\"tone\":\"\(Tone.enabled ? "Happy" : "Neutral")\""))
    let scores = try await callTool(bridge, "get_scores", ["line": 2])
    #expect(scores.text.contains("\"heard\":\"Now, let us take a closer look together.\""))
    #expect(try await callTool(bridge, "get_scores", ["line": 0]).isError)
}

@MainActor @Test func addLinesProposesNewLinesEvenIntoAnEmptyProject() async throws {
    let (projects, voices, _) = try scriptFixture()
    let other = voices.createVoice(name: "Narrator")
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

// MARK: Timeline tools

@MainActor private func waitForRenders(_ projects: ProjectStore) async throws {
    while projects.progress != nil { try await Task.sleep(for: .milliseconds(20)) }
}

/// The script fixture with a third line, every line rendered: 2 s each, with the default 0.5 s pause.
@MainActor private func timelineFixture() async throws -> (ProjectStore, VoiceStore, String) {
    let (projects, voices, id) = try scriptFixture()
    projects.addLines(["Here's what changed."], to: id, voices: voices)
    try await renderEachLine(projects, id, voices: voices)
    try await waitForRenders(projects)
    return (projects, voices, id)
}

/// Line 3 rendered again and a fourth line rendered, both after the timeline was made.
@MainActor private func renderAfterTheTimeline(_ projects: ProjectStore, _ voices: VoiceStore, _ id: String) async throws {
    projects.rerender(try #require(projects.project(id)?.lines[2].id), in: id, voices: voices)
    try await waitForRenders(projects)
    projects.addLines(["That's the plan."], to: id, voices: voices)
    try await projects.rerender(try #require(projects.project(id)?.lines.last?.id), in: id, voices: voices)?.value
    try await waitForRenders(projects)
}

private func object(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], "\(text)")
}

@MainActor @Test func getTimelineReadsTheTrackTheUserFilled() async throws {
    let (projects, voices, id) = try await timelineFixture()
    let empty = projects.create(name: "Empty")
    var open: String? = empty
    let bridge = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send)) { open }

    // A project with no renders has no timeline to read or edit, and none is made.
    let message = "This project has no renders yet. Render its lines first: the timeline is made from them."
    #expect(try await callTool(bridge, "get_timeline") == (message, true))
    #expect(try await callTool(bridge, "propose_timeline_edits", ["edits": [["op": "delete", "clip": 1]]]) == (message, true))
    #expect(projects.project(empty)?.edit == nil)

    open = id
    #expect(projects.project(id)?.edit == nil)
    // The first read opens it empty, every rendered line waiting to be added; then the user drags the takes in.
    var timeline = try object(try await callTool(bridge, "get_timeline").text)
    #expect(projects.project(id)?.edit == Edit() && (timeline["clips"] as? [Any])?.isEmpty == true)
    #expect(timeline["lines_not_on_timeline"] as? [Int] == [1, 2, 3])
    fillTimeline(projects, id)
    let edit = try #require(projects.project(id)?.edit)
    timeline = try object(try await callTool(bridge, "get_timeline").text)
    #expect(projects.project(id)?.edit == edit)
    #expect(timeline["project"] as? String == "Launch film" && timeline["duration"] as? Double == 7)
    var clips = try #require(timeline["clips"] as? [[String: Any]])
    #expect(clips.map { $0["clip"] as? Int } == [1, 2, 3] && clips.map { $0["line"] as? Int } == [1, 2, 3])
    #expect(clips.map { $0["start"] as? Double } == [0, 2.5, 5] && clips[1]["text"] as? String == "Let's take a closer look.")
    #expect(clips[0]["render_start"] as? Double == 0 && clips[0]["render_end"] as? Double == 2 && clips[0]["render_duration"] as? Double == 2)
    #expect(clips[0]["duration"] as? Double == 2 && clips[0]["gap_after"] as? Double == 0.5 && clips[0]["volume_db"] as? Double == 0)
    #expect(clips[0]["speed"] as? Double == 1 && clips[0]["pitch"] as? Double == 0 && clips[0]["denoise"] as? Bool == false)
    #expect(clips.allSatisfy { $0["new_render_waiting"] as? Bool == false })
    #expect(timeline["lines_not_on_timeline"] as? [Int] == [] && timeline["pending_proposal"] == nil)

    // A line rendered again waits to be swapped in; a line rendered after the timeline was made waits to be added.
    try await renderAfterTheTimeline(projects, voices, id)
    timeline = try object(try await callTool(bridge, "get_timeline").text)
    clips = try #require(timeline["clips"] as? [[String: Any]])
    #expect(clips.map { $0["new_render_waiting"] as? Bool } == [false, false, true])
    #expect(timeline["lines_not_on_timeline"] as? [Int] == [4])
}

@MainActor @Test func timelineEditsApplyInOrderToTheNumbersTheAgentRead() async throws {
    let (projects, voices, id) = try await timelineFixture()
    let bridge = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send)) { id }
    fillTimeline(projects, id)
    try await renderAfterTheTimeline(projects, voices, id)
    let before = try #require(projects.project(id)?.edit)

    let result = try await callTool(bridge, "propose_timeline_edits", ["edits": [
        ["op": "split", "clip": 1, "at": 0.8],
        ["op": "trim", "clip": 2, "start": 0.2, "end": 1.9],
        ["op": "move", "clip": 2, "to": 1],
        ["op": "volume", "clip": 1, "db": -3],
        ["op": "trim", "clip": 9, "end": 1],
        ["op": "gap", "clip": 2, "seconds": 12],
        ["op": "voice", "clip": 2, "speed": 1.05, "pitch": -1],
        ["op": "delete", "clip": 1],
        ["op": "fade", "clip": 1, "out": 0.3],
        ["op": "spin"],
        ["op": "swap_in", "line": 3],
        ["op": "add_line", "line": 4],
        ["op": "gap", "clip": 3, "seconds": 0],
        ["op": "move", "clip": 2, "to": 3],
    ]])
    #expect(!result.isError, "\(result.text)")
    let json = try object(result.text)
    let changes = [
        "Split clip 1 (line 1) at 0.8 s", "Trim clip 2 (line 2) to 0.20–1.90 s of its render", "Move clip 2 (line 2) before clip 1 (line 1)",
        "Make clip 1 (line 1) 3 dB quieter", "Clip 2 (line 2): speed up to 105%, pitch down 1 semitone", "Delete clip 1 (line 1)",
        "Swap in line 3's new render", "Add line 4 to the timeline", "Shorten the gap after clip 3 (line 3) to 0 s",
        "Move clip 2 (line 2) after clip 3 (line 3)",
    ]
    #expect(json["proposed"] as? Int == 10 && json["changes"] as? [String] == changes)
    // Bad edits are skipped by name; clip 1 was deleted by an earlier edit in the same call.
    #expect(json["errors"] as? [String] == [
        "Edit 5 (trim clip 9): clip must be a clip number from 1 to 3.", "Edit 6 (gap clip 2): seconds must be from 0 to 10.",
        "Edit 9 (fade clip 1): That clip is no longer on the timeline.",
        "Edit 10 (spin): op must be one of split, trim, delete, move, gap, volume, fade, voice, swap_in, add_line.",
    ])
    #expect(json["note"] as? String == "Nothing is applied: the user accepts or rejects these changes in the Timeline tab.")

    // Proposed only: the timeline is unchanged until the user accepts.
    let project = try #require(projects.project(id))
    #expect(project.edit == before)
    let proposal = try #require(project.editProposal)
    let clips = proposal.edit.clips, lines = project.lines
    #expect(proposal.changes == changes && clips.map(\.lineID) == [lines[0].id, lines[2].id, lines[1].id, lines[3].id])
    // The split's second half; the first half, made quieter, was deleted.
    #expect(clips[0].start == 0.8 && clips[0].end == 2 && clips[0].gain == 0 && clips[0].id != before.clips[0].id)
    #expect(clips[1].id == before.clips[2].id && clips[1].versionID == lines[2].chosen && clips[1].gapAfter == 0)
    #expect(clips[2].start == 0.2 && clips[2].end == 1.9 && clips[2].effects == VoiceEffects(tempo: 1.05, pitch: -1))
    #expect(try await callTool(bridge, "get_timeline").text.contains("\"pending_proposal\":{\"changes\":[\"Split clip 1 (line 1) at 0.8 s\","))

    // A call where every edit fails leaves the earlier proposal waiting.
    let failed = try object(try await callTool(bridge, "propose_timeline_edits", ["edits": [["op": "delete", "clip": 7]]]).text)
    #expect(failed["proposed"] as? Int == 0 && failed["note"] as? String == "Nothing was proposed; any earlier proposal still waits.")
    #expect(projects.project(id)?.editProposal == proposal)
    // Each call starts from the timeline as it is and replaces the last proposal; one that leaves it as it is clears it.
    let same = try object(try await callTool(bridge, "propose_timeline_edits", ["edits": [["op": "volume", "clip": 1, "db": 0]]]).text)
    #expect(same["proposed"] as? Int == 0 && same["changes"] as? [String] == [])
    #expect(same["note"] as? String == "These edits leave the timeline as it is, so nothing is pending.")
    #expect(projects.project(id)?.editProposal == nil && projects.project(id)?.edit == before)
    #expect(try await callTool(bridge, "propose_timeline_edits").isError)
}

// MARK: Pace tools

/// Waits for renders and mark runs to finish.
@MainActor private func settle(_ projects: ProjectStore) async throws {
    for _ in 0..<1000 {
        if projects.progress == nil && projects.applying.isEmpty && projects.queued.isEmpty { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Still rendering")
}

/// The script fixture's voice, whose take is one word in 2 s (30 words a minute), with a project of a plain line and a
/// line with marks, both rendered, and a third line added after.
@MainActor private func pacingFixture() async throws -> (ProjectStore, VoiceStore, String) {
    let (projects, voices, _) = try scriptFixture()
    let id = projects.create(name: "Pace")
    projects.addLines(["One two three four five six seven eight.", "Wait [pause 0.5] for it, [speed 80%]right now[/speed]."], to: id, voices: voices)
    try await renderEachLine(projects, id, voices: voices)
    try await settle(projects)
    projects.addLines(["Not rendered."], to: id, voices: voices)
    return (projects, voices, id)
}

@MainActor @Test func getPacingReadsEachLinesWordTimesAndPace() async throws {
    let (projects, voices, id) = try await pacingFixture()
    let bridge = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send)) { id }
    var pacing = try object(try await callTool(bridge, "get_pacing").text)
    #expect(pacing["project"] as? String == "Pace" && pacing["pace_target"] == nil)
    var lines = try #require(pacing["lines"] as? [[String: Any]])
    #expect(lines.map { $0["line"] as? Int } == [1, 2, 3])

    // The fake render is the 2 s take with the words spread evenly: 8 words in 2 s against the take's 30 a minute.
    var plain = lines[0]
    #expect(plain["timed"] as? Bool == true && plain["matched"] as? Double == 1 && plain["note"] == nil)
    let words = try #require(plain["words"] as? [[String: Any]])
    #expect(words.count == 8 && words[0]["word"] as? String == "One" && words[1]["start"] as? Double == 0.25 && words[1]["end"] as? Double == 0.5)
    #expect(plain["words_per_minute"] as? Int == 240 && plain["target"] as? Int == 30 && plain["target_from"] as? String == "take")
    #expect(plain["verdict"] as? String == "240 words a minute, 700% faster than your usual 30.")
    let rushed = try #require(plain["rushed"] as? [[String: Any]])
    #expect(rushed.count == 1 && rushed[0]["from_word"] as? Int == 1 && rushed[0]["to_word"] as? Int == 8)
    #expect(rushed[0]["text"] as? String == "One two three four five six seven eight.")
    #expect(plain["dragging"] as? [Any] != nil && (plain["dragging"] as? [Any])?.isEmpty == true && (plain["gaps"] as? [Any])?.isEmpty == true)

    // Times are the played version's: the pause and the slower words are in them, and the asked-for pause isn't a gap
    // or speaking time (5 words in 2.7 s, less the 0.5 s pause).
    let marked = lines[1]
    #expect(marked["text"] as? String == "Wait [pause 0.5] for it, [speed 80%]right now[/speed]." && marked["plain"] as? String == "Wait for it, right now.")
    let markedWords = try #require(marked["words"] as? [[String: Any]])
    #expect(markedWords.map { $0["word"] as? String } == ["Wait", "for", "it,", "right", "now."])
    #expect(markedWords[1]["start"] as? Double == 0.9 && markedWords[4]["end"] as? Double == 2.7)
    #expect(marked["words_per_minute"] as? Int == 136 && (marked["gaps"] as? [Any])?.isEmpty == true && marked["problems"] as? [String] == [])

    #expect(lines[2]["timed"] as? Bool == false && lines[2]["note"] as? String == "Not rendered yet." && lines[2]["words"] == nil)

    // Raw renders stay hidden: line 2's raw source and its marked version count as one version.
    #expect(projects.project(id)?.lines[1].versions.count == 2)
    let scores = try object(try await callTool(bridge, "get_scores", ["line": 2]).text)
    let versions = try #require(scores["versions"] as? [[String: Any]])
    #expect(versions.count == 1 && versions[0]["version"] as? Int == 1 && versions[0]["of"] as? Int == 1 && versions[0]["chosen"] as? Bool == true)
    let script = try #require(try object(try await callTool(bridge, "get_script").text)["lines"] as? [[String: Any]])
    #expect((script[1]["chosen_version"] as? [String: Any])?["of"] as? Int == 1)
    // The timeline shows the words spoken, without tags.
    fillTimeline(projects, id)
    let clips = try #require(try object(try await callTool(bridge, "get_timeline").text)["clips"] as? [[String: Any]])
    #expect(clips[1]["text"] as? String == "Wait for it, right now.")

    // A project target replaces the take's, at once.
    let set = try object(try await callTool(bridge, "set_pace_target", ["words_per_minute": 240]).text)
    #expect(set["pace_target"] as? Double == 240 && projects.project(id)?.paceTarget == 240)
    pacing = try object(try await callTool(bridge, "get_pacing").text)
    lines = try #require(pacing["lines"] as? [[String: Any]])
    plain = lines[0]
    #expect(pacing["pace_target"] as? Double == 240 && plain["target"] as? Int == 240 && plain["target_from"] as? String == "project")
    #expect(plain["verdict"] as? String == "On pace." && (plain["rushed"] as? [Any])?.isEmpty == true)
    #expect(try await callTool(bridge, "set_pace_target", ["words_per_minute": 400])
        == ("words_per_minute must be a number from 80 to 260, or null.", true))
    #expect(try await callTool(bridge, "set_pace_target", ["words_per_minute": true]).isError && projects.project(id)?.paceTarget == 240)
    let cleared = try object(try await callTool(bridge, "set_pace_target", ["words_per_minute": NSNull()]).text)
    #expect(cleared["pace_target"] == nil && projects.project(id)?.paceTarget == nil)
    projects.setPaceTarget(150, in: id)
    _ = try await callTool(bridge, "set_pace_target")
    #expect(projects.project(id)?.paceTarget == nil)

    // A line's tag problems show with its pace.
    projects.setText("Say it [speed 80%]slowly.", line: try #require(projects.project(id)?.lines[2].id), in: id)
    lines = try #require(try object(try await callTool(bridge, "get_pacing").text)["lines"] as? [[String: Any]])
    #expect(lines[2]["problems"] as? [String] == ["A [speed] isn't closed."] && lines[2]["plain"] as? String == "Say it slowly.")
}

@MainActor @Test func getPacingTimesUntimedLinesForTheNextCall() async throws {
    let root = try tempFolder()
    let folder = root.appending(path: "old")
    try FileManager.default.createDirectory(at: folder.appending(path: "renders"), withIntermediateDirectories: true)
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: folder.appending(path: "renders/v1.wav"))
    // Rendered before word times existed, and unscored, so its take's pace isn't known.
    try Data(#"""
        {"createdAt": 700000000, "id": "old", "name": "Old film", "lines": [
          {"id": "l1", "text": "Hello there my friend.", "voiceID": "me", "tone": "Neutral", "pauseAfter": 0.5, "chosen": "v1",
           "versions": [{"id": "v1", "text": "Hello there my friend.", "voiceID": "me", "tone": "Neutral", "direction": false,
                         "seed": 7, "duration": 2, "createdAt": 700000000}]}]}
        """#.utf8).write(to: folder.appending(path: "project.json"))
    let projects = ProjectStore(root: root)
    let bridge = ToolBridge(projects: projects, voices: VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero)),
                            jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send)) { "old" }

    var line = try #require(try object(try await callTool(bridge, "get_pacing").text)["lines"] as? [[String: Any]]).first
    #expect(line?["timed"] as? Bool == false && (line?["note"] as? String)?.hasPrefix("Its words aren't timed yet.") == true)
    for _ in 0..<500 where projects.project("old")?.lines[0].chosenVersion?.words == nil { try await Task.sleep(for: .milliseconds(10)) }

    line = try #require(try object(try await callTool(bridge, "get_pacing").text)["lines"] as? [[String: Any]]).first
    #expect(line?["timed"] as? Bool == true && (line?["words"] as? [Any])?.count == 4 && line?["words_per_minute"] == nil)
    #expect(line?["note"] as? String == "No pace target: its take's pace isn't known. Set one with set_pace_target.")
    _ = try await callTool(bridge, "set_pace_target", ["words_per_minute": 120])
    line = try #require(try object(try await callTool(bridge, "get_pacing").text)["lines"] as? [[String: Any]]).first
    #expect(line?["words_per_minute"] as? Int == 120 && line?["verdict"] as? String == "On pace." && line?["note"] == nil)
}

@MainActor @Test func proposalsWithTagProblemsComeBackAsErrors() async throws {
    let (projects, voices, id) = try scriptFixture()
    let bridge = ToolBridge(projects: projects, voices: voices, jev: Jev(keys: MemoryKeys(), send: FakeTypeSafe([:]).send)) { id }

    let update = try object(try await callTool(bridge, "update_script", ["changes": [
        ["line": 1, "text": "Meet the [speed 80%]next chapter.", "tone": "Happy"],
        ["line": 2, "text": "Let's take [pause 0.4] a [stress]closer[/stress] look."],
    ]]).text)
    #expect(update["proposed"] as? [Int] == [2] && update["warnings"] as? [String] == [])
    #expect(update["errors"] as? [String] == ["Line 1 not proposed: A [speed] isn't closed. Fix the tags and send it again."])
    let lines = try #require(projects.project(id)?.lines)
    #expect(lines[0].proposal == nil && lines[1].proposal?.text == "Let's take [pause 0.4] a [stress]closer[/stress] look.")

    let added = try object(try await callTool(bridge, "add_lines", ["lines": [
        ["text": "Go [pause twenty] now."], ["text": "Fine [breath] then."], ["text": "[/say] Odd."],
    ]]).text)
    #expect(added["proposed"] as? [Int] == [3])
    #expect(added["errors"] as? [String] == [
        "New line 1 not added: Write a pause in seconds, as [pause 0.5]. Fix the tags and send it again.",
        "New line 3 not added: A [/say] has no [say] before it. Fix the tags and send it again.",
    ])
    #expect(projects.project(id)?.lines.map { $0.proposal?.text } == [nil, "Let's take [pause 0.4] a [stress]closer[/stress] look.", "Fine [breath] then."])
}

// MARK: Take tools

/// A voice with two Neutral takes, one Happy take and a pronunciation.
@MainActor private func voiceFixture(delay: Duration = .zero) throws -> (VoiceStore, String) {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: delay))
    let id = voices.createVoice(name: "Sarnavo")
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
    // Scores are saved; the main takes are only proposed. Tones are hidden, so only the Neutral takes are auditioned.
    #expect(voice.takes("Neutral").allSatisfy { $0.score != nil } && voice.takes("Happy").allSatisfy { $0.score == nil } && voice.mains.isEmpty)
    let neutral = voice.takes("Neutral")
    let best = try #require(neutral.max { $0.score! < $1.score! })
    let bestNumber = try #require(voice.takes.firstIndex(of: best)) + 1
    let json = try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    let rows = try #require(json["best"] as? [[String: Any]])
    #expect(rows.map { $0["tone"] as? String } == ["Neutral"] && rows[0]["take"] as? Int == bestNumber)
    // The first take is already Neutral's main.
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
    projects.renderScript(id, voices: voices)
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

@Test func instructionsTeachTheScriptCommandsAndPacing() {
    let instructions = Agent.instructions
    for text in ["[pause 0.5]", "[breath]", "[speed 80%]words[/speed]", "[stress]word[/stress]", "[say Koo-ber]Kuber[/say]",
                 "no new render", "need a new render", "propose_take_changes", "get_pacing", "set_pace_target", "calm intro, punchy ending"] {
        #expect(instructions.contains(text), "\(text)")
    }
    // Pauses are applied after the render now, so they no longer split the take.
    #expect(!instructions.contains("splits the line into parts") && instructions.contains("don't split the take"))
    for tool in ["get_script", "get_pacing", "update_script"] { #expect(Agent.reviewPacePrompt.contains(tool)) }
}

@Test func askSendsToTheSelectedAgentElseTheFirstInstalled() throws {
    #expect(Terminals.target(selected: .codex, installed: [.claude: "/c", .codex: "/x"]) == .codex)
    #expect(Terminals.target(selected: .codex, installed: [.opencode: "/o", .claude: "/c"]) == .claude)
    #expect(Terminals.target(selected: nil, installed: [.opencode: "/o"]) == .opencode)
    #expect(Terminals.target(selected: .claude, installed: [:]) == nil)

    // Typed into a running session: one paste when the CLI has bracketed paste on, else one line; Return goes after.
    #expect(Terminals.typed("Review\nthe pace.\n", bracketed: false) == "Review the pace.")
    #expect(Terminals.typed("Review\nthe \u{1B}pace.", bracketed: true) == "\u{1B}[200~Review\nthe pace.\u{1B}[201~")

    // A session started for the prompt gets it as the CLI's first prompt, never read as an option.
    let support = try tempFolder(), prompt = Agent.reviewPacePrompt
    func command(_ agent: Agent, _ prompt: String? = nil) throws -> String {
        try agent.launch(path: "/bin/\(agent.rawValue)", bridge: "/App/vocalcord-mcp", socket: "/s.sock", support: support,
                         codexConfig: support.appending(path: "none.toml"), prompt: prompt).command
    }
    #expect(try command(.claude, prompt) == (try command(.claude)) + " '--' " + shellQuoted(prompt))
    #expect(try command(.codex, prompt) == (try command(.codex)) + " '--' " + shellQuoted(prompt))
    #expect(try command(.opencode, "-v") == (try command(.opencode)) + " '--prompt=-v'")
    #expect(try command(.claude, "") == (try command(.claude)))
}

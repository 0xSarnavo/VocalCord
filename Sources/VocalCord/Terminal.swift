import AppKit
import SwiftTerm
import SwiftUI

/// A terminal agent CLI that can run in the Terminal panel.
enum Agent: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, opencode

    var id: Self { self }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }

    static let instructions = """
        You are VocalCord's voiceover director. You help only with the script and timeline of the project open in Generate and Timeline \
        and the takes of the voice selected in Clone. To anything else, reply exactly: "I only help with voiceover scripts."

        Script (Generate):
        - Write new lines or a whole script with add_lines, even into an empty project. Each line has text, \
        \(Tone.enabled ? "a voice, a tone" : "a voice") and a pause after it in seconds.
        - Write one sentence per line: the user renders, names, tags and arranges each line on its own. Render all in \
        Generate reads consecutive lines in one voice as one take (about 600 characters a take) and cuts it back into \
        the lines, so they share one flow; a row's own Render or Re-render reads that line alone, as its own take.
        - Write for the ear: short sentences, one idea each, under 25 words, with a very short one now and then. Put \
        the word to stress at the end of its sentence. Use contractions. Write numbers, symbols and abbreviations as \
        spoken words.
        - Pauses come from punctuation: a comma is short, a full stop longer, a colon sets up what follows, and an \
        ellipsis adds weight (use it rarely). Use the pause after a line for longer gaps, and tags (below) for a beat \
        inside a line; (sigh) adds a sigh.
        - \(Tone.enabled ? toneRule : neutralRule)
        - Fix every warning and error that update_script, add_lines and get_script return.
        - Render only when the user asks. render_line renders one line on its own, as a separate take that may not \
        match the rest; to fix one line, ask the user to click Re-render on its row, and for a voice that sounds the same \
        throughout, Render all, which reads the whole script again as one take.
        - Fix low scores: read the scores, then rewrite or respell, and have the user render again. Low \
        is Like you under 70%, Words under 90%, Human more than 0.5 below the voice's own take, or a flag for pitch, \
        pace or a gap that drifts from the take. Each render comes out a little different, so rendering again can fix \
        a bad one. Nothing renders again on its own: a line renders only when the user clicks its Render or Render all.
        - Keep one voice across the script. Each line is a fresh take, so one can come out lower, faster or less like \
        the voice than the rest. After the user renders, read get_script: different_from_other_lines says how a line's \
        render stands out from the others. Tell the user which lines and why, in plain words, and suggest clicking \
        Re-render on that row first, as each take differs. If a line keeps standing out, look at its text: a very short line, odd \
        punctuation or a tag can change the delivery. You can't hear the audio, so say these are measurements and ask \
        the user to listen.

        Directing delivery:
        - Tags in a line's text: [pause 0.5] is that many seconds of silence (0.05 to 10); [breath] a short pause; \
        [speed 80%]words[/speed] plays them slower or faster (50 to 200%); [stress]word[/stress] emphasizes it; \
        [say Koo-ber]Kuber[/say] respells a word for this line only. Any other [label], such as [softly], is a tone \
        direction from there on and starts a fresh take, so use it rarely.
        - Pauses, breaths and speeds are applied after the render: changing them is instant, with no new render, and \
        they don't split the take. [say] and [stress] need a new render, as does any change to the words.
        - Punctuation is still the most natural tool; use tags where it can't do the job. A pause gives a beat after a \
        key idea. Slow a phrase that should land; speed up a throwaway. Stress sparingly, about one word a line. Use \
        [say] only for a word the voice gets wrong; a word it gets wrong in every line needs a pronunciation \
        (propose_take_changes).
        - get_pacing gives each rendered line's words with times, its words a minute against the target (the take's \
        pace, or set_pace_target's), and rushed or dragging stretches and long gaps by word number. Slow a rushed \
        stretch or give it a beat, and speed up a dragging one. Keep a normal pace and pause after new ideas; don't \
        slow everything down.
        - For a brief such as "calm intro, punchy ending", read get_script and get_pacing first, then propose tagged \
        lines with update_script. Keep the wording unless asked to change it, and explain each change briefly.

        Timeline:
        - The Timeline tab edits the project's audio on one track, each clip a piece of one line's render. Read it with \
        get_timeline and change it with propose_timeline_edits.
        - Fix a line in Generate first: render it again\(Tone.enabled ? ", change its tone" : "") or rewrite it. Use the voice tools only after \
        that, and keep them small: pitch beyond about 2 semitones up or down, or speed outside about 90 to 110%, stops \
        sounding like the speaker.
        - Cut long gaps, breaths and stray sounds with trim, split and gap.

        Takes (Clone):
        - Each render copies the voice, mood and pace of one take, read with its transcript. A good take is 10 to 15 \
        seconds, recorded close to the mic in a quiet room, in one mood, with half a second of silence before and \
        after, and its transcript matches the words spoken exactly. \(Tone.enabled ? takesPerTone : oneReading)
        - Fix transcript errors you can spot (get_takes), such as a misheard name or missing punctuation; never guess \
        at words.
        - \(Tone.enabled ? "Label each take with the tone it is spoken in, and make a clean take with no warnings each tone's main take." : "Make a clean take with no warnings the main take.") \
        A take marked cut off starts or ends mid-word: suggest recording it again.
        - Add pronunciations for words the voice says wrong.
        - audition scores the takes and proposes the best\(Tone.enabled ? " per tone" : "") as the main take.

        Use only the VocalCord tools. update_script, add_lines, propose_timeline_edits, propose_take_changes and audition \
        only propose changes: the user accepts or rejects them, so never say a change is applied. set_pace_target is the \
        exception: it changes the project's pace target at once.
        """

    private static let toneRule = "Give each line the tone its words call for, and let the words carry the emotion too. Tones "
        + "the voice has takes for (get_voices) sound most like it; any other tone renders from a written direction, so suggest "
        + "recording a take in that tone in Clone."
    private static let neutralRule = "Tones are switched off for now: every line uses Neutral, and the words carry the emotion. "
        + "Don't add [label] tone directions."
    private static let takesPerTone = "Suggest a take like that for each tone the script uses, and a storytelling take for narration."
    private static let oneReading = "A voice comes from one recording of the script in Clone, cut into takes at its pauses; for a "
        + "better voice, suggest reading that script again in a quieter room and uploading it."

    /// What the Generate tab's pace review asks the agent.
    static let reviewPacePrompt = "Review the pace and rhythm of the project open in VocalCord. Read it with get_script and "
        + "get_pacing, then propose changes with update_script: pauses, speeds, stress and the pause after each line, keeping "
        + "the wording unless something reads badly aloud. Then sum up what you proposed and why in a few lines."

    /// What the login shell starts from, like a new Terminal window; the user's profile adds the rest. The app's own
    /// environment could carry a parent agent's session markers when VocalCord was opened from a terminal.
    static var shellEnvironment: [String: String] {
        var environment = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR"] { environment[key] = ProcessInfo.processInfo.environment[key] }
        return environment
    }

    /// Each CLI's path on the user's login shell PATH, which GUI apps don't inherit. The shell is interactive too,
    /// since installers often add to PATH in .zshrc; `whence -p` skips aliases and functions.
    static func detect(shell: String = "/bin/zsh", environment: [String: String] = shellEnvironment) async -> [Agent: String] {
        let script = "for c in \(allCases.map(\.rawValue).joined(separator: " ")); do printf '\\nVOCALCORD\\t%s\\t%s\\n' $c \"$(whence -p $c)\"; done"
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: shell)
            process.arguments = ["-ilc", script]
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [:] }
            // A shell profile that hangs must not leave the panel waiting forever.
            let timeout = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return parse(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Lines of `VOCALCORD<tab>name<tab>path`; anything else the shell printed is ignored.
    static func parse(_ output: String) -> [Agent: String] {
        var found: [Agent: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0] == "VOCALCORD", let agent = Agent(rawValue: parts[1]), parts[2].hasPrefix("/") else { continue }
            found[agent] = parts[2]
        }
        return found
    }

    /// The user's Codex config, whose MCP servers and plugins a Codex launch switches off.
    /// shortcut: assumes the default CODEX_HOME; a CODEX_HOME set in the shell profile isn't read.
    static let codexConfig = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/config.toml")

    /// `-c` overrides that switch off every MCP server and plugin a Codex config.toml declares. Only table headers are read.
    /// Codex splits `-c` keys on every dot and ignores quotes, so a name containing a dot can't be switched off; none do today.
    static func codexOverrides(_ config: String) -> [String] {
        var overrides: [String] = []
        for line in config.split(whereSeparator: \.isNewline) {
            guard let match = line.wholeMatch(of: /\s*\[\s*(mcp_servers|plugins)\s*\.\s*(?:"([^"]+)"|([A-Za-z0-9_-]+))(?:\..*)?\]\s*(?:#.*)?/),
                  let name = match.2 ?? match.3, !name.contains(".") else { continue }
            let override = "\(match.1).\(name).enabled=false"
            if !overrides.contains(override) { overrides.append(override) }
        }
        return overrides
    }

    /// The shell command that runs this CLI restricted to the VocalCord tools, and its working folder.
    /// Writes the configs it needs under `support`. `prompt` is sent as the session's first message once the CLI is
    /// ready: Claude Code and Codex take it as their positional prompt, OpenCode as `--prompt`.
    func launch(path: String, bridge: String, socket: String, support: URL, codexConfig: URL = Agent.codexConfig,
                prompt: String? = nil) throws -> (command: String, folder: URL) {
        let files = FileManager.default
        // Empty, and outside the home folder so no CLAUDE.md or AGENTS.md above it is picked up.
        let folder = files.temporaryDirectory.appending(path: "VocalCord/\(rawValue)", directoryHint: .isDirectory)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try files.createDirectory(at: support, withIntermediateDirectories: true)
        func json(_ object: Any, _ name: String) throws -> URL {
            let url = support.appending(path: name)
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url)
            return url
        }
        var arguments: [String]
        switch self {
        case .claude:
            let config = try json(["mcpServers": ["vocalcord": ["command": bridge, "args": [socket]]]], "claude-mcp.json")
            // No settings sources: the user's settings, CLAUDE.md, hooks and permissions stay out.
            arguments = [path, "--setting-sources", "", "--tools", "", "--mcp-config", config.path, "--strict-mcp-config",
                         "--allowedTools", "mcp__vocalcord__*", "--disable-slash-commands", "--append-system-prompt", Self.instructions]
        case .codex:
            // Codex can't skip ~/.codex/config.toml in its interactive mode, and its own home keeps the user's sign-in, so the
            // user's MCP servers, plugins, notify command and hooks are switched off instead; `--disable plugins` also covers
            // plugins installed from a remote marketplace, which config.toml doesn't list. ~/.codex/AGENTS.md still loads.
            let user = Self.codexOverrides((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "")
            arguments = [path, "--sandbox", "read-only", "--ask-for-approval", "never", "--cd", folder.path,
                         "--disable", "plugins", "--disable", "hooks", "--disable", "apps", "--disable", "computer_use", "--disable", "browser_use"]
                + user.flatMap { ["-c", $0] }
                // Trusted up front, so Codex neither asks nor writes the answer into the user's config.
                + (folder.path.contains(".") ? [] : ["-c", "projects.\(folder.path).trust_level=\"trusted\""])
                + ["-c", "notify=[]",
                         "-c", "mcp_servers.vocalcord.command=\(toml(bridge))",
                         "-c", "mcp_servers.vocalcord.args=[\(toml(socket))]",
                         "-c", "mcp_servers.vocalcord.tool_timeout_sec=900",
                         "-c", "mcp_servers.vocalcord.default_tools_approval_mode=\"approve\"",
                         "-c", "skills.include_instructions=false",
                         "-c", "web_search=\"disabled\"",
                         "-c", "developer_instructions=\(toml(Self.instructions))"]
        case .opencode:
            let config = try json([
                "$schema": "https://opencode.ai/config.json",
                "default_agent": "vocalcord",
                "mcp": ["vocalcord": ["type": "local", "command": [bridge, socket], "enabled": true, "timeout": 900_000]],
                "agent": [
                    "vocalcord": ["description": "VocalCord's voiceover director", "mode": "primary", "prompt": Self.instructions,
                                  "tools": ["*": false, "vocalcord_*": true]],
                    "build": ["disable": true],
                    "plan": ["disable": true],
                ],
            ], "opencode.json")
            // An empty config home keeps the user's global config, with its MCP servers and agents, out.
            let configHome = support.appending(path: "opencode-config", directoryHint: .isDirectory)
            try files.createDirectory(at: configHome, withIntermediateDirectories: true)
            arguments = ["env", "XDG_CONFIG_HOME=\(configHome.path)", "OPENCODE_CONFIG=\(config.path)", "OPENCODE_DISABLE_CLAUDE_CODE=1",
                         "OPENCODE_DISABLE_PROJECT_CONFIG=1", "OPENCODE_DISABLE_EXTERNAL_SKILLS=1", path, "--pure"]
        }
        if let prompt, !prompt.isEmpty {
            // OpenCode's positional is a folder; in the joined form a prompt starting with "-" stays a value. The other two
            // end their options with "--", so the prompt is never read as one.
            arguments += self == .opencode ? ["--prompt=\(prompt)"] : ["--", prompt]
        }
        return ("exec " + arguments.map(shellQuoted).joined(separator: " "), folder)
    }
}

func shellQuoted(_ value: String) -> String { "'" + value.replacing("'", with: "'\\''") + "'" }

/// A TOML basic string.
private func toml(_ value: String) -> String {
    "\"" + value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"").replacing("\n", with: "\\n") + "\""
}

/// The Terminal panel's agent sessions and the socket their tools reach the app through. Sessions keep running
/// while the panel is closed.
@MainActor @Observable
final class Terminals {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "VocalCord", directoryHint: .isDirectory)

    /// Nil until the first look.
    private(set) var installed: [Agent: String]?
    var selected: Agent?
    private(set) var ended: Set<Agent> = []
    private(set) var bridgeError: String?
    @ObservationIgnored private var sessions: [Agent: AgentTerminalView] = [:]
    @ObservationIgnored private var server: BridgeServer?
    @ObservationIgnored private var looking: Task<Void, Never>?
    /// A prompt `ask` holds while the agents are looked for; the first session started takes it as its first prompt.
    @ObservationIgnored private var waiting: String?
    /// False when the agents were handed in (`found:`): sessions draw an empty terminal and start no CLI.
    @ObservationIgnored private var launches = true
    private let socket: String

    init(tools: ToolBridge, support: URL = Terminals.support) {
        socket = support.appending(path: "bridge.sock").path
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppError("No random bytes.") }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            let tokenFile = support.appending(path: "bridge.token")
            try? FileManager.default.removeItem(at: tokenFile)
            guard FileManager.default.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw AppError("Couldn't write \(tokenFile.path).")
            }
            server = try BridgeServer(path: socket, token: token) { data in await tools.handle(data) }
        } catch {
            bridgeError = "Agents can't reach VocalCord. \(error.localizedDescription)"
        }
    }

    /// For tests: these agents count as found, so no shell looks for them, and their sessions never start a process.
    convenience init(tools: ToolBridge, support: URL, found: [Agent: String]) {
        self.init(tools: tools, support: support)
        installed = found
        selected = Self.target(selected: nil, installed: found)
        launches = false
    }

    /// Looks for the CLIs again while none are found. Calls during a look wait for it.
    func detect() async {
        if let looking { return await looking.value }
        guard launches, installed?.isEmpty ?? true else { return }
        let look = Task {
            let found = await Agent.detect()
            installed = found
            selected = Self.target(selected: selected, installed: found)
        }
        looking = look
        await look.value
        looking = nil
    }

    /// The agent `ask` sends to: the selected one if it's installed, else the first installed.
    nonisolated static func target(selected: Agent?, installed: [Agent: String]) -> Agent? {
        if let selected, installed[selected] != nil { return selected }
        return Agent.allCases.first { installed[$0] != nil }
    }

    /// Sends `prompt` to the selected agent, else the first installed one, and selects it, as if the user typed it and
    /// pressed Return. A session this starts, or restarts after it ended, gets it as the CLI's first prompt; a running
    /// one gets it typed once the CLI can read it. Does nothing when no agent is installed.
    func ask(_ prompt: String) {
        guard installed?.isEmpty == false else {
            // Not looked for yet, or none found last time: look, then send. The panel may start the session meanwhile.
            waiting = prompt
            Task {
                await detect()
                guard let prompt = waiting else { return }
                waiting = nil
                send(prompt)
            }
            return
        }
        send(prompt)
    }

    private func send(_ prompt: String) {
        guard let agent = Self.target(selected: selected, installed: installed ?? [:]) else { return }
        selected = agent
        if ended.contains(agent) { restart(agent) }
        if let view = sessions[agent] {
            Task { await type(prompt, into: view, agent: agent) }
        } else {
            _ = start(agent, prompt: prompt)
        }
    }

    /// Seconds after a CLI's first output before typing into it: before then it may still be starting, and drop input.
    static let startupSeconds = 2.5

    /// Types into a running session. A CLI that's still starting drops what's typed, so this waits for its first
    /// output and a moment more. Return goes separately, after a pause, so it isn't taken as part of a paste.
    private func type(_ prompt: String, into view: AgentTerminalView, agent: Agent) async {
        for _ in 0..<300 where view.firstOutput == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let first = view.firstOutput else { return }
        let wait = Self.startupSeconds - Date.now.timeIntervalSince(first)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        func live() -> Bool { sessions[agent] === view && !ended.contains(agent) }
        guard live() else { return }
        view.send(txt: Self.typed(prompt, bracketed: view.getTerminal().bracketedPasteMode))
        try? await Task.sleep(for: .milliseconds(300))
        guard live() else { return }
        view.send(txt: "\r")
    }

    /// The text to type for a prompt, without Return. With bracketed paste on, it goes as one paste, line breaks
    /// and all; without it a line break would send early, so line breaks become spaces.
    nonisolated static func typed(_ prompt: String, bracketed: Bool) -> String {
        if bracketed { return "\u{1B}[200~" + prompt.replacing("\u{1B}", with: "") + "\u{1B}[201~" }
        return prompt.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// The agent's terminal, started on first use. A prompt `ask` is holding goes to it as its first prompt.
    func session(_ agent: Agent) -> LocalProcessTerminalView {
        if let view = sessions[agent] { return view }
        var prompt: String?
        if installed?[agent] != nil, Self.target(selected: selected, installed: installed ?? [:]) == agent {
            prompt = waiting
            waiting = nil
        }
        return start(agent, prompt: prompt)
    }

    private func start(_ agent: Agent, prompt: String?) -> AgentTerminalView {
        let view = AgentTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(Theme.content)
        view.nativeForegroundColor = NSColor(Theme.text)
        view.caretColor = NSColor(Theme.secondary)
        view.selectedTextBackgroundColor = NSColor(Theme.selection)
        view.processDelegate = self
        sessions[agent] = view
        guard launches, let path = installed?[agent] else { return view }
        do {
            let bridge = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "vocalcord-mcp").path
            let launch = try agent.launch(path: path, bridge: bridge, socket: socket,
                                          support: Self.support.appending(path: "Agents", directoryHint: .isDirectory), prompt: prompt)
            // Through the login shell, so the CLI finds its own config and sign-in.
            view.startProcess(executable: "/bin/zsh", args: ["-ilc", launch.command], environment: Agent.shellEnvironment.map { "\($0)=\($1)" },
                              currentDirectory: launch.folder.path)
        } catch {
            view.feed(text: "Couldn't start \(agent.title). \(error.localizedDescription)\r\n")
        }
        return view
    }

    func restart(_ agent: Agent) {
        sessions.removeValue(forKey: agent)?.terminate()
        ended.remove(agent)
    }

}

/// An agent's terminal, which notes when its process first prints, so a prompt typed in can wait until the CLI reads input.
final class AgentTerminalView: LocalProcessTerminalView {
    private(set) var firstOutput: Date?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if firstOutput == nil { firstOutput = .now }
        super.dataReceived(slice: slice)
    }
}

/// SwiftTerm calls its delegate on the main queue.
extension Terminals: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if let agent = sessions.first(where: { $0.value === source })?.key { ended.insert(agent) }
    }
}

// MARK: Panel

/// The panel under the script: its top edge resizes it, then a tab per installed agent and the selected agent's terminal.
struct TerminalPanel: View {
    @Environment(Terminals.self) private var terminals
    @AppStorage("terminalOpen") private var open = false
    /// The column's width; its left edge resizes it. Every tab puts it on the window's right edge.
    @Binding var width: Double
    let maxWidth: Double

    static let minWidth = 300.0

    var body: some View {
        let range = Self.minWidth...max(Self.minWidth, maxWidth)
        HStack(spacing: 0) {
            ResizeDivider(edge: .leading, size: $width, range: range, label: "Resize terminal")
            panel
        }
        .frame(width: width.clamped(range))
        .panel()
        .task { await terminals.detect() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Agent.allCases.filter { terminals.installed?[$0] != nil }) { agent in
                    Button(agent.title) { terminals.selected = agent }
                        .buttonStyle(.vc(.ghost, .s, selected: terminals.selected == agent))
                        .accessibilityAddTraits(terminals.selected == agent ? .isSelected : [])
                }
                Spacer()
                Button { open = false } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.icon(.s))
                    .help("Hide Terminal (\u{2303}`)")
                    .accessibilityLabel("Hide Terminal")
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Theme.line.frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var content: some View {
        if let error = terminals.bridgeError {
            Warning(text: error).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if terminals.installed == nil {
            ProgressView("Looking for agents…").controlSize(.small)
        } else if let agent = terminals.selected {
            ZStack {
                TerminalHost(terminal: terminals.session(agent))
                    .padding(.leading, 12)
                    .padding(.vertical, 8)
                    .id(agent)
                if terminals.ended.contains(agent) {
                    VStack(spacing: 12) {
                        Text("Session ended").foregroundStyle(Theme.secondary)
                        Button("Restart") { terminals.restart(agent) }.buttonStyle(.vc(.secondary, .m))
                    }
                    .padding(24)
                    .background(Theme.content.opacity(0.92), in: .rect(cornerRadius: Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Theme.line))
                }
            }
        } else {
            VStack(spacing: 4) {
                Text("No agents found").font(.vcTitle)
                Text("Install Claude Code, Codex or OpenCode, then open Terminal again.").foregroundStyle(Theme.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(24)
        }
    }
}

/// Hosts a terminal that outlives this view, so a session survives closing the panel or switching tabs.
private struct TerminalHost: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard terminal.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}

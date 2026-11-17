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
        You are VocalCord's voiceover script director. You help only with the script of the project open in VocalCord. \
        To anything else, reply exactly: "I only help with voiceover scripts."

        Your job:
        - Rewrite lines so they sound natural spoken aloud: shorter sentences, pauses, breaths, and one tone per line, \
        chosen from the tones the line's voice has takes for (get_voices).
        - Fix low scores: render_line, read the scores, then rewrite or respell and render again.
        - Respell words the voice says wrong, such as Kuber as Koo-ber.

        How the script works:
        - Each line has text, a voice, a tone, and a pause after it in seconds.
        - Inside text, [pause 0.3] adds a pause and (sigh) a sigh. For a breath, end the sentence or add a short pause.
        - Low scores: Like you under 70%, Words under 90%, or Human more than 0.5 below the voice's own take.

        Use only the VocalCord tools. update_script only proposes changes: the user accepts or rejects each line in the \
        script, so never say a change is applied.
        """

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
    /// Writes the configs it needs under `support`.
    func launch(path: String, bridge: String, socket: String, support: URL, codexConfig: URL = Agent.codexConfig) throws -> (command: String, folder: URL) {
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
        let arguments: [String]
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
                    "vocalcord": ["description": "VocalCord's script director", "mode": "primary", "prompt": Self.instructions,
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
    @ObservationIgnored private var sessions: [Agent: LocalProcessTerminalView] = [:]
    @ObservationIgnored private var server: BridgeServer?
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

    /// Looks for the CLIs again while none are found.
    func detect() async {
        guard installed?.isEmpty ?? true else { return }
        let found = await Agent.detect()
        installed = found
        if selected.map({ found[$0] == nil }) ?? true { selected = Agent.allCases.first { found[$0] != nil } }
    }

    /// The agent's terminal, started on first use.
    func session(_ agent: Agent) -> LocalProcessTerminalView {
        if let view = sessions[agent] { return view }
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 300))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(Theme.content)
        view.nativeForegroundColor = NSColor(Theme.text)
        view.caretColor = NSColor(Theme.secondary)
        view.selectedTextBackgroundColor = NSColor(Theme.selection)
        view.processDelegate = self
        sessions[agent] = view
        guard let path = installed?[agent] else { return view }
        do {
            let bridge = Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "vocalcord-mcp").path
            let launch = try agent.launch(path: path, bridge: bridge, socket: socket,
                                          support: Self.support.appending(path: "Agents", directoryHint: .isDirectory))
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

/// The panel under the script: a resize handle, a tab per installed agent and the selected agent's terminal.
struct TerminalPanel: View {
    @Environment(Terminals.self) private var terminals
    @AppStorage("terminalOpen") private var open = false
    @Binding var height: Double
    let maxHeight: Double
    @State private var dragStart: Double?

    static let minHeight = 140.0

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.outline).frame(width: 52, height: 4)
                .frame(maxWidth: .infinity).frame(height: 14)
                .contentShape(.rect)
                .pointerStyle(.frameResize(position: .top))
                .gesture(DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? height
                        dragStart = start
                        height = clamp(start - value.translation.height)
                    }
                    .onEnded { _ in dragStart = nil })
                .accessibilityElement()
                .accessibilityLabel("Resize terminal")
                .accessibilityValue("\(Int(height)) points")
                .accessibilityAdjustableAction { direction in
                    height = clamp(height + (direction == .increment ? 40 : -40))
                }
            HStack(spacing: 4) {
                ForEach(Agent.allCases.filter { terminals.installed?[$0] != nil }) { agent in
                    Button { terminals.selected = agent } label: {
                        Text(agent.title)
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(terminals.selected == agent ? Theme.selection : .clear, in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(terminals.selected == agent ? .isSelected : [])
                }
                Spacer()
                Button { open = false } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close terminal")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Theme.line.frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: clamp(height))
        .background(Theme.content)
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .task { await terminals.detect() }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, Self.minHeight), max(Self.minHeight, maxHeight)) }

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
                    VStack(spacing: 10) {
                        Text("Session ended").foregroundStyle(Theme.secondary)
                        Button("Restart") { terminals.restart(agent) }.buttonStyle(.outline(height: 30))
                    }
                    .padding(20)
                    .background(Theme.content.opacity(0.92), in: .rect(cornerRadius: 12))
                }
            }
        } else {
            VStack(spacing: 6) {
                Text("No agents found").font(.system(size: 15, weight: .semibold))
                Text("Install Claude Code, Codex or OpenCode, then open Terminal again.").foregroundStyle(Theme.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(16)
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

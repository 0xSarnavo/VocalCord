import AppKit
import AVFoundation
import Speech
import Carbon
import ApplicationServices

enum Command: Equatable {
    case startDictation, stopDictation
    case dictate(String), openApp(String), findLocal(String, Bool), askWeb(String)

    static func parse(_ speech: String, dictating: Bool) -> Command? {
        let input = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let lower = input.lowercased()
        if lower == "stop dictation" || lower == "stop dictating" { return .stopDictation }
        if lower == "start dictation" || lower == "start dictating" { return .startDictation }
        if dictating { return .dictate(input) }
        for prefix in ["dictate ", "type "] where lower.hasPrefix(prefix) {
            return .dictate(String(input.dropFirst(prefix.count)))
        }
        if lower.hasPrefix("open ") { return .openApp(String(input.dropFirst(5))) }
        for prefix in ["search the web for ", "search web for ", "search online for ", "look up "] where lower.hasPrefix(prefix) {
            return .askWeb(String(input.dropFirst(prefix.count)))
        }
        if lower.hasPrefix("find ") {
            var query = String(input.dropFirst(5))
            let q = query.lowercased()
            for suffix in [" on my mac", " on this mac", " on my computer", " on this computer"] where q.hasSuffix(suffix) {
                query = String(query.dropLast(suffix.count))
                return .findLocal(query, false)
            }
            for suffix in [" on the web", " online", " on the internet"] where q.hasSuffix(suffix) {
                query = String(query.dropLast(suffix.count))
                return .askWeb(query)
            }
            return .findLocal(query, true)
        }
        return .askWeb(input)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var listening = false
    private var finishing = false
    private var lastTranscript = ""
    private var dictating = false
    private var destinationApp: NSRunningApplication?
    private let voice = AVSpeechSynthesizer()
    private var answerWindow: NSWindow?
    private var codexProcess: Process?
    private var videoVoiceWindow: VideoVoiceWindowController?
    private var voiceLibraryWindow: VoiceLibraryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Press ⌃⌥Space to listen", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let listen = NSMenuItem(title: "Start listening", action: #selector(toggleFromMenu), keyEquivalent: "")
        listen.target = self
        menu.addItem(listen)
        let video = NSMenuItem(title: "Video voiceover…", action: #selector(openVideoVoiceover), keyEquivalent: "")
        video.target = self
        menu.addItem(video)
        let library = NSMenuItem(title: "Voice library…", action: #selector(openVoiceLibrary), keyEquivalent: "")
        library.target = self
        menu.addItem(library)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VoiceDesk", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        registerHotKey()
        if CommandLine.arguments.contains("--video-window") { openVideoVoiceover() }
        if CommandLine.arguments.contains("--library-window") { openVoiceLibrary() }
    }

    @objc private func toggleFromMenu() { toggleRecording() }
    @objc private func openVideoVoiceover() {
        if videoVoiceWindow == nil { videoVoiceWindow = VideoVoiceWindowController() }
        videoVoiceWindow?.show()
    }
    @objc private func openVoiceLibrary() {
        if voiceLibraryWindow == nil {
            voiceLibraryWindow = VoiceLibraryWindowController(onOpenVoiceover: { [weak self] in self?.openVideoVoiceover() })
        }
        voiceLibraryWindow?.show()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { app.toggleRecording() }
            return noErr
        }, 1, &eventType, userData, &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x5644534B), id: 1)
        let registration = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr || registration != noErr { showError("Could not register Control–Option–Space. Check whether another app uses it.") }
    }

    func toggleRecording() {
        if listening { stopRecording(); return }
        if finishing { return }
        destinationApp = NSWorkspace.shared.frontmostApplication
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            DispatchQueue.main.async {
                guard let self else { return }
                guard authorization == .authorized else { self.showError("Allow Speech Recognition in System Settings to use VoiceDesk."); return }
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    DispatchQueue.main.async {
                        if allowed { self.startRecording() }
                        else { self.showError("Allow Microphone access in System Settings to use VoiceDesk.") }
                    }
                }
            }
        }
    }

    private func startRecording() {
        guard !listening else { return }
        voice.stopSpeaking(at: .immediate)
        guard let recognizer = ["en-IN", "en-US"].compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }).first(where: { $0.supportsOnDeviceRecognition }) else {
            showError("On-device speech recognition is unavailable for English on this Mac. Install the language's speech files in macOS and retry.")
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        lastTranscript = ""
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result { self.lastTranscript = result.bestTranscription.formattedString }
                if let error, self.listening {
                    self.listening = false
                    self.engine.stop()
                    self.engine.inputNode.removeTap(onBus: 0)
                    self.recognitionTask = nil
                    self.request = nil
                    self.statusItem.button?.title = "🎙"
                    self.showError("Speech recognition stopped: \(error.localizedDescription)")
                    return
                }
                if self.finishing && (result?.isFinal == true || error != nil) { self.finishRecognition() }
            }
        }
        do {
            engine.prepare()
            try engine.start()
            listening = true
            statusItem.button?.title = "🔴"
        } catch {
            input.removeTap(onBus: 0)
            recognitionTask?.cancel()
            recognitionTask = nil
            self.request = nil
            showError("Microphone failed to start: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard listening else { return }
        listening = false
        finishing = true
        statusItem.button?.title = "…"
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.finishing == true { self?.finishRecognition() }
        }
    }

    private func finishRecognition() {
        guard finishing else { return }
        finishing = false
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        statusItem.button?.title = "🎙"
        guard let command = Command.parse(lastTranscript, dictating: dictating) else {
            speak("I didn't catch that. Try again.")
            return
        }
        run(command)
    }

    private func run(_ command: Command) {
        switch command {
        case .startDictation:
            dictating = true
            speak("Dictation on.")
        case .stopDictation:
            dictating = false
            speak("Dictation off.")
        case .dictate(let text):
            paste(text)
        case .openApp(let name):
            openApp(named: name)
        case .findLocal(let query, let fallbackWeb):
            findLocal(query, fallbackWeb: fallbackWeb)
        case .askWeb(let query):
            askCodex(query)
        }
    }

    private func paste(_ text: String) {
        guard !text.isEmpty else { speak("Nothing to dictate."); return }
        guard let app = destinationApp, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            showError("Focus the app where you want the text, then press the shortcut.")
            return
        }
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        guard trusted else { showError("Allow VoiceDesk Accessibility access in System Settings, then try again."); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            self?.speak("Dictated.")
        }
    }

    private func openApp(named name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { speak("Tell me which app to open."); return }
        let folders = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Applications/Utilities"]
        var candidates: [URL] = []
        for folder in folders {
            if let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil) {
                candidates += urls.filter { $0.pathExtension.lowercased() == "app" }
            }
        }
        let wanted = cleaned.lowercased().replacingOccurrences(of: ".app", with: "")
        let match = candidates.first { $0.deletingPathExtension().lastPathComponent.lowercased() == wanted }
            ?? candidates.first { $0.deletingPathExtension().lastPathComponent.lowercased().contains(wanted) }
        guard let match else { speak("I couldn't find \(cleaned) in Applications."); return }
        NSWorkspace.shared.openApplication(at: match, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { self?.showError("Could not open \(cleaned): \(error.localizedDescription)") }
                else { self?.speak("Opened \(match.deletingPathExtension().lastPathComponent).") }
            }
        }
    }

    private func findLocal(_ query: String, fallbackWeb: Bool) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { speak("Tell me what to find."); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-name", query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let paths = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let first = paths.first, process.terminationStatus == 0 {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                        self.speak("Found \(URL(fileURLWithPath: first).lastPathComponent) in Finder.")
                    } else if fallbackWeb {
                        self.askCodex("Find \(query) on the web")
                    } else {
                        self.speak("No Mac files matched \(query).")
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.showError("Spotlight search failed: \(error.localizedDescription)") }
            }
        }
    }

    private func askCodex(_ question: String) {
        guard codexProcess == nil else { speak("I'm still working on the last request."); return }
        let paths = [NSHomeDirectory() + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let binary = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            showError("Install Codex CLI and sign in with your ChatGPT account first.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["exec", "--ephemeral", "--sandbox", "read-only", "--skip-git-repo-check", "-C", NSHomeDirectory(), "-c", "web_search=\"live\"", "Answer this user's spoken request. Search the web when current information is needed. Keep the answer concise, include source URLs for web claims, and do not read local files or execute commands: \(question)"]
        let output = Pipe()
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("voicedesk-codex-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errors = try? FileHandle(forWritingTo: errorURL)
        process.standardOutput = output
        process.standardError = errors ?? FileHandle.nullDevice
        codexProcess = process
        statusItem.button?.title = "…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                try? errors?.close()
                let answer = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self)
                try? FileManager.default.removeItem(at: errorURL)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.codexProcess = nil
                    self.statusItem.button?.title = "🎙"
                    if process.terminationStatus == 0 && !answer.isEmpty {
                        self.showAnswer(answer)
                        self.speak(self.spokenAnswer(answer))
                    } else {
                        self.showError("Codex couldn't finish the request. \(detail.suffix(400))")
                    }
                }
            } catch {
                try? errors?.close()
                try? FileManager.default.removeItem(at: errorURL)
                DispatchQueue.main.async {
                    self?.codexProcess = nil
                    self?.statusItem.button?.title = "🎙"
                    self?.showError("Codex failed to start: \(error.localizedDescription)")
                }
            }
        }
    }

    private func showAnswer(_ answer: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "VoiceDesk answer"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: scroll.bounds)
        textView.string = answer
        textView.isEditable = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        scroll.documentView = textView
        window.contentView?.addSubview(scroll)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        answerWindow = window
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "VoiceDesk"
        alert.informativeText = message
        alert.runModal()
    }

    private func speak(_ message: String) {
        voice.stopSpeaking(at: .immediate)
        voice.speak(AVSpeechUtterance(string: message))
    }

    private func spokenAnswer(_ answer: String) -> String {
        let withoutLinks = answer.replacingOccurrences(of: "https?://[^\\s)]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[#*`>]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if withoutLinks.count <= 350 { return "Done. " + withoutLinks }
        let excerpt = String(withoutLinks.prefix(350))
        let cut = excerpt.lastIndex(of: " ") ?? excerpt.endIndex
        return "Done. " + excerpt[..<cut] + ". The full answer is on screen."
    }
}

if CommandLine.arguments.contains("--self-test") {
    let tests: [(String, Bool, Command)] = [
        ("Open Safari", false, .openApp("Safari")),
        ("Find budget on my Mac", false, .findLocal("budget", false)),
        ("Find budget", false, .findLocal("budget", true)),
        ("Search the web for weather", false, .askWeb("weather")),
        ("Dictate hello there", false, .dictate("hello there")),
        ("Start dictation", false, .startDictation),
        ("Open Safari", true, .dictate("Open Safari")),
        ("Stop dictation", true, .stopDictation)
    ]
    for (input, dictating, expected) in tests {
        guard Command.parse(input, dictating: dictating) == expected else {
            fputs("Failed: \(input)\n", stderr)
            exit(1)
        }
    }
    print("Command routing: \(tests.count) checks passed")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

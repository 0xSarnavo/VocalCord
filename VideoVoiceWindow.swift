import AppKit
import AVFoundation

final class VideoVoiceWindowController: NSWindowController {
    private let scriptView = NSTextView()
    private let modeChoice = NSSegmentedControl(labels: ["Directed voiceover", "Compare styles"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeHelp = NSTextField(labelWithString: "Use directions in your script to shape each part.")
    private let modelChoice = NSPopUpButton()
    private let voiceChoice = NSPopUpButton()
    private var voiceIDs: [String] = []
    private let strengthSlider = NSSlider(value: 4, minValue: 1, maxValue: 6, target: nil, action: nil)
    private let strengthValue = NSTextField(labelWithString: "4.0")
    private let loudnessSlider = NSSlider(value: -16, minValue: -20, maxValue: -12, target: nil, action: nil)
    private let loudnessValue = NSTextField(labelWithString: "-16 LUFS")
    private let pauseSlider = NSSlider(value: 0.35, minValue: 0.2, maxValue: 1.2, target: nil, action: nil)
    private let pauseValue = NSTextField(labelWithString: "0.35 s")
    private let breathName = NSTextField(labelWithString: "No breath recorded")
    private let status = NSTextField(labelWithString: "Ready to render")
    private let renderButton = NSButton(title: "Render voiceover", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let resultsStack = NSStackView()
    private let resultsHint = NSTextField(labelWithString: "Your WAV files will appear here after rendering.")
    private var outputHeight: NSLayoutConstraint?
    private var breathURL: URL?
    private var breathRecorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var renderProcess: Process?
    private var timer: Timer?
    private var renderStarted = Date()
    private var cancelled = false
    private var results: [(String, URL)] = []

    private var projectURL: URL { Bundle.main.bundleURL.deletingLastPathComponent() }
    private var modelsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("voice/models") }
    private var outputFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/VocalCord", isDirectory: true) }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 870, height: 750),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "VocalCord · Video voiceover"
        window.minSize = NSSize(width: 830, height: 730)
        super.init(window: window)
        buildWindow()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        refreshVoices()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    private func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func card() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        return view
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        label(text, size: 15, weight: .semibold)
    }

    private func setting(_ name: String, value: NSTextField, slider: NSSlider) -> NSStackView {
        let heading = row([label(name, size: 12, weight: .medium), value])
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        heading.distribution = .fillProportionally
        slider.controlSize = .small
        slider.setAccessibilityLabel(name)
        let stack = column([heading, slider], spacing: 3)
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        slider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func buildWindow() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = label("Video voiceover", size: 27, weight: .bold)
        let subtitle = label("Write, direct, and hear your own voice.", size: 13, color: .secondaryLabelColor)
        let headerText = column([title, subtitle], spacing: 2)
        let localBadge = label("●  LOCAL · NO SIGN-IN", size: 11, weight: .semibold, color: .systemGreen)
        let header = row([headerText, localBadge])
        header.distribution = .equalSpacing

        modeChoice.selectedSegment = 0
        modeChoice.target = self
        modeChoice.action = #selector(modeChanged)
        modeChoice.setWidth(168, forSegment: 0)
        modeChoice.setWidth(145, forSegment: 1)
        modeHelp.textColor = .secondaryLabelColor
        modeHelp.font = .systemFont(ofSize: 12)
        let modeArea = column([modeChoice, modeHelp], spacing: 5)

        let editorCard = card()
        let editorTitle = sectionTitle("Script")
        let editorHint = label("Add a direction or a pause at the cursor.", size: 12, color: .secondaryLabelColor)
        let editorText = column([editorTitle, editorHint], spacing: 3)
        let moreStyles = NSPopUpButton()
        moreStyles.addItems(withTitles: ["More styles", "Angry", "Soft", "Slow", "Hesitant"])
        moreStyles.target = self
        moreStyles.action = #selector(insertMoreStyle(_:))
        let editorHeader = row([editorText, moreStyles])
        editorHeader.distribution = .equalSpacing
        let tokenTitles = ["Neutral", "Confident", "Sad", "Happy", "Pause", "Breath", "Sigh"]
        let tokenButtons = tokenTitles.enumerated().map { index, title -> NSButton in
            let button = NSButton(title: title, target: self, action: #selector(insertToken(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.toolTip = "Insert \(title.lowercased()) at the cursor"
            return button
        }
        let tokenRow = row(tokenButtons, spacing: 6)
        let editorScroll = NSScrollView()
        editorScroll.hasVerticalScroller = true
        editorScroll.borderType = .noBorder
        editorScroll.wantsLayer = true
        editorScroll.layer?.cornerRadius = 9
        scriptView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        scriptView.textContainerInset = NSSize(width: 13, height: 12)
        scriptView.isRichText = false
        scriptView.isAutomaticQuoteSubstitutionEnabled = false
        scriptView.isAutomaticDashSubstitutionEnabled = false
        scriptView.setAccessibilityLabel("Video script")
        scriptView.string = "[neutral] Welcome to my video.\n[pause 0.35]\n[confident] Here is what I learned."
        editorScroll.documentView = scriptView
        let editorLayout = column([editorHeader, tokenRow, editorScroll], spacing: 12)
        editorLayout.translatesAutoresizingMaskIntoConstraints = false
        editorCard.addSubview(editorLayout)
        NSLayoutConstraint.activate([
            editorLayout.leadingAnchor.constraint(equalTo: editorCard.leadingAnchor, constant: 18),
            editorLayout.trailingAnchor.constraint(equalTo: editorCard.trailingAnchor, constant: -18),
            editorLayout.topAnchor.constraint(equalTo: editorCard.topAnchor, constant: 17),
            editorLayout.bottomAnchor.constraint(equalTo: editorCard.bottomAnchor, constant: -18),
            editorScroll.widthAnchor.constraint(equalTo: editorLayout.widthAnchor),
            editorScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 205),
        ])

        let settingsCard = card()
        let settingsTitle = sectionTitle("Voice settings")
        let sampleRow = row([label("Voice", size: 12, weight: .medium), NSButton(title: "Play sample", target: self, action: #selector(playOriginal))])
        sampleRow.distribution = .equalSpacing
        voiceChoice.setAccessibilityLabel("Saved voice")
        let voiceSection = column([sampleRow, voiceChoice], spacing: 4)
        refreshVoices()
        modelChoice.addItems(withTitles: ["Breeze 8-bit · best quality", "Breeze 4-bit · faster"])
        modelChoice.setAccessibilityLabel("Voice model")
        let eightBitURL = modelsURL.appendingPathComponent("Breeze-TTS-2-mlx-8bit/model.safetensors")
        if !FileManager.default.fileExists(atPath: eightBitURL.path) { modelChoice.selectItem(at: 1) }
        let modelLabel = label("Model", size: 12, weight: .medium)
        let modelSection = column([modelLabel, modelChoice], spacing: 4)
        strengthSlider.target = self
        strengthSlider.action = #selector(slidersChanged)
        loudnessSlider.target = self
        loudnessSlider.action = #selector(slidersChanged)
        pauseSlider.target = self
        pauseSlider.action = #selector(slidersChanged)
        let strengthSetting = setting("Direction strength", value: strengthValue, slider: strengthSlider)
        let loudnessSetting = setting("Output loudness", value: loudnessValue, slider: loudnessSlider)
        let pauseSetting = setting("Pause button length", value: pauseValue, slider: pauseSlider)
        let breathLabel = label("Natural breath", size: 12, weight: .medium)
        let recordBreath = NSButton(title: "Record", target: self, action: #selector(recordBreath))
        let chooseBreath = NSButton(title: "Import WAV", target: self, action: #selector(chooseBreath))
        breathName.font = .systemFont(ofSize: 11)
        breathName.textColor = .secondaryLabelColor
        breathName.lineBreakMode = .byTruncatingMiddle
        let breathSection = column([breathLabel, row([recordBreath, chooseBreath], spacing: 6), breathName], spacing: 4)
        let settingsLayout = column([settingsTitle, voiceSection, modelSection, strengthSetting, loudnessSetting, pauseSetting, breathSection], spacing: 8)
        settingsLayout.translatesAutoresizingMaskIntoConstraints = false
        settingsCard.addSubview(settingsLayout)
        for view in [voiceSection, modelSection, strengthSetting, loudnessSetting, pauseSetting, breathSection] {
            view.widthAnchor.constraint(equalTo: settingsLayout.widthAnchor).isActive = true
        }
        sampleRow.widthAnchor.constraint(equalTo: voiceSection.widthAnchor).isActive = true
        voiceChoice.widthAnchor.constraint(equalTo: voiceSection.widthAnchor).isActive = true
        modelChoice.widthAnchor.constraint(equalTo: modelSection.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            settingsLayout.leadingAnchor.constraint(equalTo: settingsCard.leadingAnchor, constant: 18),
            settingsLayout.trailingAnchor.constraint(equalTo: settingsCard.trailingAnchor, constant: -18),
            settingsLayout.topAnchor.constraint(equalTo: settingsCard.topAnchor, constant: 17),
            settingsLayout.bottomAnchor.constraint(lessThanOrEqualTo: settingsCard.bottomAnchor, constant: -14),
        ])

        let workspace = row([editorCard, settingsCard], spacing: 14)
        workspace.alignment = .top
        settingsCard.widthAnchor.constraint(equalToConstant: 260).isActive = true
        editorCard.heightAnchor.constraint(equalToConstant: 397).isActive = true
        settingsCard.heightAnchor.constraint(equalToConstant: 397).isActive = true

        let outputCard = card()
        let outputTitle = sectionTitle("Results")
        let outputHint = label("Saved in Movies / VocalCord", size: 12, color: .secondaryLabelColor)
        let outputHeading = column([outputTitle, outputHint], spacing: 2)
        renderButton.bezelStyle = .rounded
        renderButton.keyEquivalent = "\r"
        renderButton.target = self
        renderButton.action = #selector(render)
        cancelButton.target = self
        cancelButton.action = #selector(cancelRender)
        cancelButton.isHidden = true
        let outputHeader = row([outputHeading, cancelButton, renderButton])
        outputHeader.distribution = .equalSpacing
        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 4
        resultsHint.textColor = .secondaryLabelColor
        resultsHint.font = .systemFont(ofSize: 12)
        resultsStack.addArrangedSubview(resultsHint)
        let outputLayout = column([outputHeader, resultsStack], spacing: 12)
        outputLayout.translatesAutoresizingMaskIntoConstraints = false
        outputCard.addSubview(outputLayout)
        outputHeight = outputCard.heightAnchor.constraint(equalToConstant: 140)
        outputHeight?.isActive = true
        NSLayoutConstraint.activate([
            outputLayout.leadingAnchor.constraint(equalTo: outputCard.leadingAnchor, constant: 18),
            outputLayout.trailingAnchor.constraint(equalTo: outputCard.trailingAnchor, constant: -18),
            outputLayout.topAnchor.constraint(equalTo: outputCard.topAnchor, constant: 15),
            outputLayout.bottomAnchor.constraint(lessThanOrEqualTo: outputCard.bottomAnchor, constant: -12),
            outputHeader.widthAnchor.constraint(equalTo: outputLayout.widthAnchor),
            resultsStack.widthAnchor.constraint(equalTo: outputLayout.widthAnchor),
        ])

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let root = column([header, modeArea, workspace, outputCard, status], spacing: 13)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            modeArea.widthAnchor.constraint(equalTo: root.widthAnchor),
            workspace.widthAnchor.constraint(equalTo: root.widthAnchor),
            editorCard.widthAnchor.constraint(equalTo: workspace.widthAnchor, constant: -274),
            outputCard.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    @objc private func modeChanged() {
        let compare = modeChoice.selectedSegment == 1
        modeHelp.stringValue = compare
            ? "Hear the same script in four styles. Direction tags are replaced; pauses and breaths stay."
            : "Use directions in your script to shape each part."
        renderButton.title = compare ? "Render four styles" : "Render voiceover"
    }

    @objc private func slidersChanged() {
        strengthValue.stringValue = String(format: "%.1f", strengthSlider.doubleValue)
        loudnessValue.stringValue = "\(Int(loudnessSlider.doubleValue.rounded())) LUFS"
        pauseValue.stringValue = String(format: "%.2f s", (pauseSlider.doubleValue * 20).rounded() / 20)
    }

    @objc private func insertToken(_ sender: NSButton) {
        let pause = (pauseSlider.doubleValue * 20).rounded() / 20
        let tokens = ["[neutral] ", "[confident] ", "[sad] ", "[happy] ", String(format: " [pause %.2f] ", pause), " [breath] ", "(sigh) "]
        scriptView.insertText(tokens[sender.tag], replacementRange: scriptView.selectedRange())
        window?.makeFirstResponder(scriptView)
    }

    @objc private func insertMoreStyle(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0 else { return }
        let style = sender.titleOfSelectedItem?.lowercased() ?? "neutral"
        scriptView.insertText("[\(style)] ", replacementRange: scriptView.selectedRange())
        sender.selectItem(at: 0)
        window?.makeFirstResponder(scriptView)
    }

    private func refreshVoices() {
        let previous = voiceChoice.indexOfSelectedItem >= 0 && voiceChoice.indexOfSelectedItem < voiceIDs.count
            ? voiceIDs[voiceChoice.indexOfSelectedItem] : nil
        voiceIDs = VoiceLibraryStore.shared.profiles.map(\.id)
        voiceChoice.removeAllItems()
        voiceChoice.addItems(withTitles: VoiceLibraryStore.shared.profiles.map(\.name))
        if let previous, let index = voiceIDs.firstIndex(of: previous) { voiceChoice.selectItem(at: index) }
        else if !voiceIDs.isEmpty { voiceChoice.selectItem(at: 0) }
    }

    @objc private func playOriginal() {
        guard voiceIDs.indices.contains(voiceChoice.indexOfSelectedItem),
              let profile = VoiceLibraryStore.shared.profiles.first(where: { $0.id == voiceIDs[voiceChoice.indexOfSelectedItem] }),
              let take = profile.currentTake else { return }
        playURL(VoiceLibraryStore.shared.takeURL(take))
    }

    @objc private func chooseBreath() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.message = "Choose a short, clean recording of your inhale (0.05–2 seconds)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        breathURL = url
        breathName.stringValue = url.lastPathComponent
    }

    @objc private func recordBreath() {
        let alert = NSAlert()
        alert.messageText = "Record a breath"
        alert.informativeText = "Take one natural inhale after you click Start. Recording lasts 1.2 seconds."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else { self.showError("Allow microphone access in System Settings, then try again."); return }
                do {
                    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("VocalCord", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("breath-\(UUID().uuidString).wav")
                    let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM),
                                                   AVSampleRateKey: 24000,
                                                   AVNumberOfChannelsKey: 1,
                                                   AVLinearPCMBitDepthKey: 16,
                                                   AVLinearPCMIsFloatKey: false]
                    let recorder = try AVAudioRecorder(url: url, settings: settings)
                    recorder.prepareToRecord()
                    guard recorder.record(forDuration: 1.2) else { self.showError("Could not start recording. Try again."); return }
                    self.breathRecorder = recorder
                    self.status.stringValue = "Recording a breath…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                        recorder.stop()
                        self?.breathRecorder = nil
                        self?.breathURL = url
                        self?.breathName.stringValue = "Your recorded breath"
                        self?.status.stringValue = "Breath ready. Add it with the Breath button."
                    }
                } catch { self.showError("Could not record a breath: \(error.localizedDescription)") }
            }
        }
    }

    private func showError(_ message: String) {
        status.stringValue = message
        let alert = NSAlert()
        alert.messageText = "Video voiceover"
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) }
    }

    @objc private func render() {
        guard renderProcess == nil else { return }
        let script = scriptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { showError("Enter a script first."); return }
        refreshVoices()
        guard voiceIDs.indices.contains(voiceChoice.indexOfSelectedItem),
              let profile = VoiceLibraryStore.shared.profiles.first(where: { $0.id == voiceIDs[voiceChoice.indexOfSelectedItem] }),
              let reference = profile.currentTake else {
            showError("Create a voice in Voice library first.")
            return
        }
        if script.range(of: "[breath]", options: .caseInsensitive) != nil && breathURL == nil {
            showError("Record or import a breath before rendering the [breath] tag.")
            return
        }
        let modelName = modelChoice.indexOfSelectedItem == 0 ? "Breeze-TTS-2-mlx-8bit" : "Breeze-TTS-2-mlx-4bit"
        let modelURL = modelsURL.appendingPathComponent(modelName)
        guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("model.safetensors").path) else {
            showError("\(modelName) is not downloaded yet.")
            return
        }
        let compare = modeChoice.selectedSegment == 1
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let destination = outputFolder.appendingPathComponent("Breeze-TTS-2-\(modelChoice.indexOfSelectedItem == 0 ? "8bit" : "4bit")-\(stamp).wav")
        do { try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true) }
        catch { showError("Could not create the output folder: \(error.localizedDescription)"); return }
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("vocalcord-\(UUID().uuidString).txt")
        let referenceTextURL = FileManager.default.temporaryDirectory.appendingPathComponent("vocalcord-ref-\(UUID().uuidString).txt")
        let referenceMapURL = FileManager.default.temporaryDirectory.appendingPathComponent("vocalcord-map-\(UUID().uuidString).json")
        let temporary = [scriptURL, referenceTextURL, referenceMapURL]
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try reference.transcript.write(to: referenceTextURL, atomically: true, encoding: .utf8)
            let map = VoiceLibraryStore.shared.referenceMap(for: profile)
            try JSONSerialization.data(withJSONObject: map).write(to: referenceMapURL, options: .atomic)
        }
        catch { showError("Could not prepare the script: \(error.localizedDescription)"); return }
        let process = Process()
        process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("voice/venv/bin/python")
        process.currentDirectoryURL = projectURL
        process.arguments = [projectURL.appendingPathComponent("directed_voice.py").path,
                             "--script", scriptURL.path,
                             "--reference", VoiceLibraryStore.shared.takeURL(reference).path,
                             "--reference-text-file", referenceTextURL.path,
                             "--reference-map", referenceMapURL.path,
                             "--model", modelURL.path,
                             "--output", destination.path,
                             "--cfg-scale", String(format: "%.1f", strengthSlider.doubleValue),
                             "--lufs", String(Int(loudnessSlider.doubleValue.rounded()))]
        if compare { process.arguments! += ["--all-styles"] }
        if let breathURL { process.arguments! += ["--breath-audio", breathURL.path] }
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        renderProcess = process
        cancelled = false
        renderButton.isEnabled = false
        cancelButton.isHidden = false
        renderStarted = Date()
        status.stringValue = "Loading \(modelName)…"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.status.stringValue = "Rendering \(compare ? "four styles" : "voiceover")… \(Int(Date().timeIntervalSince(self.renderStarted))) s"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try process.run()
                let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                DispatchQueue.main.async {
                    self?.finishRender(succeeded: process.terminationStatus == 0, destination: destination, compare: compare, temporary: temporary, log: log)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishRender(succeeded: false, destination: destination, compare: compare, temporary: temporary, log: error.localizedDescription)
                }
            }
        }
    }

    @objc private func cancelRender() {
        cancelled = true
        renderProcess?.terminate()
        status.stringValue = "Stopping render…"
    }

    private func finishRender(succeeded: Bool, destination: URL, compare: Bool, temporary: [URL], log: String) {
        timer?.invalidate()
        timer = nil
        renderProcess = nil
        renderButton.isEnabled = true
        cancelButton.isHidden = true
        temporary.forEach { try? FileManager.default.removeItem(at: $0) }
        if cancelled {
            status.stringValue = "Render stopped. Completed files, if any, are in Movies / VocalCord."
            return
        }
        if succeeded {
            let names = compare ? ["Neutral", "Confident", "Sad", "Happy"] : ["Directed voiceover"]
            results = names.map { name in
                let url = compare ? destination.deletingLastPathComponent().appendingPathComponent("\(destination.deletingPathExtension().lastPathComponent)-\(name.lowercased()).wav") : destination
                return (name, url)
            }.filter { FileManager.default.fileExists(atPath: $0.1.path) }
            guard !results.isEmpty else { showError("The render finished without a WAV file. Check the output folder."); return }
            showResults()
            status.stringValue = "Done in \(Int(Date().timeIntervalSince(renderStarted))) s · \(results.count) WAV \(results.count == 1 ? "file" : "files") saved"
            NSSound.beep()
            window?.makeKeyAndOrderFront(nil)
        } else {
            showError("Render failed: \(log.suffix(600))")
        }
    }

    private func showResults() {
        let needsTallResults = results.count > 1
        outputHeight?.constant = needsTallResults ? 205 : 140
        window?.minSize = NSSize(width: 830, height: needsTallResults ? 800 : 730)
        window?.setContentSize(NSSize(width: window?.contentView?.bounds.width ?? 870,
                                      height: needsTallResults ? 810 : 750))
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, result) in results.enumerated() {
            let play = NSButton(title: "Play", target: self, action: #selector(playResult(_:)))
            play.tag = index
            play.toolTip = "Play \(result.0.lowercased())"
            let show = NSButton(title: "Show", target: self, action: #selector(revealResult(_:)))
            show.tag = index
            show.toolTip = "Show \(result.0.lowercased()) in Finder"
            let name = label(result.0, size: 12, weight: .medium)
            let file = label(result.1.lastPathComponent, size: 11, color: .secondaryLabelColor)
            file.lineBreakMode = .byTruncatingMiddle
            let text = column([name, file], spacing: 1)
            let line = row([text, play, show], spacing: 8)
            line.distribution = .fill
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            resultsStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        }
    }

    private func playURL(_ url: URL) {
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch { showError("Could not play the WAV file: \(error.localizedDescription)") }
    }

    @objc private func playResult(_ sender: NSButton) {
        guard results.indices.contains(sender.tag) else { return }
        playURL(results[sender.tag].1)
    }

    @objc private func revealResult(_ sender: NSButton) {
        guard results.indices.contains(sender.tag) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([results[sender.tag].1])
    }
}

import AppKit
import AVFoundation
import UniformTypeIdentifiers

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class VoiceWaveformView: NSView {
    var levels: [CGFloat] = [] { didSet { needsDisplay = true } }

    func load(_ url: URL) {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            levels = []; return
        }
        do { try file.read(into: buffer) } catch { levels = []; return }
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { levels = []; return }
        let count = Int(buffer.frameLength)
        levels = (0..<82).map { bin in
            let start = bin * count / 82
            let end = min(count, (bin + 1) * count / 82)
            var peak: Float = 0
            if start < end { for index in start..<end { peak = max(peak, abs(samples[index])) } }
            return CGFloat(max(0.12, min(1, peak * 2.8)))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.03, green: 0.06, blue: 0.065, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        guard !levels.isEmpty else { return }
        let width = bounds.width / CGFloat(levels.count)
        for (index, level) in levels.enumerated() {
            let height = 6 + level * (bounds.height - 20)
            let rect = NSRect(x: CGFloat(index) * width + 2, y: (bounds.height - height) / 2,
                              width: max(2, width - 2), height: height)
            (index < levels.count * 2 / 3 ? NSColor(calibratedRed: 0.66, green: 0.87, blue: 0.80, alpha: 0.92)
                                            : NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.42, alpha: 0.9)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}

final class VoiceLibraryWindowController: NSWindowController {
    private let store = VoiceLibraryStore.shared
    private let onOpenVoiceover: () -> Void
    private var selectedProfileID: String?
    private var selectedTakeID: String?
    private let profileStack = NSStackView()
    private let takesStack = NSStackView()
    private let takesDocument = FlippedView()
    private let profileTitle = NSTextField(labelWithString: "My voice")
    private let referenceName = NSTextField(labelWithString: "")
    private let referenceDetail = NSTextField(labelWithString: "")
    private let transcriptText = NSTextField(labelWithString: "")
    private let waveform = VoiceWaveformView()
    private let compareLine = NSTextField(string: "Welcome back to the studio.")
    private let status = NSTextField(labelWithString: "")
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let cleanButton = NSButton(title: "Make cleaned copy", target: nil, action: nil)
    private let compareButton = NSButton(title: "Generate comparison", target: nil, action: nil)
    private let playCurrentButton = NSButton(title: "▶ Current", target: nil, action: nil)
    private let playNewButton = NSButton(title: "▶ New take", target: nil, action: nil)
    private var styleButtons: [NSButton] = []
    private var player: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingNewVoice = false
    private var renderProcess: Process?
    private var renderStarted = Date()
    private var timer: Timer?
    private var currentPreviewURL: URL?
    private var newPreviewURL: URL?

    private var selectedProfile: VoiceProfile? { store.profiles.first { $0.id == selectedProfileID } }
    private var selectedTake: VoiceTake? { selectedProfile?.takes.first { $0.id == selectedTakeID } }
    private var projectURL: URL { Bundle.main.bundleURL.deletingLastPathComponent() }

    init(onOpenVoiceover: @escaping () -> Void) {
        self.onOpenVoiceover = onOpenVoiceover
        selectedProfileID = store.profiles.first?.id
        selectedTakeID = store.profiles.first?.currentTakeID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 580),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "VoiceDesk · Voice library"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 1000, height: 560)
        window.maxSize = NSSize(width: 1250, height: 900)
        super.init(window: window)
        buildWindow()
        refresh()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func glass() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        return view
    }

    private func padded(_ content: NSView, in card: NSView, inset: CGFloat = 16) {
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            content.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -inset),
        ])
    }

    private func buildWindow() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.045, green: 0.061, blue: 0.066, alpha: 1).cgColor

        let brand = label("≋  VoiceDesk", size: 15, weight: .bold)
        let videoTab = NSButton(title: "Video voiceover", target: self, action: #selector(openVoiceover))
        let local = label("●  PRIVATE ON THIS MAC", size: 10, weight: .semibold,
                          color: NSColor(calibratedRed: 0.64, green: 0.86, blue: 0.77, alpha: 1))
        let header = row([brand, videoTab, NSView(), local], spacing: 13)
        header.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 34),
        ])
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9),
        ])

        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: separator.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 185),
        ])
        let sidebarTitle = label("VOICES", size: 10, weight: .semibold, color: .secondaryLabelColor)
        let newVoiceButton = NSButton(title: "+  New voice", target: self, action: #selector(newVoice))
        newVoiceButton.alignment = .left
        profileStack.orientation = .vertical
        profileStack.alignment = .leading
        profileStack.spacing = 7
        let sidebarLayout = column([sidebarTitle, profileStack, newVoiceButton], spacing: 14)
        sidebarLayout.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarLayout)
        NSLayoutConstraint.activate([
            sidebarLayout.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarLayout.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            sidebarLayout.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 22),
            profileStack.widthAnchor.constraint(equalTo: sidebarLayout.widthAnchor),
            newVoiceButton.widthAnchor.constraint(equalTo: sidebarLayout.widthAnchor),
        ])

        profileTitle.font = .systemFont(ofSize: 26, weight: .bold)
        let renameButton = NSButton(title: "Rename", target: self, action: #selector(renameVoice))
        let heading = row([profileTitle, renameButton])
        heading.distribution = .equalSpacing

        let referenceCard = glass()
        let referenceEyebrow = label("CURRENT REFERENCE", size: 10, weight: .semibold, color: .secondaryLabelColor)
        referenceName.font = .systemFont(ofSize: 15, weight: .semibold)
        referenceDetail.font = .systemFont(ofSize: 11)
        referenceDetail.textColor = .secondaryLabelColor
        let referenceText = column([referenceName, referenceDetail], spacing: 3)
        let editWords = NSButton(title: "Edit words", target: self, action: #selector(editTranscript))
        let playReference = NSButton(title: "▶ Play original", target: self, action: #selector(playReference))
        let referenceHead = row([referenceText, row([editWords, playReference], spacing: 5)])
        referenceHead.distribution = .equalSpacing
        waveform.wantsLayer = true
        waveform.layer?.cornerRadius = 9
        waveform.heightAnchor.constraint(equalToConstant: 76).isActive = true
        transcriptText.font = .systemFont(ofSize: 11)
        transcriptText.textColor = .secondaryLabelColor
        transcriptText.maximumNumberOfLines = 3
        transcriptText.preferredMaxLayoutWidth = 530
        transcriptText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        referenceText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let transcriptLabel = label("EXACT TRANSCRIPT", size: 10, weight: .semibold, color: .secondaryLabelColor)
        let referenceLayout = column([referenceEyebrow, referenceHead, waveform, transcriptLabel, transcriptText], spacing: 10)
        padded(referenceLayout, in: referenceCard)
        referenceHead.widthAnchor.constraint(equalTo: referenceLayout.widthAnchor).isActive = true
        waveform.widthAnchor.constraint(equalTo: referenceLayout.widthAnchor).isActive = true
        transcriptText.widthAnchor.constraint(equalTo: referenceLayout.widthAnchor).isActive = true
        referenceCard.heightAnchor.constraint(equalToConstant: 225).isActive = true

        let takesCard = glass()
        let takeHeading = label("Takes", size: 14, weight: .semibold)
        takesStack.orientation = .vertical
        takesStack.alignment = .leading
        takesStack.spacing = 7
        takesStack.translatesAutoresizingMaskIntoConstraints = false
        takesDocument.frame = NSRect(x: 0, y: 0, width: 400, height: 110)
        takesDocument.addSubview(takesStack)
        NSLayoutConstraint.activate([
            takesStack.leadingAnchor.constraint(equalTo: takesDocument.leadingAnchor),
            takesStack.trailingAnchor.constraint(equalTo: takesDocument.trailingAnchor),
            takesStack.topAnchor.constraint(equalTo: takesDocument.topAnchor),
        ])
        let takesScroll = NSScrollView()
        takesScroll.hasVerticalScroller = true
        takesScroll.autohidesScrollers = true
        takesScroll.drawsBackground = false
        takesScroll.documentView = takesDocument
        let takeLayout = column([takeHeading, takesScroll], spacing: 10)
        padded(takeLayout, in: takesCard)
        takesScroll.widthAnchor.constraint(equalTo: takeLayout.widthAnchor).isActive = true
        takesScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        takesCard.heightAnchor.constraint(equalToConstant: 173).isActive = true
        let leftColumn = column([referenceCard, takesCard], spacing: 12)
        referenceCard.widthAnchor.constraint(equalTo: leftColumn.widthAnchor).isActive = true
        takesCard.widthAnchor.constraint(equalTo: leftColumn.widthAnchor).isActive = true

        let refineCard = glass()
        let refineTitle = label("Add and compare", size: 15, weight: .semibold)
        let addLabel = label("Add a take", size: 12, weight: .semibold)
        recordButton.target = self
        recordButton.action = #selector(recordTake)
        let importButton = NSButton(title: "Import audio", target: self, action: #selector(addTake))
        let importRow = row([recordButton, importButton], spacing: 6)
        importRow.distribution = .fillEqually
        cleanButton.target = self
        cleanButton.action = #selector(cleanSelected)
        cleanButton.toolTip = "Remove noise and normalize volume in a separate copy."
        let tagLabel = label("Speaking style", size: 12, weight: .semibold)
        let styleRows = [Array(VoiceLibraryStore.styles.prefix(3)),
                         Array(VoiceLibraryStore.styles.dropFirst(3).prefix(3)),
                         Array(VoiceLibraryStore.styles.suffix(2))].map { titles -> NSStackView in
            let buttons = titles.map { style -> NSButton in
                let button = NSButton(title: style, target: self, action: #selector(styleClicked(_:)))
                button.tag = VoiceLibraryStore.styles.firstIndex(of: style) ?? 0
                button.bezelStyle = .rounded
                button.font = .systemFont(ofSize: 10)
                styleButtons.append(button)
                return button
            }
            return row(buttons, spacing: 4)
        }
        let compareLabel = label("Compare takes", size: 12, weight: .semibold)
        compareLine.font = .systemFont(ofSize: 11)
        compareLine.placeholderString = "Type one short test line"
        compareLine.setAccessibilityLabel("Comparison test line")
        compareButton.target = self
        compareButton.action = #selector(compare)
        compareButton.bezelStyle = .rounded
        compareButton.contentTintColor = NSColor(calibratedRed: 0.73, green: 0.91, blue: 0.83, alpha: 1)
        playCurrentButton.target = self
        playCurrentButton.action = #selector(playCurrentPreview)
        playNewButton.target = self
        playNewButton.action = #selector(playNewPreview)
        playCurrentButton.isEnabled = false
        playNewButton.isEnabled = false
        let previewRow = row([playCurrentButton, playNewButton], spacing: 6)
        previewRow.distribution = .fillEqually
        let refineLayout = column([refineTitle, addLabel, importRow, cleanButton,
                                   tagLabel, styleRows[0], styleRows[1], styleRows[2], compareLabel,
                                   compareLine, compareButton, previewRow], spacing: 8)
        padded(refineLayout, in: refineCard, inset: 14)
        for view in [importRow, cleanButton, compareLine, compareButton, previewRow] {
            view.widthAnchor.constraint(equalTo: refineLayout.widthAnchor).isActive = true
        }
        refineCard.heightAnchor.constraint(equalToConstant: 403).isActive = true

        let workArea = row([leftColumn, refineCard], spacing: 12)
        workArea.alignment = .top
        refineCard.widthAnchor.constraint(equalToConstant: 255).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let mainLayout = column([heading, workArea, status], spacing: 12)
        mainLayout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainLayout)
        NSLayoutConstraint.activate([
            mainLayout.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 18),
            mainLayout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            mainLayout.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 17),
            heading.widthAnchor.constraint(equalTo: mainLayout.widthAnchor),
            workArea.widthAnchor.constraint(equalTo: mainLayout.widthAnchor),
            leftColumn.widthAnchor.constraint(equalTo: workArea.widthAnchor, constant: -267),
            status.widthAnchor.constraint(equalTo: mainLayout.widthAnchor),
        ])
    }

    private func replaceViews(in stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }

    private func refresh() {
        if selectedProfile == nil { selectedProfileID = store.profiles.first?.id }
        if selectedTake == nil { selectedTakeID = selectedProfile?.currentTakeID }
        replaceViews(in: profileStack)
        for (index, profile) in store.profiles.enumerated() {
            let button = NSButton(title: "≋  \(profile.name)", target: self, action: #selector(selectProfile(_:)))
            button.tag = index
            button.toolTip = "\(profile.takes.count) \(profile.takes.count == 1 ? "take" : "takes")"
            button.alignment = .left
            button.font = .systemFont(ofSize: 11, weight: profile.id == selectedProfileID ? .semibold : .regular)
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.layer?.backgroundColor = profile.id == selectedProfileID ? NSColor.white.withAlphaComponent(0.11).cgColor : NSColor.clear.cgColor
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            profileStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: profileStack.widthAnchor).isActive = true
        }
        guard let profile = selectedProfile else {
            profileTitle.stringValue = "Your voice library"
            referenceName.stringValue = "No voice yet"
            referenceDetail.stringValue = "Record or import a clean sample to begin."
            transcriptText.stringValue = ""
            waveform.levels = []
            replaceViews(in: takesStack)
            return
        }
        profileTitle.stringValue = profile.name
        if let current = profile.currentTake {
            referenceName.stringValue = current.name
            let audio = store.takeURL(current)
            let duration = (try? AVAudioFile(forReading: audio)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            referenceDetail.stringValue = String(format: "Original recording · %.1f seconds · %@", duration, current.style)
            transcriptText.stringValue = "“\(current.transcript)”"
            waveform.load(audio)
        }
        replaceViews(in: takesStack)
        for (index, take) in profile.takes.enumerated() {
            let selected = take.id == selectedTakeID
            let play = NSButton(title: "▶", target: self, action: #selector(playTake(_:)))
            play.tag = index
            play.toolTip = "Play \(take.name)"
            let select = NSButton(title: "\(take.name) · \(take.style)", target: self, action: #selector(selectTake(_:)))
            select.tag = index
            select.alignment = .left
            select.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
            let use = NSButton(title: take.id == profile.currentTakeID ? "Current" : "Use", target: self, action: #selector(makeCurrent(_:)))
            use.tag = index
            use.isEnabled = take.id != profile.currentTakeID
            let line = row([play, select, use], spacing: 5)
            select.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            takesStack.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: takesStack.widthAnchor).isActive = true
        }
        takesDocument.setFrameSize(NSSize(width: takesCardWidth(), height: CGFloat(max(110, profile.takes.count * 35))))
        for button in styleButtons { button.state = VoiceLibraryStore.styles[button.tag] == selectedTake?.style ? .on : .off }
        cleanButton.isEnabled = selectedTake != nil
        compareButton.isEnabled = selectedTakeID != profile.currentTakeID && renderProcess == nil
    }

    private func takesCardWidth() -> CGFloat {
        max(300, window?.contentView?.bounds.width ?? 1120) - 185 - 36 - 255 - 12 - 32
    }

    private func showError(_ message: String) {
        status.stringValue = message
        let alert = NSAlert()
        alert.messageText = "Voice library"
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) }
    }

    private func promptDetails(newVoice: Bool, suggestedName: String) -> (String, String)? {
        let alert = NSAlert()
        alert.messageText = newVoice ? "Create a voice" : "Add a voice take"
        alert.informativeText = "Enter the exact words spoken in the recording. This helps Breeze match your voice."
        alert.addButton(withTitle: "Add recording")
        alert.addButton(withTitle: "Cancel")
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: newVoice ? 151 : 111))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 115, width: 440, height: 24))
        nameField.stringValue = suggestedName
        if newVoice {
            let nameLabel = label("VOICE NAME", size: 10, weight: .semibold, color: .secondaryLabelColor)
            nameLabel.frame = NSRect(x: 0, y: 140, width: 440, height: 12)
            form.addSubview(nameLabel)
            form.addSubview(nameField)
        }
        let transcriptField = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 85))
        transcriptField.font = .systemFont(ofSize: 12)
        transcriptField.isRichText = false
        let transcriptScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 88))
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.documentView = transcriptField
        let transcriptLabel = label("EXACT TRANSCRIPT", size: 10, weight: .semibold, color: .secondaryLabelColor)
        transcriptLabel.frame = NSRect(x: 0, y: 95, width: 440, height: 12)
        form.addSubview(transcriptLabel)
        form.addSubview(transcriptScroll)
        alert.accessoryView = form
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = transcriptField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty, !name.isEmpty else { showError("Enter a voice name and the exact transcript."); return nil }
        return (name, transcript)
    }

    private func importRecording(newVoice: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a clean recording of your own voice (3–60 seconds)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let details = promptDetails(newVoice: newVoice, suggestedName: newVoice ? "New voice" : url.deletingPathExtension().lastPathComponent) else { return }
        do {
            if newVoice {
                selectedProfileID = try store.addVoice(name: details.0, source: url, transcript: details.1, style: "Neutral")
                selectedTakeID = selectedProfile?.currentTakeID
            } else if let profileID = selectedProfileID {
                selectedTakeID = try store.addTake(profileID: profileID, source: url, transcript: details.1, style: "Neutral")
            }
            currentPreviewURL = nil; newPreviewURL = nil
            playCurrentButton.isEnabled = false; playNewButton.isEnabled = false
            refresh()
            status.stringValue = "Recording added. Select its speaking style, then compare it."
        } catch { showError(error.localizedDescription) }
    }

    @objc private func newVoice() {
        let alert = NSAlert()
        alert.messageText = "Create a new voice"
        alert.informativeText = "Start with a clean recording of your own voice."
        alert.addButton(withTitle: "Record now")
        alert.addButton(withTitle: "Import audio")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            recordingNewVoice = true
            recordTake()
        case .alertSecondButtonReturn: importRecording(newVoice: true)
        default: break
        }
    }
    @objc private func addTake() { importRecording(newVoice: selectedProfile == nil) }
    @objc private func openVoiceover() { onOpenVoiceover() }

    @objc private func selectProfile(_ sender: NSButton) {
        guard store.profiles.indices.contains(sender.tag) else { return }
        selectedProfileID = store.profiles[sender.tag].id
        selectedTakeID = store.profiles[sender.tag].currentTakeID
        clearPreviews()
        refresh()
    }

    @objc private func selectTake(_ sender: NSButton) {
        guard let profile = selectedProfile, profile.takes.indices.contains(sender.tag) else { return }
        selectedTakeID = profile.takes[sender.tag].id
        clearPreviews()
        refresh()
    }

    @objc private func makeCurrent(_ sender: NSButton) {
        guard let profile = selectedProfile, profile.takes.indices.contains(sender.tag) else { return }
        do {
            try store.makeCurrent(profileID: profile.id, takeID: profile.takes[sender.tag].id)
            selectedTakeID = profile.takes[sender.tag].id
            clearPreviews()
            refresh()
            status.stringValue = "Current reference updated. Video voiceover will use this take."
        } catch { showError(error.localizedDescription) }
    }

    @objc private func renameVoice() {
        guard let profile = selectedProfile else { return }
        let alert = NSAlert()
        alert.messageText = "Rename voice"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = profile.name
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { showError("Enter a voice name."); return }
        do { try store.rename(profileID: profile.id, name: name); refresh() }
        catch { showError(error.localizedDescription) }
    }

    @objc private func editTranscript() {
        guard let profile = selectedProfile, let take = profile.currentTake else { return }
        let alert = NSAlert()
        alert.messageText = "Edit exact transcript"
        alert.informativeText = "Write only the words spoken in this recording. Include repeats and fillers."
        alert.addButton(withTitle: "Save words")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 88))
        field.font = .systemFont(ofSize: 12)
        field.isRichText = false
        field.string = take.transcript
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 90))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = field
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let words = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { showError("Enter the words spoken in the recording."); return }
        do { try store.setTranscript(profileID: profile.id, takeID: take.id, transcript: words); refresh() }
        catch { showError(error.localizedDescription) }
    }

    @objc private func styleClicked(_ sender: NSButton) {
        guard let profile = selectedProfile, let take = selectedTake else { return }
        do {
            try store.setStyle(profileID: profile.id, takeID: take.id, style: VoiceLibraryStore.styles[sender.tag])
            refresh()
            status.stringValue = "Labeled \(take.name) as \(VoiceLibraryStore.styles[sender.tag].lowercased())."
        } catch { showError(error.localizedDescription) }
    }

    @objc private func cleanSelected() {
        guard let profile = selectedProfile, let take = selectedTake else { return }
        do {
            selectedTakeID = try store.addTake(profileID: profile.id, source: store.takeURL(take),
                                               transcript: take.transcript, style: take.style, clean: true)
            refresh()
            status.stringValue = "Cleaned take added. Compare it before making it current."
        } catch { showError(error.localizedDescription) }
    }

    private func play(_ url: URL) {
        do { player = try AVAudioPlayer(contentsOf: url); player?.play() }
        catch { showError("Could not play this recording: \(error.localizedDescription)") }
    }

    @objc private func playReference() {
        guard let take = selectedProfile?.currentTake else { return }
        play(store.takeURL(take))
    }
    @objc private func playTake(_ sender: NSButton) {
        guard let profile = selectedProfile, profile.takes.indices.contains(sender.tag) else { return }
        play(store.takeURL(profile.takes[sender.tag]))
    }
    @objc private func playCurrentPreview() { if let currentPreviewURL { play(currentPreviewURL) } }
    @objc private func playNewPreview() { if let newPreviewURL { play(newPreviewURL) } }

    private func clearPreviews() {
        currentPreviewURL = nil
        newPreviewURL = nil
        playCurrentButton.isEnabled = false
        playNewButton.isEnabled = false
    }

    @objc private func recordTake() {
        if let recorder {
            recorder.stop()
            self.recorder = nil
            recordButton.title = "Record"
            guard let url = recordingURL else { recordingNewVoice = false; return }
            let newVoice = recordingNewVoice || selectedProfile == nil
            recordingNewVoice = false
            guard let details = promptDetails(newVoice: newVoice, suggestedName: "New voice") else {
                try? FileManager.default.removeItem(at: url)
                recordingURL = nil
                return
            }
            do {
                if !newVoice, let profileID = selectedProfileID {
                    selectedTakeID = try store.addTake(profileID: profileID, source: url, transcript: details.1, style: "Neutral")
                } else {
                    selectedProfileID = try store.addVoice(name: details.0, source: url, transcript: details.1, style: "Neutral")
                    selectedTakeID = selectedProfile?.currentTakeID
                }
                refresh()
                status.stringValue = "Recording added. Label its speaking style, then compare it."
            } catch { showError(error.localizedDescription) }
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else {
                    self.recordingNewVoice = false
                    self.showError("Allow microphone access in System Settings to record a take.")
                    return
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicedesk-take-\(UUID().uuidString).wav")
                let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatLinearPCM),
                                               AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
                                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
                do {
                    let recorder = try AVAudioRecorder(url: url, settings: settings)
                    guard recorder.record() else { self.showError("Could not start recording."); return }
                    self.recorder = recorder
                    self.recordingURL = url
                    self.recordButton.title = "Stop recording"
                    self.status.stringValue = "Recording… Speak for 3–60 seconds, then click Stop recording."
                } catch {
                    self.recordingNewVoice = false
                    self.showError("Could not record: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func compare() {
        guard renderProcess == nil, let profile = selectedProfile,
              let current = profile.currentTake, let selected = selectedTake,
              current.id != selected.id else { showError("Select a different take to compare with the current one."); return }
        let line = compareLine.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { showError("Enter a short test line first."); return }
        let model = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("voice/models/Breeze-TTS-2-mlx-8bit")
        guard FileManager.default.fileExists(atPath: model.appendingPathComponent("model.safetensors").path) else {
            showError("The Breeze 8-bit model is not installed on this Mac."); return
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/VoiceDesk/Voice tests", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { showError("Could not create the voice tests folder: \(error.localizedDescription)"); return }
        let base = folder.appendingPathComponent("Breeze-TTS-2-8bit-\(UUID().uuidString.prefix(8)).wav")
        let temporary = FileManager.default.temporaryDirectory
        let scriptURL = temporary.appendingPathComponent("voice-test-\(UUID().uuidString).txt")
        let currentTextURL = temporary.appendingPathComponent("voice-current-\(UUID().uuidString).txt")
        let newTextURL = temporary.appendingPathComponent("voice-new-\(UUID().uuidString).txt")
        do {
            try line.write(to: scriptURL, atomically: true, encoding: .utf8)
            try current.transcript.write(to: currentTextURL, atomically: true, encoding: .utf8)
            try selected.transcript.write(to: newTextURL, atomically: true, encoding: .utf8)
        } catch { showError("Could not prepare the test line: \(error.localizedDescription)"); return }
        let process = Process()
        process.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("voice/venv/bin/python")
        process.currentDirectoryURL = projectURL
        process.arguments = [projectURL.appendingPathComponent("directed_voice.py").path,
                             "--script", scriptURL.path, "--reference", store.takeURL(current).path,
                             "--reference-text-file", currentTextURL.path,
                             "--compare-reference", store.takeURL(selected).path,
                             "--compare-reference-text-file", newTextURL.path,
                             "--model", model.path, "--output", base.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        renderProcess = process
        renderStarted = Date()
        compareButton.isEnabled = false
        status.stringValue = "Generating both versions…"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.status.stringValue = "Generating both versions… \(Int(Date().timeIntervalSince(self.renderStarted))) s"
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try process.run()
                let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                DispatchQueue.main.async {
                    self?.finishCompare(ok: process.terminationStatus == 0, base: base,
                                        temp: [scriptURL, currentTextURL, newTextURL], log: log)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishCompare(ok: false, base: base,
                                        temp: [scriptURL, currentTextURL, newTextURL], log: error.localizedDescription)
                }
            }
        }
    }

    private func finishCompare(ok: Bool, base: URL, temp: [URL], log: String) {
        timer?.invalidate()
        timer = nil
        renderProcess = nil
        temp.forEach { try? FileManager.default.removeItem(at: $0) }
        let stem = base.deletingPathExtension().lastPathComponent
        let current = base.deletingLastPathComponent().appendingPathComponent("\(stem)-current.wav")
        let new = base.deletingLastPathComponent().appendingPathComponent("\(stem)-new.wav")
        if ok && FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: new.path) {
            currentPreviewURL = current
            newPreviewURL = new
            playCurrentButton.isEnabled = true
            playNewButton.isEnabled = true
            status.stringValue = "Comparison ready in \(Int(Date().timeIntervalSince(renderStarted))) s. Listen to both, then choose a current take."
            NSSound.beep()
        } else {
            showError("Comparison failed: \(log.suffix(500))")
        }
        refresh()
    }
}

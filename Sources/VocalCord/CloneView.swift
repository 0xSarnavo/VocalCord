import SwiftUI
import UniformTypeIdentifiers

enum Flow: Hashable {
    /// `file` holds the new voice's name: that voice is made only at the end.
    case fast(String), full(String), file(String)

    var voiceID: String? {
        switch self {
        case .fast(let id), .full(let id): id
        case .file: nil
        }
    }
}

struct CloneView: View {
    @Environment(VoiceStore.self) private var store
    @State private var selection: String?
    @State private var flow: Flow?
    @State private var showNew = false
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection, newIsPrimary: flow == nil, onNew: { showNew = true },
                    onRename: startRename, onDelete: { deleting = $0 })
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.content)
        }
        .onAppear { if selection == nil { selection = store.voices.first?.id } }
        .onChange(of: selection) { if flow?.voiceID != selection { flow = nil } }
        .sheet(isPresented: $showNew) {
            NewVoiceSheet { name, kind in
                if kind == .file {
                    selection = nil
                    flow = .file(name)
                    return
                }
                let id = store.createVoice(name: name, fullClone: kind == .full)
                selection = id
                flow = kind == .full ? .full(id) : .fast(id)
            }
        }
        // `presenting:` hands the ID to the actions, since dismissing clears the state.
        .alert("Rename voice", isPresented: Binding(present: $renaming), presenting: renaming) { id in
            TextField("Name", text: $newName)
            Button("Rename") { store.rename(id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \u{201C}\(store.voice(deleting)?.name ?? "")\u{201D}?",
                            isPresented: Binding(present: $deleting), titleVisibility: .visible, presenting: deleting) { id in
            Button("Delete voice", role: .destructive) {
                store.deleteVoice(id)
                if selection == id { selection = store.voices.first?.id }
            }
        } message: { _ in
            Text("Its recordings move to the Trash.")
        }
    }

    @ViewBuilder private var detail: some View {
        switch flow {
        case .full(let id):
            FullCloneView(voiceID: id) { flow = nil }.id(id)
        case .fast(let id):
            FastCloneView(voiceID: id) { flow = nil }.id(id)
        case .file(let name):
            FileCloneView(name: name) { id in
                flow = nil
                selection = id ?? store.voices.first?.id
            }
        case nil:
            if let voice = store.voice(selection) {
                VoicePage(voice: voice, onResume: { flow = .full(voice.id) }, onRename: startRename, onDelete: { deleting = $0 })
                    .id(voice.id)
            } else {
                Text("No voices").foregroundStyle(Theme.secondary)
            }
        }
    }

    private func startRename(_ id: String) {
        newName = store.voice(id)?.name ?? ""
        renaming = id
    }
}

struct VoiceMenu: View {
    let id: String
    let onRename: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        Button("Rename…") { onRename(id) }
        Button("Delete…", role: .destructive) { onDelete(id) }
    }
}

struct Sidebar: View {
    @Environment(VoiceStore.self) private var store
    @Binding var selection: String?
    let newIsPrimary: Bool
    let onNew: () -> Void
    let onRename: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Group {
                if newIsPrimary {
                    Button(action: onNew) { newLabel }.buttonStyle(.primary(height: 40))
                } else {
                    Button(action: onNew) { newLabel }.buttonStyle(.outline(height: 40))
                }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.voices) { voice in
                        Button { selection = voice.id } label: {
                            Label(voice.name, systemImage: "waveform")
                                .font(.system(size: 14))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .background(selection == voice.id ? Theme.selection : .clear, in: .rect(cornerRadius: 10))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == voice.id ? .isSelected : [])
                        .contextMenu { VoiceMenu(id: voice.id, onRename: onRename, onDelete: onDelete) }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var newLabel: some View {
        Label("New voice", systemImage: "plus").frame(maxWidth: .infinity)
    }
}

// MARK: Voice page

struct VoicePage: View {
    @Environment(VoiceStore.self) private var store
    let voice: Voice
    let onResume: () -> Void
    let onRename: (String) -> Void
    let onDelete: (String) -> Void
    @AppStorage("pronunciationsOpen") private var inspectorOpen = true
    @State private var auditioning = Progress()
    @State private var recordTone: String?
    @State private var picking = false
    @State private var pickTone = "Neutral"
    @State private var importing = Progress()
    @State private var importingTone: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Text(voice.name)
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1)
                        .contextMenu { VoiceMenu(id: voice.id, onRename: onRename, onDelete: onDelete) }
                    Spacer()
                    if voice.session != nil {
                        Button("Resume session", action: onResume).buttonStyle(.primary)
                    }
                    auditionButton
                }
                TakesTable(voice: voice, importingTone: importingTone, importProgress: importing.value,
                           onRecord: { recordTone = $0 }, onUpload: { pickTone = $0; picking = true })
            }
            // Columns stop stretching on wide windows.
            .frame(maxWidth: 1160, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 24)
            PronunciationsPanel(voice: voice, open: $inspectorOpen)
        }
        .sheet(isPresented: Binding(present: $recordTone)) {
            if let tone = recordTone {
                TakeCapture(voiceID: voice.id, tone: tone, prompt: Prompts.sentence(for: tone),
                            minSeconds: 1, maxSeconds: 30, saveTitle: "Save take", large: false,
                            onCancel: { recordTone = nil }) { _ in recordTone = nil }
                    .frame(width: 680, height: 470)
                    .background(Theme.content)
                    .focusEffectDisabled()
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            let tone = pickTone
            Task { await importUpload(url, tone: tone) }
        }
    }

    private var auditionButton: some View {
        Button {
            Task {
                auditioning.start()
                defer { auditioning.active = false }
                do { try await store.audition(voice.id, progress: auditioning.callback) }
                catch { store.error = error.localizedDescription }
            }
        } label: {
            if auditioning.active {
                HStack(spacing: 8) {
                    ProgressView(value: auditioning.value).frame(width: 70)
                    Text("Audition")
                }
            } else {
                Label("Audition", systemImage: "play.fill")
            }
        }
        .buttonStyle(.outline(height: 34))
        .disabled(auditioning.active || voice.takes.isEmpty)
    }

    private func importUpload(_ url: URL, tone: String) async {
        importingTone = tone
        importing.start()
        defer { importingTone = nil; importing.active = false }
        do { _ = try await store.importMedia(url, voiceID: voice.id, tone: tone, progress: importing.callback) }
        catch { store.error = "Couldn't import this file. \(error.localizedDescription)" }
    }
}

// MARK: Takes table

private enum Column {
    static let tone: CGFloat = 130
    static let length: CGFloat = 72
    static let like: CGFloat = 84
    static let main: CGFloat = 58
    static let gutter: CGFloat = 36
    static let row: CGFloat = 44
    static let emptyRow: CGFloat = 36
    static let fixed = tone + length + like + main + gutter
}

/// Row separator: fainter than Theme.line so the table reads as rows, not a grid.
private let rule = Color(hex: 0x1E2023)

struct TakesTable: View {
    let voice: Voice
    let importingTone: String?
    let importProgress: Double
    let onRecord: (String) -> Void
    let onUpload: (String) -> Void
    @State private var collapsed: Set<String> = []
    @State private var hovered: String?
    @State private var takeWidth: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cell("Tone", width: Column.tone, alignment: .leading)
                cell("Take", width: takeWidth, alignment: .leading)
                cell("Length", width: Column.length)
                cell("Like you", width: Column.like)
                cell("Main", width: Column.main)
                Color.clear.frame(width: Column.gutter)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .frame(height: 34)
            rule.frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Tone.all, id: \.self) { tone in
                        group(tone)
                        rule.frame(height: 1)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
        }
        // Measures the space offered, not the rows' own width, so the columns can shrink again.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { takeWidth = max(120, $0 - Column.fixed) }
    }

    private func cell(_ title: String, width: CGFloat, alignment: Alignment = .center) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(width: width, alignment: alignment)
    }

    private func group(_ tone: String) -> some View {
        let takes = voice.takes(tone)
        let isCollapsed = collapsed.contains(tone)
        let collapsible = takes.count > 1
        let height = takes.isEmpty ? Column.emptyRow : Column.row
        let label = HStack(spacing: 6) {
            // Hidden, not removed, so every tone name starts at the same x.
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .foregroundStyle(Theme.secondary)
                .opacity(collapsible ? 1 : 0)
            Text(tone)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(takes.isEmpty ? Theme.secondary : Theme.text)
            if collapsible {
                Text("(\(takes.count))").font(.system(size: 14)).foregroundStyle(Theme.secondary)
            }
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .frame(width: Column.tone, height: height, alignment: .leading)
        .contentShape(.rect)
        return HStack(alignment: .top, spacing: 0) {
            if collapsible {
                Button {
                    if isCollapsed { collapsed.remove(tone) } else { collapsed.insert(tone) }
                } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tone), \(takes.count) takes, \(isCollapsed ? "collapsed" : "expanded")")
            } else {
                label.accessibilityElement(children: .combine)
            }

            VStack(spacing: 0) {
                if isCollapsed || takes.isEmpty {
                    blankRow(takes.isEmpty ? "No take" : nil, height: height)
                } else {
                    ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                        TakeRow(take: take, voice: voice, showsMain: takes.count > 1, takeWidth: takeWidth)
                            .overlay(alignment: .top) { if index > 0 { rule.frame(height: 1) } }
                    }
                }
            }

            ZStack {
                if !takes.isEmpty {
                    addMenu(tone).opacity(hovered == tone || importingTone == tone ? 1 : 0)
                }
            }
            .frame(width: Column.gutter, height: height)
        }
        .overlay(alignment: .topTrailing) {
            if takes.isEmpty { emptyActions(tone).opacity(hovered == tone || importingTone == tone ? 1 : 0) }
        }
        .background(hovered == tone ? Theme.selection.opacity(0.45) : .clear)
        .onHover { hovering in
            if hovering { hovered = tone } else if hovered == tone { hovered = nil }
        }
    }

    @ViewBuilder private func addMenu(_ tone: String) -> some View {
        if importingTone == tone {
            ProgressView(value: importProgress).frame(width: 34)
        } else {
            Menu {
                Button("Record") { onRecord(tone) }
                Button("Upload") { onUpload(tone) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.outline))
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add take to \(tone)")
        }
    }

    /// Record and Upload for a tone with no take, shown on hover at the row end.
    private func emptyActions(_ tone: String) -> some View {
        HStack(spacing: 8) {
            if importingTone == tone {
                ProgressView(value: importProgress).frame(width: 120)
            } else {
                Button { onRecord(tone) } label: {
                    HStack(spacing: 6) { RecordDot(size: 8); Text("Record") }
                }
                .buttonStyle(.outline(height: 26))
                Button("Upload") { onUpload(tone) }.buttonStyle(.outline(height: 26))
            }
        }
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: Column.emptyRow)
    }

    private func blankRow(_ note: String?, height: CGFloat) -> some View {
        Text(note ?? "")
            .font(.system(size: 14))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 12)
            .frame(width: takeWidth + Column.length + Column.like + Column.main, height: height, alignment: .leading)
    }
}

struct TakeRow: View {
    @Environment(VoiceStore.self) private var store
    let take: Take
    let voice: Voice
    let showsMain: Bool
    let takeWidth: CGFloat
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        let url = store.audioURL(take, voiceID: voice.id)
        let isMain = voice.mainTake(take.tone)?.id == take.id
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                PlayButton(url: url)
                SmallWaveform(url: url).frame(width: 54, height: 18)
                TextField("Transcript", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(editing ? nil : 2)
                    .help(take.transcript)
                    .focused($editing)
                    .onSubmit(commit)
                    .onChange(of: editing) { if !editing { commit() } }
                if !take.issues.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.amber)
                        .help(take.issues.map(\.label).joined(separator: ", "))
                        .accessibilityLabel(take.issues.map(\.label).joined(separator: ", "))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: takeWidth, alignment: .leading)

            Text(formatTime(take.duration))
                .frame(width: Column.length)
                .frame(maxHeight: .infinity)
            Text(take.score.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                .foregroundStyle(take.score == nil ? Theme.secondary : Theme.text)
                .frame(width: Column.like)
                .frame(maxHeight: .infinity)
            // ZStack, not Group: an empty Group would drop the column's fixed width.
            ZStack {
                if showsMain {
                    Button { store.setMain(take, voiceID: voice.id) } label: {
                        Image(systemName: isMain ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 17))
                            .frame(width: 30, height: 30)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Main take")
                    .accessibilityAddTraits(isMain ? .isSelected : [])
                }
            }
            .frame(width: Column.main)
            .frame(maxHeight: .infinity)
        }
        .font(.system(size: 14).monospacedDigit())
        .frame(minHeight: Column.row)
        // Lets the fixed columns stretch to a wrapped transcript's height.
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
        .contextMenu {
            Button("Delete take", role: .destructive) { store.removeTakes([take.id], from: voice.id) }
        }
        .onAppear { text = take.transcript }
        .onChange(of: take.transcript) { text = take.transcript }
    }

    private func commit() {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = take.transcript; return }
        store.setTranscript(text, take: take, voiceID: voice.id)
    }
}

struct PlayButton: View {
    @Environment(Player.self) private var player
    let url: URL

    var body: some View {
        Button { player.toggle(url) } label: {
            Image(systemName: player.playing == url ? "stop.fill" : "play.fill")
                .font(.system(size: 11))
                .frame(width: 30, height: 24)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(player.playing == url ? "Stop" : "Play")
    }
}

struct SmallWaveform: View {
    @Environment(Waveforms.self) private var waveforms
    let url: URL

    var body: some View {
        Canvas { context, size in
            let bars = waveforms.bars[url] ?? []
            guard !bars.isEmpty else { return }
            let step = size.width / CGFloat(bars.count)
            for (index, bar) in bars.enumerated() {
                let height = max(2, CGFloat(bar) * size.height)
                let rect = CGRect(x: CGFloat(index) * step + step * 0.25, y: (size.height - height) / 2,
                                  width: max(1, step * 0.5), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Theme.secondary))
            }
        }
        .task(id: url) { await waveforms.load(url) }
        .accessibilityHidden(true)
    }
}

// MARK: Pronunciations

struct PronunciationsPanel: View {
    @Environment(VoiceStore.self) private var store
    let voice: Voice
    @Binding var open: Bool
    @State private var adding = false
    @State private var word = ""
    @State private var respelling = ""

    var body: some View {
        Group {
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Pronunciations").font(.system(size: 17, weight: .bold))
                        Spacer()
                        Button { open = false } label: { Image(systemName: "chevron.right").padding(6).contentShape(.rect) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Hide pronunciations")
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 64)
                    rule.frame(height: 1).padding(.horizontal, 12)
                    ForEach(voice.pronunciations) { item in
                        HStack(spacing: 10) {
                            Text(item.word)
                            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            Text(item.respelling)
                        }
                        .font(.system(size: 14))
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(.rect)
                        .contextMenu {
                            Button("Delete", role: .destructive) { store.removePronunciation(item.id, voiceID: voice.id) }
                        }
                    }
                    Button { adding = true } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(.outline(height: 32))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .popover(isPresented: $adding, arrowEdge: .bottom) { addForm }
                }
                .frame(width: 240)
            } else {
                Button { open = true } label: { Image(systemName: "chevron.left").padding(8).contentShape(.rect) }
                    .buttonStyle(.plain)
                    .help("Pronunciations")
                    .accessibilityLabel("Show pronunciations")
                    .frame(width: 44, height: 64)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(8)
        // Hugs its content, so an empty list isn't a tall empty box.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Word", text: $word)
            TextField("Say as", text: $respelling).onSubmit(add)
            Button("Add", action: add)
                .buttonStyle(.primary(height: 30))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty || respelling.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .focusEffectDisabled(false)
        .padding(16)
        .frame(width: 240)
    }

    private func add() {
        store.addPronunciation(word: word, respelling: respelling, voiceID: voice.id)
        word = ""
        respelling = ""
        adding = false
    }
}

// MARK: New voice

struct NewVoiceSheet: View {
    enum Kind { case fast, full, file }

    @Environment(\.dismiss) private var dismiss
    let onStart: (String, Kind) -> Void
    @State private var name = ""
    @State private var kind = Kind.fast
    @State private var consent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New voice").font(.system(size: 22, weight: .bold))
            TextField("Name", text: $name, prompt: Text("Untitled voice"))
                .textFieldStyle(.roundedBorder)
                .focusEffectDisabled(false)
            HStack(spacing: 12) {
                choice("Fast clone", detail: "One 10–20 s clip", kind: .fast)
                choice("Full clone", detail: "Guided, about 8 min", kind: .full)
                choice("From a file", detail: "Any audio or video", kind: .file)
            }
            Toggle("This is my voice, or I have the speaker's permission.", isOn: $consent)
                .toggleStyle(.checkbox)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.outline(height: 32)).keyboardShortcut(.cancelAction)
                Button("Start") {
                    onStart(name, kind)
                    dismiss()
                }
                .buttonStyle(.primary(height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(!consent)
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(Theme.content)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    private func choice(_ title: String, detail: String, kind: Kind) -> some View {
        let selected = self.kind == kind
        return Button { self.kind = kind } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selection : .clear, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.outline : Theme.line))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: From a file

/// Drop files, cut them into clips, pick the speaker, review the clips, then create the voice and audition it.
struct FileCloneView: View {
    @Environment(VoiceStore.self) private var store
    let name: String
    /// The new voice's ID, or nil when cancelled.
    let onDone: (String?) -> Void

    private enum Stage { case pick, cutting, grouping, speakers, review, auditioning }
    @State private var stage = Stage.pick
    @State private var working = Progress()
    @State private var task: Task<Void, Never>?
    /// Copies of the sources and every clip, until Create moves them to the voice's raw/.
    @State private var folder: URL?
    @State private var groups: [[FileClip]] = []
    @State private var clips: [FileClip] = []
    @State private var picking = false
    @State private var dropping = false

    var body: some View {
        Group {
            switch stage {
            case .pick: pickView
            case .cutting: progressView("Cutting into clips", button: "Cancel")
            case .grouping: progressView("Finding speakers", button: "Cancel")
            case .speakers: speakersView
            case .review: reviewView
            case .auditioning: progressView("Audition", button: "Skip")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { _ = start(urls) }
        }
        .onDisappear {
            task?.cancel()
            discard()
        }
    }

    /// Full clone's layout: a large prompt, its controls, and one button at the bottom.
    private func screen<Content: View>(_ title: String, bottom: String, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer()
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer().frame(height: 52)
            content()
            Spacer()
            Button(bottom, action: action).buttonStyle(.outline(height: 44)).padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity)
    }

    private var pickView: some View {
        screen("Drop audio or video files", bottom: "Cancel", action: { onDone(nil) }) {
            Button { picking = true } label: { Text("Choose files").frame(minWidth: 260) }
                .buttonStyle(.primary(height: 76))
        }
        .background(dropping ? Theme.selection.opacity(0.5) : .clear, in: .rect(cornerRadius: 18))
        .padding(8)
        .dropDestination(for: URL.self) { urls, _ in start(urls) } isTargeted: { dropping = $0 }
    }

    private func progressView(_ title: String, button: String) -> some View {
        screen(title, bottom: button, action: { task?.cancel() }) {
            ProgressView(value: working.value).frame(width: 260)
        }
    }

    private var speakersView: some View {
        screen("Who do you want to clone?", bottom: "Cancel", action: { onDone(nil) }) {
            VStack(spacing: 4) {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    SpeakerRow(number: index + 1, clips: group) { choose(group) }
                }
            }
            .frame(width: 440)
        }
    }

    private var reviewView: some View {
        let kept = clips.filter(\.keep)
        let ready = !kept.isEmpty && !kept.contains { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Text(title.isEmpty ? "Untitled voice" : title)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(1)
                Spacer()
                if groups.count > 1 {
                    Button("Back") { stage = .speakers }.buttonStyle(.outline(height: 34))
                }
                Button("Cancel") { onDone(nil) }.buttonStyle(.outline(height: 34))
                Button("Create voice", action: create).buttonStyle(.primary).disabled(!ready)
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("\(kept.count) of \(clips.count) clips").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: FileColumn.issues)
                    Text("Length").frame(width: FileColumn.length)
                    Text("Tone").frame(width: FileColumn.tone, alignment: .leading)
                }
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 34)
                rule.frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach($clips) { $clip in
                            FileClipRow(clip: $clip)
                            rule.frame(height: 1)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: 1160, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 24)
    }

    /// Cuts the files, then groups the clips by speaker. Returns false when nothing dropped is audio or video.
    private func start(_ urls: [URL]) -> Bool {
        let media = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audiovisualContent) == true }
        guard !media.isEmpty, stage == .pick else { return false }
        let folder = FileManager.default.temporaryDirectory.appending(path: "VocalCord-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.folder = folder
        task = Task {
            do {
                stage = .cutting
                working.start()
                let all = try await store.cutFiles(media, into: folder, progress: working.callback)
                stage = .grouping
                working.start()
                groups = try await store.groupBySpeaker(all, progress: working.callback)
                if groups.count > 1 { stage = .speakers } else { choose(groups.first ?? all) }
            } catch {
                if !(error is CancellationError) {
                    store.error = "Couldn't use \(media.count > 1 ? "these files" : "this file"). \(error.localizedDescription)"
                }
                discard()
                stage = .pick
            }
            working.active = false
        }
        return true
    }

    private func choose(_ group: [FileClip]) {
        clips = group
        stage = .review
    }

    private func create() {
        guard let folder else { return }
        do {
            let id = try store.createVoice(name: name, from: folder, clips: clips)
            self.folder = nil
            stage = .auditioning
            working.start()
            task = Task {
                do { try await store.audition(id, progress: working.callback) } catch {
                    if !(error is CancellationError) { store.error = "Audition failed. \(error.localizedDescription)" }
                }
                working.active = false
                onDone(id)
            }
        } catch {
            store.error = "Couldn't create this voice. \(error.localizedDescription)"
        }
    }

    private func discard() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
}

private enum FileColumn {
    static let issues: CGFloat = 170
    static let length: CGFloat = 64
    static let tone: CGFloat = 110
}

struct SpeakerRow: View {
    let number: Int
    let clips: [FileClip]
    let onChoose: () -> Void
    @State private var hovered = false

    var body: some View {
        // The clean clip nearest 8 s says the most about the voice.
        let sample = clips.filter(\.issues.isEmpty).min { abs($0.duration - 8) < abs($1.duration - 8) } ?? clips[0]
        HStack(spacing: 14) {
            PlayButton(url: sample.url)
            Button(action: onChoose) {
                HStack(spacing: 10) {
                    Text("Speaker \(number)").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(clips.count == 1 ? "1 clip" : "\(clips.count) clips").foregroundStyle(Theme.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(hovered ? Theme.selection : .clear, in: .rect(cornerRadius: 10))
        .onHover { hovered = $0 }
    }
}

struct FileClipRow: View {
    @Binding var clip: FileClip

    var body: some View {
        let warnings = clip.issues.map(\.label) + (clip.duration < 3 ? ["Too short"] : clip.duration > 20 ? ["Too long"] : [])
        HStack(spacing: 12) {
            Toggle("Use clip", isOn: $clip.keep).toggleStyle(.checkbox).labelsHidden()
            PlayButton(url: clip.url)
            SmallWaveform(url: clip.url).frame(width: 54, height: 18)
            TextField("Transcript", text: $clip.transcript, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .foregroundStyle(clip.keep ? Theme.text : Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            // ZStack, not Group: an empty Group would drop the column's fixed width.
            ZStack(alignment: .leading) {
                if !warnings.isEmpty {
                    Warning(text: warnings.joined(separator: ", ")).lineLimit(1).help(warnings.joined(separator: ", "))
                }
            }
            .frame(width: FileColumn.issues, alignment: .leading)
            Text(formatTime(clip.duration)).monospacedDigit().frame(width: FileColumn.length)
            Menu {
                Picker("Tone", selection: $clip.tone) {
                    ForEach(Tone.all, id: \.self) { Text($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 5) {
                    Text(clip.tone)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: FileColumn.tone, alignment: .leading)
            .accessibilityLabel("Tone, \(clip.tone)")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

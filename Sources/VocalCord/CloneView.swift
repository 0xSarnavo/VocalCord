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
    /// Stored, so the agents' tools know the voice selected here.
    @AppStorage("voice") private var selection: String?
    @State private var flow: Flow?
    @State private var showNew = false
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        SidebarLayout {
            Sidebar(selection: $selection, newIsPrimary: flow == nil, onNew: { showNew = true },
                    onRename: startRename, onDelete: { deleting = $0 })
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // The panel opens under the voice page, so not during a clone.
                TerminalButton().disabled(flow != nil || store.voice(selection) == nil)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { SettingsButton() }
        }
        .onAppear { if store.voice(selection) == nil { selection = store.voices.first?.id } }
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
            FullCloneView(voiceID: id) { flow = nil }.id(id).panel()
        case .fast(let id):
            FastCloneView(voiceID: id) { flow = nil }.id(id).panel()
        case .file(let name):
            FileCloneView(name: name) { id in
                flow = nil
                selection = id ?? store.voices.first?.id
            }
            .panel()
        case nil:
            if let voice = store.voice(selection) {
                VoicePage(voice: voice, onResume: { flow = .full(voice.id) }, onRename: startRename, onDelete: { deleting = $0 })
                    .id(voice.id)
            } else {
                Text("No voices").foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).panel()
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
    @AppStorage("terminalOpen") private var terminalOpen = false
    @AppStorage("terminalHeight") private var terminalHeight = 300.0

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                VStack(spacing: 8) {
                    VStack(spacing: 0) {
                        PanelHeader {
                            Text(voice.name).contextMenu { VoiceMenu(id: voice.id, onRename: onRename, onDelete: onDelete) }
                        } actions: {
                            decideAll
                            if voice.session != nil {
                                Button("Resume session", action: onResume).buttonStyle(.primary(height: 30))
                            }
                            auditionButton
                        }
                        TakesTable(voice: voice, importingTone: importingTone, importProgress: importing.value,
                                   onRecord: { recordTone = $0 }, onUpload: { pickTone = $0; picking = true })
                    }
                    .frame(maxHeight: .infinity)
                    .panel()
                    if terminalOpen {
                        // The table keeps room for its header and a few takes.
                        TerminalPanel(height: $terminalHeight, maxHeight: proxy.size.height - 250)
                    }
                }
            }
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

    /// Accept all and Reject all, once an agent has proposed two or more changes.
    @ViewBuilder private var decideAll: some View {
        let takes = voice.takes.filter { $0.proposal != nil }.map(\.id)
        let words = (voice.proposedPronunciations ?? []).map(\.id)
        if takes.count + words.count > 1 {
            Button("Accept all") {
                store.acceptTakes(takes, voiceID: voice.id)
                store.acceptPronunciations(words, voiceID: voice.id)
            }
            .buttonStyle(.outline)
            Button("Reject all") {
                store.rejectTakes(takes, voiceID: voice.id)
                store.rejectPronunciations(words, voiceID: voice.id)
            }
            .buttonStyle(.outline)
        }
    }

    /// Also shows an audition an agent started.
    private var auditionButton: some View {
        Button {
            Task {
                auditioning.start()
                defer { auditioning.active = false }
                do { try await store.audition(voice.id, progress: auditioning.callback) }
                catch { store.error = error.localizedDescription }
            }
        } label: {
            if auditioning.active || store.auditioning == voice.id {
                HStack(spacing: 8) {
                    ProgressView(value: auditioning.active ? auditioning.value : nil).frame(width: 70)
                    Text("Audition")
                }
            } else {
                Label("Audition", systemImage: "play.fill")
            }
        }
        .buttonStyle(.outline)
        .disabled(auditioning.active || store.auditioning != nil || voice.takes.isEmpty)
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
    static let length: CGFloat = 64
    static let like: CGFloat = 72
    static let main: CGFloat = 58
    static let gutter: CGFloat = 36
    static let row: CGFloat = 44
    static let emptyRow: CGFloat = 40
    /// Between a number and its column's right edge.
    static let inset: CGFloat = 12
    static let fixed = tone + length + like + main + gutter
}

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
        ScrollView {
            // The header scrolls with the rows, so a scroll bar that takes room can't shift the rows under it.
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Tone.all, id: \.self) { tone in
                        group(tone)
                        Theme.rule.frame(height: 1)
                    }
                } header: {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            cell("Tone", width: Column.tone, alignment: .leading)
                            cell("Take", width: takeWidth, alignment: .leading)
                            cell("Length", width: Column.length, alignment: .trailing)
                            cell("Like you", width: Column.like, alignment: .trailing)
                            cell("Main", width: Column.main)
                            Color.clear.frame(width: Column.gutter)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(height: 32)
                        Theme.line.frame(height: 1)
                    }
                    .background(Theme.content)
                }
            }
            // Measures the width the rows get, not their own, so the columns can shrink again.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { takeWidth = max(120, $0 - Column.fixed) }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func cell(_ title: String, width: CGFloat, alignment: Alignment = .center) -> some View {
        Text(title)
            .lineLimit(1)
            .padding(.leading, alignment == .leading ? Column.inset : 0)
            .padding(.trailing, alignment == .trailing ? Column.inset : 0)
            .frame(width: width, alignment: alignment)
    }

    private func group(_ tone: String) -> some View {
        let takes = voice.takes(tone)
        // A pending change stays in view.
        let isCollapsed = collapsed.contains(tone) && !takes.contains { $0.proposal != nil }
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
                    // A tone with no take shows only its name; Record and Upload appear on hover.
                    blankRow(height: height)
                } else {
                    ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                        TakeRow(take: take, voice: voice, showsMain: takes.count > 1, takeWidth: takeWidth)
                            .overlay(alignment: .top) { if index > 0 { Theme.rule.frame(height: 1) } }
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
        .background(hovered == tone ? Theme.hover : .clear)
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

    private func blankRow(height: CGFloat) -> some View {
        Color.clear.frame(width: takeWidth + Column.length + Column.like + Column.main, height: height)
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
                if let proposal = take.proposal {
                    TakeProposalText(take: take, proposal: proposal).frame(maxWidth: .infinity, alignment: .leading)
                    DecisionButtons(label: "change to this take",
                                    onAccept: { store.acceptTakes([take.id], voiceID: voice.id) },
                                    onReject: { store.rejectTakes([take.id], voiceID: voice.id) })
                } else {
                    TextField("Transcript", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(editing ? nil : 2)
                        .help(take.transcript)
                        .focused($editing)
                        .onSubmit(commit)
                        .onChange(of: editing) { if !editing { commit() } }
                }
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
                .padding(.trailing, Column.inset)
                .frame(width: Column.length, alignment: .trailing)
                .frame(maxHeight: .infinity)
            // No score yet leaves the cell blank.
            Text(take.score.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                .padding(.trailing, Column.inset)
                .frame(width: Column.like, alignment: .trailing)
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

/// A take's pending change: the old transcript struck through above the new, and any tone or main take change.
private struct TakeProposalText: View {
    let take: Take
    let proposal: TakeProposal

    var body: some View {
        let changes = [proposal.tone.map { "\(take.tone) → \($0)" }, proposal.main == true ? "Set as main take" : nil].compactMap(\.self)
        VStack(alignment: .leading, spacing: 3) {
            if let transcript = proposal.transcript {
                Text(take.transcript).strikethrough().foregroundStyle(Theme.secondary)
                Text(transcript)
            } else {
                Text(take.transcript)
            }
            if !changes.isEmpty {
                Text(changes.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([proposal.transcript.map { "Proposed: \($0), was: \(take.transcript)" } ?? take.transcript] + changes)
            .joined(separator: ", "))
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
                    PanelHeader("Pronunciations") { FoldButton(label: "pronunciations") { open = false } }
                    ScrollView { list }.scrollBounceBehavior(.basedOnSize)
                }
                .frame(width: 240)
                .sidePanel()
            } else {
                FoldedSidePanel(title: "Pronunciations") { open = true }
            }
        }
        .onChange(of: voice.proposedPronunciations?.count ?? 0, initial: true) { _, count in if count > 0 { open = true } }
    }

    /// Each word and how to say it, then Add.
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(voice.pronunciations) { item in
                HStack(spacing: 10) {
                    Text(item.word)
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Text(item.respelling)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1).padding(.horizontal, 8) }
                .contentShape(.rect)
                .contextMenu {
                    Button("Delete", role: .destructive) { store.removePronunciation(item.id, voiceID: voice.id) }
                }
            }
            // Two lines, so the word and its respelling don't break mid-word beside the buttons.
            ForEach(voice.proposedPronunciations ?? []) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.word)
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            Text(item.respelling)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 4)
                    DecisionButtons(label: "pronunciation of \(item.word)",
                                    onAccept: { store.acceptPronunciations([item.id], voiceID: voice.id) },
                                    onReject: { store.rejectPronunciations([item.id], voiceID: voice.id) })
                }
                .font(.system(size: 14))
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .overlay(alignment: .bottom) { Theme.line.frame(height: 1).padding(.horizontal, 8) }
            }
            Button { adding = true } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.outline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .popover(isPresented: $adding, arrowEdge: .bottom) { addForm }
        }
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

    /// Full clone's layout: a large prompt, its controls and one button below them, in a centred column.
    private func screen<Content: View>(_ title: String, bottom: String, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer().frame(height: 52)
            content()
            Spacer(minLength: 32).frame(maxHeight: 72)
            Button(bottom, action: action).buttonStyle(.outline(height: 44))
            Spacer(minLength: 24)
        }
        .frame(maxWidth: 880)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ScrollView {
                // The header scrolls with the rows, so a scroll bar that takes room can't shift the rows under it.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach($clips) { $clip in
                            FileClipRow(clip: $clip)
                            Theme.rule.frame(height: 1)
                        }
                    } header: {
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
                            Theme.rule.frame(height: 1)
                        }
                        .background(Theme.content)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
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

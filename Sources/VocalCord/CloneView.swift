import SwiftUI
import UniformTypeIdentifiers

struct CloneView: View {
    @Environment(VoiceStore.self) private var store
    /// Stored, so the agents' tools know the voice selected here.
    @AppStorage("voice") private var selection: String?
    @AppStorage("pronunciationsOpen") private var pronunciationsOpen = true
    /// The voice being made from a recording, while its screen shows: the voice exists only at the end.
    @State private var making: NewVoice?
    @State private var showNew = false
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    /// The voice page is on screen: not while a voice is being made, and only with a voice selected.
    private var showsVoice: Bool { making == nil && store.voice(selection) != nil }

    var body: some View {
        SidebarLayout {
            Sidebar(selection: $selection, onNew: { showNew = true }, onRename: startRename, onDelete: { deleting = $0 })
        } detail: {
            detail
        }
        // The Terminal opens under the voice page, so not while a voice is being made.
        .toolbar { WorkspaceToolbar(terminalEnabled: showsVoice) }
        .focusedSceneValue(\.terminalAvailable, showsVoice)
        .focusedSceneValue(\.newItemAction, { showNew = true })
        .focusedSceneValue(\.newItemTitle, "New Voice\u{2026}")
        .focusedSceneValue(\.toggleSidePanel, showsVoice ? { pronunciationsOpen.toggle() } : nil)
        .onAppear { if store.voice(selection) == nil { selection = store.voices.first?.id } }
        // Choosing a voice in the sidebar leaves the new voice's screen.
        .onChange(of: selection) { if selection != nil { making = nil } }
        .sheet(isPresented: $showNew) {
            NewVoiceSheet { voice in
                selection = nil
                making = voice
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
        if let voice = making {
            FileCloneView(name: voice.name, script: voice.script) { id in
                making = nil
                selection = id ?? store.voices.first?.id
            }
            .id(voice.id)
            .panel()
        } else if let voice = store.voice(selection) {
            VoicePage(voice: voice, onRename: startRename, onDelete: { deleting = $0 })
                .id(voice.id)
        } else if store.voices.isEmpty {
            EmptyState(title: "No voices yet", message: "Read a short script out loud or upload any recording, and VocalCord "
                       + "clones the voice on this Mac.") {
                Button("New voice") { showNew = true }.buttonStyle(.vc(.primary, .l))
            }
            .panel()
        } else {
            EmptyState(title: "No voice selected", message: "Choose a voice in the sidebar.").panel()
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

/// The voices, under a "Voices" header whose + starts a new one.
struct Sidebar: View {
    @Environment(VoiceStore.self) private var store
    @Binding var selection: String?
    let onNew: () -> Void
    let onRename: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Voices") {
                // The window's first control, so it takes keyboard focus at launch: a quiet outline, not the bright ring.
                Button(action: onNew) { Image(systemName: "plus") }
                    .buttonStyle(.icon(.s))
                    .focusEffectDisabled()
                    .help("New voice (⌘N)")
                    .accessibilityLabel("New voice")
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(store.voices) { voice in
                        Button { selection = voice.id } label: {
                            SidebarRow(title: voice.name, systemImage: "waveform", selected: selection == voice.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == voice.id ? .isSelected : [])
                        .contextMenu { VoiceMenu(id: voice.id, onRename: onRename, onDelete: onDelete) }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: Voice page

struct VoicePage: View {
    @Environment(VoiceStore.self) private var store
    let voice: Voice
    let onRename: (String) -> Void
    let onDelete: (String) -> Void
    @AppStorage("pronunciationsOpen") private var inspectorOpen = true
    @State private var auditioning = Progress()
    @State private var checkingVoice = false
    @State private var picking = false
    @State private var importing = Progress()
    @AppStorage("terminalOpen") private var terminalOpen = false
    @AppStorage("terminalWidth") private var terminalWidth = 380.0

    var body: some View {
        GeometryReader { proxy in
        HStack(spacing: 0) {
                VStack(spacing: 0) {
                        PanelHeader {
                            Text(voice.name).contextMenu { VoiceMenu(id: voice.id, onRename: onRename, onDelete: onDelete) }
                        } actions: {
                            decideAll
                            uploadButton
                            Button("Voice check\u{2026}") { checkingVoice = true }
                                .buttonStyle(.vc(.secondary, .s))
                                .disabled(voice.takes.isEmpty)
                                .help("Render test lines and see how the voice holds up")
                            auditionButton
                        }
                        TakesTable(voice: voice)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panel()
            PaneDivider()
            PronunciationsPanel(voice: voice, open: $inspectorOpen)
            if terminalOpen {
                // The takes keep room for their columns beside Pronunciations.
                TerminalPanel(width: $terminalWidth, maxWidth: proxy.size.width - 640)
            }
        }
        }
        .sheet(isPresented: $checkingVoice) { VoiceCheckSheet(voice: voice) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            Task { await importUpload(url) }
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
            .buttonStyle(.vc(.secondary, .s))
            Button("Reject all") {
                store.rejectTakes(takes, voiceID: voice.id)
                store.rejectPronunciations(words, voiceID: voice.id)
            }
            .buttonStyle(.vc(.secondary, .s))
        }
    }

    /// Another recording, cut into takes beside the ones the voice has. While it's cut a progress ring stands in for
    /// the glyph, so the button keeps its width.
    private var uploadButton: some View {
        Button { picking = true } label: {
            HStack(spacing: 6) {
                if importing.active {
                    ProgressView(value: importing.value)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: "plus").frame(width: 13, height: 13)
                }
                Text("Upload\u{2026}")
            }
        }
        .buttonStyle(.vc(.secondary, .s))
        .disabled(importing.active)
        .help("Add takes from another recording")
    }

    /// Also shows an audition an agent started. While it runs a small progress ring stands in for the play glyph, so
    /// the button keeps its width.
    private var auditionButton: some View {
        Button {
            Task {
                auditioning.start()
                defer { auditioning.active = false }
                do { try await store.audition(voice.id, progress: auditioning.callback) }
                catch { store.error = error.localizedDescription }
            }
        } label: {
            HStack(spacing: 6) {
                if auditioning.active || store.auditioning == voice.id {
                    ProgressView(value: auditioning.active ? auditioning.value : nil)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: "play.fill").frame(width: 13, height: 13)
                }
                Text("Audition")
            }
        }
        .buttonStyle(.vc(.secondary, .s))
        .disabled(auditioning.active || store.busy != nil || voice.takes.isEmpty)
        .help("Render a test line from the best takes and make the one most like you the main take")
    }

    private func importUpload(_ url: URL) async {
        importing.start()
        defer { importing.active = false }
        do { _ = try await store.importMedia(url, voiceID: voice.id, tone: "Neutral", progress: importing.callback) }
        catch { store.error = "Couldn't import this file. \(error.localizedDescription)" }
    }
}

// MARK: Takes table

private enum Column {
    static let tone: CGFloat = 128
    static let length: CGFloat = 64
    static let like: CGFloat = 72
    static let main: CGFloat = 56
    static let header: CGFloat = 28
    static let row: CGFloat = 40
    static let emptyRow: CGFloat = 32
    /// The pane edge to the tone names and the "Tone" header.
    static let leading: CGFloat = 16
    static let trailing: CGFloat = 8
    /// Between a cell's content and its column edge.
    static let inset: CGFloat = 8

    /// The first column: the tone names while tones show, else the room that puts the takes on the pane's text edge.
    static func lead(tones: Bool) -> CGFloat { tones ? tone : leading - inset }

    /// Everything but the Take column. "Like you" is left out until a take has a score, Main while no tone has two takes
    /// to choose between.
    static func fixed(like: Bool, tones: Bool, main showsMain: Bool) -> CGFloat {
        lead(tones: tones) + length + (like ? self.like : 0) + (showsMain ? main : 0) + trailing
    }
}

/// The voice's takes, grouped by tone while tones show (`Tone.enabled`); otherwise one list of the Neutral takes.
struct TakesTable: View {
    let voice: Voice
    @State private var collapsed: Set<String> = []
    @State private var width: CGFloat = 0

    private var showsTones: Bool { Tone.shown.count > 1 }

    var body: some View {
        // Audition scores the takes; before that the column would be empty in every row.
        let showsLike = voice.takes.contains { $0.score != nil }
        let showsMain = Tone.shown.contains { voice.takes($0).count > 1 }
        let takeWidth = max(120, width - Column.fixed(like: showsLike, tones: showsTones, main: showsMain))
        ScrollView {
            // The header scrolls with the rows, so a scroll bar that takes room can't shift the rows under it.
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Tone.shown, id: \.self) { tone in
                        group(tone, showsLike: showsLike, showsMain: showsMain, takeWidth: takeWidth)
                        Theme.rule.frame(height: 1)
                    }
                } header: {
                    header(showsLike: showsLike, showsMain: showsMain, takeWidth: takeWidth)
                }
            }
            // Measures the width the rows get, not their own, so the columns can shrink again.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func header(showsLike: Bool, showsMain: Bool, takeWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(showsTones ? "Tone" : "").padding(.leading, Column.leading).frame(width: Column.lead(tones: showsTones), alignment: .leading)
            Text("Take").padding(.leading, Column.inset).frame(width: takeWidth, alignment: .leading)
            Text("Length").padding(.trailing, Column.inset).frame(width: Column.length, alignment: .trailing)
            if showsLike {
                Text("Like you").padding(.trailing, Column.inset).frame(width: Column.like, alignment: .trailing)
            }
            if showsMain { Text("Main").frame(width: Column.main) }
        }
        .lineLimit(1)
        .font(.vcCaptionBold)
        .foregroundStyle(Theme.secondary)
        .padding(.trailing, Column.trailing)
        .frame(maxWidth: .infinity, minHeight: Column.header, maxHeight: Column.header, alignment: .leading)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .background(Theme.content)
    }

    /// A tone's rows: one per take, with the tone's name in the first while tones show, or one row for a tone with no
    /// take or folded away. Separators run the full width.
    private func group(_ tone: String, showsLike: Bool, showsMain: Bool, takeWidth: CGFloat) -> some View {
        let takes = voice.takes(tone)
        // A pending change stays in view.
        let isCollapsed = showsTones && collapsed.contains(tone) && !takes.contains { $0.proposal != nil }
        return VStack(spacing: 0) {
            if takes.isEmpty {
                HStack(spacing: 0) {
                    lead(tone, takes: takes, collapsed: false)
                    Text("No takes yet. Upload a recording.")
                        .font(.vcBody)
                        .foregroundStyle(Theme.secondary)
                        .padding(.leading, Column.inset)
                    Spacer(minLength: 0)
                }
                .frame(height: Column.emptyRow)
            } else if isCollapsed {
                HStack(spacing: 0) {
                    lead(tone, takes: takes, collapsed: true)
                    Spacer(minLength: 0)
                }
                .padding(.trailing, Column.trailing)
                .frame(height: Column.row)
            } else {
                ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                    HStack(spacing: 0) {
                        // ZStacks, not Groups: an empty Group would drop the column's fixed width.
                        ZStack(alignment: .leading) {
                            if index == 0 { lead(tone, takes: takes, collapsed: false) }
                        }
                        .frame(width: Column.lead(tones: showsTones))
                        .frame(maxHeight: .infinity)
                        TakeRow(take: take, voice: voice, showsMain: takes.count > 1, mainColumn: showsMain, showsLike: showsLike,
                                takeWidth: takeWidth)
                    }
                    .padding(.trailing, Column.trailing)
                    // Lets the fixed columns stretch to a wrapped transcript's height.
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(alignment: .top) { if index > 0 { Theme.rule.frame(height: 1) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The first column: the tone cell while tones show, else the space that lines the takes up with the header.
    @ViewBuilder private func lead(_ tone: String, takes: [Take], collapsed isCollapsed: Bool) -> some View {
        if showsTones {
            toneCell(tone, takes: takes, collapsed: isCollapsed)
        } else {
            Color.clear.frame(width: Column.lead(tones: false))
        }
    }

    /// The tone's name, with a chevron that folds a tone of two or more takes. The chevron sits in the leading margin,
    /// so every name lines up with the "Tone" header.
    @ViewBuilder private func toneCell(_ tone: String, takes: [Take], collapsed isCollapsed: Bool) -> some View {
        let collapsible = takes.count > 1
        let label = HStack(spacing: 2) {
            // Hidden, not removed, so every tone name starts at the same x.
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                .foregroundStyle(Theme.secondary)
                .frame(width: 12)
                .opacity(collapsible ? 1 : 0)
            HStack(spacing: 4) {
                Text(tone)
                    .font(takes.isEmpty ? .vcBody : .vcBodyBold)
                    .foregroundStyle(takes.isEmpty ? Theme.secondary : Theme.text)
                if collapsible {
                    Text("(\(takes.count))").font(.vcBody.monospacedDigit()).foregroundStyle(Theme.secondary)
                }
            }
        }
        .lineLimit(1)
        .padding(.leading, Column.leading - 14)
        .frame(width: Column.tone, alignment: .leading)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        if collapsible {
            Button {
                if isCollapsed { collapsed.remove(tone) } else { collapsed.insert(tone) }
            } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tone), \(takes.count) takes, \(isCollapsed ? "collapsed" : "expanded")")
        } else {
            label.accessibilityElement(children: .combine)
        }
    }
}

struct TakeRow: View {
    @Environment(VoiceStore.self) private var store
    let take: Take
    let voice: Voice
    let showsMain: Bool
    /// The table has a Main column (some tone has two takes to choose between).
    var mainColumn = true
    var showsLike = true
    let takeWidth: CGFloat
    @State private var text = ""
    /// The transcript reads as text, cut with an ellipsis, until clicked; then it's a field.
    @State private var editing = false
    @State private var confirmingDelete = false
    @FocusState private var focused: Bool

    var body: some View {
        let url = store.audioURL(take, voiceID: voice.id)
        let isMain = voice.mainTake(take.tone)?.id == take.id
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                PlayButton(url: url)
                SmallWaveform(url: url).frame(width: 56, height: 20)
                if let proposal = take.proposal {
                    TakeProposalText(take: take, proposal: proposal).frame(maxWidth: .infinity, alignment: .leading)
                    DecisionButtons(label: "change to this take",
                                    onAccept: { store.acceptTakes([take.id], voiceID: voice.id) },
                                    onReject: { store.rejectTakes([take.id], voiceID: voice.id) })
                } else {
                    transcript
                }
                if !take.issues.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.amber)
                        .help(take.issues.map(\.label).joined(separator: ", "))
                        .accessibilityLabel(take.issues.map(\.label).joined(separator: ", "))
                }
            }
            .padding(.horizontal, Column.inset)
            .padding(.vertical, 8)
            .frame(width: takeWidth, alignment: .leading)

            Text(formatTime(take.duration))
                .padding(.trailing, Column.inset)
                .frame(width: Column.length, alignment: .trailing)
                .frame(maxHeight: .infinity)
            if showsLike {
                // No score yet leaves the cell blank.
                Text(take.score.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                    .padding(.trailing, Column.inset)
                    .frame(width: Column.like, alignment: .trailing)
                    .frame(maxHeight: .infinity)
            }
            // ZStack, not Group: an empty Group would drop the column's fixed width.
            ZStack {
                if showsMain {
                    Button { store.setMain(take, voiceID: voice.id) } label: {
                        Image(systemName: isMain ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(isMain ? Theme.text : Theme.secondary)
                            .frame(width: VCSize.s.height, height: VCSize.s.height)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Main take")
                    .accessibilityAddTraits(isMain ? .isSelected : [])
                }
            }
            .frame(width: mainColumn ? Column.main : 0)
            .frame(maxHeight: .infinity)
        }
        .font(.vcBody.monospacedDigit())
        .frame(minHeight: Column.row)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.rect)
        .contextMenu {
            Button("Delete take…", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog(Tone.enabled ? "Delete this \(take.tone) take?" : "Delete this take?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete take", role: .destructive) { store.removeTakes([take.id], from: voice.id) }
        } message: {
            Text("The voice stops using it. The recording stays in the voice's folder.")
        }
        .onAppear { text = take.transcript }
        .onChange(of: take.transcript) { text = take.transcript }
    }

    @ViewBuilder private var transcript: some View {
        if editing {
            TextField("Transcript", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { focused = false }
                .onExitCommand {
                    text = take.transcript
                    focused = false
                }
                .onChange(of: focused) {
                    if !focused {
                        commit()
                        editing = false
                    }
                }
                // After the field is in the window, or the focus has nowhere to go.
                .onAppear { Task { focused = true } }
        } else {
            Button { editing = true } label: {
                Text(take.transcript)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(take.transcript)
            .accessibilityLabel(take.transcript)
            .accessibilityHint("Edit the transcript")
        }
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
        VStack(alignment: .leading, spacing: 4) {
            if let transcript = proposal.transcript {
                Text(take.transcript).strikethrough().foregroundStyle(Theme.secondary)
                Text(transcript)
            } else {
                Text(take.transcript)
            }
            if !changes.isEmpty {
                Text(changes.joined(separator: " · ")).font(.vcCaption).foregroundStyle(Theme.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([proposal.transcript.map { "Proposed: \($0), was: \(take.transcript)" } ?? take.transcript] + changes)
            .joined(separator: ", "))
    }
}

/// Plays a take or clip: the transport's play button at S.
struct PlayButton: View {
    @Environment(Player.self) private var player
    let url: URL

    var body: some View {
        TransportPlayButton(playing: player.playing == url, size: .s) { player.toggle(url) }
    }
}

/// A take's loudness as one continuous mirrored shape, a point per column.
struct SmallWaveform: View {
    @Environment(Waveforms.self) private var waveforms
    let url: URL

    var body: some View {
        Canvas { context, size in
            let peaks = waveforms.bars[url] ?? []
            guard peaks.count > 1 else { return }
            let middle = size.height / 2
            let step = size.width / CGFloat(peaks.count - 1)
            // Half a point at least, so silence still draws a line through the middle.
            let reach = peaks.map { max(0.5, CGFloat($0) * middle) }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: middle - reach[0]))
            for index in reach.indices.dropFirst() { path.addLine(to: CGPoint(x: CGFloat(index) * step, y: middle - reach[index])) }
            for index in reach.indices.reversed() { path.addLine(to: CGPoint(x: CGFloat(index) * step, y: middle + reach[index])) }
            path.closeSubpath()
            context.fill(path, with: .color(Theme.secondary))
        }
        .task(id: url) { await waveforms.load(url, count: 56) }
        .accessibilityHidden(true)
    }
}

// MARK: Pronunciations

struct PronunciationsPanel: View {
    @Environment(VoiceStore.self) private var store
    let voice: Voice
    @Binding var open: Bool
    /// Which Add button the form opens from: the header's + or the empty state's.
    @State private var adding: AddButton?
    @State private var word = ""
    @State private var respelling = ""

    private enum AddButton { case header, empty }

    var body: some View {
        Group {
            if open {
                VStack(spacing: 0) {
                    let empty = voice.pronunciations.isEmpty && (voice.proposedPronunciations ?? []).isEmpty
                    PanelHeader("Pronunciations") {
                        // While the list is empty its own Add button is the one way in, so the header doesn't repeat it.
                        if !empty {
                            Button { adding = .header } label: { Image(systemName: "plus") }
                                .buttonStyle(.icon(.s))
                                .help("Add a pronunciation")
                                .accessibilityLabel("Add pronunciation")
                                .popover(isPresented: presenting(.header), arrowEdge: .bottom) { addForm }
                        }
                        FoldButton(label: "pronunciations") { open = false }
                    }
                    if empty {
                        // At the top of the column, like the Timeline Inspector's, not floating mid-column.
                        EmptyState(title: "No pronunciations", message: "Add a word the voice says wrong and how it should sound.") {
                            Button("Add") { adding = .empty }
                                .buttonStyle(.vc(.secondary, .s))
                                .popover(isPresented: presenting(.empty), arrowEdge: .bottom) { addForm }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                    } else {
                        ScrollView { list }.scrollBounceBehavior(.basedOnSize)
                    }
                }
                .frame(width: 240)
                .sidePanel()
            } else {
                FoldedSidePanel(title: "Pronunciations") { open = true }
            }
        }
        .onChange(of: voice.proposedPronunciations?.count ?? 0, initial: true) { _, count in if count > 0 { open = true } }
    }

    private func presenting(_ button: AddButton) -> Binding<Bool> {
        Binding(get: { adding == button }, set: { if !$0 { adding = nil } })
    }

    /// Each word and how to say it, then an agent's proposals.
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(voice.pronunciations) { item in
                HStack(spacing: 6) {
                    Text(item.word)
                    arrow
                    Text(item.respelling)
                }
                .font(.vcBody)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(.rect)
                .help("\(item.word) \u{2192} \(item.respelling)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.word), said \(item.respelling)")
                .contextMenu {
                    Button("Delete", role: .destructive) { store.removePronunciation(item.id, voiceID: voice.id) }
                }
            }
            // Two lines, so the word and its respelling don't break mid-word beside the buttons.
            ForEach(voice.proposedPronunciations ?? []) { item in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.word)
                        HStack(spacing: 6) {
                            arrow
                            Text(item.respelling)
                        }
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 4)
                    DecisionButtons(label: "pronunciation of \(item.word)",
                                    onAccept: { store.acceptPronunciations([item.id], voiceID: voice.id) },
                                    onReject: { store.rejectPronunciations([item.id], voiceID: voice.id) })
                }
                .font(.vcBody)
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
        }
        .padding(.vertical, 8)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.vcCaption).foregroundStyle(Theme.tertiary).accessibilityHidden(true)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Word", text: $word)
            TextField("Say as", text: $respelling).onSubmit(add)
            Button("Add", action: add)
                .buttonStyle(.vc(.primary, .m))
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
        adding = nil
    }
}

// MARK: New voice

/// A new voice's name and how it's made: from a reading of the app's script, or from any audio or video.
struct NewVoice: Equatable, Identifiable {
    var name: String
    var script: Bool
    /// A fresh screen for each new voice, even one started while another is being cut.
    var id = UUID()
}

struct NewVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onStart: (NewVoice) -> Void
    @State private var name = ""
    @State private var script = true
    @State private var consent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New voice").font(.vcTitle)
            TextField("Name", text: $name, prompt: Text("Untitled voice"))
                .textFieldStyle(.roundedBorder)
                .focusEffectDisabled(false)
            HStack(spacing: 12) {
                choice("Read a script", detail: "Read our 2-minute script aloud, record it on your phone or Mac, then upload it. "
                       + "Sounds most like you.", script: true)
                choice("Upload any audio", detail: "A podcast, a video or an old recording. Best with one person talking and "
                       + "no music.", script: false)
            }
            Toggle("This is my voice, or I have the speaker's permission.", isOn: $consent)
                .toggleStyle(.checkbox)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.vc(.secondary, .m)).keyboardShortcut(.cancelAction)
                Button("Continue") {
                    onStart(NewVoice(name: name, script: script))
                    dismiss()
                }
                .buttonStyle(.vc(.primary, .m))
                .keyboardShortcut(.defaultAction)
                .disabled(!consent)
                .help(consent ? "" : "Tick the permission box to continue")
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.content)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    /// A card: the selection grey and a stronger border when chosen.
    private func choice(_ title: String, detail: String, script: Bool) -> some View {
        let selected = self.script == script
        return Button { self.script = script } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.vcBodyBold)
                Text(detail).font(.vcBody).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Theme.selection : Theme.hover, in: .rect(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(selected ? Theme.strong : Theme.line))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: From a recording

/// A new voice from a recording: with `script`, the script to read and how, then the upload; otherwise any audio or
/// video. The recording is cut into clips at its pauses, the speaker is asked for only when there's more than one, the
/// clean clips become takes, and an audition picks the main take.
struct FileCloneView: View {
    @Environment(VoiceStore.self) private var store
    let name: String
    /// Shows the app's script to read first; false goes straight to the upload.
    var script = true
    /// The new voice's ID, or nil when cancelled.
    let onDone: (String?) -> Void

    private enum Stage { case pick, cutting, grouping, speakers }
    @State private var stage = Stage.pick
    @State private var working = Progress()
    @State private var task: Task<Void, Never>?
    /// Copies of the sources and every clip, until the voice is made and they move to its raw/.
    @State private var folder: URL?
    @State private var groups: [[FileClip]] = []
    @State private var picking = false
    @State private var dropping = false
    @State private var copied = false

    var body: some View {
        Group {
            switch stage {
            case .pick: if script { pickView } else { anyFileView }
            case .cutting: progressView("Cutting your recording into clips", button: "Cancel")
            case .grouping: progressView("Finding your voice", button: "Cancel")
            case .speakers: speakersView
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

    private var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled voice" : trimmed
    }

    /// A large title, its controls and one button below them, in a centred column.
    private func screen<Content: View>(_ title: String, bottom: String, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text(title)
                .font(.vcDisplay)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer().frame(height: 48)
            content()
            Spacer(minLength: 32).frame(maxHeight: 72)
            Button(bottom, action: action).buttonStyle(.vc(.secondary, .l))
            Spacer(minLength: 24)
        }
        .frame(maxWidth: 880)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The script, in the Read view's type so it reads well aloud from the screen, under the steps. The whole pane
    /// takes a dropped file and lights up while one is over it.
    private var pickView: some View {
        VStack(spacing: 0) {
            PanelHeader {
                Text(title)
            } actions: {
                Button("Cancel") { onDone(nil) }.buttonStyle(.vc(.secondary, .s))
                Button {
                    CloneScript.copy()
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    // As wide as "Copy script", so Copied doesn't move the buttons beside it.
                    ZStack { Text("Copy script").hidden(); Text(copied ? "Copied" : "Copy script") }
                }
                .buttonStyle(.vc(.secondary, .s))
                .help("Copy the script to read it from your phone")
                Button("Upload recording\u{2026}") { picking = true }.buttonStyle(.vc(.primary, .s))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Read this script out loud, record it, and upload the recording.").font(.vcTitle)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(CloneScript.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(index + 1)").font(.vcBodyBold.monospacedDigit()).frame(width: 12, alignment: .leading)
                                    Text(step).fixedSize(horizontal: false, vertical: true)
                                }
                                .foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(CloneScript.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                            if index > 0 { PauseMark() }
                            Text(paragraph)
                                .font(.vcDisplay)
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("That's the end. Stop recording, send it to this Mac and upload it.").font(.vcTitle)
                        Button("Upload recording\u{2026}") { picking = true }.buttonStyle(.vc(.primary, .m))
                    }
                }
                .frame(maxWidth: ReadLayout.textWidth, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(dropping ? Theme.selection.opacity(0.5) : .clear)
        .overlay { if dropping { Rectangle().strokeBorder(Theme.strong) } }
        .dropDestination(for: URL.self) { urls, _ in start(urls) } isTargeted: { dropping = $0 }
    }

    /// Any audio or video, laid out like the script screen: the header's buttons, and the whole pane takes a drop.
    private var anyFileView: some View {
        VStack(spacing: 0) {
            PanelHeader {
                Text(title)
            } actions: {
                Button("Cancel") { onDone(nil) }.buttonStyle(.vc(.secondary, .s))
                Button("Choose files\u{2026}") { picking = true }.buttonStyle(.vc(.primary, .s))
            }
            EmptyState(title: "Drop audio or video files here",
                       message: "A podcast, a video or an old recording. Best with one person talking and no music.") {
                Button("Choose files\u{2026}") { picking = true }.buttonStyle(.vc(.secondary, .m))
            }
        }
        .background(dropping ? Theme.selection.opacity(0.5) : .clear)
        .overlay { if dropping { Rectangle().strokeBorder(Theme.strong) } }
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
                    SpeakerRow(number: index + 1, clips: group) { create(group) }
                }
            }
            .frame(width: 440)
        }
    }

    /// Cuts the files, then groups the clips by speaker. Returns false when nothing dropped is audio or video.
    private func start(_ urls: [URL]) -> Bool {
        let media = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audiovisualContent) == true }
        guard stage == .pick else { return false }
        guard !media.isEmpty else {
            if !urls.isEmpty { store.error = "That isn't an audio or video file. Upload the recording itself, such as an M4A or MP4." }
            return false
        }
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
                if groups.count > 1 {
                    stage = .speakers
                    working.active = false
                } else {
                    create(groups.first ?? all)
                }
            } catch {
                if !(error is CancellationError) {
                    store.error = "Couldn't use \(media.count > 1 ? "these files" : "this file"). \(error.localizedDescription)"
                }
                discard()
                stage = .pick
                working.active = false
            }
        }
        return true
    }

    /// Makes the voice from the speaker's clean clips, or, when none is clean, from those of a usable length, and opens
    /// it. The audition that picks its main take runs on in the store, so leaving the screen doesn't stop it; the voice
    /// page's Audition button shows it working.
    private func create(_ group: [FileClip]) {
        guard let folder else { return }
        var clips = group
        if !clips.contains(where: \.keep) {
            for index in clips.indices where (3...20).contains(clips[index].duration) { clips[index].keep = true }
        }
        guard clips.contains(where: \.keep) else {
            store.error = "No part of this recording is 3 to 20 seconds of clear speech. "
                + (script ? "Read the script again, stopping at each pause, and upload that." : "Try a clearer recording.")
            discard()
            stage = .pick
            working.active = false
            return
        }
        do {
            let id = try store.createVoice(name: name, from: folder, clips: clips)
            self.folder = nil
            working.active = false
            let store = store
            Task {
                do { try await store.audition(id) { _ in } } catch {
                    store.error = "Couldn't pick the best take. Click Audition to try again. \(error.localizedDescription)"
                }
            }
            onDone(id)
        } catch {
            store.error = "Couldn't create this voice. \(error.localizedDescription)"
            discard()
            stage = .pick
            working.active = false
        }
    }

    private func discard() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
}

/// Where the reader stops for about two seconds: the script's pause chip, between paragraphs.
private struct PauseMark: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "pause.fill").font(.system(size: 9))
            Text("pause 2 s")
        }
        .font(.vcCaptionBold)
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(Theme.fill, in: .rect(cornerRadius: Radius.chip))
        .accessibilityLabel("Pause for about two seconds")
    }
}

struct SpeakerRow: View {
    let number: Int
    let clips: [FileClip]
    let onChoose: () -> Void
    @State private var hovered = false

    var body: some View {
        // The clean clip nearest 8 s says the most about the voice.
        let sample = clips.filter(\.issues.isEmpty).min { abs($0.duration - 8) < abs($1.duration - 8) } ?? clips[0]
        HStack(spacing: 12) {
            PlayButton(url: sample.url)
            Button(action: onChoose) {
                HStack(spacing: 8) {
                    Text("Speaker \(number)").font(.vcBodyBold)
                    Spacer()
                    Text(clips.count == 1 ? "1 clip" : "\(clips.count) clips").foregroundStyle(Theme.secondary).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .font(.vcBody)
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(hovered ? Theme.hover : .clear, in: .rect(cornerRadius: Radius.row))
        .onHover { hovered = $0 }
    }
}

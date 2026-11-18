import SwiftUI
import UniformTypeIdentifiers

struct GenerateView: View {
    @Environment(VoiceStore.self) private var voices
    @Environment(ProjectStore.self) private var projects
    @Environment(Preview.self) private var preview
    @AppStorage("project") private var selection = ""
    @State private var exporting = false
    @AppStorage("terminalOpen") private var terminalOpen = false
    @AppStorage("terminalHeight") private var terminalHeight = 300.0
    /// Preview and Outputs; folding them gives the script the room. Preview keeps its state and playback while folded.
    @AppStorage("generateSideOpen") private var sideOpen = true
    /// Everything right of the sidebar, for the side column's width.
    @State private var width = 999.0
    /// The empty state's New project: the sidebar asks for the name, as its + does.
    @State private var creating = false

    var body: some View {
        SidebarLayout {
            ProjectsSidebar(selection: $selection, newRequest: $creating)
        } detail: {
            Group {
                if let project = projects.project(selection) {
                    workspace(project)
                } else {
                    EmptyState(title: "No projects yet", message: "A project holds one script, its voices and its renders.") {
                        Button("New project") { creating = true }.buttonStyle(.vc(.primary, .l))
                    }
                    .panel()
                }
            }
            .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
            .onDisappear { preview.pause() }
        }
        .toolbar {
            WorkspaceToolbar {
                renderSlot
                exportButton
            }
        }
        .focusedSceneValue(\.renderAction, renderAction)
        .focusedSceneValue(\.exportAction, exportAction)
        .sheet(isPresented: $exporting) { ExportSheet(projectID: selection) }
    }

    /// Edge to edge: the script, then Preview and Outputs, meeting at 1 pt dividers with no gaps and no frames.
    private func workspace(_ project: Project) -> some View {
        let timeline = Timeline(project) { projects.audioURL($0, projectID: project.id) }
        return HStack(spacing: 0) {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    ScriptPane(project: project).id(project.id)
                        .frame(maxHeight: .infinity)
                        .panel()
                    if terminalOpen {
                        // Its top edge is its own resizable divider. The script keeps room for its header and a few lines.
                        TerminalPanel(height: $terminalHeight, maxHeight: proxy.size.height - 250)
                    }
                }
            }
            PaneDivider()
            sideColumn(project)
        }
        .task(id: timeline) { await preview.load(timeline) }
        .onChange(of: project.video, initial: true) { preview.setVideo(project.video) }
        // Renders made before word timing get their words in the background, for the read-along and the pace notes; a
        // render blocks it, so it tries again once the render finishes.
        .onChange(of: project.id, initial: true) { projects.timeWordsIfNeeded(project.id, voices: voices) }
        .onChange(of: projects.progress == nil) { _, idle in
            if idle { projects.timeWordsIfNeeded(project.id, voices: voices) }
        }
        .focusedSceneValue(\.toggleSidePanel, toggleSide)
    }

    @ViewBuilder private func sideColumn(_ project: Project) -> some View {
        if sideOpen {
            VStack(spacing: 0) {
                // Laid out first, so the video gets the column's whole width and Outputs the height left.
                PreviewPane(project: project) { sideOpen = false }
                    .layoutPriority(1)
                PaneDivider(axis: .horizontal)
                OutputsPane(project: project).id(project.id)
            }
            .frame(width: Self.sideWidth(detail: width))
        } else {
            FoldedSidePanel(title: "Preview") { sideOpen = true }
        }
    }

    private func toggleSide() { sideOpen.toggle() }

    /// For the menu bar's Render and Export…: nil while there's nothing to do, which disables them.
    private var renderAction: (() -> Void)? { canRender ? { render() } : nil }
    private var exportAction: (() -> Void)? { canExport ? { exporting = true } : nil }

    /// The Preview and Outputs column for a detail `width` wide (everything right of the sidebar): 256 at the narrowest
    /// window with the default sidebar, so the script table fits, growing to 320 in wide windows.
    static func sideWidth(detail width: Double) -> Double { min(320, max(256, 256 + (width - 1000) * 0.15)) }

    // MARK: Toolbar

    /// Lines with text and no render that reads it: what Render renders, or applies when only marks changed.
    private var needed: Int { projects.project(selection)?.lines.count(where: \.needsRender) ?? 0 }
    private var canRender: Bool { projects.progress == nil && voices.busy == nil && needed > 0 }
    private var canExport: Bool { projects.project(selection)?.lines.contains { $0.chosenVersion != nil } ?? false }

    private func render() { projects.renderNeeded(selection, voices: voices) }

    /// Render, or its progress while it runs, in one slot as wide as the widest of them, so nothing beside it moves.
    private var renderSlot: some View {
        ZStack(alignment: .trailing) {
            // Sizes the slot: progress with the retry count is the widest state.
            renderProgress(value: 0, attempt: Version.tries).hidden().accessibilityHidden(true).allowsHitTesting(false)
            if let progress = projects.progress {
                renderProgress(value: progress, attempt: projects.renderTry)
            } else {
                let count = needed
                Button(action: render) {
                    HStack(spacing: 6) {
                        Text("Render")
                        if count > 0 { Text("\(count)").foregroundStyle(Theme.secondary).monospacedDigit() }
                    }
                }
                .buttonStyle(.vc(.secondary, .m))
                .disabled(!canRender)
                .help(voices.busy != nil ? "A voice check or audition is running"
                      : count == 0 ? "Every line is up to date" : "Render the lines that need it (⌘R)")
                .accessibilityLabel(count == 0 ? "Render" : "Render \(count) \(count == 1 ? "line" : "lines")")
            }
        }
    }

    private func renderProgress(value: Double, attempt: Int?) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: value)
                .progressViewStyle(.linear)
                .frame(width: 72)
                .accessibilityLabel("Rendering")
            // Lines that failed a check render again, keeping the best of up to five.
            if let attempt, attempt > 1 {
                Text("Try \(attempt) of \(Version.tries)").font(.vcCaption).foregroundStyle(Theme.secondary).monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            Button { projects.cancel() } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon(.s))
                .help("Cancel render")
                .accessibilityLabel("Cancel render")
        }
        .frame(height: VCSize.m.height)
    }

    /// The screen's one off-white action.
    private var exportButton: some View {
        Button("Export") { exporting = true }
            .buttonStyle(.vc(.primary, .m))
            .disabled(!canExport)
            .help(canExport ? "Export (⇧⌘E)" : "Render a line first")
    }
}

/// The projects list in Generate and Timeline, with its New, Rename and Delete; it keeps a project selected. It also
/// gives the menu bar its New Project (⌘N).
struct ProjectsSidebar: View {
    @Environment(ProjectStore.self) private var projects
    @Binding var selection: String
    /// Set to ask for a new project's name, as the + does (Generate's empty state); the sidebar sets it back.
    var newRequest: Binding<Bool> = .constant(false)
    @State private var naming: NameRequest?
    @State private var name = ""
    @State private var deleting: String?

    /// The New project and Rename alerts share one text field.
    private enum NameRequest: Identifiable {
        case new, rename(String)
        var id: String { if case .rename(let id) = self { id } else { "new" } }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Projects") {
                Button(action: askForNew) { Image(systemName: "plus") }
                    .buttonStyle(.icon(.s))
                    .help("New project (⌘N)")
                    .accessibilityLabel("New project")
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(projects.projects) { project in
                        Button { selection = project.id } label: {
                            SidebarRow(title: project.name, systemImage: "folder", selected: selection == project.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == project.id ? .isSelected : [])
                        .contextMenu {
                            Button("Rename…") { name = project.name; naming = .rename(project.id) }
                            Button("Delete…", role: .destructive) { deleting = project.id }
                        }
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
        }
        .onAppear { if projects.project(selection) == nil { selection = projects.projects.first?.id ?? "" } }
        .onChange(of: newRequest.wrappedValue) { _, requested in
            guard requested else { return }
            newRequest.wrappedValue = false
            askForNew()
        }
        .focusedSceneValue(\.newItemAction, askForNew)
        .focusedSceneValue(\.newItemTitle, "New Project")
        .alert(naming.map { if case .new = $0 { "New project" } else { "Rename project" } } ?? "",
               isPresented: Binding(present: $naming), presenting: naming) { request in
            TextField("Name", text: $name)
            switch request {
            case .new: Button("Create") { selection = projects.create(name: name) }
            case .rename(let id): Button("Rename") { projects.rename(id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \u{201C}\(projects.project(deleting)?.name ?? "")\u{201D}?",
                            isPresented: Binding(present: $deleting), titleVisibility: .visible, presenting: deleting) { id in
            Button("Delete project", role: .destructive) {
                projects.delete(id)
                if selection == id { selection = projects.projects.first?.id ?? "" }
            }
        } message: { _ in
            Text("Its renders move to the Trash.")
        }
    }

    private func askForNew() {
        name = ""
        naming = .new
    }
}

// MARK: Script

/// The script table's columns: fixed widths, and Text takes the rest. The header uses the same widths and insets as the
/// cells. Voice fits a name of about 11 characters; a score column fits its heading and a flagged value.
enum ScriptColumn {
    /// The status bar and the line number.
    static let number: CGFloat = 24
    static let text: CGFloat = 136
    static let voice: CGFloat = 100
    static let tone: CGFloat = 88
    static let pause: CGFloat = 44
    static let like: CGFloat = 60
    static let human: CGFloat = 48
    static let words: CGFloat = 56
    static let jev: CGFloat = 32
    static let version: CGFloat = 76
    static let gutter: CGFloat = 28
    /// From the pane's edges to the first and last columns.
    static let edge: CGFloat = 16
    /// A number's distance from its column's right edge.
    static let trailing: CGFloat = 8
    /// A pop-up's text from its column's left edge, which its heading shares.
    static let leading: CGFloat = 6
    /// Between the end of the text and the Voice column.
    static let textGap: CGFloat = 8

    /// The narrowest pane that shows every column: 692 pt, or 724 with Jev's, inside the 742 a 1200 pt window leaves.
    static func minimumWidth(jev: Bool) -> CGFloat {
        let fixed = number + voice + tone + pause + like + human + words + (jev ? self.jev : 0) + version + gutter
        return edge * 2 + fixed + text
    }
}

private typealias Column = ScriptColumn

/// The Script panel's two views: the table of lines, or the whole script to read along.
enum ScriptViewMode: String {
    case table, read

    var title: String { self == .table ? "Table" : "Read" }
}

/// The Pace menu's choices, in words a minute; nil follows each line's take.
enum PaceChoice {
    static let presets: [Double] = [130, 150, 170, 190]

    /// The menu's label: "Pace: take" or "Pace: 150".
    static func title(_ target: Double?) -> String {
        target.map { "Pace: \(Int($0.rounded()))" } ?? "Pace: take"
    }

    /// Set, but not one of the presets.
    static func isCustom(_ target: Double?) -> Bool {
        target.map { value in !presets.contains { abs($0 - value) < 0.5 } } ?? false
    }
}

struct ScriptPane: View {
    @Environment(VoiceStore.self) private var voices
    @Environment(ProjectStore.self) private var projects
    @Environment(Jev.self) private var jev
    @Environment(Player.self) private var player
    @Environment(Preview.self) private var preview
    @Environment(Terminals.self) private var terminals
    let project: Project
    @AppStorage("scriptView") private var mode = ScriptViewMode.table
    @AppStorage("terminalOpen") private var terminalOpen = false
    @State private var splitText: String?
    @State private var importing = false
    @State private var comparing: [String]?
    @State private var customPace = false
    @State private var customValue = 150.0
    /// The table's width, to tell when it's too narrow for every column.
    @State private var tableWidth: CGFloat = 0

    /// How much of the header's actions fit: all of them, then Pace, Compare and Check in one menu, then Review too.
    private enum HeaderFit { case full, folded, compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader {
                HStack(spacing: 12) {
                    Text("Script")
                    SegmentedTabs(selection: $mode, options: [ScriptViewMode.table, .read], title: \.title, segmentWidth: 56, size: .s,
                                  label: "Script view")
                }
                .fixedSize()
            } actions: {
                ViewThatFits(in: .horizontal) {
                    actions(.full)
                    actions(.folded)
                    actions(.compact)
                }
                // The Pace menu, or the menu that holds it, is the leftmost action in every fit.
                .popover(isPresented: $customPace, attachmentAnchor: .rect(.rect(CGRect(x: 0, y: 0, width: 40, height: 24))),
                         arrowEdge: .bottom) {
                    CustomPacePopover(value: customValue) { value in
                        projects.setPaceTarget(value, in: project.id)
                        customPace = false
                    }
                }
                // Ahead of the header's spacer, so the actions get the room they need and fold only when it runs out.
                .layoutPriority(1)
            }
            if mode == .read {
                ReadView(project: project)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .sheet(isPresented: Binding(present: $splitText)) {
            SplitSheet(text: splitText ?? "") { lines in projects.addLines(lines, to: project.id, voices: voices) }
        }
        .sheet(isPresented: Binding(present: $comparing)) {
            CompareSheet(lines: project.lines.filter { comparing?.contains($0.id) ?? false },
                         title: comparing?.count == 1 ? "Line \((project.lines.firstIndex { $0.id == comparing?.first } ?? 0) + 1)" : "Whole script") { tones in
                projects.compare(comparing ?? [], tones: tones, in: project.id, voices: voices)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { splitText = try String(contentsOf: url, encoding: .utf8) } catch {
                projects.error = "Couldn't read this file. \(error.localizedDescription)"
            }
        }
    }

    private var renderable: [Line] { project.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } }

    private var table: some View {
        let minimum = Column.minimumWidth(jev: jev.added)
        // Narrower than every column needs (the widest sidebar in a small window): the table keeps its columns and
        // scrolls sideways, rather than cut off Version and the render buttons. The allowance is for a scroll bar that
        // takes room.
        let narrow = tableWidth > 0 && tableWidth < minimum + 16
        // One clock for the read-along, here rather than per row: each tick gives only the playing row a new `lit`,
        // and rows are Equatable, so the others aren't redrawn.
        return TimelineView(.animation(minimumInterval: 0.05, paused: player.playing == nil && !preview.isPlaying)) { _ in
            let lit = ReadAlong.lit(in: project, projects: projects, preview: preview, player: player)
            if narrow {
                ScrollView(.horizontal) {
                    rows(lit).frame(width: minimum)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                rows(lit)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
    }

    private func rows(_ lit: LitWord?) -> some View {
        ScrollView {
            // The header scrolls with the rows, so a scroll bar that takes room can't shift the rows under it. Rows and
            // their separators run to both edges; the rows carry their own inset.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(project.lines.enumerated()), id: \.element.id) { index, line in
                        LineRow(projectID: project.id, line: line, number: index + 1, isLast: index == project.lines.count - 1,
                                lit: LineRow.lit(lit, in: line), paceTarget: project.paceTarget,
                                onCompare: { comparing = [line.id] })
                            .equatable()
                        Theme.rule.frame(height: 1)
                    }
                    footer
                } header: {
                    // Leading, so the rule under a header wider than the pane starts at its edge.
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Theme.line.frame(height: 1)
                    }
                    .background(Theme.content)
                }
            }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Header actions

    /// Least used on the left, most used on the right: the pace target, Compare, Check, Review pace, then Accept and
    /// Reject all while an agent's changes wait.
    private func actions(_ fit: HeaderFit) -> some View {
        let pending = project.lines.filter { $0.proposal != nil }.map(\.id)
        return HStack(spacing: 8) {
            if fit == .full {
                Menu {
                    paceOptions
                } label: {
                    HStack(spacing: 4) {
                        Text(PaceChoice.title(project.paceTarget))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.vc(.ghost, .s))
                .menuIndicator(.hidden)
                .fixedSize()
                .help("The pace the pace notes aim for")
                .accessibilityLabel("Pace target")
                .accessibilityValue(paceValue)
                Button("Compare styles…") { comparing = renderable.map(\.id) }
                    .buttonStyle(.vc(.secondary, .s))
                    .disabled(!canCompare)
                if jev.added {
                    Button(jev.isChecking ? "Checking…" : "Check script", action: checkScript)
                        .buttonStyle(.vc(.secondary, .s))
                        .disabled(!canCheck)
                }
            } else {
                Menu {
                    Button("Compare styles…") { comparing = renderable.map(\.id) }.disabled(!canCompare)
                    if jev.added {
                        Button(jev.isChecking ? "Checking…" : "Check script", action: checkScript).disabled(!canCheck)
                    }
                    Divider()
                    Menu(PaceChoice.title(project.paceTarget)) { paceOptions }
                    if fit == .compact {
                        Divider()
                        Button("Review pace", action: reviewPace).disabled(!canReview)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.icon(.s))
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More script actions")
            }
            if fit != .compact {
                Button("Review pace", action: reviewPace)
                    .buttonStyle(.vc(.secondary, .s))
                    .disabled(!canReview)
                    .help(canReview ? "Ask the terminal agent to review the pacing and propose changes" : "Render a line first")
            }
            if pending.count > 1 {
                Button("Accept all") { projects.accept(pending, in: project.id) }.buttonStyle(.vc(.secondary, .s))
                Button("Reject all") { projects.reject(pending, in: project.id) }.buttonStyle(.vc(.secondary, .s))
            }
        }
        .fixedSize()
    }

    /// Checked items: the take's own pace, the presets, and Custom… for any other number.
    @ViewBuilder private var paceOptions: some View {
        let target = project.paceTarget
        Toggle("Your take's pace", isOn: Binding(get: { target == nil }, set: { _ in projects.setPaceTarget(nil, in: project.id) }))
        Divider()
        ForEach(PaceChoice.presets, id: \.self) { preset in
            Toggle("\(Int(preset)) words a minute", isOn: Binding(get: { target.map { abs($0 - preset) < 0.5 } ?? false },
                                                                 set: { _ in projects.setPaceTarget(preset, in: project.id) }))
        }
        Divider()
        Toggle(PaceChoice.isCustom(target) ? "Custom (\(Int((target ?? 0).rounded())))…" : "Custom…",
               isOn: Binding(get: { PaceChoice.isCustom(target) }, set: { _ in
                   customValue = (target ?? 150).rounded()
                   customPace = true
               }))
    }

    private var paceValue: String {
        project.paceTarget.map { "\(Int($0.rounded())) words a minute" } ?? "Your take's pace"
    }

    private var canCompare: Bool { !renderable.isEmpty && projects.progress == nil }
    private var canCheck: Bool { !jev.isChecking && !renderable.isEmpty }
    /// The agent reads the pace from renders, so there must be one.
    private var canReview: Bool { project.lines.contains { $0.chosenVersion != nil } }

    private func checkScript() {
        let subjects = project.lines.map(JevSubject.init)
        Task { await jev.check(subjects) }
    }

    private func reviewPace() {
        terminalOpen = true
        terminals.ask(Agent.reviewPacePrompt)
    }

    /// Column headings, with what each score means on hover.
    private var header: some View {
        HStack(spacing: 0) {
            Text("#").padding(.leading, Column.leading).frame(width: Column.number, alignment: .leading)
            Text("Text").padding(.trailing, Column.textGap).frame(minWidth: Column.text, maxWidth: .infinity, alignment: .leading)
            Text("Voice").padding(.leading, Column.leading).frame(width: Column.voice, alignment: .leading)
            Text("Tone").padding(.leading, Column.leading).frame(width: Column.tone, alignment: .leading)
            Text("Pause").padding(.trailing, Column.trailing).frame(width: Column.pause, alignment: .trailing)
                .help("Silence after the line, in seconds")
            Text("Like you").padding(.trailing, Column.trailing).frame(width: Column.like, alignment: .trailing)
                .help("How much the render sounds like you. Grey when the line is too short to judge.")
            Text("Human").padding(.trailing, Column.trailing).frame(width: Column.human, alignment: .trailing)
                .help("How natural it sounds, from 1 to 5")
            Text("Words").padding(.trailing, Column.trailing).frame(width: Column.words, alignment: .trailing)
                .help("How many of the words were heard as written")
            if jev.added { Text("Jev").frame(width: Column.jev).help("Jev's checks of the line") }
            Text("Version").padding(.leading, Column.leading).frame(width: Column.version, alignment: .leading)
            Color.clear.frame(width: Column.gutter)
        }
        .font(.vcCaptionBold)
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
        .padding(.horizontal, Column.edge)
        .frame(height: 28)
    }

    /// Ghost buttons, their labels on the pane's 16 pt text edge.
    private var footer: some View {
        HStack(spacing: 8) {
            Button { projects.addLines([""], to: project.id, voices: voices) } label: { Label("Add line", systemImage: "plus") }
            Button("Paste…") { splitText = NSPasteboard.general.string(forType: .string) ?? "" }
            Button("Import…") { importing = true }
        }
        .buttonStyle(.vc(.ghost, .s))
        .padding(.horizontal, Column.edge - VCSize.s.padding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LineRow: View {
    @Environment(VoiceStore.self) private var voices
    @Environment(ProjectStore.self) private var projects
    @Environment(Jev.self) private var jev
    @Environment(Player.self) private var player
    @Environment(Preview.self) private var preview
    let projectID: String
    let line: Line
    let number: Int
    let isLast: Bool
    /// The display word being said while this row's text plays, else nil.
    let lit: Int?
    /// The project's pace target, for the pace notes.
    let paceTarget: Double?
    let onCompare: () -> Void
    @State private var hovered = false
    @State private var versionHovered = false
    /// Applying marks takes a moment; a spinner shows only when it takes longer, so the usual case doesn't flash.
    @State private var slowApply = false

    /// The bar beside a line's number: nothing while its render is current, grey while it has none or its text changed
    /// since, amber when the chosen version failed a check.
    enum Mark: Equatable {
        case current, stale, flagged

        var color: Color? {
            switch self {
            case .current: nil
            case .stale: Theme.secondary.opacity(0.6)
            case .flagged: Theme.amber
            }
        }
    }

    static func mark(_ line: Line) -> Mark {
        if line.needsRender { return .stale }
        if let version = line.chosenVersion, !version.flags.isEmpty { return .flagged }
        return .current
    }

    /// What VoiceOver says for the row: "Line 3, changed since render".
    static func accessibilityLabel(_ line: Line, number: Int) -> String {
        let state: String? = switch mark(line) {
        case .current: nil
        case .stale: line.chosenVersion == nil ? "not rendered" : "changed since render"
        case .flagged: "failed a check"
        }
        return (["Line \(number)"] + (state.map { [$0] } ?? [])).joined(separator: ", ")
    }

    var body: some View {
        let version = line.chosenVersion
        let scores = version?.scores
        // A pending change takes room from the version cell for its Accept and Reject buttons.
        let decision: CGFloat = line.proposal == nil ? 0 : 22
        let isApplying = projects.applying.contains(line.id)
        let playing = preview.currentLine == line.id
        HStack(spacing: 0) {
            Text("\(number)")
                .font(.vcCaption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .padding(.leading, Column.leading)
                .frame(width: Column.number, alignment: .leading)
            // The script rules the line breaks show under its text, for the pending change while there is one.
            VStack(alignment: .leading, spacing: 4) {
                if let proposal = line.proposal {
                    ProposalText(line: line, proposal: proposal)
                } else {
                    // Return or leaving the text renders or applies the edit and plays it; a command applies at once.
                    ScriptTextView(text: line.text, style: .row, lit: lit,
                                   onChange: { projects.setText($0, line: line.id, in: projectID) },
                                   onCommit: commit,
                                   onCommand: { text in
                                       projects.setText(text, line: line.id, in: projectID)
                                       commit()
                                   })
                }
                ForEach(Script.warnings(line.proposal?.text ?? line.text), id: \.self) { Warning(text: $0) }
                let pace = paceNotes
                ForEach(pace.notes, id: \.self) { note in
                    PaceNoteView(note: note, help: pace.verdict, busy: isApplying, onFix: fixPace)
                }
            }
            .padding(.trailing, Column.textGap)
            .frame(minWidth: Column.text, maxWidth: .infinity, alignment: .leading)
            voiceMenu.frame(width: Column.voice)
            toneMenu.frame(width: Column.tone)
            pauseField.frame(width: Column.pause)
            ScoreCell(value: scores.map { "\($0.likeYou)%" }, flag: joined(version?.likeYouFlag, version?.pitchFlag), dim: version?.likeYouJudged == false,
                      help: version?.likeYouJudged == false ? "Too short to judge" : nil).frame(width: Column.like)
            ScoreCell(value: scores.map { String(format: "%.1f", $0.human) },
                      flag: joined(version?.humanFlag, version?.paceFlag, version?.gapFlag)).frame(width: Column.human)
            ScoreCell(value: scores.map { "\($0.words)%" }, flag: version?.wordsFlag,
                      help: scores.map { "Heard: \u{201C}\($0.heard)\u{201D}" }).frame(width: Column.words)
            if jev.added { JevCell(subject: JevSubject(line)).frame(width: Column.jev) }
            versionControl(playingRow: playing).frame(width: Column.version - decision)
            Group {
                if line.proposal != nil {
                    DecisionButtons(label: line.added == true ? "new line \(number)" : "change to line \(number)",
                                    onAccept: { projects.accept([line.id], in: projectID) },
                                    onReject: { projects.reject([line.id], in: projectID) })
                } else {
                    statusCell
                }
            }
            .frame(width: Column.gutter + decision, alignment: .trailing)
        }
        .font(.vcBody.monospacedDigit())
        .padding(.horizontal, Column.edge)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        // Rectangular, between the full-width separators: rows are a table, not cards.
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle().fill(playing ? Theme.selection : hovered ? Theme.hover : .clear)
                if let color = Self.mark(line).color {
                    StatusBar(color: color).padding(.vertical, 8).padding(.leading, Column.edge)
                }
            }
        }
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .task(id: isApplying) {
            slowApply = false
            guard isApplying else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { slowApply = true }
        }
        .simultaneousGesture(TapGesture().onEnded { preview.seek(toLine: line.id) })
        .contextMenu {
            Button("Compare styles…", action: onCompare).disabled(line.text.isEmpty || projects.progress != nil)
            Divider()
            Button("Move up") { projects.moveLine(line.id, by: -1, in: projectID) }.disabled(number == 1)
            Button("Move down") { projects.moveLine(line.id, by: 1, in: projectID) }.disabled(isLast)
            Divider()
            Button("Delete line", role: .destructive) { projects.deleteLine(line.id, in: projectID) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(line, number: number))
    }

    /// A score cell's flags: Like you also covers pitch, Human also covers pace and gaps.
    private func joined(_ flags: String?...) -> String? {
        let found = flags.compactMap(\.self)
        return found.isEmpty ? nil : found.joined(separator: "\n")
    }

    private var voiceMenu: some View {
        Menu {
            ForEach(voices.voices) { voice in
                Button(voice.name) { projects.setVoice(voice.id, line: line.id, in: projectID) }
            }
        } label: {
            InlinePopupLabel(title: voices.voice(line.voiceID)?.name ?? "Choose", dim: voices.voice(line.voiceID) == nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(voices.voice(line.voiceID)?.name ?? "")
        .accessibilityLabel("Voice")
    }

    private var toneMenu: some View {
        Menu {
            ForEach(Tone.all, id: \.self) { tone in
                Button(tone) { projects.setTone(tone, line: line.id, in: projectID) }
            }
        } label: {
            InlinePopupLabel(title: line.tone)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // The whole column, so "Confident", the longest tone, fits beside the chevron.
        .accessibilityLabel("Tone")
    }

    private var pauseField: some View {
        HStack(spacing: 0) {
            TextField("Pause", value: Binding(get: { line.pauseAfter }, set: { projects.setPause($0, line: line.id, in: projectID) }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 28)
            Text("s")
        }
        .padding(.trailing, Column.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pause after, seconds")
    }

    /// Borderless like the other pop-ups: the label plays the chosen version, the chevron picks another, which then
    /// plays; a fill under the pointer, the selection grey while it plays. Raw renders, the hidden sources of marked
    /// versions, are never listed or counted. A pending change narrows the cell, so it gets smaller type.
    @ViewBuilder private func versionControl(playingRow: Bool) -> some View {
        let compact = line.proposal != nil
        let visible = line.visibleVersions
        if let version = line.chosenVersion, let index = visible.firstIndex(of: version) {
            let url = projects.audioURL(version, projectID: projectID)
            let playing = player.playing == url
            HStack(spacing: 0) {
                Button { player.toggle(url) } label: {
                    HStack(spacing: 4) {
                        Text("v\(index + 1) of \(visible.count)").lineLimit(1).minimumScaleFactor(0.8)
                        if version.direction {
                            Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.leading, Column.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(versionTitle(version, index))
                .accessibilityLabel(playing ? "Stop" : "Play version \(index + 1)")
                Menu {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { offset, item in
                        Button(versionTitle(item, offset)) {
                            projects.choose(item.id, line: line.id, in: projectID)
                            let url = projects.audioURL(item, projectID: projectID)
                            if player.playing != url { player.toggle(url) }
                        }
                    }
                } label: {
                    // Tertiary at rest like the other pop-ups' chevrons, but never on the selection grey.
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(versionHovered || playing || playingRow ? Theme.secondary : Theme.tertiary)
                        .frame(width: compact ? 14 : 18, height: VCSize.s.height)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Versions")
            }
            .font((compact ? Font.vcCaption : .vcBody).monospacedDigit())
            .frame(height: VCSize.s.height)
            .background(playing ? Theme.selection : versionHovered ? Theme.hover : .clear, in: .rect(cornerRadius: VCSize.s.radius))
            .onHover { versionHovered = $0 }
            .padding(.trailing, compact ? 2 : 4)
        } else {
            // Nothing rendered yet: an empty cell, not a dash.
            Color.clear
        }
    }

    private func versionTitle(_ version: Version, _ index: Int) -> String {
        (["v\(index + 1)", version.tone] + (version.direction ? ["direction"] : [])).joined(separator: " · ")
    }

    /// What the gutter shows: a spinner while the line renders (or applies for a while), a clock while it waits for
    /// the render ahead of it, else the button that brings it up to date.
    enum Status: Equatable {
        case rendering, waiting, applying
        /// Only marks changed: applying them needs no render.
        case apply
        case render
    }

    static func status(_ line: Line, renderingLine: String?, queued: [String], applying: Set<String>) -> Status {
        if renderingLine == line.id { return .rendering }
        if queued.contains(line.id) { return .waiting }
        if applying.contains(line.id) { return .applying }
        return line.needsRender && !line.needsVoice ? .apply : .render
    }

    @ViewBuilder private var statusCell: some View {
        let status = Self.status(line, renderingLine: projects.renderingLine, queued: projects.queued, applying: projects.applying)
        switch status {
        case .rendering:
            ProgressView().controlSize(.small).frame(width: VCSize.s.height, height: VCSize.s.height)
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .frame(width: VCSize.s.height, height: VCSize.s.height)
                .help("Waiting… It renders after the line ahead of it.")
                .accessibilityElement()
                .accessibilityLabel("Line \(number) waiting to render")
        case .applying where slowApply:
            ProgressView().controlSize(.small).frame(width: VCSize.s.height, height: VCSize.s.height)
        case .applying, .apply, .render:
            // Kept as is while marks apply, so the usual quick apply doesn't flash a new state.
            rerenderButton(apply: status != .render)
        }
    }

    /// Bright and always there while the line needs a render or its marks applied; otherwise rendering again is a
    /// choice, so it waits for the pointer to come over the row.
    private func rerenderButton(apply: Bool) -> some View {
        let needed = line.needsRender
        return Button {
            if apply {
                guard !projects.applying.contains(line.id) else { return }
                commit()
            } else {
                projects.rerender(line.id, in: projectID, voices: voices)
            }
        } label: {
            if needed {
                Image(systemName: "arrow.clockwise").foregroundStyle(Theme.text)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.icon(.s))
        .opacity(needed || hovered ? 1 : 0)
        // Applying marks doesn't use the voice model, so it can run beside a render.
        .disabled(line.text.trimmingCharacters(in: .whitespaces).isEmpty || !apply && (projects.progress != nil || voices.busy != nil))
        .help(apply ? "Apply the changed pauses and speeds, without a new render" : "Render again, until a version passes")
        .accessibilityLabel(apply ? "Apply changes to line \(number)" : "Render line \(number) again")
    }

    // MARK: Editing and pace

    /// Renders the line or applies its marks as needed, then plays it.
    private func commit() {
        projects.commitAndPlay(line.id, in: projectID, voices: voices, player: player)
    }

    /// The pace notes for the chosen version, as `ProjectStore.paceReport` judges it but from this row's own line, so an
    /// edit to another line doesn't redraw every row. None while the text differs from the version's: its words are
    /// what the report's word numbers count.
    private var paceNotes: (notes: [PaceNote], verdict: String?) {
        guard line.proposal == nil, let version = line.chosenVersion, version.text == line.text, let words = version.words,
              let target = Pace.target(projectOverride: paceTarget, referencePace: version.scores?.referencePace) else { return ([], nil) }
        let parsed = Marks.parse(version.text)
        guard let times = Marks.displayTimes(parsed, spoken: words), let report = Pace.report(parsed, times: times, target: target)
        else { return ([], nil) }
        return (PaceNote.notes(report, tokens: parsed.tokens), report.verdict)
    }

    /// Slows or speeds a stretch at once, then plays the line. A line that needs the voice first is rendered, then played.
    private func fixPace(_ range: ClosedRange<Int>) {
        let lineID = line.id
        Task {
            do {
                if try await projects.fixPace(line: lineID, range: range, in: projectID, voices: voices) {
                    if let version = projects.project(projectID)?.line(lineID)?.chosenVersion {
                        player.play(projects.audioURL(version, projectID: projectID), from: 0)
                    }
                } else {
                    projects.commitAndPlay(lineID, in: projectID, voices: voices, player: player)
                }
            } catch is CancellationError {
            } catch {
                projects.error = "Couldn't change the pace. \(error.localizedDescription)"
            }
        }
    }

    /// The row's display word being said, from the word playing now: only when this line's version plays, and only while
    /// the line's text is still that version's, so the word numbers match.
    static func lit(_ lit: LitWord?, in line: Line) -> Int? {
        guard let lit, lit.lineID == line.id, let version = line.versions.first(where: { $0.id == lit.versionID }),
              version.text == line.text else { return nil }
        return lit.token
    }
}

extension LineRow: Equatable {
    /// The row's values without `onCompare`, which only captures the pane's state. The read-along clock rebuilds every
    /// row on each tick; with this only the playing one, whose `lit` changed, is redrawn.
    nonisolated static func == (a: LineRow, b: LineRow) -> Bool {
        a.projectID == b.projectID && a.line == b.line && a.number == b.number && a.isLast == b.isLast && a.lit == b.lit
            && a.paceTarget == b.paceTarget
    }
}

/// One quiet note under a line about its pace: a rushed or slow stretch with the button that fixes it, a long gap, or
/// the verdict alone when there's nothing more particular to point at. Shown only when the line as a whole is off pace.
struct PaceNote: Hashable, Sendable {
    enum Fix: Hashable, Sendable {
        case slowDown, speedUp
        var title: String { self == .slowDown ? "Slow down" : "Speed up" }
    }

    /// In amber: "Rushed:", "Slow:" or "1.4 s gap".
    var key: String
    /// After the key: the stretch's words in quotes, or where the gap is.
    var detail: String
    /// Display tokens, for `ProjectStore.fixPace`.
    var range: ClosedRange<Int>? = nil
    var fix: Fix? = nil

    /// `Rushed: “and it's free” · Slow down`
    var text: String { "\(key) \(detail)" + (fix.map { " · \($0.title)" } ?? "") }

    /// The fix button's label for VoiceOver, with its words: `Slow down “and it's free”`.
    var fixLabel: String? { fix.map { "\($0.title) \(detail)" } }

    static let limit = 2
    /// A longer stretch shows its first and last words.
    static let phraseWords = 8

    /// Up to `limit` notes: stretches in the order they're said, then gaps, even on a line that's on pace overall, as one
    /// rushed phrase is what the ear catches. Without either, the verdict when the whole line is off.
    static func notes(_ report: PaceReport, tokens: [ParsedLine.Token]) -> [PaceNote] {
        let stretches = (report.rushed.map { ($0, Fix.slowDown) } + report.dragging.map { ($0, Fix.speedUp) })
            .filter { tokens.indices.contains($0.0.lowerBound) }
            .sorted { $0.0.lowerBound < $1.0.lowerBound }
            .map { range, fix in
                PaceNote(key: fix == .slowDown ? "Rushed:" : "Slow:", detail: quoted(phrase(range, in: tokens)), range: range, fix: fix)
            }
        let gaps = report.gaps.filter { tokens.indices.contains($0.after) }.map { gap in
            PaceNote(key: String(format: "%.1f s gap", gap.seconds), detail: "after " + quoted(phrase(gap.after...gap.after, in: tokens)))
        }
        let notes = stretches + gaps
        guard notes.isEmpty else { return Array(notes.prefix(limit)) }
        guard let verdict = report.verdict else { return [] }
        return [PaceNote(key: report.wordsPerMinute > report.target ? "Rushed:" : "Slow:", detail: verdict)]
    }

    /// The display words of `range` as written, without the punctuation at either end: `and it's free`. Past
    /// `phraseWords`, the first four and last three with an ellipsis between.
    static func phrase(_ range: ClosedRange<Int>, in tokens: [ParsedLine.Token]) -> String {
        let low = max(range.lowerBound, 0), high = min(range.upperBound, tokens.count - 1)
        guard low <= high else { return "" }
        let words = tokens[low...high].map(\.text)
        let shown = words.count > phraseWords ? words.prefix(4) + ["…"] + words.suffix(3) : words[...]
        return shown.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    private static func quoted(_ text: String) -> String { "\u{201C}\(text)\u{201D}" }
}

/// A pace note in the row: secondary text with its key in amber, quieter than a `Warning`, and its fix as a text button.
private struct PaceNoteView: View {
    let note: PaceNote
    /// The verdict sentence, on hover.
    let help: String?
    let busy: Bool
    let onFix: (ClosedRange<Int>) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("\(Text(note.key).foregroundStyle(Theme.amber)) \(note.detail)")
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let fix = note.fix, let range = note.range {
                Text("·").foregroundStyle(Theme.secondary).accessibilityHidden(true)
                Button(fix.title) { onFix(range) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .fontWeight(.semibold)
                    .fixedSize()
                    .disabled(busy)
                    .accessibilityLabel(note.fixLabel ?? fix.title)
            }
        }
        .font(.vcCaption)
        .help(help ?? "")
    }
}

/// The Pace menu's Custom…: a target in words a minute, which the store keeps within `Project.paceTargets`.
struct CustomPacePopover: View {
    @State var value: Double
    let onSet: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pace target").font(.vcBodyBold)
            HStack(spacing: 8) {
                TextField("150", value: $value, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .onSubmit { onSet(value) }
                    .accessibilityLabel("Words a minute")
                Text("words a minute").foregroundStyle(Theme.secondary)
            }
            HStack {
                Text("\(Int(Project.paceTargets.lowerBound)) to \(Int(Project.paceTargets.upperBound))")
                    .font(.vcCaption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 12)
                Button("Set") { onSet(value) }.buttonStyle(.vc(.primary, .m)).keyboardShortcut(.defaultAction)
            }
        }
        .font(.vcBody)
        .padding(16)
        .frame(width: 240)
    }
}

/// ✓ and ✕ for a change an agent proposed: icon buttons, no outlines.
struct DecisionButtons: View {
    /// What is decided, for VoiceOver: "Accept change to line 3".
    let label: String
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("checkmark", help: "Accept", action: onAccept).accessibilityLabel("Accept \(label)")
            button("xmark", help: "Reject", action: onReject).accessibilityLabel("Reject \(label)")
        }
    }

    private func button(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(.icon(.s))
            .help(help)
    }
}

/// A line's pending change: the old text struck through above the new, and any tone or pause change. A line an agent
/// added is marked new.
private struct ProposalText: View {
    let line: Line
    let proposal: Proposal

    var body: some View {
        let changes = [
            line.added == true ? "New line" : nil,
            proposal.tone == line.tone ? nil : "\(line.tone) → \(proposal.tone)",
            proposal.pauseAfter == line.pauseAfter ? nil : "\(seconds(line.pauseAfter)) → \(seconds(proposal.pauseAfter))",
        ].compactMap(\.self)
        let replaced = !line.text.isEmpty && proposal.text != line.text
        VStack(alignment: .leading, spacing: 3) {
            if replaced {
                Text(line.text).strikethrough().foregroundStyle(Theme.secondary)
            }
            Text(proposal.text)
            if !changes.isEmpty {
                Text(changes.joined(separator: " · ")).font(.vcCaption).foregroundStyle(Theme.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((["Proposed: \(proposal.text)"] + (replaced ? ["was: \(line.text)"] : []) + changes).joined(separator: ", "))
    }

    private func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) + "s" }
}

/// A score as a number, right-aligned so values line up row to row; a low one gets the amber triangle, a semibold
/// value and its reason on hover. A dim one is shown but not judged. No score leaves the cell empty.
private struct ScoreCell: View {
    let value: String?
    let flag: String?
    var dim = false
    var help: String?

    var body: some View {
        HStack(spacing: 4) {
            if flag != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Theme.amber)
            }
            if let value {
                Text(value)
                    .fontWeight(flag == nil ? .regular : .semibold)
                    .foregroundStyle(dim ? Theme.secondary : Theme.text)
            }
        }
        .lineLimit(1)
        .padding(.trailing, Column.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .contentShape(.rect)
        .help(flag ?? help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([value ?? "None", flag ?? (dim ? help : nil)].compactMap(\.self).joined(separator: ", "))
    }
}

/// A line's Jev checks: quiet when they pass, the amber triangle when one fails, a neutral mark when one is unsettled.
/// A failed call is shown as an error, never as a failed check. The reasons show on hover.
private struct JevCell: View {
    @Environment(Jev.self) private var jev
    let subject: JevSubject

    var body: some View {
        let result = jev.results[subject], error = jev.failures[subject]
        let help = error.map { "Check failed. \($0)" } ?? result?.notes(tone: subject.tone).joined(separator: "\n")
            ?? (subject.text.isEmpty ? "" : "Not checked")
        Group {
            if jev.checking.contains(subject) {
                ProgressView().controlSize(.mini)
            } else if error != nil {
                mark("exclamationmark.icloud", Theme.secondary)
            } else if let result {
                switch result.status {
                case .no: mark("exclamationmark.triangle.fill", Theme.amber)
                case .unsettled: mark("questionmark.circle", Theme.secondary)
                case .yes: mark("checkmark", Theme.secondary)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help.isEmpty ? "Jev: not checked" : "Jev: " + help.replacing("\n", with: ", "))
    }

    private func mark(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
    }
}

// MARK: Sheets

struct SplitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let onAdd: ([String]) -> Void
    @State private var split = ScriptSplit.sentences

    var body: some View {
        let lines = Script.lines(Script.plainText(text), by: split)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Split into lines").font(.vcTitle)
                Spacer()
                Picker("Split", selection: $split) {
                    ForEach(ScriptSplit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            TextEditor(text: $text)
                .font(.vcBody)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.hover, in: .rect(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Theme.line))
                .frame(height: 280)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.vc(.secondary, .m)).keyboardShortcut(.cancelAction)
                Button(lines.count == 1 ? "Add 1 line" : "Add \(lines.count) lines") {
                    onAdd(lines)
                    dismiss()
                }
                .buttonStyle(.vc(.primary, .m))
                .keyboardShortcut(.defaultAction)
                .disabled(lines.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Theme.content)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }
}

struct CompareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VoiceStore.self) private var voices
    let lines: [Line]
    let title: String
    let onRender: ([String]) -> Void
    @State private var tones: Set<String> = []

    var body: some View {
        let count = lines.count * tones.count
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare styles").font(.vcTitle)
                Text(title).foregroundStyle(Theme.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                ForEach(Tone.all, id: \.self) { tone in
                    Toggle(isOn: Binding(get: { tones.contains(tone) },
                                         set: { if $0 { tones.insert(tone) } else { tones.remove(tone) } })) {
                        HStack(spacing: 6) {
                            Text(tone)
                            if !recorded(tone) { Text("direction").foregroundStyle(Theme.secondary) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.vc(.secondary, .m)).keyboardShortcut(.cancelAction)
                Button(count == 1 ? "Render 1 version" : "Render \(count) versions") {
                    onRender(Tone.all.filter(tones.contains))
                    dismiss()
                }
                .buttonStyle(.vc(.primary, .m))
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Theme.content)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onAppear {
            // Recorded tone takes first; with none, two contrasting directions.
            let own = Set(lines.map(\.tone))
            let recordedTones = Tone.all.filter { recorded($0) && !own.contains($0) }
            tones = Set(recordedTones.isEmpty ? ["Confident", "Happy"] : recordedTones)
        }
    }

    /// Every line's voice has a take in this tone.
    private func recorded(_ tone: String) -> Bool {
        lines.allSatisfy { !(voices.voice($0.voiceID)?.takes(tone).isEmpty ?? true) }
    }
}

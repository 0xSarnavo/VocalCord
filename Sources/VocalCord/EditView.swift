import SwiftUI

// MARK: Track math

/// Where times sit on the track at a zoom: `pointsPerSecond` of timeline, after a margin so 0:00 isn't on the edge.
struct TrackScale: Equatable {
    var pointsPerSecond: Double
    var inset = 16.0

    /// Past 100 points a second the peaks (100 a second) only get wider; 200 leaves room to aim a split.
    static let zooms = 4.0...200.0
    static let standard = 60.0
    /// Round steps for labelled ruler ticks.
    static let steps = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

    func x(_ time: Double) -> Double { inset + time * pointsPerSecond }
    func time(at x: Double) -> Double { (x - inset) / pointsPerSecond }

    /// One step in or out, kept within `zooms`.
    static func zoomed(_ pointsPerSecond: Double, in zoomIn: Bool) -> Double {
        (zoomIn ? pointsPerSecond * 1.5 : pointsPerSecond / 1.5).clamped(zooms)
    }

    /// The zoom that shows `duration` whole in `width` points.
    static func fitting(_ duration: Double, in width: Double, inset: Double = 16) -> Double {
        guard duration > 0, width > inset * 2 else { return standard }
        return ((width - inset * 2) / duration).clamped(zooms)
    }

    /// Seconds between labelled ticks: the smallest round step that leaves `spacing` points for each label.
    func tickStep(spacing: Double = 64) -> Double {
        Self.steps.first { $0 * pointsPerSecond >= spacing } ?? Self.steps[Self.steps.count - 1]
    }

    /// "1:05" on whole-second steps; "0:04.5" or "0:04.25" on finer ones.
    static func label(_ time: Double, step: Double) -> String {
        guard step < 1 else { return formatTime(time) }
        let digits = abs(step * 10 - (step * 10).rounded()) < 1e-9 ? 1 : 2
        let scale = digits == 1 ? 10.0 : 100.0
        let total = (time * scale).rounded() / scale, minutes = Int(total / 60)
        return String(format: "%d:%0\(digits + 3).\(digits)f", minutes, total - Double(minutes * 60))
    }
}

/// A clip's place on the track, in points.
struct ClipFrame: Equatable {
    var x: Double
    var width: Double
    var maxX: Double { x + width }
}

enum TrimEdge: Equatable { case start, end }

/// A trim in progress: where the clip would start and end in its render.
struct TrimDraft: Equatable {
    var clipID: String
    var edge: TrimEdge
    var start: Double
    var end: Double
}

/// The track's layout and gestures as plain numbers, so they can be tested without a window.
enum TrackLayout {
    /// Each clip's frame. A trim in progress moves the edge being dragged: an end pushes the clips after it along, as
    /// the edit will once released; a start leaves the rest in place until then, so the edge stays under the pointer.
    static func frames(_ edit: Edit, scale: TrackScale, trim: TrimDraft? = nil) -> [ClipFrame] {
        var shift = 0.0
        return zip(edit.clips, edit.starts).map { clip, start in
            var frame = ClipFrame(x: scale.x(start) + shift, width: clip.duration * scale.pointsPerSecond)
            if let trim, trim.clipID == clip.id {
                let width = (trim.end - trim.start) / clip.effects.tempo * scale.pointsPerSecond
                switch trim.edge {
                case .start: frame.x += frame.width - width
                case .end: shift = width - frame.width
                }
                frame.width = width
            }
            return frame
        }
    }

    /// Where an edge lands after dragging it `seconds` along the timeline: in seconds of the render, scaled by the clip's
    /// speed, kept inside the render and at least `Edit.shortest` long, which is all the store accepts.
    static func trimmed(_ clip: EditClip, edge: TrimEdge, by seconds: Double, renderDuration: Double) -> (start: Double, end: Double) {
        let delta = seconds * clip.effects.tempo
        switch edge {
        case .start:
            return ((clip.start + delta).clamped(0...max(0, clip.end - Edit.shortest)), clip.end)
        case .end:
            let lowest = clip.start + Edit.shortest
            return (clip.start, (clip.end + delta).clamped(lowest...max(lowest, renderDuration)))
        }
    }

    /// A dragged clip's new index in `Edit.move`'s terms, its place among the other clips: after each one whose middle
    /// is left of the dragged clip's middle. `center` is in timeline seconds.
    static func dropIndex(center: Double, moving index: Int, in edit: Edit) -> Int {
        zip(edit.clips, edit.starts).enumerated().filter { offset, item in
            offset != index && item.1 + item.0.duration / 2 < center
        }.count
    }

    /// Where to draw the mark for a drop: just before the clip it would land in front of, or after the last.
    static func insertionX(_ drop: Int, moving index: Int, frames: [ClipFrame]) -> Double? {
        let others = frames.indices.filter { $0 != index }.map { frames[$0] }
        guard let last = others.last else { return nil }
        return drop < others.count ? others[drop].x - 4 : last.maxX + 4
    }

    /// The clip whose audio is under the playhead and how far into it, on the timeline; nil in a gap, or too near an
    /// end for the store to split there.
    static func split(at time: Double, in edit: Edit) -> (clip: EditClip, offset: Double)? {
        guard let clip = edit.clip(at: time), let start = edit.start(of: clip.id) else { return nil }
        let offset = time - start
        guard offset * clip.effects.tempo >= Edit.shortest, (clip.duration - offset) * clip.effects.tempo >= Edit.shortest else { return nil }
        return (clip, offset)
    }

    /// The words a render speaks, without tags such as `[confident]` or `[pause 0.3]`.
    static func words(_ text: String) -> String { Marks.plain(text) }

    /// Room inside a clip's rounded ends before the first word and after the last, and between words.
    static let stripInset = 4.0, stripGap = 6.0

    /// The words a clip plays, for the strip under its waveform: each one mostly inside the trim (`start`–`end` of the
    /// render), placed where it starts, `(word.start − clip.start) / tempo × pointsPerSecond` from the clip's left edge.
    /// A word whose label would run into the one before it, or past the clip's end, is left out, so zoomed out the strip
    /// thins rather than overlaps; a clip under 40 points shows none. `texts` and `times` are the render's display words.
    static func stripWords(_ texts: [String], times: [WordTime], clip: EditClip, pointsPerSecond: Double,
                           measure: (String) -> Double) -> [StripWord] {
        let width = clip.duration * pointsPerSecond
        guard texts.count == times.count, clip.end > clip.start, width >= 40 else { return [] }
        var words: [StripWord] = [], next = stripInset
        for (token, time) in times.enumerated() {
            let middle = (time.start + time.end) / 2
            guard middle >= clip.start, middle <= clip.end else { continue }
            let x = max(stripInset, (max(time.start, clip.start) - clip.start) / clip.effects.tempo * pointsPerSecond)
            let label = measure(texts[token])
            guard x >= next, x + label <= width - stripInset else { continue }
            words.append(StripWord(token: token, text: texts[token], x: x))
            next = x + label + stripGap
        }
        return words
    }
}

/// A word under a clip's waveform: its display token in the render's text and where it starts, in points from the
/// clip's left edge.
struct StripWord: Equatable {
    var token: Int
    var text: String
    var x: Double
}

extension Double {
    /// To the nearest multiple of `step`, so a slider settles on a round value.
    func snapped(_ step: Double) -> Double { ((self / step).rounded() * step * 1000).rounded() / 1000 }
}

/// Each render's loudness for the clips' waveforms: 100 peaks a second, loaded once.
@MainActor @Observable
final class RenderPeaks {
    static let perSecond = 100.0
    private(set) var peaks: [URL: [Float]] = [:]
    @ObservationIgnored private var loading: Set<URL> = []

    func load(_ url: URL) async {
        guard peaks[url] == nil, loading.insert(url).inserted else { return }
        defer { loading.remove(url) }
        guard let samples = try? await loadSamples(url, rate: 8000), !samples.isEmpty else { return }
        peaks[url] = Preview.peaks(samples, count: max(1, samples.count / 80))
    }
}

// MARK: Timeline tab

/// The Timeline tab: a project's renders on one track to cut, move and shape, the selected clip's settings beside it.
struct EditView: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(Preview.self) private var preview
    /// The same project as Generate, so the terminal agents' tools act on this one.
    @AppStorage("project") private var selection = ""
    @AppStorage("mode") private var mode = Mode.timeline
    @AppStorage("terminalOpen") private var terminalOpen = false
    @AppStorage("terminalHeight") private var terminalHeight = 300.0
    @AppStorage("timelineSideOpen") private var sideOpen = true
    @State private var selected: String?
    @State private var exporting = false

    /// Opens the timeline when a project has a render to put on it, including one rendered while the tab is open.
    private struct Opening: Equatable {
        var projectID: String
        var rendered: Bool
    }

    var body: some View {
        SidebarLayout {
            ProjectsSidebar(selection: $selection)
        } detail: {
            Group {
                if let project = projects.project(selection) {
                    let rendered = project.lines.contains { $0.chosenVersion != nil }
                    HStack(spacing: 8) {
                        GeometryReader { proxy in
                            VStack(spacing: 8) {
                                Group {
                                    if project.edit != nil {
                                        EditorPane(project: project, selected: $selected).id(project.id)
                                    } else if !rendered {
                                        VStack(spacing: 12) {
                                            Text("Render lines in Generate first.").foregroundStyle(Theme.secondary)
                                            Button("Open Generate") { mode = .generate }.buttonStyle(.outline)
                                        }
                                        .font(.system(size: 14))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    } else {
                                        Color.clear  // the timeline opens on the next update
                                    }
                                }
                                .frame(maxHeight: .infinity)
                                .panel()
                                if terminalOpen {
                                    // The track keeps room for its header, questions, transport and clips.
                                    TerminalPanel(height: $terminalHeight, maxHeight: proxy.size.height - 376)
                                }
                            }
                        }
                        if project.edit != nil {
                            if sideOpen {
                                InspectorPane(project: project, clipID: selected) { sideOpen = false }.frame(width: 280)
                            } else {
                                FoldedSidePanel(title: "Inspector") { sideOpen = true }
                            }
                        }
                    }
                    .onChange(of: Opening(projectID: project.id, rendered: rendered), initial: true) { _, opening in
                        if opening.rendered { projects.startEdit(opening.projectID) }
                    }
                } else {
                    Text("No projects").foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).panel()
                }
            }
            .onDisappear { preview.pause() }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $exporting) { ExportSheet(projectID: selection) }
        .onChange(of: selection) { selected = nil }
    }

    /// As in Generate, without Render: Terminal, Export as the one off-white action, then the gear.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { TerminalButton() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { exporting = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.toolbarPrimary)
                .disabled(!canExport)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { SettingsButton() }
    }

    private var canExport: Bool {
        guard let project = projects.project(selection) else { return false }
        return project.edit.map { !$0.clips.isEmpty } ?? project.lines.contains { $0.chosenVersion != nil }
    }
}

// MARK: Editor

/// The track, with the questions about it above and the transport between.
struct EditorPane: View {
    @Environment(VoiceStore.self) private var voices
    @Environment(ProjectStore.self) private var projects
    @Environment(Preview.self) private var preview
    let project: Project
    @Binding var selected: String?
    @AppStorage("timelineZoom") private var zoom = TrackScale.standard
    @State private var peaks = RenderPeaks()
    @State private var building = false
    @State private var buildError: String?
    @State private var resetting = false
    @State private var scroll = ScrollPosition(edge: .leading)
    /// The track's visible stretch, in points from its left end.
    @State private var visible = 0.0...0.0
    @State private var height = 0.0
    @State private var bannersHeight = 0.0
    @FocusState private var focused: Bool

    private var edit: Edit { project.edit ?? Edit() }
    private var scale: TrackScale { TrackScale(pointsPerSecond: zoom.clamped(TrackScale.zooms)) }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Timeline") { zoomButtons }
            banners
            transport
            Theme.line.frame(height: 1).padding(.horizontal, 8)
            // The clips grow with the panel up to a point; the rest stays empty below, as under a short script. The
            // smallest still has room for its name, some waveform and its words.
            GeometryReader { proxy in
                let lane = min(216, max(64, proxy.size.height - Track.height(lane: 0) - 40))
                VStack(alignment: .leading, spacing: 4) {
                    Track(project: project, edit: edit, scale: scale, lane: lane, peaks: peaks, selected: $selected, scroll: $scroll,
                          visible: $visible) { focused = true }
                    Text("Click a clip to select it and move the playhead there. Drag its edges to trim it, its middle to move it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                    Spacer(minLength: 0)
                }
            }
        }
        .onGeometryChange(for: Double.self) { $0.size.height } action: { height = $0 }
        // Plain keys only while the track has focus, so typing in the terminal never splits or deletes.
        .focusable(interactions: .edit)
        .focused($focused)
        .onKeyPress(phases: .down, action: key)
        .onAppear {
            focused = true
            // Old renders get their word times in the background, for the words under the clips.
            projects.timeWordsIfNeeded(project.id, voices: voices)
        }
        .task(id: project.edit) { await build() }
        .confirmationDialog("Reset the timeline from the script?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset timeline", role: .destructive) {
                projects.resetEdit(project.id)
                selected = nil
            }
        } message: {
            Text("Each line's chosen render goes back on whole, with its pause, replacing your cuts and settings. You can undo this.")
        }
    }

    /// Makes the audio of edited clips (the engine keeps each one) and hands the timeline to the preview. The progress
    /// shows only if it takes a moment, so quick edits don't flash it.
    private func build() async {
        let slow = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(250))
            building = true
        }
        defer { slow.cancel() }
        do {
            let timeline = try await projects.playbackTimeline(project.id, engine: voices.engine)
            try Task.checkCancellation()
            await preview.load(timeline)
            buildError = nil
            building = false
        } catch is CancellationError {
        } catch {
            buildError = "Couldn't prepare the audio. \(error.localizedDescription)"
            building = false
        }
    }

    // MARK: Keys and actions

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.key {
        case .space: preview.toggle()
        case .delete, .deleteForward: deleteSelected()
        case .escape: selected = nil
        default:
            guard press.characters.lowercased() == "s" else { return .ignored }
            splitAtPlayhead()
        }
        return .handled
    }

    private func splitAtPlayhead() {
        guard let split = TrackLayout.split(at: preview.position, in: edit) else { return NSSound.beep() }
        projects.splitClip(split.clip.id, at: split.offset, in: project.id)
    }

    private func deleteSelected() {
        guard let id = selected, edit.clips.contains(where: { $0.id == id }) else { return NSSound.beep() }
        if projects.deleteClip(id, in: project.id) { selected = nil }
    }

    /// Zooms around the playhead when it's in view, else around the left edge, so what you were looking at stays put.
    private func setZoom(_ pointsPerSecond: Double) {
        let old = scale, new = TrackScale(pointsPerSecond: pointsPerSecond)
        let head = old.x(preview.position)
        let showing = visible.contains(head)
        let time = showing ? preview.position : max(0, old.time(at: visible.lowerBound))
        let anchor = showing ? head - visible.lowerBound : 0
        zoom = pointsPerSecond
        Task { @MainActor in scroll.scrollTo(x: max(0, new.x(time) - anchor)) }
    }

    // MARK: Header, banners and transport

    @ViewBuilder private var zoomButtons: some View {
        Group {
            Button { setZoom(TrackScale.zoomed(scale.pointsPerSecond, in: false)) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(scale.pointsPerSecond <= TrackScale.zooms.lowerBound)
                .help("Zoom out (⌘−)")
                .accessibilityLabel("Zoom out")
            Button { setZoom(TrackScale.zoomed(scale.pointsPerSecond, in: true)) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(scale.pointsPerSecond >= TrackScale.zooms.upperBound)
                .help("Zoom in (⌘+)")
                .accessibilityLabel("Zoom in")
                // ⌘= is ⌘+ without Shift on most keyboards.
                .background {
                    Button("") { setZoom(TrackScale.zoomed(scale.pointsPerSecond, in: true)) }
                        .keyboardShortcut("=", modifiers: .command)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            Button("Fit") {
                zoom = TrackScale.fitting(edit.duration, in: visible.upperBound - visible.lowerBound)
                Task { @MainActor in scroll.scrollTo(x: 0) }
            }
            .help("Show the whole timeline")
            .accessibilityLabel("Zoom to fit")
        }
        .buttonStyle(.outline(height: 28))
    }

    /// One row per question: a new render to swap in, a line left off, and an agent's proposed changes.
    @ViewBuilder private var banners: some View {
        let renders = projects.newRenders(project.id), missing = Set(projects.linesNotOnTimeline(project.id))
        let numbered = Array(project.lines.enumerated()).filter { renders[$0.element.id] != nil || missing.contains($0.element.id) }
        if project.editProposal != nil || !numbered.isEmpty {
            let rows = VStack(spacing: 6) {
                if let proposal = project.editProposal { proposalBanner(proposal) }
                ForEach(numbered, id: \.element.id) { index, line in
                    if renders[line.id] != nil {
                        banner("Line \(index + 1) has a new render.", icon: "arrow.triangle.2.circlepath", tint: Theme.amber) {
                            Button("Keep my edit") { projects.keepEditedClip(line: line.id, in: project.id) }
                            Button("Swap in") { projects.swapInNewRender(line: line.id, in: project.id) }
                        }
                    } else {
                        banner("Line \(index + 1) isn\u{2019}t on the timeline.", icon: "plus.circle", tint: Theme.secondary) {
                            Button("Add") { projects.addLineToEdit(line: line.id, in: project.id) }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            // As tall as the rows, scrolling only once they'd squeeze the clips under about 120 points.
            ScrollView {
                rows.padding(.bottom, 2).onGeometryChange(for: Double.self) { $0.size.height } action: { bannersHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(bannersHeight, max(120, height - 300)))
        }
    }

    private func banner(_ text: String, icon: String, tint: Color, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).lineLimit(1)
            Spacer(minLength: 8)
            actions().buttonStyle(.outline(height: 26))
        }
        .font(.system(size: 13))
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 40)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        .accessibilityElement(children: .contain)
    }

    private func proposalBanner(_ proposal: EditProposal) -> some View {
        let before = formatTime(edit.duration), after = formatTime(proposal.edit.duration)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .accessibilityHidden(true)
                Text("Claude proposed changes").fontWeight(.semibold)
                if before != after { Text("\(before) \u{2192} \(after)").foregroundStyle(Theme.secondary).monospacedDigit() }
                Spacer(minLength: 8)
                Button("Reject") { projects.rejectEditProposal(project.id) }
                    .accessibilityLabel("Reject the proposed timeline changes")
                Button("Accept") { projects.acceptEditProposal(project.id) }
                    .accessibilityLabel("Accept the proposed timeline changes")
            }
            .buttonStyle(.outline(height: 26))
            ForEach(Array(proposal.changes.enumerated()), id: \.offset) { _, change in
                Text("\u{2022} \(change)").foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 20)
        }
        .font(.system(size: 13))
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.selection.opacity(0.6), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.outline.opacity(0.5)))
        .accessibilityElement(children: .contain)
    }

    private var transport: some View {
        HStack(spacing: 8) {
            PlayToggle()
            PlayTime().padding(.leading, 4)
            if building {
                ProgressView().controlSize(.small).padding(.leading, 6)
                Text("Preparing audio\u{2026}").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            } else if let buildError {
                Warning(text: buildError).lineLimit(1).help(buildError).padding(.leading, 6)
            }
            Spacer(minLength: 8)
            SplitButton(edit: edit, action: splitAtPlayhead)
            Button(action: deleteSelected) { Label("Delete", systemImage: "trash") }
                .disabled(!edit.clips.contains { $0.id == selected })
                .help("Delete the selected clip (\u{232B})")
            Group {
                Button { projects.undoEdit(project.id) } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!projects.canUndoEdit(project.id))
                    .help("Undo (⌘Z)")
                    .accessibilityLabel("Undo")
                Button { projects.redoEdit(project.id) } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!projects.canRedoEdit(project.id))
                    .help("Redo (⇧⌘Z)")
                    .accessibilityLabel("Redo")
            }
            .padding(.leading, 6)
            Button("Reset from script\u{2026}") { resetting = true }
                .padding(.leading, 6)
                .help("Put each line's chosen render back whole, in script order")
        }
        .buttonStyle(.outline(height: 28))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .frame(height: 52)
    }
}

/// Play and pause, the round button the preview uses, on the track and in the Read view. On the track Space does the
/// same while it has focus.
struct PlayToggle: View {
    @Environment(Preview.self) private var preview
    /// Space plays and pauses here too, so the tooltip says so.
    var spaceKey = true

    var body: some View {
        Button { preview.toggle() } label: {
            Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 13))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.08), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(preview.timeline.duration == 0)
        .help((preview.isPlaying ? "Pause" : "Play") + (spaceKey ? " (space)" : ""))
        .accessibilityLabel(preview.isPlaying ? "Pause" : "Play")
    }
}

/// Its own view, as it follows the playhead to know whether there's a clip to split.
private struct SplitButton: View {
    @Environment(Preview.self) private var preview
    let edit: Edit
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label("Split", systemImage: "scissors") }
            .disabled(TrackLayout.split(at: preview.position, in: edit) == nil)
            .help("Split the clip at the playhead (S)")
    }
}

// MARK: Track

private struct Track: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(Preview.self) private var preview
    let project: Project
    let edit: Edit
    let scale: TrackScale
    /// The clips' height.
    let lane: Double
    let peaks: RenderPeaks
    @Binding var selected: String?
    @Binding var scroll: ScrollPosition
    @Binding var visible: ClosedRange<Double>
    /// Gives the track keyboard focus, for Space, S and Delete.
    let onFocus: () -> Void
    @State private var trim: TrimDraft?
    @State private var moving: Move?

    private struct Move: Equatable {
        var clipID: String
        var offset: Double
    }

    static let ruler = 26.0, spacing = 10.0, scrollBar = 16.0

    /// The ruler, the clips and room under them for a scroll bar.
    static func height(lane: Double) -> Double { ruler + spacing + lane + scrollBar }

    var body: some View {
        GeometryReader { proxy in
            let frames = TrackLayout.frames(edit, scale: scale, trim: trim)
            let width = max(proxy.size.width, (frames.map(\.maxX).max() ?? scale.x(0)) + 200)
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: Self.spacing) {
                        Ruler(scale: scale, visible: visible).frame(width: width, height: Self.ruler)
                        lanes(frames, height: lane).frame(width: width, height: lane)
                    }
                    Playhead(scale: scale, height: Self.ruler + Self.spacing + lane)
                }
                .frame(width: width, height: Self.height(lane: lane), alignment: .topLeading)
                .coordinateSpace(.named(Self.space))
            }
            .scrollIndicators(.automatic)
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: ClosedRange<Double>.self) { geometry in
                geometry.contentOffset.x...(geometry.contentOffset.x + max(0, geometry.containerSize.width))
            } action: { _, range in visible = range }
            .background { PlayheadFollower(scale: scale, visible: visible, scroll: $scroll) }
        }
        .frame(height: Self.height(lane: lane))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    private static let space = "track"

    private func lanes(_ frames: [ClipFrame], height: Double) -> some View {
        let numbers = Dictionary(project.lines.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
        let renders = projects.newRenders(project.id)
        return ZStack(alignment: .topLeading) {
            // Empty space seeks.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { location in
                    onFocus()
                    preview.seek(to: scale.time(at: location.x))
                }
            ForEach(Array(edit.clips.enumerated().dropLast()), id: \.element.id) { index, clip in
                GapMark(seconds: clip.gapAfter, width: frames[index + 1].x - frames[index].maxX)
                    .frame(height: height)
                    .offset(x: frames[index].maxX)
            }
            ForEach(Array(edit.clips.enumerated()), id: \.element.id) { index, clip in
                clipView(clip, index: index, frame: frames[index], height: height, number: numbers[clip.lineID],
                         newRender: renders[clip.lineID] != nil)
            }
            if let moving, let index = edit.clips.firstIndex(where: { $0.id == moving.clipID }) {
                let center = edit.starts[index] + edit.clips[index].duration / 2 + moving.offset / scale.pointsPerSecond
                let drop = TrackLayout.dropIndex(center: center, moving: index, in: edit)
                if drop != index, let x = TrackLayout.insertionX(drop, moving: index, frames: frames) {
                    Capsule().fill(Theme.primary).frame(width: 3, height: height + 8).offset(x: x - 1.5, y: -4).allowsHitTesting(false)
                }
            }
            if edit.clips.isEmpty {
                Text("The timeline is empty.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
            }
        }
    }

    private func clipView(_ clip: EditClip, index: Int, frame: ClipFrame, height: Double, number: Int?, newRender: Bool) -> some View {
        let version = project.version(clip.versionID)
        let url = version.map { projects.audioURL($0, projectID: project.id) }
        let render = version?.duration ?? clip.end
        let words = TrackLayout.words(version?.text ?? project.line(clip.lineID)?.text ?? "")
        let name = number.map { "Line \($0)" } ?? "Line"
        var shown = clip
        if let trim, trim.clipID == clip.id { (shown.start, shown.end) = (trim.start, trim.end) }
        let strip = version.flatMap { version in
            projects.displayTimes(version).map { times in
                TrackLayout.stripWords(Marks.parse(version.text).tokens.map(\.text), times: times, clip: shown,
                                       pointsPerSecond: scale.pointsPerSecond, measure: StripText.width)
            }
        } ?? []
        let isMoving = moving?.clipID == clip.id
        let handle = min(8, frame.width / 4)
        return ZStack {
            ClipBlock(clip: shown, name: name, words: words, selected: selected == clip.id, newRender: newRender,
                      peaks: url.flatMap { peaks.peaks[$0] }, project: project, strip: strip)
                .contentShape(.rect)
                .onTapGesture { location in
                    onFocus()
                    selected = clip.id
                    preview.seek(to: edit.starts[index] + location.x / max(1, frame.width) * clip.duration)
                }
                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        onFocus()
                        selected = clip.id
                        moving = Move(clipID: clip.id, offset: value.translation.width)
                    }
                    .onEnded { value in
                        moving = nil
                        let center = edit.starts[index] + clip.duration / 2 + value.translation.width / scale.pointsPerSecond
                        let drop = TrackLayout.dropIndex(center: center, moving: index, in: edit)
                        if drop != index { projects.moveClip(clip.id, to: drop, in: project.id) }
                    })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words.isEmpty ? name : "\(name): \(words)")
                .accessibilityValue(String(format: "%.1f seconds, at ", clip.duration) + formatTime(edit.starts[index])
                    + (newRender ? ", new render" : ""))
                .accessibilityAddTraits(selected == clip.id ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { selected = clip.id }
                .accessibilityAction(named: "Delete") { projects.deleteClip(clip.id, in: project.id) }
                .accessibilityAction(named: "Move earlier") { projects.moveClip(clip.id, to: index - 1, in: project.id) }
                .accessibilityAction(named: "Move later") { projects.moveClip(clip.id, to: index + 1, in: project.id) }
            HStack(spacing: 0) {
                trimHandle(clip, .start, render: render, width: handle, name: name)
                Spacer(minLength: 0)
                trimHandle(clip, .end, render: render, width: handle, name: name)
            }
        }
        .frame(width: max(2, frame.width), height: height)
        .shadow(color: .black.opacity(isMoving ? 0.5 : 0), radius: 8, y: 2)
        .offset(x: frame.x + (isMoving ? moving?.offset ?? 0 : 0))
        .zIndex(isMoving || trim?.clipID == clip.id ? 1 : 0)
        .task(id: url) { if let url { await peaks.load(url) } }
    }

    /// Drags an edge, showing the trim live and committing it once on release, so it's one step to undo.
    private func trimHandle(_ clip: EditClip, _ edge: TrimEdge, render: Double, width: Double, name: String) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    onFocus()
                    selected = clip.id
                    let (start, end) = TrackLayout.trimmed(clip, edge: edge, by: value.translation.width / scale.pointsPerSecond,
                                                           renderDuration: render)
                    trim = TrimDraft(clipID: clip.id, edge: edge, start: start, end: end)
                }
                .onEnded { _ in
                    if let trim, trim.clipID == clip.id, trim.start != clip.start || trim.end != clip.end {
                        projects.trimClip(clip.id, start: trim.start, end: trim.end, in: project.id)
                    }
                    trim = nil
                })
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? "Start of \(name)" : "End of \(name)")
            .accessibilityValue(String(format: "%.2f seconds into the render", edge == .start ? clip.start : clip.end))
            .accessibilityAdjustableAction { direction in
                let step = (direction == .increment ? 0.1 : -0.1) / clip.effects.tempo
                let (start, end) = TrackLayout.trimmed(clip, edge: edge, by: step, renderDuration: render)
                projects.trimClip(clip.id, start: start, end: end, in: project.id)
            }
    }
}

/// One clip: its waveform for the trimmed stretch, shaped by its volume and fades, under "Line N" and its first words,
/// with its words along the bottom where they're said.
private struct ClipBlock: View {
    let clip: EditClip
    let name: String
    let words: String
    let selected: Bool
    let newRender: Bool
    let peaks: [Float]?
    let project: Project
    let strip: [StripWord]
    @State private var hovered = false

    /// The words' row along the bottom, kept even when they aren't timed yet so every clip's waveform lines up.
    static let stripHeight = 16.0, stripBottom = 4.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                shape.fill(selected ? Theme.selection : Color.white.opacity(hovered ? 0.075 : 0.055))
                waveform.padding(.top, 24).padding(.bottom, Self.stripHeight + Self.stripBottom + 2).padding(.horizontal, 3)
                if !strip.isEmpty {
                    ClipWords(project: project, clipID: clip.id, words: strip)
                        .frame(height: Self.stripHeight)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, Self.stripBottom)
                }
                if proxy.size.width >= 40 {
                    HStack(spacing: 5) {
                        Text(name).fontWeight(.semibold).foregroundStyle(Theme.text).layoutPriority(1)
                        Text(words).foregroundStyle(Theme.secondary)
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .padding(.leading, 8)
                    .padding(.trailing, newRender ? 26 : 8)
                    .padding(.top, 6)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(selected ? Theme.primary : hovered ? Theme.outline : Theme.line, lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                if newRender && proxy.size.width >= 24 {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.onPrimary)
                        .frame(width: 16, height: 16)
                        .background(Theme.amber, in: .circle)
                        .padding(5)
                        .help("This line has a new render")
                }
            }
            .overlay {
                // Grips on the edges say they can be dragged.
                if selected || hovered, proxy.size.width >= 24 {
                    HStack {
                        grip
                        Spacer(minLength: 0)
                        grip
                    }
                    .padding(.horizontal, 3)
                }
            }
        }
        .onHover { hovered = $0 }
    }

    private var grip: some View { Capsule().fill(Theme.text.opacity(0.7)).frame(width: 3, height: 20) }

    private var waveform: some View {
        let clip = clip, peaks = peaks ?? [], color = selected ? Theme.text : Theme.secondary
        return Canvas { context, size in
            let bar = 3.0, count = Int(size.width / bar), length = clip.end - clip.start
            guard count > 0, size.width > 0 else { return }
            let gain = pow(10, clip.gain / 20) * 0.85
            for index in 0..<count {
                let left = Double(index) * bar
                var peak: Float = 0
                if !peaks.isEmpty {
                    // The loudest peak under the bar, so a zoomed-out clip keeps its loud parts.
                    let from = clip.start + left / size.width * length, to = clip.start + (left + bar) / size.width * length
                    let low = min(max(0, Int(from * RenderPeaks.perSecond)), peaks.count - 1)
                    let high = min(max(low + 1, Int((to * RenderPeaks.perSecond).rounded(.up))), peaks.count)
                    peak = peaks[low..<high].max() ?? 0
                }
                let time = (left + bar / 2) / size.width * clip.duration
                let fadeIn = clip.fadeIn > 0 ? time / clip.fadeIn : 1, fadeOut = clip.fadeOut > 0 ? (clip.duration - time) / clip.fadeOut : 1
                let level = min(1, Double(peak) * gain * max(0, min(1, fadeIn, fadeOut)))
                let height = max(1, level * size.height)
                context.fill(Path(CGRect(x: left, y: (size.height - height) / 2, width: 1.5, height: height)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A clip's words under its waveform, lit up to the word being said while it plays. Its own view, so only it follows
/// playback; the drawing redraws only when the lit word changes.
private struct ClipWords: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(Preview.self) private var preview
    let project: Project
    let clipID: String
    let words: [StripWord]

    var body: some View {
        StripText(words: words, lit: lit).equatable()
    }

    /// The word being said, while the preview plays this clip. The cheap check first, as every clip asks on each tick.
    private var lit: Int? {
        guard preview.isPlaying, preview.timeline.segment(at: preview.position)?.clipID == clipID,
              let word = ReadAlong.lit(preview.timeline, at: preview.position, in: project, projects: projects), word.clipID == clipID
        else { return nil }
        return word.token
    }
}

/// The strip's words: spoken ones in Theme.text, the rest in Theme.secondary.
struct StripText: View, Equatable {
    let words: [StripWord]
    /// The last display token spoken; nil while the clip isn't playing.
    let lit: Int?

    static let fontSize = 11.0
    @MainActor private static var widths: [String: Double] = [:]

    var body: some View {
        Canvas { context, size in
            for word in words {
                let spoken = lit.map { word.token <= $0 } ?? false
                context.draw(Text(word.text).font(.system(size: Self.fontSize)).foregroundStyle(spoken ? Theme.text : Theme.secondary),
                             at: CGPoint(x: word.x, y: size.height / 2), anchor: .leading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A word's label width, measured once.
    static func width(_ text: String) -> Double {
        if let width = widths[text] { return width }
        let width = ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width)
        widths[text] = width
        return width
    }
}

/// The silence after a clip: a dashed line, with its length when there's room.
private struct GapMark: View {
    let seconds: Double
    let width: Double

    var body: some View {
        if width > 6 {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 3, y: 0))
                    path.addLine(to: CGPoint(x: max(3, width - 3), y: 0))
                }
                .stroke(Theme.outline.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: width, height: 1)
                if width >= 34 {
                    Text(seconds.formatted(.number.precision(.fractionLength(0...2))) + "s")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 3)
                        .background(Theme.content)
                }
            }
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Seconds along the top, drawn only for the stretch in view so a long timeline zoomed in stays light. Click or drag to seek.
private struct Ruler: View {
    @Environment(Preview.self) private var preview
    let scale: TrackScale
    let visible: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            let step = scale.tickStep()
            let first = max(0, Int((scale.time(at: visible.lowerBound) / step).rounded(.down)) - 1)
            let last = Int((scale.time(at: visible.upperBound) / step).rounded(.up)) + 1
            guard last >= first else { return }
            for tick in first...last {
                let time = Double(tick) * step, x = scale.x(time), half = scale.x(time + step / 2)
                context.fill(Path(CGRect(x: x, y: size.height - 9, width: 1, height: 9)), with: .color(Theme.outline))
                context.fill(Path(CGRect(x: half, y: size.height - 4, width: 1, height: 4)), with: .color(Theme.line))
                context.draw(Text(TrackScale.label(time, step: step)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.secondary),
                             at: CGPoint(x: x + 4, y: 3), anchor: .topLeading)
            }
        }
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in preview.seek(to: scale.time(at: value.location.x)) })
        .accessibilityHidden(true)
    }
}

/// The line at the play position, over the ruler and clips. Its own view, so only it redraws as playback moves.
private struct Playhead: View {
    @Environment(Preview.self) private var preview
    let scale: TrackScale
    /// From the top of the ruler to the bottom of the clips.
    let height: Double

    var body: some View {
        let position = preview.position, duration = preview.timeline.duration
        VStack(spacing: 0) {
            Circle().fill(Theme.text).frame(width: 9, height: 9)
            Rectangle().fill(Theme.text).frame(width: 1.5)
        }
        .frame(width: 9, height: height - 12)
        .offset(x: scale.x(min(position, duration)) - 4.5, y: 12)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(formatTime(position)) of \(formatTime(duration))")
        .accessibilityAdjustableAction { direction in preview.seek(to: position + (direction == .increment ? 1 : -1)) }
    }
}

/// Keeps the playhead in view while playing, a page at a time.
private struct PlayheadFollower: View {
    @Environment(Preview.self) private var preview
    let scale: TrackScale
    let visible: ClosedRange<Double>
    @Binding var scroll: ScrollPosition

    var body: some View {
        Color.clear.onChange(of: preview.position) { _, position in
            guard preview.isPlaying, visible.upperBound > visible.lowerBound else { return }
            let x = scale.x(position)
            if x > visible.upperBound - 24 || x < visible.lowerBound { scroll.scrollTo(x: max(0, x - 24)) }
        }
    }
}

// MARK: Inspector

/// The selected clip's settings. Each slider commits once, on release, so each change is one step to undo.
private struct InspectorPane: View {
    @Environment(ProjectStore.self) private var projects
    let project: Project
    let clipID: String?
    let onFold: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Inspector") { FoldButton(label: "inspector", action: onFold) }
            if let edit = project.edit, let index = edit.clips.firstIndex(where: { $0.id == clipID }) {
                ScrollView {
                    ClipSettings(project: project, clip: edit.clips[index], isLast: index == edit.clips.count - 1)
                        .id(edit.clips[index].id)
                        .padding(16)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Text("Select a clip to set its volume, fades and voice.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sidePanel()
    }
}

private struct ClipSettings: View {
    @Environment(ProjectStore.self) private var projects
    let project: Project
    let clip: EditClip
    let isLast: Bool

    var body: some View {
        let line = project.line(clip.lineID), version = project.version(clip.versionID)
        let number = project.lines.firstIndex { $0.id == clip.lineID }.map { $0 + 1 }
        let take = line.flatMap { line in
            line.visibleVersions.firstIndex { $0.id == clip.versionID }.map { "v\($0 + 1) of \(line.visibleVersions.count)" }
        }
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(number.map { "Line \($0)" } ?? "Line").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(([take, version?.tone].compactMap(\.self)).joined(separator: " \u{00B7} ")).foregroundStyle(Theme.secondary)
                }
                Text(version?.text ?? line?.text ?? "").foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(String(format: "%.2f s on the timeline, from %.2f\u{2013}%.2f s of the render", clip.duration, clip.start, clip.end))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            section("Clip")
            CommitSlider(title: "Volume", value: clip.gain, range: Edit.gains, step: 0.5, format: { signed($0, "dB") }) {
                projects.setClipGain($0, clip: clip.id, in: project.id)
            }
            let fades = 0...max(Edit.shortest, min(Edit.longest, clip.duration))
            CommitSlider(title: "Fade in", value: clip.fadeIn, range: fades, step: 0.05, format: seconds) {
                projects.setClipFades(fadeIn: $0, fadeOut: clip.fadeOut, clip: clip.id, in: project.id)
            }
            CommitSlider(title: "Fade out", value: clip.fadeOut, range: fades, step: 0.05, format: seconds) {
                projects.setClipFades(fadeIn: clip.fadeIn, fadeOut: $0, clip: clip.id, in: project.id)
            }
            CommitSlider(title: "Gap after", value: clip.gapAfter, range: 0...Edit.longest, step: 0.05, format: seconds,
                         hint: isLast ? "The last clip\u{2019}s gap isn\u{2019}t played." : nil) {
                projects.setClipGap($0, clip: clip.id, in: project.id)
            }
            section("Voice")
            CommitSlider(title: "Speed", value: clip.effects.tempo, range: VoiceEffects.tempos, step: 0.05,
                         format: { "\(Int(($0 * 100).rounded()))%" }) { value in effects { $0.tempo = value } }
            CommitSlider(title: "Pitch", value: clip.effects.pitch, range: VoiceEffects.semitones, step: 0.5, format: { signed($0, "st") },
                         spoken: { signed($0, "semitones") },
                         hint: "More than about \u{00B1}2 semitones sounds less like the speaker.", warns: { abs($0) > 2 }) { value in
                effects { $0.pitch = value }
            }
            CommitSlider(title: "Warmth", value: clip.effects.warmth, range: VoiceEffects.shelves, step: 0.5, format: { signed($0, "dB") }) { value in
                effects { $0.warmth = value }
            }
            CommitSlider(title: "Brightness", value: clip.effects.brightness, range: VoiceEffects.shelves, step: 0.5,
                         format: { signed($0, "dB") }) { value in effects { $0.brightness = value } }
            Toggle("Remove noise", isOn: Binding(get: { clip.effects.denoise }, set: { value in effects { $0.denoise = value } }))
                .toggleStyle(.checkbox)
            Button("Reset voice tools") { projects.setClipEffects(VoiceEffects(), clip: clip.id, in: project.id) }
                .buttonStyle(.outline(height: 28))
                .disabled(clip.effects.isNeutral)
        }
        .font(.system(size: 13))
    }

    private func effects(_ change: (inout VoiceEffects) -> Void) {
        var effects = clip.effects
        change(&effects)
        projects.setClipEffects(effects, clip: clip.id, in: project.id)
    }

    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Theme.line.frame(height: 1)
            Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
        }
    }

    private func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }
}

/// "+1.5 dB", "−3.0 dB", "0.0 dB", with a real minus sign.
private func signed(_ value: Double, _ unit: String) -> String {
    let rounded = (value * 10).rounded() / 10
    return (rounded == 0 ? "0.0" : String(format: "%+.1f", rounded).replacing("-", with: "\u{2212}")) + " \(unit)"
}

/// A labelled slider that shows its value while dragging and calls `commit` once, on release, with the value rounded to
/// `step`. VoiceOver and the keyboard step it, committing each step.
private struct CommitSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    var spoken: ((Double) -> String)? = nil
    var hint: String? = nil
    var warns: (Double) -> Bool = { _ in false }
    let commit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        let shown = draft ?? value
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundStyle(Theme.secondary)
                Spacer()
                Text(format(shown)).monospacedDigit()
            }
            Slider(value: Binding(get: { shown.clamped(range) }, set: { draft = $0 }), in: range) { editing in
                guard !editing, let draft else { return }
                self.draft = nil
                let rounded = draft.snapped(step).clamped(range)
                if rounded != value { commit(rounded) }
            }
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue((spoken ?? format)(value))
            .accessibilityAdjustableAction { direction in
                let next = (value + (direction == .increment ? step : -step)).snapped(step).clamped(range)
                if next != value { commit(next) }
            }
            if let hint {
                if warns(shown) {
                    Warning(text: hint).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(hint).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

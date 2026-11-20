import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// The voiceover: each line's chosen take in order, with the line's pause after it. A line with text but no
/// render keeps a silent gap of about its reading time, so a video stays roughly in line once it is rendered.
struct Timeline: Equatable {
    struct Segment: Equatable {
        var lineID: String
        /// Nil for a line without a render.
        var audio: URL?
        var start: Double
        var duration: Double
        /// The timeline clip this plays, when built from a project's edit.
        var clipID: String? = nil
        /// The version whose audio this plays; nil for a line without a render.
        var versionID: String? = nil
        /// Where it starts in the version's own file, in seconds, and how fast it plays it: a timeline clip's trim and tempo.
        var renderStart = 0.0
        var tempo = 1.0

        /// Seconds into the version's own file (where its word times are) at `time` on the timeline; nil outside the
        /// segment or without a render.
        func renderTime(at time: Double) -> Double? {
            guard versionID != nil, time >= start - 0.001, time <= start + duration + 0.001 else { return nil }
            return renderStart + (min(max(time, start), start + duration) - start) * tempo
        }
    }

    var projectID = ""
    var segments: [Segment] = []
    var duration = 0.0

    init() {}

    init(_ project: Project, audioURL: (Version) -> URL) {
        projectID = project.id
        var time = 0.0
        for line in project.lines {
            let version = line.chosenVersion
            guard version != nil || !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            // shortcut: about 15 characters a second; a real estimate would need the voice's pace.
            let length = version?.duration ?? max(1, (Double(line.text.count) / 15).rounded())
            segments.append(Segment(lineID: line.id, audio: version.map(audioURL), start: time, duration: length, versionID: version?.id))
            duration = time + length
            time = duration + line.pauseAfter
        }
    }

    /// The line playing at `time`, its pause included.
    func line(at time: Double) -> String? { segment(at: time)?.lineID }

    /// The segment playing at `time`, the pause after it included.
    func segment(at time: Double) -> Segment? { segments.last { $0.start <= time + 0.001 } }
}

/// Plays the voiceover through the shared Player, with the project's video muted and in step.
@MainActor @Observable
final class Preview {
    static let rate = 24000.0

    private(set) var timeline = Timeline()
    /// Loudest sample per bin, 0–1.
    private(set) var peaks: [Float] = []
    private(set) var position = 0.0
    private(set) var isPlaying = false
    /// The line under the playhead while playing or after a seek.
    private(set) var currentLine: String?
    @ObservationIgnored let videoPlayer: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        return player
    }()
    @ObservationIgnored private let player: Player
    @ObservationIgnored private var video: Video?
    @ObservationIgnored private var mix: URL?
    @ObservationIgnored private var samples: [URL: [Float]] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var videoSeeking = false

    init(player: Player) { self.player = player }

    /// Builds the voiceover as one WAV for playback and the waveform.
    func load(_ timeline: Timeline) async {
        guard timeline != self.timeline else { return }
        let newProject = timeline.projectID != self.timeline.projectID
        if newProject { samples = [:] }
        var out = [Float](repeating: 0, count: Int(timeline.duration * Self.rate))
        for segment in timeline.segments {
            guard let url = segment.audio else { continue }
            if samples[url] == nil { samples[url] = try? await loadSamples(url, rate: Self.rate) }
            guard let audio = samples[url] else { continue }  // a missing file plays as a gap
            let start = min(Int(segment.start * Self.rate), out.count)
            let count = min(audio.count, Int(segment.duration * Self.rate), out.count - start)
            out.replaceSubrange(start..<start + count, with: audio[..<count])
        }
        guard !Task.isCancelled else { return }
        pause()
        let url = FileManager.default.temporaryDirectory.appending(path: "VocalCord-preview-\(UUID().uuidString).wav")
        if let mix { try? FileManager.default.removeItem(at: mix) }
        mix = (try? writeWAV(out[...], rate: Self.rate, to: url)) != nil ? url : nil
        self.timeline = timeline
        peaks = Self.peaks(out, count: 600)
        position = newProject ? 0 : min(position, timeline.duration)
        updateCurrentLine()
        syncVideo(seek: true)
    }

    nonisolated static func peaks(_ samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let size = max(1, samples.count / count)
        let raw = stride(from: 0, to: samples.count, by: size).map { start in
            samples[start..<min(start + size, samples.count)].reduce(0) { max($0, abs($1)) }
        }
        let top = max(raw.max() ?? 1, 0.0001)
        return raw.map { $0 / top }
    }

    // MARK: Playback

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let mix else { return }
        if position >= timeline.duration - 0.05 { position = 0 }
        player.play(mix, from: position)
        isPlaying = player.playing == mix
        guard isPlaying else { return }
        updateCurrentLine()
        syncVideo(seek: true)
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled, self?.tick() == true { try? await Task.sleep(for: .milliseconds(33)) }
        }
    }

    func pause() {
        ticker?.cancel()
        if isPlaying, player.playing == mix {
            position = player.time
            player.pause()
        }
        isPlaying = false
        videoPlayer.pause()
        updateCurrentLine()
    }

    func seek(to time: Double) {
        position = min(max(0, time), timeline.duration)
        if isPlaying, let mix { player.play(mix, from: position) }
        updateCurrentLine()
        syncVideo(seek: true)
    }

    func seek(toLine id: String) {
        if let start = timeline.segments.first(where: { $0.lineID == id })?.start { seek(to: start) }
    }

    /// Follows the player; false once it has finished or moved on to another file.
    private func tick() -> Bool {
        guard isPlaying else { return false }
        guard let mix, player.playing == mix else {
            isPlaying = false
            videoPlayer.pause()
            if position >= timeline.duration - 0.25 { position = 0 }
            updateCurrentLine()
            return false
        }
        position = player.time
        updateCurrentLine()
        syncVideo(seek: false)
        return true
    }

    private func updateCurrentLine() {
        let line = isPlaying || position > 0 ? timeline.line(at: position) : nil
        if line != currentLine { currentLine = line }
    }

    // MARK: Video

    func setVideo(_ video: Video?) {
        if video?.path != self.video?.path {
            videoPlayer.replaceCurrentItem(with: video.map { AVPlayerItem(url: URL(filePath: $0.path)) })
        }
        self.video = video
        syncVideo(seek: true)
    }

    /// The video shows voiceover time minus the offset, and plays only while the voiceover does and has frames there.
    private func syncVideo(seek: Bool) {
        guard let video, let item = videoPlayer.currentItem else { return }
        let target = position - video.offset
        let length = item.duration.seconds  // NaN until the file is read
        if isPlaying, target >= 0, length.isNaN || target < length {
            if seek || (!videoSeeking && abs(videoPlayer.currentTime().seconds - target) > 0.15) { seekVideo(to: target) }
            if videoPlayer.rate == 0 { videoPlayer.play() }
        } else {
            videoPlayer.pause()
            if seek { seekVideo(to: max(0, length.isNaN ? target : min(target, length))) }
        }
    }

    private func seekVideo(to seconds: Double) {
        videoSeeking = true
        videoPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.videoSeeking = false }
        }
    }
}

// MARK: Preview pane

struct PreviewPane: View {
    @Environment(Preview.self) private var preview
    @Environment(ProjectStore.self) private var projects
    let project: Project
    /// Folds Preview and Outputs away.
    let onFold: () -> Void
    @State private var choosing = false
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Preview") {
                if Video.enabled {
                Menu {
                    Button("Choose video…") { choosing = true }
                    Button("Remove video") { projects.setVideo(nil, in: project.id) }.disabled(project.video == nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.icon(.s))
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Video")
                .accessibilityLabel("Video")
                }
                FoldButton(label: "preview and outputs", systemImage: "chevron.down", action: onFold)
            }
            VStack(spacing: 12) {
                if Video.enabled { videoArea }
                Waveform().frame(height: 48)
                transport
            }
            .padding(12)
        }
        .sidePanel(fill: false)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { projects.setVideo(Video(path: url.path), in: project.id) }
        }
    }

    /// Play and the time, with the video's offset beside them, or under them when the column is too narrow.
    private var transport: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                playButton
                PlayTime()
                Spacer(minLength: 8)
                if Video.enabled, project.video != nil { offsetField }
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 12) {
                    playButton
                    PlayTime()
                    Spacer(minLength: 0)
                }
                if Video.enabled, project.video != nil { offsetField }
            }
        }
    }

    private var playButton: some View {
        TransportPlayButton(playing: preview.isPlaying) { preview.toggle() }
            .disabled(preview.timeline.duration == 0)
            .help(preview.isPlaying ? "Pause" : "Play")
    }

    /// A 16:9 frame: the video once one is set, else the place to drop or choose one.
    @ViewBuilder private var videoArea: some View {
        if let video = project.video {
            ZStack {
                Color.black
                if FileManager.default.fileExists(atPath: video.path) {
                    VideoSurface(player: preview.videoPlayer)
                } else {
                    VStack(spacing: 8) {
                        Text("Video not found").foregroundStyle(Theme.secondary)
                        Button("Choose…") { choosing = true }.buttonStyle(.vc(.secondary, .s))
                    }
                    .font(.vcBody)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(dropping ? Theme.strong : Theme.line))
            .dropDestination(for: URL.self) { urls, _ in attach(urls) } isTargeted: { dropping = $0 }
        } else {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "film").font(.system(size: 20)).foregroundStyle(Theme.secondary)
                        Text("Drop a video").foregroundStyle(Theme.secondary)
                        Button("Choose…") { choosing = true }.buttonStyle(.vc(.secondary, .s))
                    }
                    .font(.vcBody)
                }
                .background(dropping ? Theme.selection : Color.white.opacity(0.02), in: .rect(cornerRadius: Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(dropping ? Theme.strong : Theme.stroke,
                                                                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .dropDestination(for: URL.self) { urls, _ in attach(urls) } isTargeted: { dropping = $0 }
        }
    }

    private func attach(_ urls: [URL]) -> Bool {
        guard let url = urls.first, UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true else { return false }
        projects.setVideo(Video(path: url.path), in: project.id)
        return true
    }

    private var offsetField: some View {
        let offset = Binding(get: { project.video?.offset ?? 0 }, set: { value in
            guard var video = project.video else { return }
            video.offset = (min(600, max(-600, value)) * 100).rounded() / 100
            projects.setVideo(video, in: project.id)
        })
        return HStack(spacing: 4) {
            Text("Offset").foregroundStyle(Theme.secondary).fixedSize()
            TextField("Offset", value: offset, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 36)
            Text("s").fixedSize()
            Stepper("Offset", value: offset, step: 0.1).labelsHidden()
        }
        .font(.vcBody.monospacedDigit())
        .help("Seconds the video starts after the voiceover; negative starts it earlier")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video offset, seconds")
    }
}

/// Its own view so only it redraws as the playhead moves.
struct PlayTime: View {
    @Environment(Preview.self) private var preview

    var body: some View {
        Text("\(formatTime(preview.position.rounded(.down))) / \(formatTime(preview.timeline.duration))")
            .font(.vcBody.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
    }
}

/// A waveform as one continuous filled shape rather than bars: the loudest peak under each point column, mirrored
/// about the middle. Plain math, so it can be tested without drawing.
enum WaveformEnvelope {
    /// The loudest of `peaks` under each of `count` columns, 0–1.
    static func columns(_ peaks: [Float], count: Int) -> [Float] {
        guard count > 0, !peaks.isEmpty else { return [] }
        return (0..<count).map { column in
            let low = column * peaks.count / count, high = max(low + 1, (column + 1) * peaks.count / count)
            return peaks[min(low, peaks.count - 1)..<min(high, peaks.count)].max() ?? 0
        }
    }

    /// The filled shape: each run of columns that `draws` becomes one closed outline, top edge left to right and bottom
    /// edge back, at least 1 pt thick so quiet stretches still show as a line. Columns that don't draw leave a hole.
    static func path(_ columns: [Float], middle: CGFloat, half: CGFloat, draws: (Int) -> Bool = { _ in true }) -> Path {
        var path = Path()
        var start: Int?
        func close(_ run: Range<Int>) {
            func amplitude(_ column: Int) -> CGFloat { max(0.5, CGFloat(columns[column]) * half) }
            path.move(to: CGPoint(x: CGFloat(run.lowerBound), y: middle - amplitude(run.lowerBound)))
            for column in run { path.addLine(to: CGPoint(x: CGFloat(column) + 0.5, y: middle - amplitude(column))) }
            path.addLine(to: CGPoint(x: CGFloat(run.upperBound), y: middle - amplitude(run.upperBound - 1)))
            path.addLine(to: CGPoint(x: CGFloat(run.upperBound), y: middle + amplitude(run.upperBound - 1)))
            for column in run.reversed() { path.addLine(to: CGPoint(x: CGFloat(column) + 0.5, y: middle + amplitude(column))) }
            path.addLine(to: CGPoint(x: CGFloat(run.lowerBound), y: middle + amplitude(run.lowerBound)))
            path.closeSubpath()
        }
        for column in columns.indices {
            if draws(column) {
                if start == nil { start = column }
            } else if let first = start {
                close(first..<column)
                start = nil
            }
        }
        if let first = start { close(first..<columns.count) }
        return path
    }

    /// A playhead's head: flat on top, pointing down at `x`.
    static func head(at x: CGFloat, width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x - width / 2, y: 0))
        path.addLine(to: CGPoint(x: x + width / 2, y: 0))
        path.addLine(to: CGPoint(x: x + width / 2, y: height / 2))
        path.addLine(to: CGPoint(x: x, y: height))
        path.addLine(to: CGPoint(x: x - width / 2, y: height / 2))
        path.closeSubpath()
        return path
    }
}

/// The whole voiceover: a continuous envelope, played part bright, a thin mark where each line starts, a dashed line
/// for a line without a render, and the playhead with its pointed head. Click or drag to seek.
private struct Waveform: View {
    @Environment(Preview.self) private var preview
    private static let headWidth: CGFloat = 9, headHeight: CGFloat = 8

    var body: some View {
        let timeline = preview.timeline, peaks = preview.peaks, position = preview.position
        GeometryReader { geometry in
            Canvas { context, size in
                guard timeline.duration > 0, size.width >= 1 else { return }
                func x(_ time: Double) -> CGFloat { CGFloat(time / timeline.duration) * size.width }
                // The envelope sits below the playhead's head.
                let top = Self.headHeight + 2, bottom = size.height - 1
                let middle = (top + bottom) / 2, half = (bottom - top) / 2
                let head = min(max(x(position), Self.headWidth / 2), size.width - Self.headWidth / 2).rounded()
                let gaps = timeline.segments.filter { $0.audio == nil }.map { x($0.start)...x($0.start + $0.duration) }
                let columns = WaveformEnvelope.columns(peaks, count: Int(size.width.rounded(.up)))
                let shape = WaveformEnvelope.path(columns, middle: middle, half: half) { column in
                    !gaps.contains { $0.contains(CGFloat(column) + 0.5) }
                }
                var played = context
                played.clip(to: Path(CGRect(x: 0, y: 0, width: head, height: size.height)))
                played.fill(shape, with: .color(Theme.text))
                var rest = context
                rest.clip(to: Path(CGRect(x: head, y: 0, width: size.width - head, height: size.height)))
                rest.fill(shape, with: .color(Theme.secondary))
                for gap in gaps {
                    var line = Path()
                    line.move(to: CGPoint(x: gap.lowerBound + 2, y: middle))
                    line.addLine(to: CGPoint(x: gap.upperBound - 2, y: middle))
                    context.stroke(line, with: .color(Theme.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for segment in timeline.segments.dropFirst() {
                    context.fill(Path(CGRect(x: x(segment.start), y: top, width: 1, height: bottom - top)), with: .color(Theme.line))
                }
                context.fill(Path(CGRect(x: head - 0.5, y: Self.headHeight - 1, width: 1, height: size.height - Self.headHeight + 1)),
                             with: .color(Theme.text))
                context.fill(WaveformEnvelope.head(at: head, width: Self.headWidth, height: Self.headHeight), with: .color(Theme.text))
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                preview.seek(to: Double(value.location.x / max(1, geometry.size.width)) * timeline.duration)
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Voiceover")
        .accessibilityValue("\(formatTime(position)) of \(formatTime(timeline.duration))")
        .accessibilityAdjustableAction { direction in preview.seek(to: position + (direction == .increment ? 5 : -5)) }
    }
}

/// AVPlayerView without controls; the voiceover's transport drives it.
private struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

// MARK: Outputs

struct OutputsPane: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(Player.self) private var player
    let project: Project
    /// Up to two rows, in the order picked: A, then B.
    @State private var picked: [String] = []
    @State private var side = 0
    @State private var hovered: String?

    var body: some View {
        let outputs = projects.outputs(project.id)
        let pair = picked.compactMap { id in outputs.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader("Outputs") {
                if pair.count == 2 {
                    SegmentedTabs(selection: Binding(get: { side }, set: { side = $0; compare(pair) }), options: [0, 1],
                                  title: { $0 == 0 ? "A" : "B" }, segmentWidth: 32, size: .s,
                                  help: { "Play \($0 == 0 ? "A" : "B") from the same moment" }, label: "Compare")
                }
            }
            if outputs.isEmpty {
                EmptyState(title: "No renders yet", message: "Each line\u{2019}s renders appear here as they finish.")
            } else {
                // Fills the rest of the column and scrolls.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(outputs) { output in
                            row(output, badge: pair.count == 2 ? (pair[0].id == output.id ? "A" : pair[1].id == output.id ? "B" : nil) : nil)
                        }
                    }
                    .padding(8)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .sidePanel()
    }

    /// Two lines, so the name gets the row's whole width: the name over its format, length and date.
    private func row(_ output: Output, badge: String?) -> some View {
        let selected = picked.contains(output.id), playing = player.playing == output.url
        return HStack(spacing: 8) {
            Button { player.toggle(output.url) } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                .buttonStyle(.icon(.s))
                .help(playing ? "Pause" : "Play")
                .accessibilityLabel("\(playing ? "Pause" : "Play") \(output.name)")
            VStack(alignment: .leading, spacing: 2) {
                Text(output.name).font(.vcBody).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(Self.details(output)).font(.vcCaption.monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let badge {
                Text(badge)
                    .font(.vcCaptionBold)
                    .foregroundStyle(Theme.text)
                    .frame(width: 16, height: 16)
                    .background(Theme.fill, in: .rect(cornerRadius: Radius.chip))
                    .accessibilityLabel("Compare \(badge)")
            }
        }
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(selected ? Theme.selection : hovered == output.id ? Theme.hover : .clear, in: .rect(cornerRadius: Radius.row))
        .onHover { if $0 { hovered = output.id } else if hovered == output.id { hovered = nil } }
        .contentShape(.rect)
        .onTapGesture { pick(output.id) }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output.url]) }
            if let line = output.usedBy {
                Button("In use by line \(line)") {}.disabled(true)
            } else {
                Button("Move to Trash") { projects.deleteOutput(output.id, in: project.id) }
            }
        }
    }

    /// "WAV · 0:02 · 18 Nov 2026": the date with its year, in the user's own order.
    static func details(_ output: Output) -> String {
        [output.format, formatTime(output.duration), output.date.formatted(.dateTime.day().month(.abbreviated).year())]
            .joined(separator: " \u{00B7} ")
    }

    private func pick(_ id: String) {
        if let index = picked.firstIndex(of: id) { picked.remove(at: index) } else { picked = Array((picked + [id]).suffix(2)) }
        side = 0
    }

    /// Switches playback to A or B at the same position.
    private func compare(_ pair: [Output]) {
        let time = pair.contains { $0.url == player.playing } ? player.time : 0
        player.play(pair[side].url, from: time)
    }
}

// MARK: Export

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VoiceStore.self) private var voices
    @Environment(ProjectStore.self) private var projects
    let projectID: String
    @State private var options = ExportOptions()
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export").font(.vcTitle)
                if projects.project(projectID)?.edit != nil {
                    Text("Follows the timeline, with its cuts and settings.").foregroundStyle(Theme.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Format").foregroundStyle(Theme.secondary)
                    Picker("Format", selection: $options.format) {
                        Text("WAV").tag("wav")
                        Text("M4A").tag("m4a")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
                GridRow {
                    Text("Loudness").foregroundStyle(Theme.secondary)
                    Picker("Loudness", selection: $options.lufs) {
                        ForEach([-14, -16, -23], id: \.self) { Text("\u{2212}\(-$0) LUFS").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("File per line", isOn: $options.perLine)
                Toggle("File per voice", isOn: $options.perVoice)
                Toggle("SRT captions", isOn: $options.srt)
                Toggle("Timing JSON", isOn: $options.timing)
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.vc(.secondary, .m)).keyboardShortcut(.cancelAction)
                Button(running ? "Exporting…" : "Export", action: run)
                    .buttonStyle(.vc(.primary, .m))
                    .keyboardShortcut(.defaultAction)
                    .disabled(running)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Theme.content)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    private func run() {
        running = true
        Task {
            do {
                let result = try await projects.export(projectID, options: options, voices: voices)
                NSWorkspace.shared.activateFileViewerSelecting(result.files)
            } catch is CancellationError {} catch {
                projects.error = "Export failed. \(error.localizedDescription)"
            }
            dismiss()
        }
    }
}

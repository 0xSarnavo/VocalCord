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
            segments.append(Segment(lineID: line.id, audio: version.map(audioURL), start: time, duration: length))
            duration = time + length
            time = duration + line.pauseAfter
        }
    }

    /// The line playing at `time`, its pause included.
    func line(at time: Double) -> String? { segments.last { $0.start <= time + 0.001 }?.lineID }
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
    @State private var choosing = false
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview").font(.system(size: 17, weight: .bold))
                Spacer()
                Menu {
                    Button("Choose video…") { choosing = true }
                    Button("Remove video") { projects.setVideo(nil, in: project.id) }.disabled(project.video == nil)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Video")
            }
            Theme.line.frame(height: 1)
            videoArea
            Waveform().frame(height: 64)
            HStack(spacing: 12) {
                Button { preview.toggle() } label: {
                    Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(preview.timeline.duration == 0)
                .accessibilityLabel(preview.isPlaying ? "Pause" : "Play")
                PlayTime()
                Spacer()
                if project.video != nil { offsetField }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { projects.setVideo(Video(path: url.path), in: project.id) }
        }
    }

    @ViewBuilder private var videoArea: some View {
        if let video = project.video {
            ZStack {
                Color.black
                if FileManager.default.fileExists(atPath: video.path) {
                    VideoSurface(player: preview.videoPlayer)
                } else {
                    VStack(spacing: 10) {
                        Text("Video not found").foregroundStyle(Theme.secondary)
                        Button("Choose…") { choosing = true }.buttonStyle(.outline(height: 28))
                    }
                    .font(.system(size: 13))
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropping ? Theme.outline : Theme.line))
            .dropDestination(for: URL.self) { urls, _ in attach(urls) } isTargeted: { dropping = $0 }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "film").foregroundStyle(Theme.secondary)
                Text("Drop a video").foregroundStyle(Theme.secondary)
                Spacer()
                Button("Choose…") { choosing = true }.buttonStyle(.outline(height: 28))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(dropping ? Theme.selection : .clear, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
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
        .font(.system(size: 13).monospacedDigit())
        .help("Seconds the video starts after the voiceover; negative starts it earlier")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video offset, seconds")
    }
}

/// Its own view so only it redraws as the playhead moves.
private struct PlayTime: View {
    @Environment(Preview.self) private var preview

    var body: some View {
        Text("\(formatTime(preview.position.rounded(.down))) / \(formatTime(preview.timeline.duration))")
            .font(.system(size: 13).monospacedDigit())
    }
}

/// The whole voiceover: bars, a thin mark where each line starts, a dashed line for a line without a render,
/// and the playhead. Click or drag to seek.
private struct Waveform: View {
    @Environment(Preview.self) private var preview

    var body: some View {
        let timeline = preview.timeline, peaks = preview.peaks, position = preview.position
        GeometryReader { geometry in
            Canvas { context, size in
                guard timeline.duration > 0 else { return }
                func x(_ time: Double) -> CGFloat { CGFloat(time / timeline.duration) * size.width }
                let middle = size.height / 2, head = min(max(x(position), 3.5), size.width - 3.5)
                let gaps = timeline.segments.filter { $0.audio == nil }.map { x($0.start)...x($0.start + $0.duration) }
                let bars = max(1, Int(size.width / 3))
                for bar in 0..<bars {
                    let left = CGFloat(bar) * 3
                    guard !gaps.contains(where: { $0.contains(left + 0.75) }) else { continue }
                    let low = bar * peaks.count / bars, high = max(low + 1, (bar + 1) * peaks.count / bars)
                    let peak = low < peaks.count ? peaks[low..<min(high, peaks.count)].max() ?? 0 : 0
                    let height = max(1, CGFloat(peak) * (size.height - 10))
                    context.fill(Path(CGRect(x: left, y: middle - height / 2, width: 1.5, height: height)),
                                 with: .color(left < head ? Theme.text : Theme.secondary))
                }
                for gap in gaps {
                    var line = Path()
                    line.move(to: CGPoint(x: gap.lowerBound + 2, y: middle))
                    line.addLine(to: CGPoint(x: gap.upperBound - 2, y: middle))
                    context.stroke(line, with: .color(Theme.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for segment in timeline.segments.dropFirst() {
                    context.fill(Path(CGRect(x: x(segment.start), y: 0, width: 1, height: size.height)), with: .color(Theme.line))
                }
                context.fill(Path(CGRect(x: head - 0.75, y: 3, width: 1.5, height: size.height - 3)), with: .color(Theme.text))
                context.fill(Path(ellipseIn: CGRect(x: head - 3.5, y: 0, width: 7, height: 7)), with: .color(Theme.text))
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

    var body: some View {
        let outputs = projects.outputs(project.id)
        let pair = picked.compactMap { id in outputs.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Outputs").font(.system(size: 17, weight: .bold))
                Spacer()
                if pair.count == 2 {
                    Picker("Compare", selection: Binding(get: { side }, set: { side = $0; compare(pair) })) {
                        Text("A").tag(0)
                        Text("B").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 80)
                }
            }
            .frame(height: 28)
            Theme.line.frame(height: 1)
            if outputs.isEmpty {
                Text("No outputs").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(outputs) { output in
                        row(output, badge: pair.count == 2 ? (pair[0].id == output.id ? "A" : pair[1].id == output.id ? "B" : nil) : nil)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func row(_ output: Output, badge: String?) -> some View {
        let selected = picked.contains(output.id), playing = player.playing == output.url
        return HStack(spacing: 8) {
            Button { player.toggle(output.url) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 11))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(playing ? "Pause" : "Play") \(output.name)")
            if let badge { Text(badge).fontWeight(.bold).foregroundStyle(Theme.secondary) }
            Text(output.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            Text(output.format).frame(width: 32, alignment: .leading)
            Text(formatTime(output.duration)).frame(width: 34, alignment: .trailing)
            Text(output.date, format: .dateTime.day().month(.abbreviated).year()).lineLimit(1).frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 13).monospacedDigit())
        .padding(.horizontal, 6)
        .frame(height: 46)
        .background(selected ? Theme.selection : .clear, in: .rect(cornerRadius: 8))
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .contentShape(.rect)
        .onTapGesture { pick(output.id) }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output.url]) }
            if let line = output.usedBy {
                Button("In use by line \(line)") {}.disabled(true)
            } else {
                Button("Delete", role: .destructive) { projects.deleteOutput(output.id, in: project.id) }
            }
        }
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
        VStack(alignment: .leading, spacing: 20) {
            Text("Export").font(.system(size: 22, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
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
            VStack(alignment: .leading, spacing: 10) {
                Toggle("File per line", isOn: $options.perLine)
                Toggle("File per voice", isOn: $options.perVoice)
                Toggle("SRT captions", isOn: $options.srt)
                Toggle("Timing JSON", isOn: $options.timing)
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.outline(height: 32)).keyboardShortcut(.cancelAction)
                Button(running ? "Exporting…" : "Export", action: run)
                    .buttonStyle(.primary(height: 32))
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

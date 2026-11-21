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

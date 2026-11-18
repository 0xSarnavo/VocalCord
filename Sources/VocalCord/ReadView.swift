import AppKit
import SwiftUI

// MARK: Read math

/// The Read view's choices as plain values, so they can be tested without a window.
@MainActor
enum ReadLayout {
    /// The column of text: about 70 characters of 26 pt type, a comfortable measure.
    static let textWidth = 680.0
    /// Room either side of the column for the line numbers and pause marks.
    static let margin = 64.0
    /// `ScriptTextView.lit` for a line already played: every word lit.
    static let allWords = Int.max

    /// The preview position the read-along follows: while the preview plays this project, or is paused partway, so a
    /// pause keeps your place. Nil while a take plays on its own (only its line lights) or before anything has played.
    static func position(_ timeline: Timeline, at position: Double, isPlaying: Bool, takePlaying: Bool, in project: Project) -> Double? {
        guard timeline.projectID == project.id, isPlaying || (!takePlaying && position > 0) else { return nil }
        return position
    }

    /// What a paragraph lights (`ScriptTextView.lit`): up to the word being said on the playing line, only when it plays
    /// the line's current text, as the words wouldn't match otherwise; every word of a line the preview has played past;
    /// nothing on the rest, or while nothing plays.
    static func lit(_ line: Line, playing: LitWord?, position: Double?, timeline: Timeline, in project: Project) -> Int? {
        if let playing, playing.lineID == line.id {
            return project.version(playing.versionID)?.text == line.text ? playing.token : nil
        }
        guard let position else { return nil }
        let segments = timeline.segments.filter { $0.lineID == line.id }
        guard !segments.isEmpty, segments.allSatisfy({ $0.start + $0.duration <= position + 0.001 }) else { return nil }
        return allWords
    }

    /// Where on the timeline a click on a line's word starts playing: at the word, in the piece of the render that holds
    /// it, a moment early so its first sound isn't cut. At the line's start when its words aren't timed, don't match its
    /// text, or were trimmed away; nil when the line isn't on the timeline.
    static func seekTime(token: Int, in line: Line, times: [WordTime]?, timeline: Timeline) -> Double? {
        let segments = timeline.segments.filter { $0.lineID == line.id }
        guard let first = segments.first else { return nil }
        guard let version = line.chosenVersion, version.text == line.text, let times, times.indices.contains(token) else { return first.start }
        let word = times[token].start
        guard let segment = segments.first(where: {
            $0.versionID == version.id && word >= $0.renderStart - 0.001 && word < $0.renderStart + $0.duration * $0.tempo
        }) else { return first.start }
        let from = max(segment.renderStart, word - ReadAlong.lead)
        return segment.start + (from - segment.renderStart) / segment.tempo
    }

    /// The space after a paragraph, growing with its pause so the page breathes where the voice does.
    static func gap(after pause: Double) -> Double { 18 + min(max(pause, 0), 3) * 20 }

    /// A note under a paragraph whose audio doesn't play its text as shown.
    static func hint(_ line: Line) -> String? {
        if line.proposal != nil { return "Change proposed. Review it in Table." }
        if line.chosenVersion == nil { return "Not rendered" }
        if line.needsRender { return "Changed since its render" }
        return nil
    }

    /// The first baseline of a `.read` paragraph, from its top, so a line number sits on it.
    static let firstBaseline: Double = {
        let storage = NSTextStorage(string: "A", attributes: ScriptTextMetrics(.read).attributes)
        let layout = NSLayoutManager(), container = NSTextContainer(size: NSSize(width: 1000, height: 1000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + layout.location(forGlyphAt: 0).y
    }()
}

// MARK: Read view

/// The Script panel's Read view: the whole script in large type, lighting up word by word as it plays, like a
/// teleprompter: lines played in white, the rest in grey. Click a word to play from it; select words and right-click
/// to direct them.
struct ReadView: View {
    @Environment(VoiceStore.self) private var voices
    @Environment(ProjectStore.self) private var projects
    @Environment(Preview.self) private var preview
    @Environment(Player.self) private var player
    let project: Project
    /// When the user last scrolled or clicked a word; following the playing line waits a few seconds after.
    @State private var touched = Date.distantPast

    var body: some View {
        let lines = project.lines.enumerated().filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        VStack(spacing: 0) {
            if lines.isEmpty {
                VStack(spacing: 6) {
                    Text("The script is empty.")
                    Text("Write or paste lines in Table, then listen to them here.").foregroundStyle(Theme.secondary)
                }
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Player.time isn't observable, so a take playing on its own redraws on a timer.
                TimelineView(.animation(minimumInterval: 0.05, paused: player.playing == nil && !preview.isPlaying)) { _ in
                    page(lines)
                }
                Theme.line.frame(height: 1).padding(.horizontal, 8)
                transport
            }
        }
        .onChange(of: project.id, initial: true) { projects.timeWordsIfNeeded(project.id, voices: voices) }
    }

    private func page(_ lines: [(offset: Int, element: Line)]) -> some View {
        let timeline = preview.timeline
        let position = ReadLayout.position(timeline, at: preview.position, isPlaying: preview.isPlaying, takePlaying: player.playing != nil,
                                           in: project)
        let playing = ReadAlong.lit(in: project, projects: projects, preview: preview, player: player)
            ?? position.flatMap { ReadAlong.lit(timeline, at: $0, in: project, projects: projects) }
        let lastID = lines.last?.element.id
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.element.id) { index, line in
                        Paragraph(line: line, number: index + 1,
                                  lit: ReadLayout.lit(line, playing: playing, position: position, timeline: timeline, in: project),
                                  playing: playing?.lineID == line.id, gap: line.id == lastID ? nil : ReadLayout.gap(after: line.pauseAfter),
                                  onCommand: { command($0, line: line) }, onWordClick: { play(line, from: $0) }, onPlay: { play(line, from: -1) })
                            .id(line.id)
                    }
                }
                .frame(maxWidth: ReadLayout.textWidth, alignment: .leading)
                .padding(.horizontal, ReadLayout.margin)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollPhaseChange { old, new in
                if Self.byUser(old) || Self.byUser(new) { touched = .now }
            }
            // Keeps the playing line about a third of the way down, unless the user is looking elsewhere.
            .onChange(of: playing?.lineID, initial: true) { _, id in
                guard let id, Date.now.timeIntervalSince(touched) > 3 else { return }
                withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.3)) }
            }
        }
    }

    private static func byUser(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating: true
        default: false
        }
    }

    /// Plays the voiceover from a word, or from the line's start for -1. The click counts as looking, so the page stays
    /// put under the pointer for a moment instead of scrolling the line away.
    private func play(_ line: Line, from token: Int) {
        guard preview.timeline.projectID == project.id else { return }
        let times = line.chosenVersion.flatMap { projects.displayTimes($0) }
        guard let time = ReadLayout.seekTime(token: token, in: line, times: times, timeline: preview.timeline) else { return }
        touched = .now
        preview.seek(to: time)
        preview.play()
    }

    /// A command from the menu: saved, then rendered or applied as needed and played.
    private func command(_ text: String, line: Line) {
        projects.setText(text, line: line.id, in: project.id)
        projects.commitAndPlay(line.id, in: project.id, voices: voices, player: player)
    }

    private var transport: some View {
        HStack(spacing: 8) {
            PlayToggle(spaceKey: false)
            PlayTime().padding(.leading, 4)
            Spacer(minLength: 16)
            ViewThatFits(in: .horizontal) {
                Text("Click a word to play from it. Select words and right-click to direct them.")
                Text("Click a word to play from it.")
                Color.clear.frame(width: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }
}

/// One line as a paragraph: its number in the margin, its words lighting as they're said, a note when its audio
/// doesn't play its text, and room after it for its pause.
private struct Paragraph: View {
    let line: Line
    let number: Int
    let lit: Int?
    let playing: Bool
    /// The space after it for its pause; nil for the last line.
    let gap: Double?
    let onCommand: (String) -> Void
    let onWordClick: (Int) -> Void
    let onPlay: () -> Void

    var body: some View {
        let hint = ReadLayout.hint(line), baseline = ReadLayout.firstBaseline
        VStack(alignment: .leading, spacing: 6) {
            ScriptTextView(text: line.text, style: .read, lit: lit, placeholder: "", onCommand: onCommand, onWordClick: onWordClick)
                // Nothing to play yet, so it reads as a draft.
                .opacity(line.chosenVersion == nil ? 0.55 : 1)
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            Text("\(number)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(playing ? Theme.text : Theme.secondary)
                .alignmentGuide(.leading) { $0[.trailing] + 20 }
                .alignmentGuide(.top) { $0[.firstTextBaseline] - baseline }
                .accessibilityHidden(true)
        }
        .padding(.bottom, gap ?? 0)
        // The pause in the margin, in the middle of the space it makes, lined up under the numbers.
        .overlay(alignment: .bottomLeading) {
            if let gap, line.pauseAfter > 0 {
                Text(ScriptDisplay.format(line.pauseAfter) + "s")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.secondary.opacity(0.6))
                    .frame(width: ReadLayout.margin - 24, height: gap, alignment: .trailing)
                    .offset(x: -ReadLayout.margin + 4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Line \(number)")
        .accessibilityValue([playing ? "Playing" : nil, hint].compactMap(\.self).joined(separator: ", "))
        .accessibilityAction(named: "Play from here", onPlay)
    }
}

import Foundation
import SwiftUI
import Testing
@testable import VocalCord

// The words under each clip on the Timeline tab's track.

/// Labels 6 points a character, so widths are easy to follow.
private func measure(_ text: String) -> Double { Double(text.count) * 6 }
private let texts = ["One", "two", "three", "four"]
/// Words at 0.2, 0.8, 1.4 and 2.0 s of a 2.6 s render, each 0.4 s long.
private let times = [WordTime(start: 0.2, end: 0.6), WordTime(start: 0.8, end: 1.2), WordTime(start: 1.4, end: 1.8), WordTime(start: 2, end: 2.4)]

private func clip(start: Double = 0, end: Double = 2.6, tempo: Double = 1) -> EditClip {
    EditClip(lineID: "a", versionID: "a1", start: start, end: end, gapAfter: 0, effects: VoiceEffects(tempo: tempo))
}

private func strip(_ clip: EditClip, zoom: Double) -> [StripWord] {
    TrackLayout.stripWords(texts, times: times, clip: clip, pointsPerSecond: zoom, measure: measure)
}

/// Each word's token and where it sits, to the thousandth of a point.
private func placed(_ words: [StripWord]) -> [String] { words.map { "\($0.text)@\(($0.x * 1000).rounded() / 1000)" } }

@Test func stripWordsSitWhereTheyreSaid() {
    // The whole render at 100 points a second: each word where it starts.
    #expect(placed(strip(clip(), zoom: 100)) == ["One@20.0", "two@80.0", "three@140.0", "four@200.0"])
    #expect(strip(clip(), zoom: 100).map(\.token) == [0, 1, 2, 3])
    // Trimmed to start at 0.7 s: "One" is cut, and the rest sit 70 points further left, from the clip's new edge.
    #expect(placed(strip(clip(start: 0.7), zoom: 100)) == ["two@10.0", "three@70.0", "four@130.0"])
    // At double speed every gap is half as wide: zoomed in twice as far, the words sit where they did; at the same zoom
    // "four" would run into "three".
    #expect(placed(strip(clip(tempo: 2), zoom: 200)) == ["One@20.0", "two@80.0", "three@140.0", "four@200.0"])
    #expect(placed(strip(clip(tempo: 2), zoom: 100)) == ["One@10.0", "two@40.0", "three@70.0"])
    // A word mostly inside a trimmed edge stays, at the clip's text inset (under "Line 3"); one mostly outside goes.
    #expect(placed(strip(clip(start: 0.9, end: 2.1), zoom: 100)) == ["two@6.0", "three@50.0"])
    // Times that don't match the words, as for a render whose words aren't timed for this text: none.
    #expect(TrackLayout.stripWords(["One"], times: times, clip: clip(), pointsPerSecond: 100, measure: measure).isEmpty)
}

@Test func stripThinsOutWhenZoomedOut() {
    // At 20 points a second words are 12 points apart: "two" would run into "One", so the strip stops there.
    #expect(placed(strip(clip(), zoom: 20)) == ["One@6.0"])
    // It stops rather than skipping: at 30 points a second "three" would fit after "One", but without "two" between
    // them the strip would read as other words ("Meet next of your"), so it shows "One" alone.
    #expect(placed(strip(clip(), zoom: 30)) == ["One@6.0"])
    // A clip under 40 points shows none.
    #expect(strip(clip(), zoom: 15).isEmpty && !strip(clip(), zoom: 16).isEmpty)
    // At any zoom, the words are the first ones in order, no label touches the one before it, and every label ends
    // inside the clip.
    for zoom in stride(from: 4.0, through: 200, by: 7) {
        let clip = clip(start: 0.3), words = strip(clip, zoom: zoom)
        #expect(words.map(\.token) == Array(0..<words.count))
        for (before, word) in zip(words, words.dropFirst()) {
            #expect(word.x >= before.x + measure(before.text) + TrackLayout.stripGap)
        }
        if let last = words.last { #expect(last.x + measure(last.text) <= clip.duration * zoom - TrackLayout.stripInset) }
        #expect(words.allSatisfy { $0.x >= TrackLayout.stripInset })
    }
}

@MainActor @Suite(.serialized, .enabled(if: canDrawOffscreen, "Needs a window server to draw."))
struct TimelineWordsSnapshots {
    @Test func trackWithWordsUnderClips() async throws {
        let (projects, voices, preview, _, id) = try await readFixture([
            "Welcome to VocalCord, the voice studio that lives on your Mac.",
            "Write a line, pick a tone, and hear it in your own voice.",
            "Then shape every word until it sounds just right.",
        ])
        #expect(projects.error == nil)
        projects.startEdit(id)
        let clips = try #require(projects.project(id)?.edit?.clips)
        #expect(clips.count == 3)
        // The first clip trimmed at both ends, the second sped up.
        #expect(projects.trimClip(clips[0].id, start: 0.6, end: 2.7, in: id))
        #expect(projects.setClipEffects(VoiceEffects(tempo: 1.25), clip: clips[1].id, in: id))
        let project = try #require(projects.project(id))
        await preview.load(try await projects.playbackTimeline(id, engine: voices.engine))

        // The zoom is read from its own defaults, so the test leaves the app's alone.
        let suite = "VocalCordTests-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        for (zoom, name) in [(90.0, "timeline-words-zoomed-in"), (60, "timeline-words-standard"), (24, "timeline-words-zoomed-out")] {
            store.set(zoom, forKey: "timelineZoom")
            let pane = EditorPane(project: project, selected: .constant(clips[1].id))
                .environment(projects).environment(voices).environment(preview).defaultAppStorage(store)
            try drawOffscreen(pane, width: 1000, height: 330, name: name)
        }
        // A short panel gives the clips their smallest height, which still fits the name, a waveform and the words.
        store.set(90.0, forKey: "timelineZoom")
        try drawOffscreen(EditorPane(project: project, selected: .constant(nil)).environment(projects).environment(voices)
            .environment(preview).defaultAppStorage(store), width: 1000, height: 250, name: "timeline-words-short")

        // While a clip plays, the words already said light up.
        let words = TrackLayout.stripWords(texts + ["five", "six"], times: times + [WordTime(start: 2.6, end: 2.9), WordTime(start: 3, end: 3.3)],
                                           clip: clip(end: 3.4), pointsPerSecond: 90, measure: StripText.width)
        try drawOffscreen(StripText(words: words, lit: 2).frame(height: 16).padding(8), width: 340, height: 32, name: "timeline-words-lit")
    }
}

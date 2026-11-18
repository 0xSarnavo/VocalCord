import Foundation
import Testing
@testable import VocalCord

private func clip(_ id: String, length: Double = 2, gap: Double = 0.5, tempo: Double = 1) -> EditClip {
    EditClip(id: id, lineID: id, versionID: id + "1", start: 0, end: length, gapAfter: gap, effects: VoiceEffects(tempo: tempo))
}

// MARK: Scale and ruler

@Test func scaleMapsTimeToPointsAndBack() {
    let scale = TrackScale(pointsPerSecond: 50, inset: 16)
    #expect(scale.x(0) == 16 && scale.x(2) == 116)
    #expect(scale.time(at: 116) == 2 && scale.time(at: 16) == 0 && scale.time(at: 0) < 0)
    for time in [0.0, 0.37, 12.5, 61] { #expect(abs(scale.time(at: scale.x(time)) - time) < 1e-9) }
}

@Test func zoomStepsStayInRange() {
    #expect(TrackScale.zoomed(60, in: true) == 90 && TrackScale.zoomed(90, in: false) == 60)
    #expect(TrackScale.zoomed(TrackScale.zooms.upperBound, in: true) == TrackScale.zooms.upperBound)
    #expect(TrackScale.zoomed(TrackScale.zooms.lowerBound, in: false) == TrackScale.zooms.lowerBound)
    // Fit leaves the margin on both sides; nothing to fit keeps the standard zoom.
    #expect(TrackScale.fitting(10, in: 532, inset: 16) == 50)
    #expect(TrackScale.fitting(0, in: 500) == TrackScale.standard && TrackScale.fitting(10, in: 10) == TrackScale.standard)
    #expect(TrackScale.fitting(3600, in: 800) == TrackScale.zooms.lowerBound && TrackScale.fitting(0.1, in: 800) == TrackScale.zooms.upperBound)
}

@Test func rulerTicksLeaveRoomForLabels() {
    #expect(TrackScale(pointsPerSecond: 60).tickStep() == 2)      // 1 s is 60 pt, under 64
    #expect(TrackScale(pointsPerSecond: 64).tickStep() == 1)
    #expect(TrackScale(pointsPerSecond: 200).tickStep() == 0.5)
    #expect(TrackScale(pointsPerSecond: 4).tickStep() == 30)
    #expect(TrackScale(pointsPerSecond: 0.01).tickStep() == 600)  // past the last step, the last
    for zoom in [4.0, 9, 33, 100, 200] {
        let step = TrackScale(pointsPerSecond: zoom).tickStep()
        #expect(step * zoom >= 64 && TrackScale.steps.contains(step))
    }
}

@Test func rulerLabelsMatchTheirStep() {
    #expect(TrackScale.label(65, step: 5) == "1:05" && TrackScale.label(0, step: 1) == "0:00")
    #expect(TrackScale.label(4.5, step: 0.5) == "0:04.5" && TrackScale.label(0, step: 0.1) == "0:00.0")
    #expect(TrackScale.label(64.25, step: 0.25) == "1:04.25" && TrackScale.label(0.3, step: 0.1) == "0:00.3")
    #expect(TrackScale.label(59.96, step: 0.1) == "1:00.0")   // rounds into the next minute, not "0:60.0"
}

// MARK: Layout

@Test func framesFollowTheEditAndTrimsInProgress() {
    let edit = Edit(clips: [clip("a", length: 2, gap: 1), clip("b", length: 4, gap: 0.5, tempo: 2), clip("c", length: 1)])
    let scale = TrackScale(pointsPerSecond: 10, inset: 0)
    // b plays 4 s of render at double speed: 2 s on the timeline.
    #expect(TrackLayout.frames(edit, scale: scale) == [ClipFrame(x: 0, width: 20), ClipFrame(x: 30, width: 20), ClipFrame(x: 55, width: 10)])

    // Dragging b's end in pushes c back by as much; dragging its start leaves c alone and moves b's left edge.
    let end = TrimDraft(clipID: "b", edge: .end, start: 0, end: 2)
    #expect(TrackLayout.frames(edit, scale: scale, trim: end) == [ClipFrame(x: 0, width: 20), ClipFrame(x: 30, width: 10), ClipFrame(x: 45, width: 10)])
    let start = TrimDraft(clipID: "b", edge: .start, start: 1, end: 4)
    #expect(TrackLayout.frames(edit, scale: scale, trim: start) == [ClipFrame(x: 0, width: 20), ClipFrame(x: 35, width: 15), ClipFrame(x: 55, width: 10)])
    #expect(TrackLayout.frames(Edit(), scale: scale).isEmpty)
}

@Test func trimHandlesStayInsideTheRender() {
    let plain = EditClip(id: "x", lineID: "a", versionID: "a1", start: 1, end: 3, gapAfter: 0)
    // Each edge moves by the drag; neither leaves the render or comes within 0.05 s of the other.
    #expect(TrackLayout.trimmed(plain, edge: .start, by: 0.5, renderDuration: 4) == (1.5, 3))
    #expect(TrackLayout.trimmed(plain, edge: .start, by: -5, renderDuration: 4) == (0, 3))
    #expect(TrackLayout.trimmed(plain, edge: .start, by: 9, renderDuration: 4) == (3 - Edit.shortest, 3))
    #expect(TrackLayout.trimmed(plain, edge: .end, by: -0.5, renderDuration: 4) == (1, 2.5))
    #expect(TrackLayout.trimmed(plain, edge: .end, by: 5, renderDuration: 4) == (1, 4))
    #expect(TrackLayout.trimmed(plain, edge: .end, by: -9, renderDuration: 4) == (1, 1 + Edit.shortest))
    // At double speed a second on the timeline is two of the render.
    var fast = plain
    fast.effects.tempo = 2
    #expect(TrackLayout.trimmed(fast, edge: .end, by: -0.25, renderDuration: 4) == (1, 2.5))
    #expect(TrackLayout.trimmed(fast, edge: .start, by: 0.25, renderDuration: 4) == (1.5, 3))
    // A render shorter than the clip says (it can't, but never a bad range).
    #expect(TrackLayout.trimmed(plain, edge: .end, by: 1, renderDuration: 0.5) == (1, 1 + Edit.shortest))
}

@Test func dropIndexIsThePlaceAmongTheOtherClips() {
    // a 0–2, b 2.5–4.5, c 5–6: middles at 1, 3.5 and 5.5.
    let edit = Edit(clips: [clip("a"), clip("b"), clip("c", length: 1)])
    #expect(TrackLayout.dropIndex(center: 1, moving: 0, in: edit) == 0)
    #expect(TrackLayout.dropIndex(center: 3.6, moving: 0, in: edit) == 1)   // past b's middle
    #expect(TrackLayout.dropIndex(center: 9, moving: 0, in: edit) == 2)
    #expect(TrackLayout.dropIndex(center: -3, moving: 2, in: edit) == 0)
    #expect(TrackLayout.dropIndex(center: 3, moving: 2, in: edit) == 1)
    #expect(TrackLayout.dropIndex(center: 5.5, moving: 2, in: edit) == 2)   // where it was
    // The index is what Edit.move expects.
    var moved = edit
    try? moved.move(clip: "a", to: TrackLayout.dropIndex(center: 3.6, moving: 0, in: edit))
    #expect(moved.clips.map(\.id) == ["b", "a", "c"])

    let frames = [ClipFrame(x: 0, width: 20), ClipFrame(x: 25, width: 20), ClipFrame(x: 50, width: 10)]
    #expect(TrackLayout.insertionX(1, moving: 0, frames: frames) == 46)    // before c
    #expect(TrackLayout.insertionX(2, moving: 0, frames: frames) == 64)    // after c
    #expect(TrackLayout.insertionX(0, moving: 2, frames: frames) == -4)
    #expect(TrackLayout.insertionX(0, moving: 0, frames: [frames[0]]) == nil)
}

@Test func splitNeedsAudioUnderThePlayhead() {
    // a 0–2, gap to 2.5, b 2.5–4.5 at double speed (4 s of render).
    let edit = Edit(clips: [clip("a"), clip("b", length: 4, tempo: 2)])
    #expect(TrackLayout.split(at: 1, in: edit)?.clip.id == "a" && TrackLayout.split(at: 1, in: edit)?.offset == 1)
    #expect(TrackLayout.split(at: 3.5, in: edit)?.clip.id == "b" && TrackLayout.split(at: 3.5, in: edit)?.offset == 1)
    #expect(TrackLayout.split(at: 2.2, in: edit) == nil)   // in the gap
    #expect(TrackLayout.split(at: 0.01, in: edit) == nil && TrackLayout.split(at: 1.99, in: edit) == nil)
    // 0.03 s on the timeline is 0.06 s of b's render, enough.
    #expect(TrackLayout.split(at: 2.53, in: edit)?.clip.id == "b" && TrackLayout.split(at: 2.51, in: edit) == nil)
    #expect(TrackLayout.split(at: -1, in: edit) == nil && TrackLayout.split(at: 1, in: Edit()) == nil)
    // Every split it offers, the edit accepts.
    for time in stride(from: 0.0, through: 4.5, by: 0.01) {
        guard let split = TrackLayout.split(at: time, in: edit) else { continue }
        var copy = edit
        #expect(throws: Never.self) { try copy.split(clip: split.clip.id, at: split.offset) }
    }
}

@Test func clipLabelsDropTags() {
    // Parentheses are words to the voice, so they stay, as in Marks.plain.
    #expect(TrackLayout.words("[confident] Hello there, [pause 0.3] friend (sigh).") == "Hello there, friend (sigh).")
    #expect(TrackLayout.words("Meet [say Ha-vee-air]Javier[/say], [stress]please[/stress].") == "Meet Javier, please.")
    #expect(TrackLayout.words("  Plain   words\nhere ") == "Plain words here")
    #expect(TrackLayout.words("[happy]") == "")
}

@Test func slidersSettleOnRoundValues() {
    #expect(1.26.snapped(0.5) == 1.5 && (-3.2).snapped(0.5) == -3 && 0.3.snapped(0.05) == 0.3)
    #expect(0.1234.snapped(0.05) == 0.1 && 1.04.snapped(0.05) == 1.05 && 7.0.snapped(1) == 7)
}

// MARK: Track and clip drawing

@Test func clipsGrowWithThePaneBetweenTheLimits() {
    // The ruler, its gap and the scroll bar's room come off first; the clips take the rest, 96 to 240 points.
    #expect(TrackLayout.height(lane: 0) == 48 && TrackLayout.lanes == 96...240)
    #expect(TrackLayout.lane(available: 600) == 240 && TrackLayout.lane(available: 200) == 152 && TrackLayout.lane(available: 100) == 96)
    // The scroll view's content stops above the scroll bar's 16 points, so the bar never lands on anything drawn.
    for lane in [96.0, 150, 240] { #expect(TrackLayout.height(lane: lane) - TrackLayout.content(lane: lane) == TrackLayout.scrollBar) }
    // Whenever there's room for the smallest clips, the whole track fits where it's put.
    for available in stride(from: 144.0, through: 800, by: 13) {
        #expect(TrackLayout.height(lane: TrackLayout.lane(available: available)) <= available)
    }
}

@Test func clipBandsFitAtEveryLaneHeight() {
    for lane in [TrackLayout.lanes.lowerBound, 160, TrackLayout.lanes.upperBound] {
        let wave = ClipLayout.waveform(height: lane)
        // The waveform starts under the header band and ends above the words strip, with room to read it.
        #expect(wave.y >= ClipLayout.header + ClipLayout.waveInset.vertical)
        #expect(wave.y + wave.height + ClipLayout.waveInset.vertical + ClipLayout.strip + ClipLayout.stripBottom <= lane)
        #expect(wave.height >= 40)
    }
    // Trim zones: 12 points inside each edge, a quarter of a narrow clip so its middle still moves it.
    #expect(TrackLayout.trimZone(200) == 12 && TrackLayout.trimZone(48) == 12 && TrackLayout.trimZone(20) == 5)
}

@Test func waveformIsAnEnvelopeAndSilenceDrawsNothing() {
    // A second of render at 100 peaks a second: silence, sound, silence.
    let peaks = [Float](repeating: 0, count: 30) + [Float](repeating: 0.8, count: 40) + [Float](repeating: 0, count: 30)
    let plain = EditClip(id: "x", lineID: "a", versionID: "a1", start: 0, end: 1, gapAfter: 0)
    let levels = ClipLayout.levels(peaks, clip: plain, width: 100, perSecond: 100)
    #expect(levels.count == 100)
    #expect(levels[..<28].allSatisfy { $0 == 0 } && levels[72...].allSatisfy { $0 == 0 })
    #expect(levels[31..<69].allSatisfy { abs($0 - 0.8 * 0.85) < 1e-6 })
    // One closed shape over the sound, mirrored about the middle; nothing at all over silence.
    let shape = ClipLayout.envelope(levels, height: 40).boundingRect
    #expect(shape.minX >= 27 && shape.maxX <= 73)
    #expect(abs(shape.midY - 20) < 1e-6 && shape.height > 20)
    #expect(ClipLayout.envelope([Double](repeating: 0, count: 50), height: 40).isEmpty)
    #expect(ClipLayout.envelope([Double](repeating: 0.001, count: 50), height: 40).isEmpty)
    // A fade in quietens the start; the volume scales it all.
    var faded = plain
    faded.fadeIn = 0.5
    faded.gain = -6
    let shaped = ClipLayout.levels(peaks, clip: faded, width: 100, perSecond: 100)
    #expect(shaped[35] < shaped[60] && shaped[60] < levels[60])
    // Zoomed out, a column keeps the loudest peak under it.
    #expect(ClipLayout.levels(peaks, clip: plain, width: 10, perSecond: 100)[3...6].allSatisfy { $0 > 0.6 })
    #expect(ClipLayout.levels([], clip: plain, width: 100, perSecond: 100).isEmpty)
}

@Test func rulerLabelsShowWholeOrNotAtAll() {
    // A 26-point label sits 6 right of its tick, clear of the playhead's head (5.5 either side) resting on the tick.
    #expect(TrackLayout.playheadHead.width == 11 && TrackLayout.playheadHead.height == 10)
    #expect(TrackLayout.rulerLabelInset > TrackLayout.playheadHead.width / 2)
    #expect(TrackLayout.rulerLabelFits(tick: 16, width: 26, left: 0, right: 718))
    // At the right edge of the view (where "0:" used to be cut off) it waits until it fits whole.
    #expect(!TrackLayout.rulerLabelFits(tick: 700, width: 26, left: 0, right: 718))
    #expect(TrackLayout.rulerLabelFits(tick: 686, width: 26, left: 0, right: 718))
    #expect(!TrackLayout.rulerLabelFits(tick: 687, width: 26, left: 0, right: 718))
    // Scrolled along, one cut by the left edge isn't drawn either.
    #expect(!TrackLayout.rulerLabelFits(tick: 90, width: 26, left: 100, right: 818))
}

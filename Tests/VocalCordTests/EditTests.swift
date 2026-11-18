import Foundation
import Testing
@testable import VocalCord

private func version(_ id: String, _ duration: Double) -> Version {
    Version(id: id, text: "x", voiceID: "me", tone: "Neutral", direction: false, seed: 1, duration: duration, createdAt: .now)
}

private func clip(_ id: String, line: String, length: Double = 2, gap: Double = 0.5) -> EditClip {
    EditClip(id: id, lineID: line, versionID: line + "1", start: 0, end: length, gapAfter: gap)
}

// MARK: Edit

@Test func editFillsFromTheScript() {
    var project = Project(name: "P")
    project.lines = [
        Line(id: "a", text: "One.", voiceID: "me", pauseAfter: 0.5, versions: [version("a1", 1), version("a2", 1.5)], chosen: "a2"),
        Line(id: "b", text: "Not rendered.", voiceID: "me"),
        Line(id: "c", text: "Three.", voiceID: "me", pauseAfter: 12, versions: [version("c1", 2)], chosen: "c1"),
        Line(id: "d", text: "Four.", voiceID: "me", pauseAfter: 0, versions: [version("d1", 0.75)], chosen: "d1"),
    ]
    let edit = Edit(project: project)
    #expect(edit.clips.map(\.lineID) == ["a", "c", "d"] && edit.clips.map(\.versionID) == ["a2", "c1", "d1"])
    #expect(edit.clips.map(\.end) == [1.5, 2, 0.75] && edit.clips.map(\.gapAfter) == [0.5, 10, 0])
    #expect(edit.clips.allSatisfy { $0.isPlain(renderDuration: project.version($0.versionID)?.duration ?? 0) } && edit.kept.isEmpty)
    // The last gap is left off, and a time in a gap belongs to the clip before it.
    #expect(edit.starts == [0, 2, 14] && edit.duration == 14.75)
    #expect(edit.clip(at: 1.9)?.lineID == "a" && edit.clip(at: 2)?.lineID == "c" && edit.clip(at: 13)?.lineID == "c")
    #expect(edit.clip(at: 20)?.lineID == "d" && edit.clip(at: -1) == nil)
    #expect(edit.start(of: edit.clips[2].id) == 14 && edit.start(of: "gone") == nil)
    #expect(Edit(project: Project(name: "Empty")).duration == 0)
}

@Test func splitAccountsForTempoAndSharesTheSettings() throws {
    var edit = Edit(clips: [
        EditClip(id: "x", lineID: "a", versionID: "a1", start: 0.5, end: 4.5, gapAfter: 0.8, gain: -3, fadeIn: 0.3, fadeOut: 0.4,
                 effects: VoiceEffects(tempo: 2, pitch: 1)),
        clip("y", line: "b"),
    ])
    #expect(edit.clips[0].duration == 2)
    try edit.split(clip: "x", at: 0.5)   // half a second on the timeline is a second of the render at double speed
    #expect(edit.clips.count == 3 && edit.clips[2].id == "y")
    let first = edit.clips[0], second = edit.clips[1]
    #expect(first.id == "x" && second.id != "x")
    #expect(first.start == 0.5 && first.end == 1.5 && second.start == 1.5 && second.end == 4.5)
    #expect(first.duration == 0.5 && second.duration == 1.5)
    #expect(first.fadeIn == 0.3 && first.fadeOut == 0 && first.gapAfter == 0)
    #expect(second.fadeIn == 0 && second.fadeOut == 0.4 && second.gapAfter == 0.8)
    #expect([first, second].allSatisfy { $0.gain == -3 && $0.effects == VoiceEffects(tempo: 2, pitch: 1) && $0.versionID == "a1" })

    let before = edit
    for time in [0.01, 0.49, 0.5, -1, .nan] { #expect(throws: AppError.self) { try edit.split(clip: "x", at: time) } }
    #expect(throws: AppError.self) { try edit.split(clip: "gone", at: 0.2) }
    #expect(edit == before)
}

@Test func trimStaysInsideTheRender() throws {
    var edit = Edit(clips: [EditClip(id: "x", lineID: "a", versionID: "a1", start: 0, end: 3, gapAfter: 0.5, fadeIn: 2, fadeOut: 1)])
    try edit.trim(clip: "x", start: -1, end: 99, renderDuration: 3)
    #expect(edit.clips[0].start == 0 && edit.clips[0].end == 3)
    try edit.trim(clip: "x", start: 1, end: 2.5, renderDuration: 3)
    #expect(edit.clips[0].start == 1 && edit.clips[0].end == 2.5)
    #expect(edit.clips[0].fadeIn == 1 && edit.clips[0].fadeOut == 0.5)   // fades that overlapped are shortened together
    try edit.trim(clip: "x", start: 2, end: 2.05, renderDuration: 3)      // the shortest clip

    let before = edit
    #expect(throws: AppError.self) { try edit.trim(clip: "x", start: 2, end: 2.04, renderDuration: 3) }
    #expect(throws: AppError.self) { try edit.trim(clip: "x", start: 2, end: 1, renderDuration: 3) }
    #expect(throws: AppError.self) { try edit.trim(clip: "x", start: 3.5, end: 9, renderDuration: 3) }   // both clamp to the end
    #expect(throws: AppError.self) { try edit.trim(clip: "x", start: .nan, end: 1, renderDuration: 3) }
    #expect(throws: AppError.self) { try edit.trim(clip: "gone", start: 0, end: 1, renderDuration: 3) }
    #expect(edit == before)
}

@Test func gapVolumeFadesAndVoiceToolsAreClamped() throws {
    var edit = Edit(clips: [clip("x", line: "a", length: 3)])
    try edit.setGap(clip: "x", to: 12)
    #expect(edit.clips[0].gapAfter == 10)
    try edit.setGap(clip: "x", to: -1)
    #expect(edit.clips[0].gapAfter == 0)
    try edit.setGain(clip: "x", to: 30)
    #expect(edit.clips[0].gain == 12)
    try edit.setGain(clip: "x", to: -40)
    #expect(edit.clips[0].gain == -24)
    try edit.setFades(clip: "x", fadeIn: 20, fadeOut: -2)
    #expect(edit.clips[0].fadeIn == 3 && edit.clips[0].fadeOut == 0)   // no longer than the 3 s clip
    try edit.setEffects(clip: "x", to: VoiceEffects(tempo: 5, pitch: -20, warmth: 20, brightness: -13, denoise: true))
    #expect(edit.clips[0].effects == VoiceEffects(tempo: 2, pitch: -12, warmth: 12, brightness: -12, denoise: true))
    // Twice as fast: half as long, and so is the fade.
    #expect(edit.clips[0].duration == 1.5 && edit.clips[0].fadeIn == 1.5)
    #expect(!edit.clips[0].effects.isNeutral && VoiceEffects().isNeutral && !edit.clips[0].isPlain(renderDuration: 3))

    let before = edit
    #expect(throws: AppError.self) { try edit.setGap(clip: "x", to: .infinity) }
    #expect(throws: AppError.self) { try edit.setGain(clip: "x", to: .nan) }
    #expect(throws: AppError.self) { try edit.setFades(clip: "x", fadeIn: 0.5, fadeOut: .nan) }
    #expect(throws: AppError.self) { try edit.setEffects(clip: "x", to: VoiceEffects(pitch: .nan)) }
    #expect(throws: AppError.self) { try edit.setGap(clip: "gone", to: 1) }
    #expect(edit == before)
}

@Test func moveAndDeleteClips() throws {
    var edit = Edit(clips: ["a", "b", "c"].map { clip($0, line: $0) })
    try edit.move(clip: "a", to: 2)
    #expect(edit.clips.map(\.id) == ["b", "c", "a"])
    try edit.move(clip: "a", to: -3)
    #expect(edit.clips.map(\.id) == ["a", "b", "c"])
    try edit.move(clip: "c", to: 1)
    #expect(edit.clips.map(\.id) == ["a", "c", "b"])
    try edit.move(clip: "a", to: 99)
    #expect(edit.clips.map(\.id) == ["c", "b", "a"])
    try edit.delete(clip: "b")
    #expect(edit.clips.map(\.id) == ["c", "a"])
    #expect(throws: AppError.self) { try edit.delete(clip: "b") }
    #expect(throws: AppError.self) { try edit.move(clip: "b", to: 0) }
}

@Test func swapReplacesALinesClipsAndKeepStopsAsking() throws {
    var edit = Edit(clips: [
        clip("a", line: "a"),
        EditClip(id: "b", lineID: "b", versionID: "b1", start: 0, end: 4, gapAfter: 1.2, gain: 3, fadeIn: 0.2, fadeOut: 0.6,
                 effects: VoiceEffects(warmth: 2)),
        clip("c", line: "c"),
    ])
    try edit.split(clip: "b", at: 1)
    try edit.trim(clip: edit.clips[2].id, start: 1, end: 3, renderDuration: 4)
    try edit.move(clip: "c", to: 2)   // another line's clip between b's halves
    #expect(edit.clips.map(\.lineID) == ["a", "b", "c", "b"])
    try edit.keep(line: "b", version: "b2")
    #expect(edit.kept == ["b": "b2"])

    try edit.swapIn(line: "b", version: "b3", duration: 2.5)
    #expect(edit.clips.map(\.lineID) == ["a", "b", "c"] && edit.kept.isEmpty)
    let swapped = edit.clips[1]
    #expect(swapped.id == "b" && swapped.versionID == "b3" && swapped.start == 0 && swapped.end == 2.5)
    #expect(swapped.gain == 3 && swapped.effects == VoiceEffects(warmth: 2) && swapped.fadeIn == 0.2)
    #expect(swapped.fadeOut == 0.6 && swapped.gapAfter == 1.2)   // from the last clip, where the split put them

    let before = edit
    #expect(throws: AppError.self) { try edit.swapIn(line: "gone", version: "x", duration: 1) }
    #expect(throws: AppError.self) { try edit.swapIn(line: "b", version: "b4", duration: 0) }
    #expect(throws: AppError.self) { try edit.keep(line: "gone", version: "x") }
    #expect(edit == before)
}

@Test func insertGoesAfterTheNearestEarlierLine() throws {
    let script = ["a", "b", "c", "d", "e"]
    var edit = Edit(clips: [clip("c", line: "c"), clip("a1", line: "a"), clip("a2", line: "a"), clip("e", line: "e")])
    try edit.insert(line: "b", version: "b1", duration: 1.5, gapAfter: 0.3, script: script)
    #expect(edit.clips.map(\.lineID) == ["c", "a", "a", "b", "e"])   // after a's last clip, wherever a was moved
    try edit.insert(line: "d", version: "d1", duration: 1, gapAfter: 20, script: script)
    #expect(edit.clips.map(\.lineID) == ["c", "d", "a", "a", "b", "e"])
    let added = edit.clips[1]
    #expect(added.versionID == "d1" && added.start == 0 && added.end == 1 && added.gapAfter == 10)

    var first = Edit(clips: [clip("c", line: "c")])
    try first.insert(line: "a", version: "a1", duration: 1, gapAfter: 0.5, script: script)
    #expect(first.clips.map(\.lineID) == ["a", "c"])   // no earlier line on the timeline

    let before = edit
    #expect(throws: AppError.self) { try edit.insert(line: "a", version: "a9", duration: 1, gapAfter: 0.5, script: script) }
    #expect(throws: AppError.self) { try edit.insert(line: "z", version: "z1", duration: 1, gapAfter: 0.5, script: script) }
    #expect(edit == before)
}

// MARK: Store

@MainActor private func finishRender(_ projects: ProjectStore) async throws {
    while projects.progress != nil { try await Task.sleep(for: .milliseconds(20)) }
}

/// A project whose lines are rendered: 2 s each, with the default 0.5 s pause.
@MainActor private func editFixture(lines: [String] = ["One.", "Two.", "Three."]) async throws -> (ProjectStore, VoiceStore, String) {
    let voices = VoiceStore(root: try tempFolder(), engine: FakeEngine(delay: .zero))
    let voiceID = voices.createVoice(name: "Me", fullClone: false)
    let wav = try tempFolder().appending(path: "take.wav")
    try writeWAV(speechLike(seconds: 2, amplitude: 0.3, floor: 0)[...], rate: 24000, to: wav)
    try voices.addTake(voiceID, file: wav, tone: "Neutral", transcript: "Hello.", issues: [])
    let projects = ProjectStore(root: try tempFolder(), exportsRoot: try tempFolder())
    let id = projects.create(name: "Cut")
    projects.addLines(lines, to: id, voices: voices)
    projects.renderNeeded(id, voices: voices)
    try await finishRender(projects)
    return (projects, voices, id)
}

@MainActor @Test func timelineEditsSaveAndUndo() async throws {
    let (projects, _, id) = try await editFixture()
    #expect(projects.project(id)?.edit == nil && projects.linesNotOnTimeline(id).isEmpty && projects.newRenders(id).isEmpty)
    projects.startEdit(id)
    let filled = try #require(projects.project(id)?.edit)
    #expect(filled.clips.map(\.versionID) == Edit(project: try #require(projects.project(id))).clips.map(\.versionID))
    #expect(filled.duration == 7)
    #expect(!projects.canUndoEdit(id))   // opening the timeline isn't a step

    let ids = filled.clips.map(\.id)
    #expect(projects.splitClip(ids[0], at: 0.5, in: id))
    #expect(projects.trimClip(ids[1], start: 0.25, end: 1.75, in: id))
    #expect(projects.moveClip(ids[2], to: 0, in: id))
    #expect(projects.setClipGap(1, clip: ids[2], in: id))
    #expect(projects.setClipGain(-6, clip: ids[2], in: id))
    #expect(projects.setClipFades(fadeIn: 0.2, fadeOut: 0.3, clip: ids[2], in: id))
    #expect(projects.setClipEffects(VoiceEffects(pitch: 2), clip: ids[2], in: id))
    #expect(projects.deleteClip(ids[1], in: id))
    let cut = try #require(projects.project(id)?.edit)
    #expect(cut.clips.count == 3 && Array(cut.clips.map(\.id).prefix(2)) == [ids[2], ids[0]])
    #expect(cut.clips[0].gapAfter == 1 && cut.clips[0].gain == -6 && cut.clips[0].fadeOut == 0.3 && cut.clips[0].effects.pitch == 2)
    #expect(cut.clips[1].end == 0.5 && cut.clips[2].start == 0.5)
    // Saved with the project.
    #expect(ProjectStore(root: projects.root).project(id)?.edit == cut)

    // A refused edit says why and changes nothing; an edit that changes nothing isn't a step.
    #expect(!projects.splitClip(ids[2], at: 0.01, in: id) && projects.error == "Split at least 0.05 s from either end of the clip.")
    #expect(!projects.trimClip("gone", start: 0, end: 1, in: id) && projects.error == "That clip is no longer on the timeline.")
    #expect(projects.setClipGap(1, clip: ids[2], in: id))
    #expect(projects.project(id)?.edit == cut)

    var undos = 0
    while projects.canUndoEdit(id) {
        projects.undoEdit(id)
        undos += 1
    }
    #expect(undos == 8 && projects.project(id)?.edit == filled && projects.canRedoEdit(id))
    projects.redoEdit(id)
    #expect(projects.project(id)?.edit?.clips.count == 4 && projects.canRedoEdit(id))
    // A new edit after an undo drops the steps that were undone.
    #expect(projects.setClipGap(2, clip: ids[2], in: id))
    #expect(!projects.canRedoEdit(id))

    // Reset fills it from the script again, and is undone like any edit.
    let beforeReset = try #require(projects.project(id)?.edit)
    projects.resetEdit(id)
    #expect(projects.project(id)?.edit?.clips.map(\.versionID) == filled.clips.map(\.versionID))
    projects.undoEdit(id)
    #expect(projects.project(id)?.edit == beforeReset)

    // Only the last 100 steps are kept.
    for step in 0..<(ProjectStore.undoLimit + 5) { projects.setClipGap(Double(step % 2), clip: ids[2], in: id) }
    undos = 0
    while projects.canUndoEdit(id) {
        projects.undoEdit(id)
        undos += 1
    }
    #expect(undos == ProjectStore.undoLimit)
}

@MainActor @Test func newRendersAskBeforeReplacingCuts() async throws {
    let (projects, voices, id) = try await editFixture()
    projects.startEdit(id)
    let lines = try #require(projects.project(id)?.lines)
    let first = try #require(projects.project(id)?.edit?.clips[0])
    #expect(projects.splitClip(first.id, at: 1, in: id))

    projects.rerender(lines[0].id, in: id, voices: voices)
    try await finishRender(projects)
    var line = try #require(projects.project(id)?.lines[0])
    #expect(line.versions.count == 2 && line.chosen == line.versions[1].id)
    // The cuts stay until the user answers.
    #expect(projects.newRenders(id) == [line.id: line.versions[1].id])
    #expect(projects.project(id)?.edit?.clips.filter { $0.lineID == line.id }.map(\.versionID) == [first.versionID, first.versionID])
    #expect(projects.keepEditedClip(line: line.id, in: id))
    #expect(projects.newRenders(id).isEmpty)

    // An even newer render asks again; swapping it in replaces both halves.
    projects.rerender(line.id, in: id, voices: voices)
    try await finishRender(projects)
    line = try #require(projects.project(id)?.lines[0])
    #expect(projects.newRenders(id) == [line.id: line.versions[2].id])
    #expect(projects.swapInNewRender(line: line.id, in: id))
    let swapped = try #require(projects.project(id)?.edit?.clips.filter { $0.lineID == line.id })
    #expect(swapped.count == 1 && swapped[0].versionID == line.versions[2].id && swapped[0].end == line.versions[2].duration)
    #expect(projects.newRenders(id).isEmpty && projects.project(id)?.edit?.kept.isEmpty == true)
    // Choosing an older take in Generate offers it too.
    projects.choose(line.versions[0].id, line: line.id, in: id)
    #expect(projects.newRenders(id) == [line.id: line.versions[0].id])
    projects.choose(line.versions[2].id, line: line.id, in: id)

    // A line rendered after the timeline was made waits to be added after the nearest earlier line's clips.
    projects.addLines(["Four."], to: id, voices: voices)
    let four = try #require(projects.project(id)?.lines.last)
    projects.moveLine(four.id, by: -1, in: id)   // the script reads 1, 2, 4, 3
    #expect(projects.linesNotOnTimeline(id).isEmpty)   // no render yet
    projects.renderNeeded(id, voices: voices)
    try await finishRender(projects)
    #expect(projects.linesNotOnTimeline(id) == [four.id] && projects.newRenders(id).isEmpty)
    #expect(projects.addLineToEdit(line: four.id, in: id))
    #expect(projects.project(id)?.edit?.clips.map(\.lineID) == [lines[0].id, lines[1].id, four.id, lines[2].id])
    #expect(projects.linesNotOnTimeline(id).isEmpty)
    #expect(!projects.addLineToEdit(line: four.id, in: id) && projects.error == "This line is already on the timeline.")

    // Deleting a line's only clip lists it again; deleting the line from the script takes its clips with it.
    let two = try #require(projects.project(id)?.edit?.clips.first { $0.lineID == lines[1].id })
    projects.deleteClip(two.id, in: id)
    #expect(projects.linesNotOnTimeline(id) == [lines[1].id])
    projects.deleteLine(four.id, in: id)
    #expect(projects.project(id)?.edit?.clips.map(\.lineID) == [lines[0].id, lines[2].id])
    // An undo step from before the line was deleted brings back only the clips whose line is still there.
    projects.undoEdit(id)
    #expect(projects.project(id)?.edit?.clips.map(\.lineID) == [lines[0].id, lines[1].id, lines[2].id])
}

@MainActor @Test func timelineProposalsWaitForTheUser() async throws {
    let (projects, _, id) = try await editFixture()
    projects.startEdit(id)
    let current = try #require(projects.project(id)?.edit)
    #expect(!projects.proposeEdit(EditProposal(edit: current, changes: ["Nothing."]), in: id))
    #expect(projects.project(id)?.editProposal == nil)

    var proposed = current
    try proposed.delete(clip: current.clips[1].id)
    try proposed.setGap(clip: current.clips[0].id, to: 1.5)
    let proposal = EditProposal(edit: proposed, changes: ["Cut line 2.", "A longer pause after line 1."])
    #expect(projects.proposeEdit(proposal, in: id))
    // Proposed only, and saved.
    #expect(projects.project(id)?.edit == current && projects.project(id)?.editProposal == proposal)
    #expect(ProjectStore(root: projects.root).project(id)?.editProposal == proposal)
    projects.rejectEditProposal(id)
    #expect(projects.project(id)?.editProposal == nil && projects.project(id)?.edit == current && !projects.canUndoEdit(id))

    // A later proposal replaces an earlier one; accepting it is a step to undo.
    var louder = current
    try louder.setGain(clip: current.clips[2].id, to: 3)
    projects.proposeEdit(EditProposal(edit: louder, changes: ["Louder line 3."]), in: id)
    projects.proposeEdit(proposal, in: id)
    #expect(projects.project(id)?.editProposal == proposal)
    projects.acceptEditProposal(id)
    #expect(projects.project(id)?.edit == proposed && projects.project(id)?.editProposal == nil)
    projects.undoEdit(id)
    #expect(projects.project(id)?.edit == current)
    projects.redoEdit(id)
    #expect(projects.project(id)?.edit == proposed)
}

@MainActor @Test func clipAudioUsesTheRenderOrACachedEdit() async throws {
    let (projects, voices, id) = try await editFixture(lines: ["One."])
    projects.startEdit(id)
    let project = try #require(projects.project(id))
    let render = projects.audioURL(try #require(project.lines[0].chosenVersion), projectID: id)
    var clip = try #require(project.edit?.clips[0])
    #expect(try await projects.clipAudio(clip, in: id, engine: voices.engine) == render)

    clip.gain = 6
    let gained = try await projects.clipAudio(clip, in: id, engine: voices.engine)
    #expect(gained == projects.folder(id).appending(path: "edits/\(clip.cacheKey).wav"))
    let original = try await loadSamples(render), louder = try await loadSamples(gained)
    let peak = { (samples: [Float]) in samples.map(abs).max() ?? 0 }
    #expect(louder.count == original.count && abs(peak(louder) / peak(original) - 2) < 0.02)   // +6 dB doubles it
    // The same settings reuse the file.
    try Data("cached".utf8).write(to: gained)
    #expect(try await projects.clipAudio(clip, in: id, engine: voices.engine) == gained)
    #expect(try Data(contentsOf: gained) == Data("cached".utf8))

    // Trimmed, twice as fast and faded: another file, as long as the clip is on the timeline.
    clip.start = 0.5
    clip.effects.tempo = 2
    clip.fadeIn = 0.1
    clip.fadeOut = 0.1
    let faster = try await projects.clipAudio(clip, in: id, engine: voices.engine)
    #expect(faster != gained && abs(audioDuration(faster) - clip.duration) < 0.01 && clip.duration == 0.75)
    let samples = try await loadSamples(faster)
    #expect(samples.first == 0 && abs(samples.last ?? 1) < 0.01)
    #expect(try FileManager.default.contentsOfDirectory(atPath: projects.folder(id).appending(path: "edits").path).count == 2)
}

@MainActor @Test func playbackFollowsTheTimeline() async throws {
    let (projects, voices, id) = try await editFixture()
    projects.startEdit(id)
    let ids = try #require(projects.project(id)?.edit?.clips.map(\.id))
    projects.setClipEffects(VoiceEffects(tempo: 2), clip: ids[1], in: id)
    projects.moveClip(ids[2], to: 0, in: id)
    let edit = try #require(projects.project(id)?.edit)
    let timeline = try await projects.playbackTimeline(id, engine: voices.engine)
    #expect(timeline.projectID == id && timeline.segments.map(\.clipID) == edit.clips.map(\.id))
    #expect(timeline.segments.map(\.lineID) == edit.clips.map(\.lineID))
    #expect(timeline.segments.map(\.start) == [0, 2.5, 5] && timeline.segments.map(\.duration) == [2, 2, 1])
    #expect(timeline.duration == 6 && edit.duration == 6)
    #expect(timeline.segments[0].audio == projects.audioURL(try #require(projects.project(id)?.lines[2].chosenVersion), projectID: id))
    #expect(timeline.segments[2].audio?.deletingLastPathComponent().lastPathComponent == "edits")
}

@MainActor @Test func exportUsesTheTimeline() async throws {
    let (projects, voices, id) = try await editFixture()
    let script = try await projects.exportLines(id, voices: voices)
    #expect(script.map(\.number) == [1, 2, 3] && script.map(\.pauseAfter) == [0.5, 0.5, 0.5])

    projects.startEdit(id)
    let lines = try #require(projects.project(id)?.lines)
    let ids = try #require(projects.project(id)?.edit?.clips.map(\.id))
    projects.splitClip(ids[0], at: 1, in: id)
    projects.deleteClip(ids[1], in: id)
    projects.setClipGap(2, clip: ids[2], in: id)
    projects.moveLine(lines[2].id, by: -1, in: id)   // numbers follow the script as it is now
    let mix = try await projects.exportLines(id, voices: voices)
    #expect(mix.map(\.number) == [1, 1, 2] && mix.map(\.pauseAfter) == [0, 0.5, 2])
    #expect(mix.map(\.text) == ["One.", "One.", "Three."] && mix.allSatisfy { $0.voice == "Me" })
    #expect(mix.map { audioDuration($0.audio) } == [1, 1, 2])
    let result = try await projects.export(id, options: ExportOptions(), voices: voices)
    #expect(result.duration == 6.5)   // the fake mix counts the last pause too
    #expect(projects.project(id)?.exports?.count == 1)

    for clip in projects.project(id)?.edit?.clips ?? [] { projects.deleteClip(clip.id, in: id) }
    await #expect(throws: AppError.self) { try await projects.export(id, options: ExportOptions(), voices: voices) }
}

@MainActor @Test func rendersTheTimelineUsesCantBeDeleted() async throws {
    let (projects, voices, id) = try await editFixture(lines: ["One."])
    projects.startEdit(id)
    let lineID = try #require(projects.project(id)?.lines[0].id)
    projects.rerender(lineID, in: id, voices: voices)
    try await finishRender(projects)
    let versions = try #require(projects.project(id)?.lines[0].versions)
    func usedBy() -> [String: Int?] { Dictionary(uniqueKeysWithValues: projects.outputs(id).map { ($0.id, $0.usedBy) }) }

    // The timeline still plays the first render, so it stays, and Outputs shows it in use.
    #expect(usedBy() == [versions[0].id: 1, versions[1].id: 1])
    projects.deleteOutput(versions[0].id, in: id)
    #expect(projects.project(id)?.lines[0].versions.count == 2)

    // Swapped out, but a pending proposal would bring it back: it stays until that is settled.
    #expect(projects.swapInNewRender(line: lineID, in: id))
    var back = try #require(projects.project(id)?.edit)
    try back.swapIn(line: lineID, version: versions[0].id, duration: versions[0].duration)
    #expect(projects.proposeEdit(EditProposal(edit: back, changes: ["Back to the first take."]), in: id))
    projects.deleteOutput(versions[0].id, in: id)
    #expect(projects.project(id)?.lines[0].versions.count == 2 && usedBy()[versions[0].id] == 1)
    projects.rejectEditProposal(id)
    #expect(usedBy() == [versions[0].id: nil, versions[1].id: 1])
}

@MainActor @Test func projectsSavedBeforeTheTimelineStillOpen() throws {
    let root = try tempFolder()
    let file = root.appending(path: "old/project.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"""
        {"createdAt": 700000000, "id": "old", "name": "Old film", "lines": [
          {"id": "l1", "text": "Hello.", "voiceID": "me", "tone": "Neutral", "pauseAfter": 0.5, "chosen": "v1",
           "versions": [{"id": "v1", "text": "Hello.", "voiceID": "me", "tone": "Neutral", "direction": false, "seed": 7,
                         "duration": 1.5, "createdAt": 700000000}]}]}
        """#.utf8).write(to: file)
    let projects = ProjectStore(root: root)
    let project = try #require(projects.project("old"))
    #expect(projects.error == nil && project.edit == nil && project.editProposal == nil)
    projects.startEdit("old")
    #expect(projects.project("old")?.edit?.clips.map(\.versionID) == ["v1"])
    #expect(ProjectStore(root: root).project("old")?.edit == projects.project("old")?.edit)
}

// MARK: Engine

/// A worker that answers `edit_clip` only when it carries exactly the contract's fields.
private let clipWorker = #"""
import json, sys

fields = {"id", "cmd", "audio", "out", "start", "end", "tempo", "pitch", "warmth", "brightness", "denoise", "gain_db",
          "fade_in", "fade_out"}
for raw in sys.stdin:
    m = json.loads(raw)
    if m["cmd"] != "edit_clip" or set(m) != fields or not isinstance(m["denoise"], bool):
        reply = {"id": m["id"], "event": "error", "code": "invalid", "message": "Fields: " + ", ".join(sorted(set(m) ^ fields))}
    else:
        reply = {"id": m["id"], "event": "result", "path": m["out"], "duration": (m["end"] - m["start"]) / m["tempo"]}
    print(json.dumps(reply), flush=True)
"""#

@Test func engineClientSendsEditClip() async throws {
    let folder = try tempFolder()
    let bin = folder.appending(path: ".venv/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appending(path: "vocalcord_engine"), withIntermediateDirectories: true)
    try clipWorker.write(to: folder.appending(path: "vocalcord_engine/__main__.py"), atomically: true, encoding: .utf8)
    let python = bin.appending(path: "python")
    try "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

    let client = EngineClient(location: .dev(folder))
    let request = ClipRequest(audio: URL(filePath: "/r/a.wav"), start: 0.5, end: 3.5, gain: -3, fadeIn: 0.1, fadeOut: 0.2,
                              effects: VoiceEffects(tempo: 1.5, denoise: true))
    #expect(try await client.editClip(request, to: URL(filePath: "/e/x.wav")) == 2)
}

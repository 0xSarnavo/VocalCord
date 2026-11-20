import Foundation
import NaturalLanguage

/// One render of a line. Its audio is `Projects/<project>/renders/<id>.wav`.
///
/// A line whose text has marks (pauses, speeds, stress) is rendered without them as a `raw` version, a hidden source,
/// and `apply_marks` makes the version the user hears from it, with `source` naming the raw one. Changing only the
/// marks makes a new version from the same source, without rendering.
struct Version: Codable, Identifiable, Hashable, Sendable {
    var id: String
    /// The line's text, voice and tone when this version was rendered.
    var text: String
    var voiceID: String
    var tone: String
    /// The voice had no take in `tone`, so its Neutral take read the tone's written direction.
    var direction: Bool
    var seed: Int
    var duration: Double
    var createdAt: Date
    var scores: Scores?
    /// The reference take's own Human score.
    var referenceHuman: Double?
    // Optional so versions saved before they existed still decode.
    /// When each `Marks.parse(text).spokenTokens` entry is spoken in this version's own file. Nil until timed.
    var words: [WordTime]? = nil
    /// 0–1: the share of words whose times Whisper heard; low means most were estimated.
    var matched: Double? = nil
    /// Model output whose text has marks that aren't applied in this file: a hidden source, never chosen or played.
    var raw: Bool? = nil
    /// Made by `apply_marks` from this version (a raw render, or a render whose text had no marks).
    var source: String? = nil

    /// Marks can be applied to it to make a version: model output with the marks left out of its audio (raw), or
    /// whose text has none, and with words to time. Versions rendered with [pause] tags before marks existed had the
    /// engine split the line at each pause, so they can't.
    var isMarkSource: Bool {
        guard source == nil else { return false }
        let parsed = Marks.parse(text)
        return (raw == true || parsed.marks.isEmpty) && (words != nil || !parsed.spokenTokens.isEmpty)
    }

    static let likeYouFloor = 70, wordsFloor = 90, humanDrop = 0.5
    /// Speaker similarity is unreliable on shorter audio: lines of about 1.4 s scored 31–57%.
    static let likeYouMinSeconds = 3.0

    var likeYouJudged: Bool { duration >= Self.likeYouMinSeconds }

    var likeYouFlag: String? {
        guard let scores, likeYouJudged, scores.likeYou < Self.likeYouFloor else { return nil }
        return "Like you under \(Self.likeYouFloor)%"
    }

    var wordsFlag: String? {
        guard let scores, scores.words < Self.wordsFloor else { return nil }
        return "Words under \(Self.wordsFloor)%. Heard: \u{201C}\(scores.heard)\u{201D}"
    }

    var humanFlag: String? {
        guard let scores, let referenceHuman, scores.human < referenceHuman - Self.humanDrop else { return nil }
        return "Human " + String(format: "%.1f below the take's %.1f", referenceHuman - scores.human, referenceHuman)
    }

    /// A direction once raised a voice by 6 semitones; this many is still the same voice. Good renders' pace was 6-17% off
    /// their take's, and short lines run faster than a take naturally (fewer pauses), so pace is judged from 6 s.
    static let pitchDrift = 1.5, paceDrift = 0.35, paceMinSeconds = 6.0, longestGap = 1.2
    /// Slow and Hesitant are meant to differ from the take in pace and pauses.
    private var paceChecked: Bool { !["Slow", "Hesitant"].contains(tone) }

    var pitchFlag: String? {
        guard let scores, let pitch = scores.pitchHz, let reference = scores.referencePitchHz, pitch > 0, reference > 0 else { return nil }
        let semitones = 12 * log2(pitch / reference)
        guard abs(semitones) > Self.pitchDrift else { return nil }
        return String(format: "Pitch %.1f semitones %@ the take", abs(semitones), semitones > 0 ? "above" : "below")
    }

    var paceFlag: String? {
        guard paceChecked, duration >= Self.paceMinSeconds, let scores, let pace = scores.pace, let reference = scores.referencePace,
              reference > 0 else { return nil }
        let change = pace / reference - 1
        guard abs(change) > Self.paceDrift else { return nil }
        return "Pace \(Int((abs(change) * 100).rounded()))% \(change > 0 ? "faster" : "slower") than the take"
    }

    var gapFlag: String? {
        guard paceChecked, let gap = scores?.longestPause, gap > Self.longestGap else { return nil }
        return String(format: "A %.1f s gap mid-line", gap)
    }

    var flags: [String] { [likeYouFlag, humanFlag, wordsFlag, pitchFlag, paceFlag, gapFlag].compactMap(\.self) }

    /// Scored with nothing flagged.
    var passes: Bool { scores != nil && flags.isEmpty }

    /// Passing versions first, then the most like the voice and the most natural.
    var rank: Double {
        guard let scores else { return -1 }
        return (passes ? 1000 : 0) + Double(scores.likeYou) + 15 * scores.human
    }
}

struct Line: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var text: String
    var voiceID: String
    var tone = "Neutral"
    var pauseAfter = 0.5
    var versions: [Version] = []
    var chosen: String?
    /// A change a terminal agent proposed, waiting for the user to accept or reject it.
    var proposal: Proposal?
    /// The text before the first accepted agent rewrite, for Jev's meaning check. Cleared when the user edits the text.
    var original: String?
    /// An agent added this line: it stays empty until the user accepts its proposal, and rejecting removes it.
    var added: Bool?

    var chosenVersion: Version? { versions.first { $0.id == chosen } }

    /// The tone the voice reads it in: its own, or Neutral while tones are hidden, so a tone set before (or by an agent)
    /// can't pick a take the user can't see.
    var renderTone: String { Tone.enabled ? tone : "Neutral" }

    /// The versions to list and play: raw sources are left out.
    var visibleVersions: [Version] { versions.filter { $0.raw != true } }

    /// The version can play for the current text, voice and tone: it reads them and isn't a raw source.
    func reads(_ version: Version) -> Bool {
        version.raw != true && version.text == text && version.voiceID == voiceID && version.tone == renderTone
    }

    /// No version plays the current text in the current voice and tone yet.
    var needsRender: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !versions.contains(where: reads)
    }

    /// Needs the voice model, not only marks applied to a version it has: the voice would read the text differently
    /// (its words, a respelling, a stress or a direction changed), or there's no render to apply marks to. A line that
    /// `needsRender` without this is fixed at once with "Apply".
    var needsVoice: Bool { needsRender && markSource == nil }

    /// The best version (by `rank`) that marks can be applied to for the current text: same voice and tone, and read
    /// the same way by the voice (`ParsedLine.renderKey`), so only the marks differ.
    var markSource: Version? {
        let key = Marks.parse(text).renderKey
        return versions.filter { $0.voiceID == voiceID && $0.tone == renderTone && $0.isMarkSource && Marks.parse($0.text).renderKey == key }
            .max { $0.rank < $1.rank }
    }
}

/// A line's text, tone and pause as an agent proposes them.
struct Proposal: Codable, Hashable, Sendable {
    var text: String
    var tone: String
    var pauseAfter: Double
}

extension Proposal {
    init(_ line: Line) { self.init(text: line.text, tone: line.tone, pauseAfter: line.pauseAfter) }
}

/// A video to watch the voiceover over. Only its path is kept; the file stays where it is.
struct Video: Codable, Hashable, Sendable {
    /// The video in Preview is hidden for now: the launch work is audio only. True brings back Choose video, the video
    /// frame and its offset.
    static let enabled = false

    var path: String
    /// Seconds the video starts after the voiceover; negative starts it earlier.
    var offset = 0.0
}

/// One export's files in `~/Movies/VocalCord/<project>/`, the mix first.
struct Export: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var files: [String]
    var duration: Double
    var createdAt = Date.now
}

struct Project: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var createdAt = Date.now
    var lines: [Line] = []
    // Optional so projects saved before they existed still decode.
    var video: Video?
    var exports: [Export]?
    /// The Timeline tab's cut of the audio, made the first time it opens; export uses it from then on.
    var edit: Edit?
    var editProposal: EditProposal?
    /// Words a minute the pace check aims for; nil uses each version's take.
    var paceTarget: Double?

    static let paceTargets = 80.0...260.0

    func line(_ id: String) -> Line? { lines.first { $0.id == id } }
    func version(_ id: String) -> Version? { lines.lazy.flatMap(\.versions).first { $0.id == id } }

    /// Renders a timeline clip uses, now or in a pending proposal; they can't be deleted.
    var editedRenders: Set<String> { Set(((edit?.clips ?? []) + (editProposal?.edit.clips ?? [])).map(\.versionID)) }
}

/// A render or export in the Outputs list.
struct Output: Identifiable, Hashable {
    var id: String
    var name: String
    var url: URL
    var duration: Double
    var date: Date
    /// The number of the line whose chosen take this is, or whose render the timeline uses; such a render can't be deleted.
    var usedBy: Int?
    var format: String { url.pathExtension.uppercased() }
}

struct ExportOptions: Sendable {
    var format = "wav"
    var lufs = -16
    var perLine = false, perVoice = false, srt = false, timing = false
}

/// Each project is `Projects/<id>/project.json`, with its renders in `Projects/<id>/renders/`.
/// A project file that can't be read is left out of the list and never written.
@MainActor @Observable
final class ProjectStore {
    static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "VocalCord/Projects", directoryHint: .isDirectory)

    private(set) var projects: [Project] = []
    var error: String?
    /// Set while a render runs: 0–1.
    private(set) var progress: Double?
    /// The lines being rendered now: a whole take's lines at once while it renders, then each line as it's scored.
    private(set) var rendering: Set<String> = []
    static let defaultExports = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appending(path: "VocalCord", directoryHint: .isDirectory)

    let root: URL
    let exportsRoot: URL
    /// Each project's timeline before each undoable step, newest last, and the steps undone. In memory only.
    private var undoSteps: [String: [Edit]] = [:]
    private var redoSteps: [String: [Edit]] = [:]
    static let undoLimit = 100
    @ObservationIgnored private var task: Task<Void, Error>?
    private let files = FileManager.default

    init(root: URL = ProjectStore.defaultRoot, exportsRoot: URL = ProjectStore.defaultExports) {
        self.root = root
        self.exportsRoot = exportsRoot
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            var unreadable: [String] = []
            for folder in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where folder.hasDirectoryPath {
                let file = folder.appending(path: "project.json")
                guard files.fileExists(atPath: file.path) else { continue }
                do {
                    var project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: file))
                    project.id = folder.lastPathComponent
                    projects.append(project)
                } catch {
                    unreadable.append(file.path)
                }
            }
            projects.sort { $0.createdAt < $1.createdAt }
            if !unreadable.isEmpty {
                error = "Couldn't read \(unreadable.count == 1 ? "a project" : "\(unreadable.count) projects"). "
                    + "Left as is: \(unreadable.joined(separator: ", "))"
            }
        } catch {
            self.error = "Couldn't read your projects. \(error.localizedDescription)"
        }
    }

    // MARK: Files

    func folder(_ projectID: String) -> URL { root.appending(path: projectID, directoryHint: .isDirectory) }
    func audioURL(_ version: Version, projectID: String) -> URL {
        folder(projectID).appending(path: "renders/\(version.id).wav")
    }

    private func save(_ project: Project) {
        do {
            try files.createDirectory(at: folder(project.id), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: folder(project.id).appending(path: "project.json"), options: .atomic)
        } catch {
            self.error = "Couldn't save \u{201C}\(project.name)\u{201D}. \(error.localizedDescription)"
        }
    }

    // MARK: Projects

    func project(_ id: String?) -> Project? { projects.first { $0.id == id } }

    private func update(_ id: String, _ change: (inout Project) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        change(&projects[index])
        save(projects[index])
    }

    func create(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(name: trimmed.isEmpty ? "Untitled project" : trimmed)
        projects.append(project)
        save(project)
        return project.id
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    /// Moves the project folder, renders included, to the Trash.
    func delete(_ id: String) {
        if files.fileExists(atPath: folder(id).path) {
            do { try files.trashItem(at: folder(id), resultingItemURL: nil) } catch {
                self.error = "Couldn't move this project to the Trash. \(error.localizedDescription)"
                return
            }
        }
        projects.removeAll { $0.id == id }
        undoSteps[id] = nil
        redoSteps[id] = nil
    }

    // MARK: Lines

    private func updateLine(_ projectID: String, _ lineID: String, _ change: (inout Line) -> Void) {
        update(projectID) { project in
            if let index = project.lines.firstIndex(where: { $0.id == lineID }) { change(&project.lines[index]) }
        }
    }

    /// New lines take the last line's voice, else the first voice.
    func defaultVoice(_ projectID: String, voices: VoiceStore) -> String {
        if let last = project(projectID)?.lines.last, voices.voice(last.voiceID) != nil { return last.voiceID }
        return voices.voices.first?.id ?? ""
    }

    func addLines(_ texts: [String], to projectID: String, voices: VoiceStore) {
        let voiceID = defaultVoice(projectID, voices: voices)
        update(projectID) { $0.lines += texts.map { Line(text: $0, voiceID: voiceID) } }
    }

    func setText(_ text: String, line: String, in projectID: String) {
        updateLine(projectID, line) { line in
            guard line.text != text else { return }
            line.text = text
            line.original = nil
        }
    }
    func setVoice(_ voiceID: String, line: String, in projectID: String) { updateLine(projectID, line) { $0.voiceID = voiceID } }
    func setTone(_ tone: String, line: String, in projectID: String) { updateLine(projectID, line) { $0.tone = tone } }
    func setPause(_ seconds: Double, line: String, in projectID: String) {
        updateLine(projectID, line) { $0.pauseAfter = min(10, max(0, seconds)) }
    }
    /// A raw source is never chosen.
    func choose(_ versionID: String, line: String, in projectID: String) {
        updateLine(projectID, line) { line in
            guard line.versions.contains(where: { $0.id == versionID && $0.raw != true }) else { return }
            line.chosen = versionID
        }
    }

    func moveLine(_ lineID: String, by offset: Int, in projectID: String) {
        update(projectID) { project in
            guard let index = project.lines.firstIndex(where: { $0.id == lineID }),
                  project.lines.indices.contains(index + offset) else { return }
            project.lines.swapAt(index, index + offset)
        }
    }

    /// The line leaves the script and its clips the timeline; its renders stay on disk.
    func deleteLine(_ lineID: String, in projectID: String) {
        update(projectID) { project in
            project.lines.removeAll { $0.id == lineID }
            project.edit?.clips.removeAll { $0.lineID == lineID }
            project.edit?.kept[lineID] = nil
        }
    }

    func setVideo(_ video: Video?, in projectID: String) { update(projectID) { $0.video = video } }

    // MARK: Proposals

    /// Sets a line's pending change; one that matches the line as it is clears it. Returns whether a change is pending.
    @discardableResult
    func propose(_ proposal: Proposal, line lineID: String, in projectID: String) -> Bool {
        var pending = false
        updateLine(projectID, lineID) { line in
            pending = proposal != Proposal(line)
            line.proposal = pending ? proposal : nil
        }
        return pending
    }

    /// Inserts lines an agent proposed at `index`, each with its own voice. They wait like any other change.
    func proposeLines(_ lines: [(proposal: Proposal, voiceID: String)], at index: Int, in projectID: String) {
        update(projectID) { project in
            let new = lines.map { Line(text: "", voiceID: $0.voiceID, tone: $0.proposal.tone, pauseAfter: $0.proposal.pauseAfter,
                                       proposal: $0.proposal, added: true) }
            project.lines.insert(contentsOf: new, at: min(max(index, 0), project.lines.count))
        }
    }

    /// Applies the lines' pending changes. A version already rendered for a line's new text and tone becomes its chosen one;
    /// otherwise the line needs a render.
    func accept(_ lineIDs: [String], in projectID: String) {
        update(projectID) { project in
            for index in project.lines.indices where lineIDs.contains(project.lines[index].id) {
                guard let proposal = project.lines[index].proposal else { continue }
                var line = project.lines[index]
                if proposal.text != line.text { line.original = line.original ?? line.text }
                line.text = proposal.text
                line.tone = proposal.tone
                line.pauseAfter = proposal.pauseAfter
                line.proposal = nil
                line.added = nil
                if let match = line.versions.last(where: line.reads) {
                    line.chosen = match.id
                }
                project.lines[index] = line
            }
        }
    }

    /// Clears the lines' pending changes; a line an agent added leaves the script.
    func reject(_ lineIDs: [String], in projectID: String) {
        update(projectID) { project in
            project.lines.removeAll { lineIDs.contains($0.id) && $0.added == true }
            for index in project.lines.indices where lineIDs.contains(project.lines[index].id) { project.lines[index].proposal = nil }
        }
    }

    // MARK: Outputs

    /// Every render and export, newest first. Raw sources are left out. A render is in use while it's its line's
    /// chosen take, the timeline uses it, or another version was made from it by applying marks.
    func outputs(_ projectID: String) -> [Output] {
        guard let project = project(projectID) else { return [] }
        let used = project.editedRenders.union(project.lines.flatMap(\.versions).compactMap(\.source))
        let renders = project.lines.enumerated().flatMap { number, line in
            line.visibleVersions.enumerated().map { index, version in
                Output(id: version.id, name: "Line \(number + 1) · v\(index + 1)", url: audioURL(version, projectID: projectID),
                       duration: version.duration, date: version.createdAt,
                       usedBy: line.chosen == version.id || used.contains(version.id) ? number + 1 : nil)
            }
        }
        let exports = (project.exports ?? []).map { export in
            let url = URL(filePath: export.files[0])
            return Output(id: export.id, name: url.deletingPathExtension().lastPathComponent, url: url,
                          duration: export.duration, date: export.createdAt)
        }
        return (renders + exports).sorted { $0.date > $1.date }
    }

    /// Moves an export's files, or a render and its timing file, to the Trash. A line's chosen take stays, and so does
    /// a render the timeline or a pending timeline proposal uses, or that another version was made from. Deleting a
    /// version made from a raw render leaves the raw one.
    func deleteOutput(_ id: String, in projectID: String) {
        guard let project = project(projectID) else { return }
        let urls: [URL]
        if let export = project.exports?.first(where: { $0.id == id }) {
            urls = export.files.map { URL(filePath: $0) }
        } else if let line = project.lines.first(where: { line in line.versions.contains { $0.id == id } }), line.chosen != id,
                  !project.editedRenders.contains(id), !project.lines.contains(where: { $0.versions.contains { $0.source == id } }),
                  let version = line.versions.first(where: { $0.id == id }) {
            let audio = audioURL(version, projectID: projectID)
            urls = [audio, audio.deletingPathExtension().appendingPathExtension("json")]
        } else { return }
        do {
            for url in urls where files.fileExists(atPath: url.path) { try files.trashItem(at: url, resultingItemURL: nil) }
        } catch {
            self.error = "Couldn't move this to the Trash. \(error.localizedDescription)"
            return
        }
        update(projectID) { project in
            project.exports?.removeAll { $0.id == id }
            for index in project.lines.indices { project.lines[index].versions.removeAll { $0.id == id } }
        }
    }

    /// Mixes the timeline, or each line's chosen take if the project has none, into `exportsRoot/<project name>/` and
    /// lists the export in Outputs. Returns the files, the mix first.
    func export(_ projectID: String, options: ExportOptions, voices: VoiceStore) async throws -> MixResult {
        guard let project = project(projectID) else { throw AppError("This project no longer exists.") }
        let lines = try await exportLines(projectID, voices: voices)
        guard !lines.isEmpty else { throw AppError(project.edit == nil ? "Render a line first." : "The timeline is empty.") }
        let name = project.name.replacing(/[\/:]/, with: "-")
        let folder = exportsRoot.appending(path: name, directoryHint: .isDirectory)
        let result = try await voices.engine.mix(MixRequest(lines: lines, folder: folder, name: name, options: options))
        update(projectID) { $0.exports = ($0.exports ?? []) + [Export(files: result.files.map(\.path), duration: result.duration)] }
        return result
    }

    /// What `export` mixes. From the timeline: one entry per clip, numbered by its line's place in the script, so the
    /// engine joins a split line's clips into one caption. Without one: each line's chosen take, lines without one left out.
    func exportLines(_ projectID: String, voices: VoiceStore) async throws -> [MixLine] {
        guard let project = project(projectID) else { throw AppError("This project no longer exists.") }
        guard let edit = project.edit else {
            return project.lines.enumerated().compactMap { number, line in
                line.chosenVersion.map { version in
                    MixLine(audio: audioURL(version, projectID: projectID), text: Marks.plain(version.text),
                            voice: voices.voice(version.voiceID)?.name ?? "Voice", pauseAfter: line.pauseAfter, number: number + 1)
                }
            }
        }
        var lines: [MixLine] = []
        for clip in edit.clips {
            guard let number = project.lines.firstIndex(where: { $0.id == clip.lineID }), let version = project.version(clip.versionID) else { continue }
            lines.append(MixLine(audio: try await clipAudio(clip, in: projectID, engine: voices.engine), text: Marks.plain(version.text),
                                 voice: voices.voice(version.voiceID)?.name ?? "Voice", pauseAfter: clip.gapAfter, number: number + 1))
        }
        return lines
    }

    // MARK: Timeline

    /// Opens the project's timeline, filled from the script the first time.
    func startEdit(_ projectID: String) {
        guard let project = project(projectID), project.edit == nil else { return }
        update(projectID) { $0.edit = Edit(project: project) }
    }

    /// Fills the timeline from the script again, dropping every cut; undo brings them back.
    func resetEdit(_ projectID: String) {
        guard let project = project(projectID) else { return }
        commit(Edit(project: project), in: projectID)
    }

    // Each returns false, with the reason in `error`, when the edit can't be made. A slider should call these once
    // when it's released, since every call is a step to undo.
    @discardableResult
    func splitClip(_ clipID: String, at time: Double, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, _ in try edit.split(clip: clipID, at: time) }
    }

    /// `start` and `end` are seconds into the clip's render.
    @discardableResult
    func trimClip(_ clipID: String, start: Double, end: Double, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, project in
            guard let render = project.version(edit.clips[try edit.index(of: clipID)].versionID) else {
                throw AppError("This clip's render no longer exists.")
            }
            try edit.trim(clip: clipID, start: start, end: end, renderDuration: render.duration)
        }
    }

    @discardableResult
    func deleteClip(_ clipID: String, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, _ in try edit.delete(clip: clipID) }
    }

    @discardableResult
    func moveClip(_ clipID: String, to index: Int, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, _ in try edit.move(clip: clipID, to: index) }
    }

    @discardableResult
    func setClipGap(_ seconds: Double, clip clipID: String, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, _ in try edit.setGap(clip: clipID, to: seconds) }
    }

    @discardableResult
    func setClipGain(_ dB: Double, clip clipID: String, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, _ in try edit.setGain(clip: clipID, to: dB) }
    }

    @discardableResult
    func setClipFades(fadeIn: Double, fadeOut: Double, clip clipID: String, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, _ in try edit.setFades(clip: clipID, fadeIn: fadeIn, fadeOut: fadeOut) }
    }

    @discardableResult
    func setClipEffects(_ effects: VoiceEffects, clip clipID: String, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, _ in try edit.setEffects(clip: clipID, to: effects) }
    }

    /// Replaces the line's clips with its chosen render, the answer to "new render, swap it in?".
    @discardableResult
    func swapInNewRender(line lineID: String, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, project in
            guard let version = project.line(lineID)?.chosenVersion else { throw AppError("This line has no render to swap in.") }
            try edit.swapIn(line: lineID, version: version.id, duration: version.duration)
        }
    }

    /// Keeps the line's clips as they are and stops asking until a newer render.
    @discardableResult
    func keepEditedClip(line lineID: String, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, project in
            guard let chosen = project.line(lineID)?.chosen else { throw AppError("This line has no render.") }
            try edit.keep(line: lineID, version: chosen)
        }
    }

    /// Puts a line's chosen render on the timeline after the clips of the nearest earlier line.
    @discardableResult
    func addLineToEdit(line lineID: String, in projectID: String) -> Bool {
        editTimeline(projectID) { edit, project in
            guard let line = project.line(lineID), let version = line.chosenVersion else { throw AppError("Render this line first.") }
            try edit.insert(line: lineID, version: version.id, duration: version.duration, gapAfter: line.pauseAfter,
                            script: project.lines.map(\.id))
        }
    }

    /// Lines re-rendered since their clips went on the timeline: line ID → the chosen version, unless the user kept their
    /// clips over that version.
    func newRenders(_ projectID: String) -> [String: String] {
        guard let project = project(projectID), let edit = project.edit else { return [:] }
        var found: [String: String] = [:]
        for line in project.lines {
            guard let chosen = line.chosenVersion?.id, edit.kept[line.id] != chosen else { continue }
            let clips = edit.clips.filter { $0.lineID == line.id }
            if !clips.isEmpty, !clips.contains(where: { $0.versionID == chosen }) { found[line.id] = chosen }
        }
        return found
    }

    /// Lines with a chosen render and no clip on the timeline, in script order.
    func linesNotOnTimeline(_ projectID: String) -> [String] {
        guard let project = project(projectID), let edit = project.edit else { return [] }
        return project.lines.filter { line in line.chosenVersion != nil && !edit.clips.contains { $0.lineID == line.id } }.map(\.id)
    }

    func canUndoEdit(_ projectID: String) -> Bool { !(undoSteps[projectID] ?? []).isEmpty }
    func canRedoEdit(_ projectID: String) -> Bool { !(redoSteps[projectID] ?? []).isEmpty }

    func undoEdit(_ projectID: String) {
        guard let project = project(projectID), let previous = undoSteps[projectID]?.popLast() else { return }
        redoSteps[projectID, default: []].append(project.edit ?? Edit(project: project))
        update(projectID) { $0.edit = pruned(previous, in: $0) }
    }

    func redoEdit(_ projectID: String) {
        guard let project = project(projectID), let next = redoSteps[projectID]?.popLast() else { return }
        undoSteps[projectID, default: []].append(project.edit ?? Edit(project: project))
        update(projectID) { $0.edit = pruned(next, in: $0) }
    }

    /// Sets the timeline edits an agent proposes, replacing any earlier ones; one that matches the timeline as it is
    /// clears it. Returns whether a proposal is pending.
    @discardableResult
    func proposeEdit(_ proposal: EditProposal, in projectID: String) -> Bool {
        startEdit(projectID)
        guard let project = project(projectID), let edit = project.edit else { return false }
        let pending = proposal.edit != edit
        update(projectID) { $0.editProposal = pending ? proposal : nil }
        return pending
    }

    func acceptEditProposal(_ projectID: String) {
        guard let project = project(projectID), let proposal = project.editProposal else { return }
        commit(pruned(proposal.edit, in: project), in: projectID)
        update(projectID) { $0.editProposal = nil }
    }

    func rejectEditProposal(_ projectID: String) { update(projectID) { $0.editProposal = nil } }

    /// The audio a clip plays: its render as is when nothing is changed, else a file the engine makes once and keeps in
    /// `edits/`, named by what went into it.
    func clipAudio(_ clip: EditClip, in projectID: String, engine: any Engine) async throws -> URL {
        guard let version = project(projectID)?.version(clip.versionID) else { throw AppError("This clip's render no longer exists.") }
        let render = audioURL(version, projectID: projectID)
        if clip.isPlain(renderDuration: version.duration) { return render }
        let edits = folder(projectID).appending(path: "edits", directoryHint: .isDirectory)
        let url = edits.appending(path: "\(clip.cacheKey).wav")
        if files.fileExists(atPath: url.path) { return url }
        // The engine writes the file whole or not at all, so one that exists is safe to reuse.
        _ = try await engine.editClip(ClipRequest(clip, audio: render), to: url)
        return url
    }

    /// The timeline (the script's, if the project has none yet) as the preview plays it.
    func playbackTimeline(_ projectID: String, engine: any Engine) async throws -> Timeline {
        guard let project = project(projectID) else { throw AppError("This project no longer exists.") }
        let edit = project.edit ?? Edit(project: project)
        var timeline = Timeline()
        timeline.projectID = projectID
        for (clip, start) in zip(edit.clips, edit.starts) {
            let audio = try await clipAudio(clip, in: projectID, engine: engine)
            timeline.segments.append(Timeline.Segment(lineID: clip.lineID, audio: audio, start: start, duration: clip.duration, clipID: clip.id,
                                                      versionID: clip.versionID, renderStart: clip.start, tempo: clip.effects.tempo))
        }
        timeline.duration = edit.duration
        return timeline
    }

    /// Applies an operation to the timeline, opening it first if need be, and saves it as one undo step.
    private func editTimeline(_ projectID: String, _ change: (inout Edit, Project) throws -> Void) -> Bool {
        startEdit(projectID)
        guard let project = project(projectID), var edit = project.edit else { return false }
        do { try change(&edit, project) } catch {
            self.error = error.localizedDescription
            return false
        }
        commit(edit, in: projectID)
        return true
    }

    /// Saves the timeline, keeping the one before for undo when it changed. Redo is cleared, as in any editor.
    /// The timeline is opened first, so the step undoes to it rather than to a new fill with other clip IDs.
    private func commit(_ edit: Edit, in projectID: String) {
        startEdit(projectID)
        guard let before = project(projectID)?.edit, edit != before else { return }
        undoSteps[projectID] = Array(((undoSteps[projectID] ?? []) + [before]).suffix(Self.undoLimit))
        redoSteps[projectID] = nil
        update(projectID) { $0.edit = edit }
    }

    /// Without clips whose line or render has left the project since, such as a line deleted after an undo step.
    private func pruned(_ edit: Edit, in project: Project) -> Edit {
        var edit = edit
        edit.clips.removeAll { clip in project.line(clip.lineID)?.versions.contains { $0.id == clip.versionID } != true }
        return edit
    }

    // MARK: Rendering

    private struct Job {
        var lineID: String
        var tone: String
        /// Make the new version the line's chosen one.
        var choose: Bool
        /// Text other than the line's own, such as a pending change.
        var text: String?
    }

    /// A new version of one line on its own, a fresh take that may not match the others. Tests use it; the app renders
    /// the whole script (`renderScript`). Nil while another render runs.
    @discardableResult
    func rerender(_ lineID: String, in projectID: String, voices: VoiceStore) -> Task<Void, Error>? {
        guard let line = project(projectID)?.lines.first(where: { $0.id == lineID }) else { return nil }
        return start([Job(lineID: line.id, tone: line.renderTone, choose: true)], in: projectID, voices: voices)
    }

    /// Render: every line with words, read as one take per run of lines in one voice (`round`), so they sound like one
    /// recording. A line of tags alone, such as a pause, has nothing to read and is left out. Each line gets a new
    /// chosen version; its earlier ones stay in its list. Nil while a render runs.
    @discardableResult
    func renderScript(_ projectID: String, voices: VoiceStore) -> Task<Void, Error>? {
        let lines = project(projectID)?.lines.filter { !Marks.parse($0.text).spokenTokens.isEmpty } ?? []
        return start(lines.map { Job(lineID: $0.id, tone: $0.renderTone, choose: true) }, in: projectID, voices: voices)
    }

    /// Extra versions of each line in each tone; the chosen versions stay as they are.
    func compare(_ lineIDs: [String], tones: [String], in projectID: String, voices: VoiceStore) {
        start(lineIDs.flatMap { id in tones.map { Job(lineID: id, tone: $0, choose: false) } }, in: projectID, voices: voices)
    }

    /// A new version of one line, scored once: the agent reads the scores and decides. A line with a pending change
    /// renders that change, and the version waits unchosen until the change is accepted. Nil while another render runs.
    func renderLine(_ lineID: String, in projectID: String, voices: VoiceStore) -> Task<Void, Error>? {
        guard let line = project(projectID)?.lines.first(where: { $0.id == lineID }) else { return nil }
        let job = line.proposal.map { Job(lineID: line.id, tone: Tone.enabled ? $0.tone : "Neutral", choose: false, text: $0.text) }
            ?? Job(lineID: line.id, tone: line.renderTone, choose: true)
        return start([job], in: projectID, voices: voices)
    }

    /// Stops the render, and drops the lines waiting their turn (`queued`): their tasks fail with CancellationError.
    func cancel() {
        let waiting = lineQueue
        lineQueue = []
        queued = []
        for entry in waiting { entry.finish(.failure(CancellationError())) }
        task?.cancel()
    }

    /// The line's chosen version's audio.
    func chosenAudio(line lineID: String, in projectID: String) -> URL? {
        project(projectID)?.line(lineID)?.chosenVersion.map { audioURL($0, projectID: projectID) }
    }

    /// The returned task fails with the render's error, which also shows in the app.
    @discardableResult
    private func start(_ jobs: [Job], in projectID: String, voices: VoiceStore) -> Task<Void, Error>? {
        guard task == nil, voices.busy == nil, !jobs.isEmpty else { return nil }
        progress = 0
        let task = Task {
            defer {
                progress = nil
                rendering = []
                self.task = nil
                startQueued()
            }
            do { try await run(jobs, in: projectID, voices: voices) } catch is CancellationError { throw CancellationError() } catch {
                self.error = "Render failed. \(error.localizedDescription)"
                throw error
            }
        }
        self.task = task
        return task
    }

    /// Renders every job once, then scores them all, so the engine swaps Breeze for Whisper once. A line that chooses
    /// gets the version it made. A job whose text has marks renders a raw version; once it's scored, the marks go on it
    /// (`markJob`). Nothing renders again on its own: a flagged line keeps its flags until the user renders it again.
    private func run(_ jobs: [Job], in projectID: String, voices: VoiceStore) async throws {
        let rendered = try await round(jobs, in: projectID, voices: voices)
        update(projectID) { project in
            for item in rendered where jobs[item.job].choose {
                guard let line = project.lines.firstIndex(where: { $0.id == jobs[item.job].lineID }),
                      project.lines[line].versions.contains(where: { $0.id == item.version && $0.raw != true }) else { continue }
                project.lines[line].chosen = item.version
            }
        }
        for item in rendered { try await markJob(jobs[item.job], made: [item.version], in: projectID, voices: voices) }
    }

    /// The marks applied to the best raw version a finished job made, as a new version; chosen if the job chooses. The
    /// version chosen before is kept, like any earlier render (`replaceChosen` is for marks changed on one render).
    private func markJob(_ job: Job, made ids: [String], in projectID: String, voices: VoiceStore) async throws {
        guard let line = project(projectID)?.line(job.lineID),
              let best = line.versions.filter({ ids.contains($0.id) && $0.raw == true }).max(by: { $0.rank < $1.rank }) else { return }
        let version = try await mark(best.id, line: job.lineID, text: best.text, in: projectID, voices: voices)
        if job.choose { choose(version.id, line: job.lineID, in: projectID) }
    }

    /// Renders every job, then scores them all. Consecutive jobs that choose, for lines in one voice and tone, are read
    /// as one take (`OneTake`) and cut back into the lines, so the voice keeps one flow across them. Every job is checked
    /// before anything renders. Returns each job's index with the version it made.
    private func round(_ jobs: [Job], in projectID: String, voices: VoiceStore) async throws -> [(job: Int, version: String)] {
        struct Rendered { var index: Int; var job: Job; var version: Version; var parsed: ParsedLine; var take: Take; var voice: Voice }
        let engine = voices.engine
        // A render counts as 10 steps a line and a score as 1.
        let steps = Double(jobs.count * 11)
        var done = 0.0
        progress = 0
        var prepared: [Rendered] = []
        for (index, job) in jobs.enumerated() {
            guard let lines = project(projectID)?.lines, let number = lines.firstIndex(where: { $0.id == job.lineID }) else { continue }
            let line = lines[number]
            let text = job.text ?? line.text, parsed = Marks.parse(text)
            guard !parsed.spokenTokens.isEmpty else { throw AppError("Line \(number + 1) has no words to say.") }
            guard let voice = voices.voice(line.voiceID) else { throw AppError("Choose a voice for line \(number + 1).") }
            guard let take = voice.reference(job.tone) else { throw AppError("\u{201C}\(voice.name)\u{201D} has no takes. Add one in Clone.") }
            // The voice gets the words with respellings in and the stressed words named; the marks wait for `mark`.
            let version = Version(id: UUID().uuidString, text: text, voiceID: voice.id, tone: job.tone,
                                  direction: take.tone != job.tone, seed: Int.random(in: 1...99_999), duration: 0, createdAt: .now,
                                  raw: parsed.marks.isEmpty ? nil : true)
            prepared.append(Rendered(index: index, job: job, version: version, parsed: parsed, take: take, voice: voice))
        }
        var groups: [[Rendered]] = []
        for item in prepared {
            if let last = groups.last?.last, last.job.choose, item.job.choose, last.job.text == nil, item.job.text == nil,
               last.voice.id == item.voice.id, last.take.id == item.take.id, last.job.tone == item.job.tone,
               groups[groups.count - 1].reduce(item.parsed.spokenText.count) { $0 + $1.parsed.spokenText.count + 1 } <= OneTake.characters {
                groups[groups.count - 1].append(item)
            } else {
                groups.append([item])
            }
        }

        func request(_ text: String, _ first: Rendered, stress: [String]) -> RenderLine {
            RenderLine(text: text, tone: first.job.tone, reference: voices.audioURL(first.take, voiceID: first.voice.id),
                       referenceText: first.take.transcript, pronunciations: first.voice.pronunciationMap, seed: first.version.seed,
                       stress: stress)
        }
        var rendered: [Rendered] = []
        for group in groups {
            try Task.checkCancellation()
            rendering = Set(group.map(\.job.lineID))
            let start = done, share = 10 * Double(group.count), clock = ContinuousClock.now
            let report: @Sendable (Double) -> Void = { value in
                Task { @MainActor in if self.progress != nil { self.progress = (start + value * share) / steps } }
            }
            var made = group
            if group.count == 1 {
                made[0].version.duration = try await engine.render(request(group[0].parsed.spokenText, group[0], stress: group[0].parsed.stressWords),
                                                                   to: audioURL(group[0].version, projectID: projectID), progress: report)
            } else {
                let take = files.temporaryDirectory.appending(path: "VocalCord-take-\(UUID().uuidString).wav")
                defer { try? files.removeItem(at: take) }
                _ = try await engine.render(request(group.map(\.parsed.spokenText).joined(separator: " "), group[0],
                                                 stress: group.flatMap(\.parsed.stressWords)), to: take, progress: report)
                let tokens = group.flatMap(\.parsed.spokenTokens)
                let timed = try await engine.timeWords(take, tokens: tokens, hints: group.flatMap { hints($0.parsed, voice: $0.voice) })
                guard timed.words.count == tokens.count else { throw AppError("Couldn't find where each line starts in the take. Render again.") }
                let samples = try await loadSamples(take, rate: OneTake.rate)
                let ranges = OneTake.ranges(samples, words: timed.words, counts: group.map(\.parsed.spokenTokens.count))
                for (index, range) in ranges.enumerated() {
                    var piece = Array(samples[range])
                    OneTake.fade(&piece)
                    let url = audioURL(made[index].version, projectID: projectID)
                    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try writeWAV(piece[...], rate: OneTake.rate, to: url)
                    made[index].version.duration = Double(piece.count) / OneTake.rate
                    made[index].version.seed = group[0].version.seed
                }
            }
            let elapsed = ContinuousClock.now - clock
            RenderSpeed.record(rendering: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                               audio: made.reduce(0) { $0 + $1.version.duration })
            for item in made {
                updateLine(projectID, item.job.lineID) { line in
                    line.versions.append(item.version)
                    if item.job.choose, item.version.raw != true, line.chosen == nil || !(line.chosenVersion?.passes ?? false) {
                        line.chosen = item.version.id
                    }
                }
            }
            rendered += made
            done += share
            progress = done / steps
        }

        // Each reference take's own Human score, once; renders more than 0.5 below it are flagged.
        for item in rendered { try await voices.scoreHuman(item.take, voiceID: item.voice.id) }

        // A raw version's scores judge the voice: its audio has none of the script's pauses yet, so they aren't gaps.
        for item in rendered {
            try Task.checkCancellation()
            rendering = [item.job.lineID]
            let result = try await engine.score(audioURL(item.version, projectID: projectID),
                                                reference: voices.audioURL(item.take, voiceID: item.voice.id),
                                                text: Marks.plain(item.version.text), hints: hints(item.parsed, voice: item.voice),
                                                tokens: item.parsed.spokenTokens)
            let scores = result.scores.paced(text: item.version.text, duration: item.version.duration, take: item.take,
                                             raw: item.version.raw == true)
            let referenceHuman = voices.voice(item.voice.id)?.takes.first { $0.id == item.take.id }?.human
            updateVersion(projectID, item.job.lineID, item.version.id) { version in
                version.scores = scores
                version.referenceHuman = referenceHuman
                if let words = result.words, words.count == item.parsed.spokenTokens.count {
                    version.words = words
                    version.matched = result.matched
                }
            }
            done += 1
            progress = done / steps
        }
        return rendered.map { ($0.index, $0.version.id) }
    }

    private func updateVersion(_ projectID: String, _ lineID: String, _ versionID: String, _ change: (inout Version) -> Void) {
        updateLine(projectID, lineID) { line in
            if let index = line.versions.firstIndex(where: { $0.id == versionID }) { change(&line.versions[index]) }
        }
    }

    /// Words Whisper should expect: the voice's respelled words, and each word a [say] respells, as written.
    private func hints(_ parsed: ParsedLine, voice: Voice?) -> [String] {
        var hints = voice?.pronunciations.map(\.word) ?? []
        for token in parsed.tokens where token.say != nil {
            let word = token.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            if !word.isEmpty, !hints.contains(word) { hints.append(word) }
        }
        return hints
    }

    // MARK: Marks

    /// Lines whose marks are being applied, for the UI.
    private(set) var applying: Set<String> = []
    @ObservationIgnored private var marking: [String: (token: UUID, task: Task<Bool, Error>)] = [:]

    /// Brings a line up to date without the voice when only its marks differ from a version it has: from the best such
    /// version (`Line.markSource`), timing its words first if it has none (a queued engine job), it applies the marks
    /// (about 0.1 s) and chooses the result. A version that already plays the text is chosen instead. True once the
    /// line's chosen version plays its text; false when it needs a render (`Line.needsVoice`). Runs beside a render;
    /// two calls for one line take turns.
    @discardableResult
    func applyMarks(line lineID: String, in projectID: String, voices: VoiceStore) async throws -> Bool {
        while let running = marking[lineID] { _ = try? await running.task.value }
        let token = UUID()
        let task = Task { () async throws -> Bool in
            defer {
                if marking[lineID]?.token == token {
                    marking[lineID] = nil
                    applying.remove(lineID)
                }
            }
            return try await markLine(lineID, in: projectID, voices: voices)
        }
        marking[lineID] = (token, task)
        applying.insert(lineID)
        return try await task.value
    }

    private func markLine(_ lineID: String, in projectID: String, voices: VoiceStore) async throws -> Bool {
        guard let line = project(projectID)?.line(lineID) else { return false }
        switch need(line) {
        case .nothing: return !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .existing(let versionID):
            choose(versionID, line: lineID, in: projectID)
            return true
        case .voice: return false
        case .marks: break
        }
        guard let source = line.markSource else { return false }
        let version = try await mark(source.id, line: lineID, text: line.text, in: projectID, voices: voices)
        replaceChosen(lineID, with: version.id, in: projectID)
        return true
    }

    /// `text`'s marks applied to a source version's audio, as a new version of the line with the source's scores. The
    /// source's words are timed first if it has none.
    private func mark(_ sourceID: String, line lineID: String, text: String, in projectID: String, voices: VoiceStore) async throws -> Version {
        guard var source = project(projectID)?.line(lineID)?.versions.first(where: { $0.id == sourceID }) else {
            throw AppError("This line's render no longer exists.")
        }
        let parsed = Marks.parse(text), audio = audioURL(source, projectID: projectID)
        if source.words?.count != parsed.spokenTokens.count {
            let timed = try await voices.engine.timeWords(audio, tokens: parsed.spokenTokens, hints: hints(parsed, voice: voices.voice(source.voiceID)))
            guard timed.words.count == parsed.spokenTokens.count else { throw AppError("Couldn't time this line's words.") }
            source.words = timed.words
            source.matched = timed.matched
            updateVersion(projectID, lineID, sourceID) { $0.words = timed.words; $0.matched = timed.matched }
        }
        var version = Version(id: UUID().uuidString, text: text, voiceID: source.voiceID, tone: source.tone, direction: source.direction,
                              seed: source.seed, duration: 0, createdAt: .now, scores: source.scores, referenceHuman: source.referenceHuman,
                              matched: source.matched, source: source.id)
        let result = try await voices.engine.applyMarks(audio, words: source.words ?? [], marks: parsed.marks,
                                                        to: audioURL(version, projectID: projectID))
        version.duration = result.duration
        version.words = result.words
        updateLine(projectID, lineID) { $0.versions.append(version) }
        return version
    }

    /// Chooses a version made by applying marks. The chosen version it replaces is dropped, file and all, when it was
    /// made the same way and nothing else uses it: not the timeline (or a step to undo or redo it), a pending timeline
    /// proposal or another line.
    private func replaceChosen(_ lineID: String, with versionID: String, in projectID: String) {
        guard let project = project(projectID), let previous = project.line(lineID)?.chosenVersion else {
            choose(versionID, line: lineID, in: projectID)
            return
        }
        choose(versionID, line: lineID, in: projectID)
        let history = (undoSteps[projectID] ?? []) + (redoSteps[projectID] ?? [])
        guard previous.id != versionID, previous.source != nil, !project.editedRenders.contains(previous.id),
              !history.contains(where: { $0.clips.contains { $0.versionID == previous.id } }),
              !project.lines.contains(where: { $0.id != lineID && $0.chosen == previous.id }),
              !project.lines.contains(where: { $0.versions.contains { $0.source == previous.id } }) else { return }
        let audio = audioURL(previous, projectID: projectID)
        for url in [audio, audio.deletingPathExtension().appendingPathExtension("json")] where files.fileExists(atPath: url.path) {
            try? files.removeItem(at: url)
        }
        updateLine(projectID, lineID) { $0.versions.removeAll { $0.id == previous.id } }
    }

    // MARK: Committing a line

    /// What a line needs for its current text, voice and tone.
    private enum Need { case nothing, existing(String), marks, voice }

    private func need(_ line: Line) -> Need {
        guard line.needsRender else {
            if let chosen = line.chosenVersion, line.reads(chosen) { return .nothing }
            return line.versions.last(where: line.reads).map { .existing($0.id) } ?? .nothing
        }
        return line.needsVoice ? .voice : .marks
    }

    /// A line committed for a render, waiting its turn.
    @MainActor private final class QueuedLine {
        let lineID: String, projectID: String, voices: VoiceStore
        private var result: Result<Void, Error>?
        private var waiters: [CheckedContinuation<Void, Error>] = []

        init(lineID: String, projectID: String, voices: VoiceStore) {
            self.lineID = lineID
            self.projectID = projectID
            self.voices = voices
        }

        func finish(_ result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result
            for waiter in waiters { waiter.resume(with: result) }
            waiters = []
        }

        func wait() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { waiters.append($0) }
        }
    }

    @ObservationIgnored private var lineQueue: [QueuedLine] = []
    /// Lines committed while a render runs, in the order they'll render.
    private(set) var queued: [String] = []

    /// Brings a line up to date and gives its chosen version's audio to play when ready. Nil when nothing is needed. A
    /// version that already plays the text is chosen; a change to the marks alone is applied at once (`applyMarks`);
    /// anything else needs the voice, which only `render` allows (the user clicked Render): the line renders once, after
    /// the render running now and the lines committed before it (`queued`; one entry per line). Without `render` such a
    /// line is left for the user to render, and this returns nil. The task fails with the render's error, or
    /// CancellationError on `cancel()`.
    func commitLine(_ lineID: String, in projectID: String, voices: VoiceStore, render: Bool) -> Task<URL?, Error>? {
        guard let line = project(projectID)?.line(lineID) else { return nil }
        switch need(line) {
        case .nothing:
            return nil
        case .existing(let versionID):
            choose(versionID, line: lineID, in: projectID)
            let url = chosenAudio(line: lineID, in: projectID)
            return Task { url }
        case .marks:
            applying.insert(lineID)
            return Task {
                if try await !applyMarks(line: lineID, in: projectID, voices: voices), project(projectID)?.line(lineID)?.needsVoice == true {
                    guard render else { return nil }
                    try await enqueue(lineID, in: projectID, voices: voices).wait()
                }
                return chosenAudio(line: lineID, in: projectID)
            }
        case .voice:
            guard render else { return nil }
            let entry = enqueue(lineID, in: projectID, voices: voices)
            return Task {
                try await entry.wait()
                return chosenAudio(line: lineID, in: projectID)
            }
        }
    }

    private func enqueue(_ lineID: String, in projectID: String, voices: VoiceStore) -> QueuedLine {
        let entry = lineQueue.first { $0.lineID == lineID } ?? QueuedLine(lineID: lineID, projectID: projectID, voices: voices)
        if !lineQueue.contains(where: { $0 === entry }) {
            lineQueue.append(entry)
            queued = lineQueue.map(\.lineID)
        }
        startQueued()
        return entry
    }

    /// Starts queued lines while no render runs. A line is looked at again when its turn comes, as it may need less by then.
    private func startQueued() {
        while task == nil, !lineQueue.isEmpty {
            let entry = lineQueue.removeFirst()
            queued = lineQueue.map(\.lineID)
            guard let line = project(entry.projectID)?.line(entry.lineID) else {
                entry.finish(.success(()))
                continue
            }
            switch need(line) {
            case .nothing:
                entry.finish(.success(()))
            case .existing(let versionID):
                choose(versionID, line: line.id, in: entry.projectID)
                entry.finish(.success(()))
            case .marks:
                Task {
                    do {
                        try await applyMarks(line: entry.lineID, in: entry.projectID, voices: entry.voices)
                        entry.finish(.success(()))
                    } catch {
                        entry.finish(.failure(error))
                    }
                }
            case .voice:
                let job = Job(lineID: line.id, tone: line.renderTone, choose: true)
                guard let render = start([job], in: entry.projectID, voices: entry.voices) else {
                    entry.finish(.failure(AppError("An audition or voice check is running. Try again when it finishes.")))
                    continue
                }
                Task {
                    do {
                        try await render.value
                        entry.finish(.success(()))
                    } catch {
                        entry.finish(.failure(error))
                    }
                }
            }
        }
    }

    // MARK: Word times and pace

    /// The version's display-token times (`ParsedLine.tokens` of its text); nil until its words are timed.
    func displayTimes(_ version: Version) -> [WordTime]? {
        version.words.flatMap { Marks.displayTimes(Marks.parse(version.text), spoken: $0) }
    }

    @ObservationIgnored private var timing: Task<Void, Never>?

    /// Times the words of each line's chosen version that has none, one at a time in the background. Call when a
    /// project opens in Generate or Timeline. Does nothing while a render runs or it's already timing, and stops when a
    /// render starts; a version that can't be timed stays untimed, quietly.
    func timeWordsIfNeeded(_ projectID: String, voices: VoiceStore) {
        guard task == nil, timing == nil else { return }
        timing = Task {
            defer { timing = nil }
            var tried = Set<String>()
            while task == nil, let (lineID, version) = untimed(projectID, skipping: tried) {
                tried.insert(version.id)
                let parsed = Marks.parse(version.text)
                guard let timed = try? await voices.engine.timeWords(audioURL(version, projectID: projectID), tokens: parsed.spokenTokens,
                                                                     hints: hints(parsed, voice: voices.voice(version.voiceID))),
                      timed.words.count == parsed.spokenTokens.count else { continue }
                updateVersion(projectID, lineID, version.id) { $0.words = timed.words; $0.matched = timed.matched }
            }
        }
    }

    /// The first line whose chosen version has no word times and could get them.
    private func untimed(_ projectID: String, skipping: Set<String>) -> (String, Version)? {
        for line in project(projectID)?.lines ?? [] {
            guard let version = line.chosenVersion, version.words == nil, !skipping.contains(version.id),
                  !Marks.parse(version.text).spokenTokens.isEmpty, files.fileExists(atPath: audioURL(version, projectID: projectID).path)
            else { continue }
            return (line.id, version)
        }
        return nil
    }

    /// Words a minute, clamped to `Project.paceTargets`; nil goes back to each version's take.
    func setPaceTarget(_ wordsPerMinute: Double?, in projectID: String) {
        if let wordsPerMinute, !wordsPerMinute.isFinite { return }
        update(projectID) { $0.paceTarget = wordsPerMinute.map { $0.clamped(Project.paceTargets) } }
    }

    /// The pace of the line's chosen version against the project's target, else its take's. Nil until it's timed.
    func paceReport(line lineID: String, in projectID: String) -> PaceReport? {
        guard let project = project(projectID), let version = project.line(lineID)?.chosenVersion, let times = displayTimes(version),
              let target = Pace.target(projectOverride: project.paceTarget, referencePace: version.scores?.referencePace) else { return nil }
        return Pace.report(Marks.parse(version.text), times: times, target: target)
    }

    /// Slows a rushed stretch of the line to 85% or speeds a dragging one to 115% (`range` is display tokens, as in
    /// `PaceReport`), on top of any speed already there, then applies it like any marks change. Returns `applyMarks`'s
    /// answer: false when the line needs a render first. Throws when the stretch isn't rushed or dragging.
    @discardableResult
    func fixPace(line lineID: String, range: ClosedRange<Int>, in projectID: String, voices: VoiceStore) async throws -> Bool {
        guard let line = project(projectID)?.line(lineID) else { throw AppError("This line no longer exists.") }
        guard let report = paceReport(line: lineID, in: projectID) else { throw AppError("This line's pace isn't known yet.") }
        let change: Double
        if report.rushed.contains(where: { $0.overlaps(range) }) {
            change = 0.85
        } else if report.dragging.contains(where: { $0.overlaps(range) }) {
            change = 1.15
        } else {
            throw AppError("Those words are on pace.")
        }
        let tokens = Marks.parse(line.text).tokens
        let current = tokens.indices.contains(range.lowerBound) ? tokens[range.lowerBound].speed ?? 1 : 1
        setText(try Marks.setSpeed(current * change, tokens: range, in: line.text), line: lineID, in: projectID)
        return try await applyMarks(line: lineID, in: projectID, voices: voices)
    }
}

// MARK: Script import

enum ScriptSplit: String, CaseIterable, Identifiable {
    case sentences = "Sentences", paragraphs = "Paragraphs"
    var id: Self { self }
}

enum Script {
    /// Markdown to plain text. Headings and list items become paragraphs of their own; code blocks are dropped.
    static func plainText(_ markdown: String) -> String {
        var out: [String] = []
        var inCode = false
        for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inCode.toggle(); continue }
            if inCode { continue }
            if line.wholeMatch(of: /([-*_]\s*){3,}/) != nil || line.wholeMatch(of: /\|?[\s:|-]*-[\s:|-]*\|?/) != nil {
                out.append("")
                continue
            }
            let heading = /^#{1,6}\s+/, item = /^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/
            let block = line.contains(heading) || line.contains(item)
            line.replace(heading, with: "")
            line.replace(item, with: "")
            line.replace(/^(>\s?)+/, with: "")
            line.replace(/!\[[^\]]*\]\([^)]*\)/, with: "")
            line.replace(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }
            line.replace(/`([^`]*)`/) { String($0.output.1) }
            line.replace(/(\*\*|__|~~)(.+?)\1/) { String($0.output.2) }
            line.replace(/(^|\W)[*_](\S(?:.*?\S)?)[*_](?=\W|$)/) { String($0.output.1) + String($0.output.2) }
            line.replace(/<\/?[A-Za-z][^>]*>/, with: "")
            if line.hasPrefix("|") { line = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            out += block ? ["", line, ""] : [line]
        }
        return out.joined(separator: "\n")
    }

    /// The script rules a computer can check, each as a fix to make, after any tag the line can't use as written. The
    /// rest (key word last, contractions, emotion in the words) live in the agents' instructions and the voice-direction
    /// skill. Pauses are added after the render, so they no longer split the take.
    static func warnings(_ text: String) -> [String] {
        let parsed = Marks.parse(text)
        let spoken = parsed.tokens.map(\.text).joined(separator: " ")
        var found = parsed.problems
        if spoken.count > 600 {
            found.append("Over 600 characters, so the voice splits it into separate takes. Split the line at a sentence.")
        }
        if let longest = lines(spoken, by: .sentences).map({ $0.split(whereSeparator: \.isWhitespace).count }).max(), longest > 25 {
            found.append("A \(longest)-word sentence. Break it up; keep sentences under 25 words.")
        }
        // A word with a [say] is already spelled out for the voice.
        let unsaid = parsed.tokens.filter { $0.say == nil }.map(\.text).joined(separator: " ")
        let symbols = Array(Set(unsaid.matches(of: /\S*[0-9$%&@#€£¥+=\/]\S*/).map { String($0.output) })).sorted().prefix(3)
        if !symbols.isEmpty {
            found.append("Write numbers and symbols as spoken words: " + symbols.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ") + ".")
        }
        return found
    }

    /// Splits plain text into script lines. Paragraphs are separated by blank lines.
    static func lines(_ text: String, by split: ScriptSplit) -> [String] {
        let paragraphs = text.split(separator: /\n[ \t]*\n/)
            .map { $0.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard split == .sentences else { return paragraphs }
        return paragraphs.flatMap { paragraph in
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            return tokenizer.tokens(for: paragraph.startIndex..<paragraph.endIndex)
                .map { paragraph[$0].trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}

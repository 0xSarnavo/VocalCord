import Foundation
import NaturalLanguage

/// One render of a line. Its audio is `Projects/<project>/renders/<id>.wav`.
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

    /// Renders that fail a check are rendered again, up to this many times in all, keeping the best.
    static let tries = 5
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

    /// Scored with nothing flagged, so the retry loop keeps it.
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

    /// No version reads the current text in the current voice and tone yet.
    var needsRender: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !versions.contains { $0.text == text && $0.voiceID == voiceID && $0.tone == tone }
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
    private(set) var renderingLine: String?
    /// Which round of the retry loop is rendering, from 1.
    private(set) var renderTry: Int?
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
    func choose(_ versionID: String, line: String, in projectID: String) { updateLine(projectID, line) { $0.chosen = versionID } }

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
                if let match = line.versions.last(where: { $0.text == line.text && $0.voiceID == line.voiceID && $0.tone == line.tone }) {
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

    /// Every render and export, newest first.
    func outputs(_ projectID: String) -> [Output] {
        guard let project = project(projectID) else { return [] }
        let edited = project.editedRenders
        let renders = project.lines.enumerated().flatMap { number, line in
            line.versions.enumerated().map { index, version in
                Output(id: version.id, name: "Line \(number + 1) · v\(index + 1)", url: audioURL(version, projectID: projectID),
                       duration: version.duration, date: version.createdAt,
                       usedBy: line.chosen == version.id || edited.contains(version.id) ? number + 1 : nil)
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
    /// a render the timeline or a pending timeline proposal uses.
    func deleteOutput(_ id: String, in projectID: String) {
        guard let project = project(projectID) else { return }
        let urls: [URL]
        if let export = project.exports?.first(where: { $0.id == id }) {
            urls = export.files.map { URL(filePath: $0) }
        } else if let line = project.lines.first(where: { line in line.versions.contains { $0.id == id } }), line.chosen != id,
                  !project.editedRenders.contains(id), let version = line.versions.first(where: { $0.id == id }) {
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
                    MixLine(audio: audioURL(version, projectID: projectID), text: version.text,
                            voice: voices.voice(version.voiceID)?.name ?? "Voice", pauseAfter: line.pauseAfter, number: number + 1)
                }
            }
        }
        var lines: [MixLine] = []
        for clip in edit.clips {
            guard let number = project.lines.firstIndex(where: { $0.id == clip.lineID }), let version = project.version(clip.versionID) else { continue }
            lines.append(MixLine(audio: try await clipAudio(clip, in: projectID, engine: voices.engine), text: version.text,
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
            timeline.segments.append(Timeline.Segment(lineID: clip.lineID, audio: audio, start: start, duration: clip.duration, clipID: clip.id))
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
        /// Renders again with a new seed while the version fails a check (`Version.passes`), this many times in all.
        var tries = 1
    }

    /// Every line with text that has no version for its current text, voice and tone, each until it passes.
    func renderNeeded(_ projectID: String, voices: VoiceStore) {
        let lines = project(projectID)?.lines.filter(\.needsRender) ?? []
        start(lines.map { Job(lineID: $0.id, tone: $0.tone, choose: true, tries: Version.tries) }, in: projectID, voices: voices)
    }

    /// A new version of one line, in its own tone, until one passes.
    func rerender(_ lineID: String, in projectID: String, voices: VoiceStore) {
        guard let line = project(projectID)?.lines.first(where: { $0.id == lineID }) else { return }
        start([Job(lineID: line.id, tone: line.tone, choose: true, tries: Version.tries)], in: projectID, voices: voices)
    }

    /// Extra versions of each line in each tone; the chosen versions stay as they are.
    func compare(_ lineIDs: [String], tones: [String], in projectID: String, voices: VoiceStore) {
        start(lineIDs.flatMap { id in tones.map { Job(lineID: id, tone: $0, choose: false) } }, in: projectID, voices: voices)
    }

    /// A new version of one line, scored once: the agent reads the scores and decides. A line with a pending change
    /// renders that change, and the version waits unchosen until the change is accepted. Nil while another render runs.
    func renderLine(_ lineID: String, in projectID: String, voices: VoiceStore) -> Task<Void, Error>? {
        guard let line = project(projectID)?.lines.first(where: { $0.id == lineID }) else { return nil }
        let job = line.proposal.map { Job(lineID: line.id, tone: $0.tone, choose: false, text: $0.text) }
            ?? Job(lineID: line.id, tone: line.tone, choose: true)
        return start([job], in: projectID, voices: voices)
    }

    func cancel() { task?.cancel() }

    /// The returned task fails with the render's error, which also shows in the app.
    @discardableResult
    private func start(_ jobs: [Job], in projectID: String, voices: VoiceStore) -> Task<Void, Error>? {
        guard task == nil, voices.busy == nil, !jobs.isEmpty else { return nil }
        progress = 0
        let task = Task {
            defer {
                progress = nil
                renderingLine = nil
                renderTry = nil
                self.task = nil
            }
            do { try await run(jobs, in: projectID, voices: voices) } catch is CancellationError { throw CancellationError() } catch {
                self.error = "Render failed. \(error.localizedDescription)"
                throw error
            }
        }
        self.task = task
        return task
    }

    /// Rounds of rendering: each renders its jobs, then scores them, so the engine swaps Breeze for Whisper once a round.
    /// A job whose version fails a check goes into the next round with a new seed, until it passes or runs out of tries.
    /// A line that chooses gets the best version this run made, and the lines that never passed are reported.
    private func run(_ jobs: [Job], in projectID: String, voices: VoiceStore) async throws {
        var pending = jobs, attempt = 0
        var made: [String: [String]] = [:]
        while !pending.isEmpty {
            attempt += 1
            renderTry = attempt
            let rendered = try await round(pending, in: projectID, voices: voices)
            for (job, id) in rendered where job.choose { made[job.lineID, default: []].append(id) }
            update(projectID) { project in
                for index in project.lines.indices {
                    guard let ids = made[project.lines[index].id] else { continue }
                    let best = project.lines[index].versions.filter { ids.contains($0.id) }.max { $0.rank < $1.rank }
                    if let best { project.lines[index].chosen = best.id }
                }
            }
            pending = rendered.filter { job, id in
                attempt < job.tries && project(projectID)?.lines.first { $0.id == job.lineID }?.versions.first { $0.id == id }?.passes == false
            }.map(\.0)
        }
        guard let lines = project(projectID)?.lines else { return }
        let failing = jobs.filter { $0.tries > 1 }.compactMap { job -> Int? in
            guard let number = lines.firstIndex(where: { $0.id == job.lineID }), lines[number].chosenVersion?.passes == false else { return nil }
            return number + 1
        }
        if !failing.isEmpty {
            let which = failing.count == 1 ? "Line \(failing[0]) still has" : "Lines " + failing.map(String.init).joined(separator: ", ") + " still have"
            error = "\(which) a flag after \(Version.tries) tries, so the best version is kept. A cleaner take, a take in "
                + "the line's tone or a rewrite usually fixes it; the flags say what's off."
        }
    }

    /// Renders every job, then scores them all. Returns each job with the version it made.
    private func round(_ jobs: [Job], in projectID: String, voices: VoiceStore) async throws -> [(Job, String)] {
        struct Rendered { var job: Job; var version: Version; var take: Take; var voice: Voice }
        let engine = voices.engine
        // A render counts as 10 steps and a score as 1.
        let steps = Double(jobs.count * 11)
        var done = 0.0
        progress = 0
        var rendered: [Rendered] = []
        for job in jobs {
            try Task.checkCancellation()
            guard let lines = project(projectID)?.lines, let number = lines.firstIndex(where: { $0.id == job.lineID }) else { continue }
            let line = lines[number]
            let text = job.text ?? line.text
            guard let voice = voices.voice(line.voiceID) else { throw AppError("Choose a voice for line \(number + 1).") }
            guard let take = voice.reference(job.tone) else { throw AppError("\u{201C}\(voice.name)\u{201D} has no takes. Add one in Clone.") }
            var version = Version(id: UUID().uuidString, text: text, voiceID: voice.id, tone: job.tone,
                                  direction: take.tone != job.tone, seed: Int.random(in: 1...99_999), duration: 0, createdAt: .now)
            renderingLine = line.id
            let start = done, clock = ContinuousClock.now
            version.duration = try await engine.render(
                RenderLine(text: text, tone: job.tone, reference: voices.audioURL(take, voiceID: voice.id),
                           referenceText: take.transcript, pronunciations: voice.pronunciationMap, seed: version.seed),
                to: audioURL(version, projectID: projectID)
            ) { value in Task { @MainActor in if self.progress != nil { self.progress = (start + value * 10) / steps } } }
            let elapsed = ContinuousClock.now - clock
            RenderSpeed.record(rendering: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                               audio: version.duration)
            updateLine(projectID, line.id) { line in
                line.versions.append(version)
                if job.choose, line.chosen == nil || !(line.chosenVersion?.passes ?? false) { line.chosen = version.id }
            }
            rendered.append(Rendered(job: job, version: version, take: take, voice: voice))
            done += 10
            progress = done / steps
        }

        // Each reference take's own Human score, once; renders more than 0.5 below it are flagged.
        for item in rendered { try await voices.scoreHuman(item.take, voiceID: item.voice.id) }

        for item in rendered {
            try Task.checkCancellation()
            renderingLine = item.job.lineID
            let scores = try await engine.score(audioURL(item.version, projectID: projectID),
                                                reference: voices.audioURL(item.take, voiceID: item.voice.id),
                                                text: item.version.text, hints: item.voice.pronunciations.map(\.word))
                .paced(text: item.version.text, duration: item.version.duration, take: item.take)
            let referenceHuman = voices.voice(item.voice.id)?.takes.first { $0.id == item.take.id }?.human
            updateLine(projectID, item.job.lineID) { line in
                guard let index = line.versions.firstIndex(where: { $0.id == item.version.id }) else { return }
                line.versions[index].scores = scores
                line.versions[index].referenceHuman = referenceHuman
            }
            done += 1
            progress = done / steps
        }
        return rendered.map { ($0.job, $0.version.id) }
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

    /// The script rules a computer can check, each as a fix to make. The rest (key word last, contractions, emotion in
    /// the words) live in the agents' instructions and the voice-direction skill.
    static func warnings(_ text: String) -> [String] {
        let spoken = text.replacing(/\[[^\]]*\]/, with: " ")
        var found: [String] = []
        if spoken.count > 600 {
            found.append("Over 600 characters, so the voice splits it into separate takes. Split the line at a sentence.")
        }
        let pauses = text.matches(of: /\[\s*pause/.ignoresCase()).count
        if pauses > 1 { found.append("\(pauses) [pause] tags, and each one splits the take. Use punctuation instead.") }
        if let longest = lines(spoken, by: .sentences).map({ $0.split(whereSeparator: \.isWhitespace).count }).max(), longest > 25 {
            found.append("A \(longest)-word sentence. Break it up; keep sentences under 25 words.")
        }
        let symbols = Array(Set(spoken.matches(of: /\S*[0-9$%&@#€£¥+=\/]\S*/).map { String($0.output) })).sorted().prefix(3)
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

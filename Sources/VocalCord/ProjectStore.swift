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
}

/// A render or export in the Outputs list.
struct Output: Identifiable, Hashable {
    var id: String
    var name: String
    var url: URL
    var duration: Double
    var date: Date
    /// The number of the line whose chosen take this is; such a take can't be deleted.
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
    static let defaultExports = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appending(path: "VocalCord", directoryHint: .isDirectory)

    let root: URL
    let exportsRoot: URL
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

    /// The line leaves the script; its renders stay on disk.
    func deleteLine(_ lineID: String, in projectID: String) { update(projectID) { $0.lines.removeAll { $0.id == lineID } } }

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
                if let match = line.versions.last(where: { $0.text == line.text && $0.voiceID == line.voiceID && $0.tone == line.tone }) {
                    line.chosen = match.id
                }
                project.lines[index] = line
            }
        }
    }

    func reject(_ lineIDs: [String], in projectID: String) {
        update(projectID) { project in
            for index in project.lines.indices where lineIDs.contains(project.lines[index].id) { project.lines[index].proposal = nil }
        }
    }

    // MARK: Outputs

    /// Every render and export, newest first.
    func outputs(_ projectID: String) -> [Output] {
        guard let project = project(projectID) else { return [] }
        let renders = project.lines.enumerated().flatMap { number, line in
            line.versions.enumerated().map { index, version in
                Output(id: version.id, name: "Line \(number + 1) · v\(index + 1)", url: audioURL(version, projectID: projectID),
                       duration: version.duration, date: version.createdAt, usedBy: line.chosen == version.id ? number + 1 : nil)
            }
        }
        let exports = (project.exports ?? []).map { export in
            let url = URL(filePath: export.files[0])
            return Output(id: export.id, name: url.deletingPathExtension().lastPathComponent, url: url,
                          duration: export.duration, date: export.createdAt)
        }
        return (renders + exports).sorted { $0.date > $1.date }
    }

    /// Moves an export's files, or a render and its timing file, to the Trash. A line's chosen take stays.
    func deleteOutput(_ id: String, in projectID: String) {
        guard let project = project(projectID) else { return }
        let urls: [URL]
        if let export = project.exports?.first(where: { $0.id == id }) {
            urls = export.files.map { URL(filePath: $0) }
        } else if let line = project.lines.first(where: { line in line.versions.contains { $0.id == id } }), line.chosen != id,
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

    /// Mixes each line's chosen take into `exportsRoot/<project name>/` and lists the export in Outputs.
    /// Lines without a render are left out. Returns the files, the mix first.
    func export(_ projectID: String, options: ExportOptions, voices: VoiceStore) async throws -> MixResult {
        guard let project = project(projectID) else { throw AppError("This project no longer exists.") }
        let lines = project.lines.enumerated().compactMap { number, line in
            line.chosenVersion.map { version in
                MixLine(audio: audioURL(version, projectID: projectID), text: version.text,
                        voice: voices.voice(version.voiceID)?.name ?? "Voice", pauseAfter: line.pauseAfter, number: number + 1)
            }
        }
        guard !lines.isEmpty else { throw AppError("Render a line first.") }
        let name = project.name.replacing(/[\/:]/, with: "-")
        let folder = exportsRoot.appending(path: name, directoryHint: .isDirectory)
        let result = try await voices.engine.mix(MixRequest(lines: lines, folder: folder, name: name, options: options))
        update(projectID) { $0.exports = ($0.exports ?? []) + [Export(files: result.files.map(\.path), duration: result.duration)] }
        return result
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

    /// Every line with text that has no version for its current text, voice and tone.
    func renderNeeded(_ projectID: String, voices: VoiceStore) {
        let lines = project(projectID)?.lines.filter(\.needsRender) ?? []
        start(lines.map { Job(lineID: $0.id, tone: $0.tone, choose: true) }, in: projectID, voices: voices)
    }

    /// A new version of one line, in its own tone.
    func rerender(_ lineID: String, in projectID: String, voices: VoiceStore) {
        guard let line = project(projectID)?.lines.first(where: { $0.id == lineID }) else { return }
        start([Job(lineID: line.id, tone: line.tone, choose: true)], in: projectID, voices: voices)
    }

    /// Extra versions of each line in each tone; the chosen versions stay as they are.
    func compare(_ lineIDs: [String], tones: [String], in projectID: String, voices: VoiceStore) {
        start(lineIDs.flatMap { id in tones.map { Job(lineID: id, tone: $0, choose: false) } }, in: projectID, voices: voices)
    }

    /// A new version of one line, scored. A line with a pending change renders that change, and the version waits
    /// unchosen until the change is accepted. Nil while another render runs.
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
        guard task == nil, !jobs.isEmpty else { return nil }
        progress = 0
        let task = Task {
            defer {
                progress = nil
                renderingLine = nil
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

    /// Renders every job first, then scores them all, so the engine swaps Breeze for Whisper once.
    private func run(_ jobs: [Job], in projectID: String, voices: VoiceStore) async throws {
        struct Rendered { var lineID: String; var version: Version; var take: Take; var voice: Voice }
        let engine = voices.engine
        // A render counts as 10 steps and a score as 1.
        let steps = Double(jobs.count * 11)
        var done = 0.0
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
            let start = done
            version.duration = try await engine.render(
                RenderLine(text: text, tone: job.tone, reference: voices.audioURL(take, voiceID: voice.id),
                           referenceText: take.transcript, pronunciations: voice.pronunciationMap, seed: version.seed),
                to: audioURL(version, projectID: projectID)
            ) { value in Task { @MainActor in if self.progress != nil { self.progress = (start + value * 10) / steps } } }
            updateLine(projectID, line.id) { line in
                line.versions.append(version)
                if job.choose { line.chosen = version.id }
            }
            rendered.append(Rendered(lineID: line.id, version: version, take: take, voice: voice))
            done += 10
            progress = done / steps
        }

        // Each reference take's own Human score, once; renders more than 0.5 below it are flagged.
        var seen = Set<String>()
        for item in rendered where seen.insert(item.take.id).inserted {
            try Task.checkCancellation()
            guard voices.voice(item.voice.id)?.takes.first(where: { $0.id == item.take.id })?.human == nil else { continue }
            let url = voices.audioURL(item.take, voiceID: item.voice.id)
            let scores = try await engine.score(url, reference: url, text: item.take.transcript, hints: [])
            voices.setHuman(scores.human, takeID: item.take.id, voiceID: item.voice.id)
        }

        for item in rendered {
            try Task.checkCancellation()
            renderingLine = item.lineID
            let scores = try await engine.score(audioURL(item.version, projectID: projectID),
                                                reference: voices.audioURL(item.take, voiceID: item.voice.id),
                                                text: item.version.text, hints: item.voice.pronunciations.map(\.word))
            let referenceHuman = voices.voice(item.voice.id)?.takes.first { $0.id == item.take.id }?.human
            updateLine(projectID, item.lineID) { line in
                guard let index = line.versions.firstIndex(where: { $0.id == item.version.id }) else { return }
                line.versions[index].scores = scores
                line.versions[index].referenceHuman = referenceHuman
            }
            done += 1
            progress = done / steps
        }
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

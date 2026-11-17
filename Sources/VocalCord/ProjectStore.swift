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

    var likeYouFlag: String? {
        guard let scores, scores.likeYou < Self.likeYouFloor else { return nil }
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

    var chosenVersion: Version? { versions.first { $0.id == chosen } }

    /// No version reads the current text in the current voice and tone yet.
    var needsRender: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !versions.contains { $0.text == text && $0.voiceID == voiceID && $0.tone == tone }
    }
}

struct Project: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var createdAt = Date.now
    var lines: [Line] = []
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
    let root: URL
    @ObservationIgnored private var task: Task<Void, Never>?
    private let files = FileManager.default

    init(root: URL = ProjectStore.defaultRoot) {
        self.root = root
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

    func setText(_ text: String, line: String, in projectID: String) { updateLine(projectID, line) { $0.text = text } }
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

    // MARK: Rendering

    private struct Job {
        var lineID: String
        var tone: String
        /// Make the new version the line's chosen one.
        var choose: Bool
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

    func cancel() { task?.cancel() }

    private func start(_ jobs: [Job], in projectID: String, voices: VoiceStore) {
        guard task == nil, !jobs.isEmpty else { return }
        progress = 0
        task = Task {
            do { try await run(jobs, in: projectID, voices: voices) } catch is CancellationError {} catch {
                self.error = "Render failed. \(error.localizedDescription)"
            }
            progress = nil
            renderingLine = nil
            task = nil
        }
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
            guard let voice = voices.voice(line.voiceID) else { throw AppError("Choose a voice for line \(number + 1).") }
            guard let take = voice.reference(job.tone) else { throw AppError("\u{201C}\(voice.name)\u{201D} has no takes. Add one in Clone.") }
            var version = Version(id: UUID().uuidString, text: line.text, voiceID: voice.id, tone: job.tone,
                                  direction: take.tone != job.tone, seed: Int.random(in: 1...99_999), duration: 0, createdAt: .now)
            renderingLine = line.id
            let start = done
            version.duration = try await engine.render(
                RenderLine(text: line.text, tone: job.tone, reference: voices.audioURL(take, voiceID: voice.id),
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

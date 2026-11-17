import Foundation

enum Tone {
    static let all = ["Neutral", "Confident", "Happy", "Sad", "Angry", "Soft", "Slow", "Hesitant"]
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Take: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var tone: String
    var transcript: String
    var duration: Double
    var score: Double?
    var issues: [AudioIssue]
    var createdAt: Date
    /// The take's own Human score, the bar its renders are compared with in Generate.
    var human: Double?
    /// A change a terminal agent proposed, waiting for the user to accept or reject it.
    var proposal: TakeProposal?
}

/// The fields an agent proposes to change on a take; nil fields stay as they are.
struct TakeProposal: Codable, Hashable, Sendable {
    var transcript: String?
    var tone: String?
    /// Makes the take the main take of its tone.
    var main: Bool?
}

/// A clip cut from a dropped file, reviewed before its voice exists.
struct FileClip: Identifiable, Hashable, Sendable {
    var url: URL
    var duration: Double
    var transcript: String
    var issues: [AudioIssue]
    var tone = "Neutral"
    var keep: Bool
    var id: URL { url }

    /// Clips with warnings or outside 3–20 s start unticked.
    init(_ clip: Clip, issues: [AudioIssue]) {
        url = clip.url
        duration = clip.duration
        transcript = clip.transcript
        self.issues = issues
        keep = issues.isEmpty && (3...20).contains(clip.duration)
    }
}

struct Pronunciation: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var word: String
    var respelling: String
}

/// Full clone progress: `step` indexes FullClone.steps, `previous` holds the last item's takes for Re-record previous.
struct Session: Codable, Hashable, Sendable {
    var step = 0
    var index = 0
    var previous: [String] = []
}

struct Voice: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var createdAt: Date
    var takes: [Take] = []
    /// Tone name to the take ID used as that tone's reference.
    var mains: [String: String] = [:]
    var pronunciations: [Pronunciation] = []
    var session: Session?
    /// Pronunciations a terminal agent proposed, each waiting for the user to accept or reject it.
    var proposedPronunciations: [Pronunciation]?
    var lastCheck: VoiceCheck?

    func takes(_ tone: String) -> [Take] { takes.filter { $0.tone == tone } }
    func mainTake(_ tone: String) -> Take? {
        let group = takes(tone)
        return group.first { $0.id == mains[tone] } ?? group.first
    }

    /// The reference for a render in `tone`: that tone's main take, else the Neutral one (or any) with a written direction.
    func reference(_ tone: String) -> Take? { mainTake(tone) ?? mainTake("Neutral") ?? takes.first }

    var pronunciationMap: [String: String] {
        Dictionary(pronunciations.map { ($0.word, $0.respelling) }) { first, _ in first }
    }
}

/// Voices live in `Voices/voices.json`, with each take at `Voices/<voice>/<take>.wav`.
/// Recordings that are not takes (room checks, uploads, deleted or replaced takes) stay in `Voices/<voice>/raw/`.
@MainActor @Observable
final class VoiceStore {
    static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "VocalCord/Voices", directoryHint: .isDirectory)
    static let auditionLine = "Here is a new line, read in my own voice."

    private(set) var voices: [Voice] = []
    var error: String?
    /// The voice an audition is running for.
    private(set) var auditioning: String?
    /// The voice a voice check is running for, with its progress (0-1) and which line and try it is on.
    private(set) var checking: String?
    private(set) var checkProgress = 0.0
    private(set) var checkStatus = ""
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    /// The voice an audition or a check is using the engine for; renders in Generate wait for it.
    var busy: String? { auditioning ?? checking }
    let root: URL
    let engine: any Engine
    /// Set when voices.json exists but cannot be read, so a save never overwrites it.
    private var readOnly = false
    private var indexURL: URL { root.appending(path: "voices.json") }
    private let files = FileManager.default

    init(root: URL = VoiceStore.defaultRoot, engine: any Engine) {
        self.root = root
        self.engine = engine
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            if files.fileExists(atPath: indexURL.path) {
                voices = try JSONDecoder().decode([Voice].self, from: Data(contentsOf: indexURL))
            } else {
                try migrateLibrary()
            }
        } catch {
            readOnly = true
            self.error = "Couldn't read your voices. \(error.localizedDescription)"
        }
    }

    /// Copies voices from the old `library.json` format. The old index and WAV files are left untouched.
    private func migrateLibrary() throws {
        struct OldTake: Decodable { var id, transcript, style: String; var createdAt: Date }
        struct OldVoice: Decodable { var id, name, currentTakeID: String; var takes: [OldTake]; var createdAt: Date }
        let library = root.appending(path: "library.json")
        guard files.fileExists(atPath: library.path) else { return }
        for old in try JSONDecoder().decode([OldVoice].self, from: Data(contentsOf: library)) {
            try files.createDirectory(at: rawFolder(old.id), withIntermediateDirectories: true)
            var voice = Voice(id: old.id, name: old.name, createdAt: old.createdAt)
            for take in old.takes {
                let source = root.appending(path: "\(take.id).wav")
                guard files.fileExists(atPath: source.path) else { continue }
                let copy = folder(old.id).appending(path: "\(take.id).wav")
                if !files.fileExists(atPath: copy.path) { try files.copyItem(at: source, to: copy) }
                voice.takes.append(Take(id: take.id, tone: Tone.all.contains(take.style) ? take.style : "Neutral",
                                        transcript: take.transcript, duration: audioDuration(copy), score: nil,
                                        issues: [], createdAt: take.createdAt))
            }
            if let current = voice.takes.first(where: { $0.id == old.currentTakeID }) {
                voice.mains[current.tone] = current.id
            }
            voices.append(voice)
        }
        save()
    }

    func save() {
        guard !readOnly else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(voices).write(to: indexURL, options: .atomic)
        } catch {
            self.error = "Couldn't save your voices. \(error.localizedDescription)"
        }
    }

    // MARK: Files

    func folder(_ voiceID: String) -> URL { root.appending(path: voiceID, directoryHint: .isDirectory) }
    func rawFolder(_ voiceID: String) -> URL { folder(voiceID).appending(path: "raw", directoryHint: .isDirectory) }
    func audioURL(_ take: Take, voiceID: String) -> URL { folder(voiceID).appending(path: "\(take.id).wav") }

    /// A new file in raw/ for a recording.
    func newRawURL(_ voiceID: String, ext: String = "wav") -> URL {
        try? files.createDirectory(at: rawFolder(voiceID), withIntermediateDirectories: true)
        return rawFolder(voiceID).appending(path: "\(UUID().uuidString).\(ext.isEmpty ? "media" : ext)")
    }

    /// Copies an uploaded file into raw/ so the original is kept.
    func keepRaw(_ upload: URL, voiceID: String) throws -> URL {
        let access = upload.startAccessingSecurityScopedResource()
        defer { if access { upload.stopAccessingSecurityScopedResource() } }
        let raw = newRawURL(voiceID, ext: upload.pathExtension)
        try files.copyItem(at: upload, to: raw)
        return raw
    }

    // MARK: Voices

    func voice(_ id: String?) -> Voice? { voices.first { $0.id == id } }

    private func update(_ id: String, _ change: (inout Voice) -> Void) {
        guard let index = voices.firstIndex(where: { $0.id == id }) else { return }
        change(&voices[index])
        save()
    }

    func createVoice(name: String, fullClone: Bool) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = Voice(id: UUID().uuidString, name: trimmed.isEmpty ? "Untitled voice" : trimmed,
                          createdAt: .now, session: fullClone ? Session() : nil)
        try? files.createDirectory(at: rawFolder(voice.id), withIntermediateDirectories: true)
        voices.append(voice)
        save()
        return voice.id
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    /// Moves the voice folder to the Trash rather than deleting it.
    func deleteVoice(_ id: String) {
        if files.fileExists(atPath: folder(id).path) {
            do { try files.trashItem(at: folder(id), resultingItemURL: nil) } catch {
                self.error = "Couldn't move this voice to the Trash. \(error.localizedDescription)"
                return
            }
        }
        voices.removeAll { $0.id == id }
        save()
    }

    func setSession(_ id: String, _ session: Session?) { update(id) { $0.session = session } }

    // MARK: Takes

    /// Moves `file` into the voice folder as a new take.
    @discardableResult
    func addTake(_ voiceID: String, file: URL, tone: String, transcript: String,
                 issues: [AudioIssue], duration: Double? = nil) throws -> String {
        let take = Take(id: UUID().uuidString, tone: tone, transcript: transcript,
                        duration: duration ?? audioDuration(file), score: nil, issues: issues, createdAt: .now)
        try files.moveItem(at: file, to: audioURL(take, voiceID: voiceID))
        update(voiceID) { $0.takes.append(take) }
        return take.id
    }

    /// Splits a file already kept in raw/ into clips and adds them as takes.
    func addClips(from media: URL, voiceID: String, tone: String,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        var ids: [String] = []
        for clip in try await split(media, minSeconds: 3, maxSeconds: 15, progress: progress) {
            let check = try await engine.checkAudio(clip.url)
            ids.append(try addTake(voiceID, file: clip.url, tone: tone, transcript: clip.transcript,
                                   issues: check.issues, duration: clip.duration))
        }
        return ids
    }

    /// Keeps the original upload in raw/, then adds the engine's clips as takes.
    func importMedia(_ upload: URL, voiceID: String, tone: String,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        try await addClips(from: keepRaw(upload, voiceID: voiceID), voiceID: voiceID, tone: tone, progress: progress)
    }

    /// Splits into a temporary folder; callers move the clips they keep.
    func split(_ media: URL, minSeconds: Double, maxSeconds: Double,
               progress: @escaping @Sendable (Double) -> Void) async throws -> [Clip] {
        let temp = files.temporaryDirectory.appending(path: "VocalCord-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: temp, withIntermediateDirectories: true)
        let clips = try await engine.split(media, minSeconds: minSeconds, maxSeconds: maxSeconds, into: temp, progress: progress)
        guard !clips.isEmpty else { throw AppError("No speech found in this file.") }
        return clips
    }

    // MARK: From a file

    /// Copies each upload into `folder/sources` and cuts it into checked clips in `folder/clips-N`.
    func cutFiles(_ uploads: [URL], into folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [FileClip] {
        let sources = folder.appending(path: "sources", directoryHint: .isDirectory)
        try files.createDirectory(at: sources, withIntermediateDirectories: true)
        let total = Double(uploads.count)
        var clips: [FileClip] = []
        for (index, upload) in uploads.enumerated() {
            let access = upload.startAccessingSecurityScopedResource()
            defer { if access { upload.stopAccessingSecurityScopedResource() } }
            let source = sources.appending(path: "\(index + 1) \(upload.lastPathComponent)")
            try files.copyItem(at: upload, to: source)
            let out = folder.appending(path: "clips-\(index + 1)", directoryHint: .isDirectory)
            try files.createDirectory(at: out, withIntermediateDirectories: true)
            let cut = try await engine.split(source, minSeconds: 3, maxSeconds: 20, into: out) { progress((Double(index) + $0 * 0.9) / total) }
            for clip in cut {
                clips.append(FileClip(clip, issues: try await engine.checkAudio(clip.url).issues))
            }
            progress(Double(index + 1) / total)
        }
        guard !clips.isEmpty else { throw AppError("No speech found in \(uploads.count > 1 ? "these files" : "this file").") }
        return clips
    }

    /// The clips grouped by who speaks, largest group first.
    func groupBySpeaker(_ clips: [FileClip], progress: @escaping @Sendable (Double) -> Void) async throws -> [[FileClip]] {
        guard clips.count > 1 else { return [clips] }
        let byPath = Dictionary(clips.map { ($0.url.path, $0) }) { first, _ in first }
        return try await engine.groupSpeakers(clips.map(\.url), progress: progress)
            .map { $0.compactMap { byPath[$0.path] } }
            .filter { !$0.isEmpty }
    }

    /// Makes a voice from reviewed clips: ticked clips become takes, and `folder` (sources and every clip) moves to raw/.
    /// The caller runs the audition.
    func createVoice(name: String, from folder: URL, clips: [FileClip]) throws -> String {
        let id = createVoice(name: name, fullClone: false)
        do {
            let takes = try clips.filter(\.keep).map { clip in
                let take = Take(id: UUID().uuidString, tone: clip.tone, transcript: clip.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                                duration: clip.duration, score: nil, issues: clip.issues, createdAt: .now)
                try files.copyItem(at: clip.url, to: audioURL(take, voiceID: id))
                return take
            }
            try files.moveItem(at: folder, to: rawFolder(id).appending(path: folder.lastPathComponent, directoryHint: .isDirectory))
            update(id) { $0.takes = takes }
            return id
        } catch {
            // The sources stay in `folder`, so Create can be tried again.
            deleteVoice(id)
            throw error
        }
    }

    /// Takes leave the list, but their audio moves to raw/ so no recording is lost.
    func removeTakes(_ ids: [String], from voiceID: String) {
        guard let voice = voice(voiceID) else { return }
        try? files.createDirectory(at: rawFolder(voiceID), withIntermediateDirectories: true)
        for take in voice.takes where ids.contains(take.id) {
            try? files.moveItem(at: audioURL(take, voiceID: voiceID),
                                to: rawFolder(voiceID).appending(path: "\(take.id).wav"))
        }
        update(voiceID) { voice in
            voice.takes.removeAll { ids.contains($0.id) }
            voice.mains = voice.mains.filter { !ids.contains($0.value) }
        }
    }

    func setTranscript(_ text: String, take: Take, voiceID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != take.transcript else { return }
        update(voiceID) { voice in
            if let index = voice.takes.firstIndex(where: { $0.id == take.id }) { voice.takes[index].transcript = trimmed }
        }
    }

    func setMain(_ take: Take, voiceID: String) { update(voiceID) { $0.mains[take.tone] = take.id } }

    /// Takes saved before the cut-off check existed get it here; each launch reads the takes not yet flagged.
    func checkCutOff() async {
        for voice in voices {
            for take in voice.takes where !take.issues.contains(.cutOff) {
                guard let samples = try? await loadSamples(audioURL(take, voiceID: voice.id)) else { continue }
                var analyzer = LevelAnalyzer()
                analyzer.add(samples, sampleRate: 24000)
                guard analyzer.issues.contains(.cutOff) else { continue }
                update(voice.id) { voice in
                    if let index = voice.takes.firstIndex(where: { $0.id == take.id }) { voice.takes[index].issues.append(.cutOff) }
                }
            }
        }
    }

    /// The take's own Human score, scored once and kept: renders more than 0.5 below it are flagged.
    func scoreHuman(_ take: Take, voiceID: String) async throws {
        guard voice(voiceID)?.takes.first(where: { $0.id == take.id })?.human == nil else { return }
        try Task.checkCancellation()
        let url = audioURL(take, voiceID: voiceID)
        setHuman(try await engine.score(url, reference: url, text: take.transcript, hints: []).human, takeID: take.id, voiceID: voiceID)
    }

    func setHuman(_ human: Double, takeID: String, voiceID: String) {
        update(voiceID) { voice in
            if let index = voice.takes.firstIndex(where: { $0.id == takeID }) { voice.takes[index].human = human }
        }
    }

    // MARK: Pronunciations

    func addPronunciation(word: String, respelling: String, voiceID: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let respelling = respelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !respelling.isEmpty else { return }
        update(voiceID) { $0.pronunciations.append(Pronunciation(word: word, respelling: respelling)) }
    }

    func removePronunciation(_ id: String, voiceID: String) {
        update(voiceID) { $0.pronunciations.removeAll { $0.id == id } }
    }

    // MARK: Proposals

    /// Merges an agent's change into the take's pending one. Fields that match the take as it is are dropped, and a main
    /// take proposed for a tone replaces any other pending there. Returns whether a change is pending.
    @discardableResult
    func propose(_ change: TakeProposal, take takeID: String, voiceID: String) -> Bool {
        var pending = false
        update(voiceID) { voice in
            guard let index = voice.takes.firstIndex(where: { $0.id == takeID }) else { return }
            let take = voice.takes[index]
            var merged = take.proposal ?? TakeProposal()
            merged.transcript = change.transcript ?? merged.transcript
            merged.tone = change.tone ?? merged.tone
            merged.main = change.main ?? merged.main
            if merged.transcript == take.transcript { merged.transcript = nil }
            if merged.tone == take.tone { merged.tone = nil }
            if merged.main != true || (merged.tone == nil && voice.mainTake(take.tone)?.id == take.id) { merged.main = nil }
            pending = merged != TakeProposal()
            voice.takes[index].proposal = pending ? merged : nil
            guard merged.main == true else { return }
            let tone = merged.tone ?? take.tone
            for other in voice.takes.indices where other != index && voice.takes[other].proposal?.main == true
                && (voice.takes[other].proposal?.tone ?? voice.takes[other].tone) == tone {
                voice.takes[other].proposal?.main = nil
                if voice.takes[other].proposal == TakeProposal() { voice.takes[other].proposal = nil }
            }
        }
        return pending
    }

    func acceptTakes(_ takeIDs: [String], voiceID: String) {
        update(voiceID) { voice in
            for index in voice.takes.indices where takeIDs.contains(voice.takes[index].id) {
                guard let proposal = voice.takes[index].proposal else { continue }
                let id = voice.takes[index].id
                if let transcript = proposal.transcript { voice.takes[index].transcript = transcript }
                if let tone = proposal.tone {
                    if voice.mains[voice.takes[index].tone] == id { voice.mains[voice.takes[index].tone] = nil }
                    voice.takes[index].tone = tone
                }
                if proposal.main == true { voice.mains[voice.takes[index].tone] = id }
                voice.takes[index].proposal = nil
            }
        }
    }

    func rejectTakes(_ takeIDs: [String], voiceID: String) {
        update(voiceID) { voice in
            for index in voice.takes.indices where takeIDs.contains(voice.takes[index].id) { voice.takes[index].proposal = nil }
        }
    }

    /// Replaces any pending pronunciation of the same word. One the voice already has isn't pending. Returns whether it is.
    @discardableResult
    func proposePronunciation(word: String, respelling: String, voiceID: String) -> Bool {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let respelling = respelling.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !respelling.isEmpty else { return false }
        var pending = false
        update(voiceID) { voice in
            var proposals = (voice.proposedPronunciations ?? []).filter { $0.word.caseInsensitiveCompare(word) != .orderedSame }
            pending = !voice.pronunciations.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame && $0.respelling == respelling }
            if pending { proposals.append(Pronunciation(word: word, respelling: respelling)) }
            voice.proposedPronunciations = proposals.isEmpty ? nil : proposals
        }
        return pending
    }

    /// An accepted pronunciation replaces the voice's own for the same word.
    func acceptPronunciations(_ ids: [String], voiceID: String) {
        update(voiceID) { voice in
            for proposal in voice.proposedPronunciations ?? [] where ids.contains(proposal.id) {
                voice.pronunciations.removeAll { $0.word.caseInsensitiveCompare(proposal.word) == .orderedSame }
                voice.pronunciations.append(proposal)
            }
            voice.proposedPronunciations = voice.proposedPronunciations?.filter { !ids.contains($0.id) }
            if voice.proposedPronunciations?.isEmpty == true { voice.proposedPronunciations = nil }
        }
    }

    func rejectPronunciations(_ ids: [String], voiceID: String) {
        update(voiceID) { voice in
            voice.proposedPronunciations = voice.proposedPronunciations?.filter { !ids.contains($0.id) }
            if voice.proposedPronunciations?.isEmpty == true { voice.proposedPronunciations = nil }
        }
    }

    // MARK: Audition

    /// Renders the audition line from up to 5 candidates per tone, scores each, and makes the best the main take, or with
    /// `proposing` proposes it as the main take instead. All renders come before all scores, so the engine swaps models once.
    /// Returns the best take's ID per tone.
    @discardableResult
    func audition(_ voiceID: String, proposing: Bool = false, progress: @escaping @Sendable (Double) -> Void) async throws -> [String: String] {
        guard busy == nil else { throw AppError("An audition or voice check is running. Try again when it finishes.") }
        guard let voice = voice(voiceID) else { return [:] }
        auditioning = voiceID
        defer { auditioning = nil }
        let candidates = Tone.all.flatMap { tone in
            voice.takes(tone)
                .sorted { ($0.issues.count, abs($0.duration - 10)) < ($1.issues.count, abs($1.duration - 10)) }
                .prefix(5)
        }
        let total = Double(candidates.count)
        let temp = files.temporaryDirectory.appending(path: "VocalCord-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: temp) }
        for (index, take) in candidates.enumerated() {
            let line = RenderLine(text: Self.auditionLine, tone: take.tone, reference: audioURL(take, voiceID: voiceID),
                                  referenceText: take.transcript, pronunciations: voice.pronunciationMap)
            _ = try await engine.render(line, to: temp.appending(path: "\(take.id).wav")) { progress((Double(index) + $0) / total * 0.8) }
        }
        var scores: [String: Double] = [:]
        for (index, take) in candidates.enumerated() {
            let result = try await engine.score(temp.appending(path: "\(take.id).wav"), reference: audioURL(take, voiceID: voiceID),
                                                text: Self.auditionLine, hints: voice.pronunciations.map(\.word))
            scores[take.id] = Double(result.likeYou) / 100
            progress(0.8 + Double(index + 1) / total * 0.2)
        }
        var best: [String: String] = [:]
        update(voiceID) { voice in
            for index in voice.takes.indices { if let score = scores[voice.takes[index].id] { voice.takes[index].score = score } }
            for tone in Tone.all {
                if let take = voice.takes(tone).filter({ scores[$0.id] != nil }).max(by: { scores[$0.id]! < scores[$1.id]! }) {
                    best[tone] = take.id
                    if !proposing { voice.mains[tone] = take.id }
                }
            }
        }
        if proposing { for id in best.values { propose(TakeProposal(main: true), take: id, voiceID: voiceID) } }
        return best
    }

    // MARK: Voice check

    func checkURL(_ version: Version, voiceID: String) -> URL { folder(voiceID).appending(path: "check/\(version.id).wav") }

    /// Runs a voice check in the background; `checking` and `checkProgress` follow it, and `lastCheck` gets the report.
    func startCheck(_ voiceID: String, test: VoiceTest, busyElsewhere: Bool) {
        guard busy == nil, !busyElsewhere else { error = "A render or audition is running. Try again when it finishes."; return }
        checking = voiceID
        checkProgress = 0
        checkStatus = "Starting"
        checkTask = Task {
            defer { checking = nil; checkTask = nil }
            do { try await check(voiceID, test: test) } catch is CancellationError {} catch {
                self.error = "The voice check stopped. \(error.localizedDescription)"
            }
        }
    }

    func cancelCheck() { checkTask?.cancel() }

    /// Rounds like Generate's: render every pending line, score them all, then render again the lines whose best
    /// version still fails a check, up to `Version.tries`. The renders are written to a fresh folder that replaces the
    /// last check's once this one finishes.
    func check(_ voiceID: String, test: VoiceTest) async throws {
        guard let voice = voice(voiceID), !voice.takes.isEmpty else { throw AppError("Add a take in Clone first.") }
        let lines = test.lines
        let fresh = folder(voiceID).appending(path: "check-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: fresh, withIntermediateDirectories: true)
        var finished = false
        defer { if !finished { try? files.removeItem(at: fresh) } }
        var best = [Version?](repeating: nil, count: lines.count), tries = [Int](repeating: 0, count: lines.count)
        var pending = Array(lines.indices)
        for attempt in 1...Version.tries where !pending.isEmpty {
            var made: [(index: Int, version: Version, take: Take)] = []
            for (step, index) in pending.enumerated() {
                try Task.checkCancellation()
                let (text, tone) = lines[index]
                guard let take = voice.reference(tone) else { continue }
                checkStatus = "Line \(index + 1) of \(lines.count)" + (attempt > 1 ? ", try \(attempt) of \(Version.tries)" : "")
                var version = Version(id: UUID().uuidString, text: text, voiceID: voiceID, tone: tone, direction: take.tone != tone,
                                      seed: Int.random(in: 1...99_999), duration: 0, createdAt: .now)
                let clock = ContinuousClock.now, share = 0.85 / Double(pending.count)
                version.duration = try await engine.render(
                    RenderLine(text: text, tone: tone, reference: audioURL(take, voiceID: voiceID), referenceText: take.transcript,
                               pronunciations: voice.pronunciationMap, seed: version.seed),
                    to: fresh.appending(path: "\(version.id).wav")
                ) { value in Task { @MainActor in self.checkProgress = (Double(step) + value) * share } }
                let elapsed = ContinuousClock.now - clock
                RenderSpeed.record(rendering: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                                   audio: version.duration)
                made.append((index, version, take))
                tries[index] += 1
            }
            checkStatus = "Scoring" + (attempt > 1 ? ", try \(attempt) of \(Version.tries)" : "")
            for item in made { try await scoreHuman(item.take, voiceID: voiceID) }
            for (step, item) in made.enumerated() {
                try Task.checkCancellation()
                var version = item.version
                version.scores = try await engine.score(fresh.appending(path: "\(version.id).wav"), reference: audioURL(item.take, voiceID: voiceID),
                                                        text: version.text, hints: voice.pronunciations.map(\.word))
                    .paced(text: version.text, duration: version.duration, take: item.take)
                version.referenceHuman = self.voice(voiceID)?.takes.first { $0.id == item.take.id }?.human
                if best[item.index].map({ version.rank > $0.rank }) ?? true { best[item.index] = version }
                checkProgress = 0.85 + 0.15 * Double(step + 1) / Double(made.count)
            }
            pending = pending.filter { !(best[$0]?.passes ?? true) }
        }
        let kept = Set(best.compactMap { $0?.id })
        for file in (try? files.contentsOfDirectory(at: fresh, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(file.deletingPathExtension().lastPathComponent) {
            try? files.removeItem(at: file)
        }
        let folder = folder(voiceID).appending(path: "check", directoryHint: .isDirectory)
        try? files.removeItem(at: folder)
        try files.moveItem(at: fresh, to: folder)
        finished = true
        let report = VoiceCheck(test: test, date: .now, model: EngineSettings.model,
                                lines: zip(best, tries).compactMap { version, tries in version.map { VoiceCheck.Line(version: $0, tries: tries) } })
        update(voiceID) { $0.lastCheck = report }
    }
}

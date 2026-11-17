import AppKit
import AVFoundation

struct VoiceTake: Codable, Identifiable {
    var id: String
    var name: String
    var transcript: String
    var style: String
    var createdAt: Date
}

struct VoiceProfile: Codable, Identifiable {
    var id: String
    var name: String
    var takes: [VoiceTake]
    var currentTakeID: String
    var createdAt: Date

    var currentTake: VoiceTake? { takes.first { $0.id == currentTakeID } }
}

final class VoiceLibraryStore {
    static let shared = VoiceLibraryStore()
    static let changed = Notification.Name("VoiceLibraryChanged")
    static let styles = ["Neutral", "Confident", "Happy", "Sad", "Angry", "Soft", "Slow", "Hesitant"]

    private(set) var profiles: [VoiceProfile] = []
    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    private init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceDesk/Voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([VoiceProfile].self, from: data) {
            profiles = decoded
        } else {
            seedExistingVoice()
        }
    }

    private func seedExistingVoice() {
        let project = Bundle.main.bundleURL.deletingLastPathComponent()
        let audio = project.appendingPathComponent("samples/reference.wav")
        let text = project.appendingPathComponent("samples/reference.txt")
        guard FileManager.default.fileExists(atPath: audio.path),
              let transcript = try? String(contentsOf: text, encoding: .utf8) else { return }
        let take = VoiceTake(id: UUID().uuidString, name: "Reference take",
                             transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
                             style: "Neutral", createdAt: Date())
        do {
            try FileManager.default.copyItem(at: audio, to: takeURL(take))
            profiles = [VoiceProfile(id: UUID().uuidString, name: "My voice", takes: [take],
                                     currentTakeID: take.id, createdAt: Date())]
            try save()
        } catch { profiles = [] }
    }

    func takeURL(_ take: VoiceTake) -> URL { root.appendingPathComponent("\(take.id).wav") }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: indexURL, options: .atomic)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func importAudio(_ source: URL, to destination: URL, clean: Bool) throws {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { throw NSError(domain: "VoiceDesk", code: 1, userInfo: [NSLocalizedDescriptionKey: "ffmpeg is needed to import audio."]) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        var arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", source.path, "-ac", "1", "-ar", "24000"]
        if clean { arguments += ["-af", "highpass=f=80,afftdn=nf=-25,loudnorm=I=-18:TP=-1.5:LRA=7"] }
        arguments += ["-c:a", "pcm_s16le", destination.path]
        process.arguments = arguments
        let errorOutput = Pipe()
        process.standardError = errorOutput
        try process.run()
        let errorText = String(decoding: errorOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw NSError(domain: "VoiceDesk", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read this recording. \(errorText.suffix(180))"])
        }
        let audio = try AVAudioFile(forReading: destination)
        let seconds = Double(audio.length) / audio.processingFormat.sampleRate
        guard (3...60).contains(seconds) else {
            try? FileManager.default.removeItem(at: destination)
            throw NSError(domain: "VoiceDesk", code: 3, userInfo: [NSLocalizedDescriptionKey: "Use a recording between 3 and 60 seconds."])
        }
    }

    @discardableResult
    func addVoice(name: String, source: URL, transcript: String, style: String) throws -> String {
        let take = VoiceTake(id: UUID().uuidString, name: source.deletingPathExtension().lastPathComponent,
                             transcript: transcript, style: style, createdAt: Date())
        try importAudio(source, to: takeURL(take), clean: false)
        let profile = VoiceProfile(id: UUID().uuidString, name: name, takes: [take],
                                   currentTakeID: take.id, createdAt: Date())
        profiles.append(profile)
        do { try save() } catch { profiles.removeLast(); try? FileManager.default.removeItem(at: takeURL(take)); throw error }
        return profile.id
    }

    @discardableResult
    func addTake(profileID: String, source: URL, transcript: String, style: String, clean: Bool = false) throws -> String {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw NSError(domain: "VoiceDesk", code: 4, userInfo: [NSLocalizedDescriptionKey: "Select a voice first."])
        }
        let name = clean ? "Cleaned reference" : source.deletingPathExtension().lastPathComponent
        let take = VoiceTake(id: UUID().uuidString, name: name, transcript: transcript,
                             style: style, createdAt: Date())
        try importAudio(source, to: takeURL(take), clean: clean)
        profiles[index].takes.append(take)
        do { try save() } catch { profiles[index].takes.removeLast(); try? FileManager.default.removeItem(at: takeURL(take)); throw error }
        return take.id
    }

    func makeCurrent(profileID: String, takeID: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].takes.contains(where: { $0.id == takeID }) else { return }
        profiles[index].currentTakeID = takeID
        try save()
    }

    func rename(profileID: String, name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].name = name
        try save()
    }

    func setStyle(profileID: String, takeID: String, style: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              let takeIndex = profiles[index].takes.firstIndex(where: { $0.id == takeID }),
              Self.styles.contains(style) else { return }
        profiles[index].takes[takeIndex].style = style
        try save()
    }

    func setTranscript(profileID: String, takeID: String, transcript: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              let takeIndex = profiles[index].takes.firstIndex(where: { $0.id == takeID }),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        profiles[index].takes[takeIndex].transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        try save()
    }

    func referenceMap(for profile: VoiceProfile) -> [String: [String: String]] {
        var map: [String: [String: String]] = [:]
        for take in profile.takes {
            map[take.style.lowercased()] = ["audio": takeURL(take).path, "text": take.transcript]
        }
        if let current = profile.currentTake {
            map[current.style.lowercased()] = ["audio": takeURL(current).path, "text": current.transcript]
        }
        return map
    }
}

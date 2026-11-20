import Foundation

/// How a script's chosen renders compare with each other. Every line is a fresh take, so one can come out lower,
/// faster or less like the voice than the rest, and sound like someone else halfway through the voiceover. A line is
/// noted when it stands out from the median of the other rendered lines in the same voice. The agents read the notes in
/// get_script and tell the user which line to render again. Needs three rendered lines in a voice, so there's a "rest".
enum Consistency {
    /// As far as the pitch check lets a render drift from its take (`Version.pitchDrift`).
    static let pitchSemitones = 1.5
    /// Lines' pace varies naturally; past this a line sounds rushed or dragged next to the others.
    static let paceShare = 0.3
    /// Like you points under the other lines'.
    static let likeYouPoints = 10
    /// Pace and Like you mean little on shorter audio (`Version.likeYouMinSeconds`).
    static let minSeconds = 3.0

    /// Line ID to what makes its chosen version stand out from the other lines' chosen versions, for lines that do.
    static func notes(_ lines: [Line]) -> [String: [String]] {
        let rendered = lines.compactMap { line -> (id: String, voice: String, duration: Double, scores: Scores)? in
            guard let version = line.chosenVersion, let scores = version.scores else { return nil }
            return (line.id, version.voiceID, version.duration, scores)
        }
        // Different voices differ on purpose.
        return Dictionary(grouping: rendered, by: \.voice).values.reduce(into: [:]) { notes, group in
            notes.merge(Self.notes(group.map { ($0.id, $0.duration, $0.scores) })) { first, _ in first }
        }
    }

    private static func notes(_ rendered: [(id: String, duration: Double, scores: Scores)]) -> [String: [String]] {
        guard rendered.count >= 3 else { return [:] }
        var notes: [String: [String]] = [:]
        for (index, line) in rendered.enumerated() {
            let others = rendered.enumerated().filter { $0.offset != index }.map(\.element)
            var found: [String] = []
            if let pitch = line.scores.pitchHz, pitch > 0,
               let typical = median(others.compactMap { $0.scores.pitchHz }.filter { $0 > 0 }) {
                let semitones = 12 * log2(pitch / typical)
                if abs(semitones) > pitchSemitones {
                    found.append(String(format: "Pitch %.1f semitones %@ than the other lines", abs(semitones), semitones > 0 ? "higher" : "lower"))
                }
            }
            if line.duration >= minSeconds, let pace = line.scores.pace, pace > 0,
               let typical = median(others.filter { $0.duration >= minSeconds }.compactMap(\.scores.pace).filter { $0 > 0 }) {
                let change = pace / typical - 1
                if abs(change) > paceShare {
                    found.append("\(Int((abs(change) * 100).rounded()))% \(change > 0 ? "faster" : "slower") than the other lines")
                }
            }
            if line.duration >= minSeconds,
               let typical = median(others.filter { $0.duration >= minSeconds }.map { Double($0.scores.likeYou) }),
               Double(line.scores.likeYou) < typical - Double(likeYouPoints) {
                found.append("Like you \(line.scores.likeYou)%, against \(Int(typical.rounded()))% for the other lines")
            }
            if !found.isEmpty { notes[line.id] = found }
        }
        return notes
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

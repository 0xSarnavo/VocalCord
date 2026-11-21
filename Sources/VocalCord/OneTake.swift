import Foundation

/// The script read as one take. Each line rendered on its own starts a fresh take, so lines drift in pitch, pace and
/// mood. Render gives the voice a run of consecutive lines in one voice as one text, then cuts the take back into the
/// lines at their word times. One Breeze call holds about 600 characters (35-40 s), so longer scripts go in runs that fit.
enum OneTake {
    static let characters = 600
    /// About how long `characters` of speech last.
    static let seconds = 35.0

    /// Which consecutive items are read as one take: the same key (voice, take and tone), joined with a space and still
    /// within `characters`. A nil key never joins. Index runs, in order. Render (`ProjectStore.round`) and the length
    /// meter both group this way.
    static func runs(_ items: [(key: String?, characters: Int)]) -> [[Int]] {
        var runs: [[Int]] = [], used = 0
        for (index, item) in items.enumerated() {
            if let key = item.key, let last = runs.last?.last, items[last].key == key, used + 1 + item.characters <= characters {
                runs[runs.count - 1].append(index)
                used += 1 + item.characters
            } else {
                runs.append([index])
                used = item.characters
            }
        }
        return runs
    }

    /// The lines with words: about how long they last (from their spoken characters, what the take limit counts), how
    /// many takes Render reads them in, and the share of one take they fill (meaningful while that's one).
    static func length(_ lines: [Line]) -> (seconds: Int, takes: Int, share: Double) {
        let spoken = lines.compactMap { line -> (key: String?, characters: Int)? in
            let count = Marks.parse(line.text).spokenText.count
            return count > 0 ? ("\(line.voiceID)|\(line.renderTone)", count) : nil
        }
        let share = Double(spoken.reduce(max(0, spoken.count - 1)) { $0 + $1.characters }) / Double(characters)
        return (Int((share * seconds).rounded()), runs(spoken).count, share)
    }

    static let rate = 24000.0
    /// Silence kept around each line's speech, like the engine's clip cutter (`KEEP_SILENCE`).
    static let keep = 0.08

    /// Each line's samples in the take, in order. `counts` is each line's number of timed words and `words` their times
    /// in the take. A cut goes at the quietest 10 ms between one line's last word and the next line's first; each piece
    /// is then trimmed to its speech with a little silence kept, since the line's own pause after follows it.
    static func ranges(_ samples: [Float], words: [WordTime], counts: [Int]) -> [Range<Int>] {
        let frame = Int(rate / 100)
        func level(_ at: Int) -> Float {
            let end = min(at + frame, samples.count)
            guard at < end else { return 0 }
            return samples[at..<end].reduce(0) { $0 + $1 * $1 } / Float(end - at)
        }
        var cuts = [0], word = 0
        for count in counts.dropLast() {
            word += count
            let lastEnd = words[word - 1].end, nextStart = words[word].start
            let from = min(max(0, Int((lastEnd - 0.05) * rate)), samples.count)
            let to = min(max(from, Int(max(nextStart, lastEnd + 0.05) * rate)), samples.count)
            let quietest = stride(from: from, through: to, by: frame / 2).min { level($0) < level($1) } ?? from
            cuts.append(min(max(cuts.last!, quietest + frame / 2), samples.count))
        }
        cuts.append(samples.count)
        return zip(cuts, cuts.dropFirst()).map { trim($0..<$1, level: level, frame: frame) }
    }

    /// The range without its outer silence: frames 45 dB under the piece's loudest frame, minus `keep` either side.
    private static func trim(_ range: Range<Int>, level: (Int) -> Float, frame: Int) -> Range<Int> {
        let starts = Array(stride(from: range.lowerBound, to: range.upperBound, by: frame))
        guard let peak = starts.map(level).max(), peak > 0 else { return range }
        let floor = peak * 3.2e-5
        guard let first = starts.first(where: { level($0) > floor }), let last = starts.last(where: { level($0) > floor }) else { return range }
        let margin = Int(keep * rate)
        return max(range.lowerBound, first - margin)..<min(range.upperBound, last + frame + margin)
    }

    /// 10 ms in and 30 ms out, like the engine's `audio.fade`, so no cut clicks.
    static func fade(_ samples: inout [Float]) {
        let fadeIn = min(Int(0.01 * rate), samples.count), fadeOut = min(Int(0.03 * rate), samples.count)
        for i in 0..<fadeIn { samples[i] *= Float(i) / Float(fadeIn) }
        for i in 0..<fadeOut { samples[samples.count - 1 - i] *= Float(i) / Float(fadeOut) }
    }
}

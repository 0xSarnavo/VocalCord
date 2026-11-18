import CryptoKit
import Foundation

/// The voice tools on one clip. The defaults leave the audio untouched.
struct VoiceEffects: Codable, Hashable, Sendable {
    var tempo = 1.0        // speed with pitch kept, 0.5–2
    var pitch = 0.0        // semitones, −12…12
    var warmth = 0.0       // dB low shelf, −12…12
    var brightness = 0.0   // dB high shelf, −12…12
    var denoise = false

    static let tempos = 0.5...2.0, semitones = -12.0...12.0, shelves = -12.0...12.0

    var isNeutral: Bool { self == VoiceEffects() }

    /// Each tool within its range.
    var clamped: VoiceEffects {
        VoiceEffects(tempo: tempo.clamped(Self.tempos), pitch: pitch.clamped(Self.semitones), warmth: warmth.clamped(Self.shelves),
                     brightness: brightness.clamped(Self.shelves), denoise: denoise)
    }
}

/// A piece of one render on the timeline.
struct EditClip: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var lineID: String
    var versionID: String          // the render; its file is Projects/<id>/renders/<versionID>.wav
    var start: Double              // trim in, seconds into the render
    var end: Double                // trim out
    var gapAfter: Double           // silence after it, 0–10
    var gain = 0.0                 // dB, −24…12
    var fadeIn = 0.0, fadeOut = 0.0  // seconds on the timeline, 0–10
    var effects = VoiceEffects()
    var duration: Double { (end - start) / effects.tempo }   // length on the timeline

    /// The whole render with nothing changed, so its file plays as is.
    func isPlain(renderDuration: Double) -> Bool {
        start < 0.001 && abs(end - renderDuration) < 0.001 && gain == 0 && fadeIn == 0 && fadeOut == 0 && effects.isNeutral
    }

    /// Names the processed audio in `edits/`: the same render, trim, gain, fades and voice tools make the same file.
    var cacheKey: String {
        let recipe = "\(versionID)|\(start)|\(end)|\(gain)|\(fadeIn)|\(fadeOut)|\(effects.tempo)|\(effects.pitch)|"
            + "\(effects.warmth)|\(effects.brightness)|\(effects.denoise)"
        return SHA256.hash(data: Data(recipe.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Every setting in range, and fades that fit in the clip together: shortened in proportion, as the engine would.
    fileprivate var fitted: EditClip {
        var clip = self
        clip.effects = effects.clamped
        clip.gapAfter = gapAfter.clamped(0...Edit.longest)
        clip.gain = gain.clamped(Edit.gains)
        clip.fadeIn = fadeIn.clamped(0...Edit.longest)
        clip.fadeOut = fadeOut.clamped(0...Edit.longest)
        let length = max(0, clip.duration), fades = clip.fadeIn + clip.fadeOut
        if fades > length {
            clip.fadeIn *= length / fades
            clip.fadeOut *= length / fades
        }
        return clip
    }
}

/// A project's edited audio: one track of clips in order.
struct Edit: Codable, Hashable, Sendable {
    var clips: [EditClip] = []
    /// Line ID → a newer render's version ID the user chose not to swap in.
    var kept: [String: String] = [:]
}

/// Timeline edits a terminal agent proposed, waiting for the user.
struct EditProposal: Codable, Hashable, Sendable {
    var edit: Edit            // the whole timeline as it would be
    var changes: [String]     // plain-language list for the user
}

// MARK: Operations

/// Each operation clamps what it can and throws an `AppError` for what it can't do, leaving the edit as it was.
/// They're pure, so an agent's proposal can be built by applying them to a copy.
extension Edit {
    /// Gaps and fades, in seconds; the shortest clip, in seconds of its render.
    static let longest = 10.0, shortest = 0.05
    static let gains = -24.0...12.0

    /// Filled from the script: each line's chosen render whole, in script order, with the line's pause after it.
    /// Lines without a render are left out.
    init(project: Project) {
        clips = project.lines.compactMap { line in
            line.chosenVersion.map {
                EditClip(lineID: line.id, versionID: $0.id, start: 0, end: $0.duration, gapAfter: line.pauseAfter.clamped(0...Self.longest))
            }
        }
    }

    func index(of clipID: String) throws -> Int {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { throw AppError("That clip is no longer on the timeline.") }
        return index
    }

    /// Splits a clip `time` seconds into it on the timeline. Both halves keep the gain and voice tools; the fade in
    /// stays on the first half, and the fade out and gap move to the second.
    mutating func split(clip clipID: String, at time: Double) throws {
        let index = try index(of: clipID)
        var first = clips[index]
        let cut = first.start + (try number(time, "The split point")) * first.effects.tempo
        guard cut - first.start >= Self.shortest - 1e-9, first.end - cut >= Self.shortest - 1e-9 else {
            throw AppError("Split at least 0.05 s from either end of the clip.")
        }
        var second = first
        second.id = UUID().uuidString
        second.start = cut
        second.fadeIn = 0
        first.end = cut
        first.fadeOut = 0
        first.gapAfter = 0
        clips[index] = first.fitted
        clips.insert(second.fitted, at: index + 1)
    }

    /// Sets where a clip starts and ends in its render, kept within the render. Under 0.05 s is refused.
    mutating func trim(clip clipID: String, start: Double, end: Double, renderDuration: Double) throws {
        let index = try index(of: clipID)
        let range = 0...max(0, renderDuration.isFinite ? renderDuration : 0)
        let start = try number(start, "The start").clamped(range), end = try number(end, "The end").clamped(range)
        guard end - start >= Self.shortest - 1e-9 else { throw AppError("A clip must be at least 0.05 s long.") }
        clips[index].start = start
        clips[index].end = end
        clips[index] = clips[index].fitted
    }

    mutating func delete(clip clipID: String) throws { clips.remove(at: try index(of: clipID)) }

    /// Moves a clip to `index` in the timeline's order; past either end means that end.
    mutating func move(clip clipID: String, to index: Int) throws {
        let clip = clips.remove(at: try self.index(of: clipID))
        clips.insert(clip, at: min(max(index, 0), clips.count))
    }

    mutating func setGap(clip clipID: String, to seconds: Double) throws {
        let index = try index(of: clipID)
        clips[index].gapAfter = try number(seconds, "The gap").clamped(0...Self.longest)
    }

    mutating func setGain(clip clipID: String, to dB: Double) throws {
        let index = try index(of: clipID)
        clips[index].gain = try number(dB, "The volume").clamped(Self.gains)
    }

    /// Each fade is at most 10 s, and the two together no longer than the clip.
    mutating func setFades(clip clipID: String, fadeIn: Double, fadeOut: Double) throws {
        let index = try index(of: clipID)
        let fadeIn = try number(fadeIn, "The fade in"), fadeOut = try number(fadeOut, "The fade out")
        clips[index].fadeIn = fadeIn
        clips[index].fadeOut = fadeOut
        clips[index] = clips[index].fitted
    }

    /// A tempo change changes the clip's length, so its fades are fitted again.
    mutating func setEffects(clip clipID: String, to effects: VoiceEffects) throws {
        let index = try index(of: clipID)
        for value in [effects.tempo, effects.pitch, effects.warmth, effects.brightness] { _ = try number(value, "Each voice tool") }
        clips[index].effects = effects
        clips[index] = clips[index].fitted
    }

    /// Replaces all of a line's clips with its new render whole, where its first clip was. The first clip's gain,
    /// fade in and voice tools carry over, and the last clip's fade out and gap, as a split leaves them there.
    mutating func swapIn(line lineID: String, version versionID: String, duration: Double) throws {
        guard let first = clips.firstIndex(where: { $0.lineID == lineID }), let last = clips.lastIndex(where: { $0.lineID == lineID }) else {
            throw AppError("This line isn't on the timeline.")
        }
        guard duration.isFinite, duration >= Self.shortest else { throw AppError("The new render is too short to use.") }
        var clip = clips[first]
        clip.versionID = versionID
        clip.start = 0
        clip.end = duration
        clip.fadeOut = clips[last].fadeOut
        clip.gapAfter = clips[last].gapAfter
        clips.removeAll { $0.lineID == lineID }
        clips.insert(clip.fitted, at: first)
        kept[lineID] = nil
    }

    /// The user keeps their cuts of a line over `versionID`: it isn't offered again, but a newer render is.
    mutating func keep(line lineID: String, version versionID: String) throws {
        guard clips.contains(where: { $0.lineID == lineID }) else { throw AppError("This line isn't on the timeline.") }
        kept[lineID] = versionID
    }

    /// Adds a line that isn't on the timeline, its render whole: after the clips of the nearest earlier script line
    /// that has any, else first. `script` is the project's line IDs in order.
    mutating func insert(line lineID: String, version versionID: String, duration: Double, gapAfter: Double, script: [String]) throws {
        guard !clips.contains(where: { $0.lineID == lineID }) else { throw AppError("This line is already on the timeline.") }
        guard let position = script.firstIndex(of: lineID) else { throw AppError("This line is no longer in the script.") }
        guard duration.isFinite, duration >= Self.shortest else { throw AppError("This render is too short to use.") }
        let gap = try number(gapAfter, "The gap").clamped(0...Self.longest)
        let after = script[..<position].reversed().compactMap { id in clips.lastIndex { $0.lineID == id } }.first
        clips.insert(EditClip(lineID: lineID, versionID: versionID, start: 0, end: duration, gapAfter: gap), at: after.map { $0 + 1 } ?? 0)
        kept[lineID] = nil
    }

    private func number(_ value: Double, _ name: String) throws -> Double {
        guard value.isFinite else { throw AppError("\(name) must be a number.") }
        return value
    }

    // MARK: Timing

    /// When each clip starts on the timeline.
    var starts: [Double] {
        var time = 0.0
        return clips.map { clip in
            defer { time += clip.duration + clip.gapAfter }
            return time
        }
    }

    /// The last clip's gap is left off, as in the mix.
    var duration: Double { zip(clips, starts).reversed().first.map { $1 + $0.duration } ?? 0 }

    func start(of clipID: String) -> Double? { clips.firstIndex { $0.id == clipID }.map { starts[$0] } }

    /// The clip playing at `time`, its gap included.
    func clip(at time: Double) -> EditClip? { zip(clips, starts).reversed().first { $0.1 <= time + 0.001 }?.0 }
}

extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}

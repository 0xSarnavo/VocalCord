import Foundation

/// The word playing now, for the read-along highlight in the script rows, the Read view and the Timeline tab.
struct LitWord: Equatable {
    var lineID: String
    /// The version playing. Its display words match the line's only while `line.text == version.text`.
    var versionID: String
    /// The display word (`Marks.parse(version.text).tokens`) being said: words up to it are lit. -1 before the first word.
    var token: Int
    /// The timeline clip playing, in the Timeline tab.
    var clipID: String? = nil
}

extension ProjectStore {
    /// After an edit (Return, leaving the text, or a command): brings the line up to date without the voice, as
    /// `commitLine(render: false)` does, then plays it. A line that needs the voice waits for Render. A failed marks
    /// step shows its error here.
    func commitAndPlay(_ lineID: String, in projectID: String, voices: VoiceStore, player: Player) {
        guard let task = commitLine(lineID, in: projectID, voices: voices, render: false) else { return }
        Task {
            do {
                if let url = try await task.value { player.play(url, from: 0) }
            } catch is CancellationError {
            } catch {
                if self.error == nil { self.error = "Couldn't update the line. \(error.localizedDescription)" }
            }
        }
    }
}

@MainActor
enum ReadAlong {
    /// Whisper's word starts tend to run a little late, so a word lights slightly early to look in step.
    static let lead = 0.05

    /// The word being said `time` seconds into a file whose display words have `times`: the last one that has started.
    static func token(at time: Double, in times: [WordTime]) -> Int {
        times.lastIndex { $0.start <= time + lead } ?? -1
    }

    /// The word at `position` on a preview timeline. In the pause after a segment, its last word stays lit.
    static func lit(_ timeline: Timeline, at position: Double, in project: Project, projects: ProjectStore) -> LitWord? {
        guard timeline.projectID == project.id, let segment = timeline.segment(at: position), let versionID = segment.versionID,
              let version = project.version(versionID), let times = projects.displayTimes(version) else { return nil }
        let time = segment.renderTime(at: position) ?? segment.renderStart + segment.duration * segment.tempo
        return LitWord(lineID: segment.lineID, versionID: versionID, token: token(at: time, in: times), clipID: segment.clipID)
    }

    /// The word playing now in `project`: from the preview while it plays, else from a take the Player plays on its own
    /// (a row's play button, or the play after an edit). `Player.time` isn't observable, so a view showing this redraws
    /// on a timer (`TimelineView(.animation(minimumInterval: 0.05))`) while `player.playing` is set.
    static func lit(in project: Project, projects: ProjectStore, preview: Preview, player: Player) -> LitWord? {
        if preview.isPlaying { return lit(preview.timeline, at: preview.position, in: project, projects: projects) }
        guard let playing = player.playing?.standardizedFileURL.path else { return nil }
        for line in project.lines {
            guard let version = line.versions.first(where: { projects.audioURL($0, projectID: project.id).standardizedFileURL.path == playing })
            else { continue }
            guard let times = projects.displayTimes(version) else { return nil }
            return LitWord(lineID: line.id, versionID: version.id, token: token(at: player.time, in: times))
        }
        return nil
    }
}

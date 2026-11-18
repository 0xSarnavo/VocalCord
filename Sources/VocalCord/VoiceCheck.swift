import SwiftUI

/// A test of a whole voice: VocalCord renders a set of lines with the same retry loop as Generate and reports how each
/// one scored. Its renders are `Voices/<voice>/check/<version>.wav`; a new check replaces them.
enum VoiceTest: String, CaseIterable, Identifiable, Codable, Sendable {
    case range, consistency, long

    var id: Self { self }

    var title: String {
        switch self {
        case .range: "10 different lines"
        case .consistency: "Same line 10 times"
        case .long: "10 long lines"
        }
    }

    var detail: String {
        switch self {
        case .range: "Narration and one line per tone, 10 to 20 seconds each. Tests range and emotion."
        case .consistency: "One narration line, ten times. Tests how steady the voice is from render to render."
        case .long: "About 35 seconds each, the most one take holds. Tests long voiceovers."
        }
    }

    var lines: [(text: String, tone: String)] {
        switch self {
        case .range: Self.rangeLines
        case .consistency: Array(repeating: Self.rangeLines[0], count: 10)
        case .long: Self.longLines
        }
    }

    /// Minutes on this Mac, from its measured render speed: every line passing the first time, then with the retries a
    /// typical check needs. A line can take up to five tries.
    func estimate(model: String = EngineSettings.model) -> ClosedRange<Int> {
        // About 15 characters a second of speech; scoring takes a few seconds a line.
        let audio = lines.reduce(0.0) { $0 + Double($1.text.count) / 15 }
        let low = audio * RenderSpeed.factor(model) + Double(lines.count) * 5
        return Int((low / 60).rounded(.up))...Int((low * 2 / 60).rounded(.up))
    }

    // Written to the script rules: short sentences, numbers as words, the emotion carried by the words.
    private static let rangeLines: [(text: String, tone: String)] = [
        ("Every morning, the harbor wakes up slowly. Fishing boats drift in, gulls circle overhead, and the café on the "
         + "corner props its door open. By eight, the whole street smells of coffee and salt.", "Neutral"),
        ("Here's how it works. You record a short clip, pick a tone for each line, and press render. A few minutes "
         + "later, your script comes back in your own voice.", "Neutral"),
        ("We've tested this with real customers for six months. It works, it's fast, and it saves every team about two "
         + "hours a week. Now it's ready for everyone.", "Confident"),
        ("I can't believe it actually worked! The whole family showed up, the cake was perfect, and Grandma laughed so "
         + "hard she cried. Best birthday we've ever had.", "Happy"),
        ("The old house is empty now. The garden's grown wild, and the swing still hangs from the oak tree. I keep "
         + "thinking I'll hear her calling us in for dinner.", "Sad"),
        ("Three times. I asked them three times to fix it, and every time they promised it was done. It wasn't. I'm "
         + "done waiting.", "Angry"),
        ("It's okay. Take a slow breath with me. You don't have to figure everything out tonight. Just rest, and we'll "
         + "look at it together in the morning.", "Soft"),
        ("First, open the lid. Then pour in one cup of water. Wait until the light turns green, and only then press "
         + "start.", "Slow"),
        ("I'm not sure this is the right time to bring it up. Maybe it can wait. Or, well, maybe it can't. I guess I "
         + "just don't know how to say it.", "Hesitant"),
        ("Have you ever wondered why the sky turns orange at sunset? The light travels farther through the air, and "
         + "the blue scatters away before it reaches you.", "Neutral"),
    ]

    private static let longLines: [(text: String, tone: String)] = [
        (rangeLines[0].text + " Old men argue about the weather on the bench by the fountain. Children race their bikes "
         + "along the sea wall, and someone always shouts at them to slow down. Nobody ever does. By noon the boats "
         + "are empty, the nets are drying, and the town settles into its long, lazy afternoon.", "Neutral"),
        (rangeLines[1].text + " You can give every line its own tone, so one sentence sounds calm and the next sounds "
         + "excited. If a line sounds off, play it again, change a word, or try a different tone. When the whole "
         + "script sounds right, export it as one file and drop it into your video.", "Neutral"),
        (rangeLines[2].text + " The numbers are simple. Teams that switched spent less time fixing mistakes and more "
         + "time shipping. Support tickets dropped by a third. And every single customer in the trial asked to keep "
         + "it when the trial ended. That's not luck. That's a product that works.", "Confident"),
        (rangeLines[3].text + " Uncle Joe told the same three jokes he tells every year, and we laughed anyway. The dog "
         + "stole a sausage off the grill and ran around the garden with it. Nobody even tried to stop him. When the "
         + "candles went out, everyone sang, badly and loudly, and it was perfect.", "Happy"),
        (rangeLines[4].text + " Her coat is still on the hook by the door. Nobody has the heart to move it. On Sundays "
         + "the kitchen used to smell of bread and cinnamon. Now it's quiet, and the clock on the wall sounds louder "
         + "than it ever did. Some days I still set out two cups without thinking.", "Sad"),
        (rangeLines[5].text + " I've lost two weeks of work because of this. Two weeks. Every call ends with someone "
         + "telling me it's being looked at. Nobody is looking at anything. If it isn't fixed by Friday, I'm taking "
         + "my business somewhere that actually answers the phone.", "Angry"),
        (rangeLines[6].text + " Close your eyes for a moment. Listen to the rain on the window. It's soft, and steady, "
         + "and it isn't going anywhere. Neither am I. Whatever happened today, it's over now. Let your shoulders "
         + "drop. Breathe in, and slowly breathe out.", "Soft"),
        (rangeLines[7].text + " While it heats, place the cup on the tray. Don't lift the lid while it's working. When "
         + "it beeps twice, wait ten seconds. Then lift the cup out carefully, because it will be hot. Finally, "
         + "switch it off at the back and let it cool.", "Slow"),
        (rangeLines[8].text + " It's about the trip. I said I'd go, and I meant it, at the time. But now, I don't know. "
         + "Maybe it's work, or maybe it's just me. I don't want to let you down. I just, well, I wanted you to "
         + "hear it from me first, I suppose.", "Hesitant"),
        (rangeLines[9].text + " At noon the sun is high, so its light takes a short path, and the sky looks blue. As "
         + "it sinks, the path gets longer, and only the reds and oranges make it through. That's why the best "
         + "sunsets come after a clear day, when the air is clean and still.", "Neutral"),
    ]
}

/// The last voice check of a voice: each test line's best version and how many renders it took.
struct VoiceCheck: Codable, Hashable, Sendable {
    struct Line: Codable, Hashable, Sendable {
        var version: Version
        var tries: Int
    }
    var test: VoiceTest
    var date: Date
    var model: String
    var lines: [Line]

    var passed: Int { lines.filter(\.version.passes).count }
}

/// Pick a test and see its time on this Mac, follow a running check, and read the last report with each render playable.
struct VoiceCheckSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VoiceStore.self) private var store
    @Environment(ProjectStore.self) private var projects
    let voice: Voice
    @State private var test = VoiceTest.range

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice check").font(.vcTitle)
                Text("Renders test lines in \u{201C}\(voice.name)\u{201D}. A line that fails a check renders again, up to \(Version.tries) "
                     + "times, and keeps its best version.")
                    .foregroundStyle(Theme.secondary)
            }
            if store.checking == voice.id {
                running
            } else {
                picker
            }
            if let report = store.voice(voice.id)?.lastCheck {
                Theme.line.frame(height: 1)
                VoiceCheckReport(voiceID: voice.id, report: report)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.vc(.secondary, .m)).keyboardShortcut(.cancelAction)
                if store.checking != voice.id {
                    Button("Start check") { store.startCheck(voice.id, test: test, busyElsewhere: projects.progress != nil) }
                        .buttonStyle(.vc(.primary, .m))
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.busy != nil || projects.progress != nil)
                }
            }
        }
        .padding(24)
        .frame(width: 820)
        .background(Theme.content)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(VoiceTest.allCases) { option in
                let selected = test == option
                Button { test = option } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? Theme.text : Theme.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title).font(.vcBodyBold)
                            Text(option.detail).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        let minutes = option.estimate()
                        Text("About \(minutes.lowerBound)\u{2013}\(minutes.upperBound) min")
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondary)
                            .help("On this Mac with the \(EngineSettings.titles[EngineSettings.model] ?? EngineSettings.model) model, "
                                  + "from how fast it has rendered so far. Lines that need retries take longer.")
                    }
                    .padding(12)
                    // A choice tile: the selection grey and a stronger border when chosen.
                    .background(selected ? Theme.selection : Theme.hover, in: .rect(cornerRadius: Radius.card))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(selected ? Theme.strong : Theme.line))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ProgressView(value: store.checkProgress)
                Button("Cancel") { store.cancelCheck() }.buttonStyle(.vc(.secondary, .s))
            }
            Text(store.checkStatus).foregroundStyle(Theme.secondary).monospacedDigit()
            Text("You can close this window; the check keeps running.").font(.vcCaption).foregroundStyle(Theme.secondary)
        }
    }
}

/// One row per test line: play, tone, text, the scores, pitch and pace against the take, tries, and the flags left.
private struct VoiceCheckReport: View {
    @Environment(VoiceStore.self) private var store
    let voiceID: String
    let report: VoiceCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(summary).font(.vcBodyBold)
            if report.test == .consistency { Text(spread).foregroundStyle(Theme.secondary).monospacedDigit() }
            ScrollView {
                VStack(spacing: 0) {
                    row(["", "Tone", "Line", "Like you", "Human", "Words", "Pitch", "Pace", "Tries", ""].map { Text($0) })
                        .font(.vcCaptionBold).foregroundStyle(Theme.secondary).frame(height: 28)
                    ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
                        let version = line.version, scores = version.scores
                        HStack(spacing: 0) {
                            PlayButton(url: store.checkURL(version, voiceID: voiceID)).frame(width: 40, alignment: .leading)
                            Text(version.tone).frame(width: 78, alignment: .leading)
                            Text(version.text).lineLimit(1).help(version.text).frame(maxWidth: .infinity, alignment: .leading)
                            Text(scores.map { "\($0.likeYou)%" } ?? "").frame(width: 66, alignment: .trailing)
                            Text(scores.map { String(format: "%.1f", $0.human) } ?? "").frame(width: 54, alignment: .trailing)
                            Text(scores.map { "\($0.words)%" } ?? "").frame(width: 56, alignment: .trailing)
                            Text(pitch(scores)).frame(width: 60, alignment: .trailing)
                            Text(pace(scores)).frame(width: 56, alignment: .trailing)
                            Text("\(line.tries)").frame(width: 44, alignment: .trailing)
                            Group {
                                if version.passes {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.secondary)
                                } else {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                                }
                            }
                            .frame(width: 34)
                            .help(version.passes ? "Passed" : version.flags.joined(separator: "\n"))
                            .accessibilityLabel(version.passes ? "Passed" : version.flags.joined(separator: ", "))
                        }
                        .font(.vcBody.monospacedDigit())
                        .frame(height: 32)
                        Theme.rule.frame(height: 1)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
    }

    private func row(_ cells: [Text]) -> some View {
        HStack(spacing: 0) {
            cells[0].frame(width: 40, alignment: .leading)
            cells[1].frame(width: 78, alignment: .leading)
            cells[2].frame(maxWidth: .infinity, alignment: .leading)
            cells[3].frame(width: 66, alignment: .trailing)
            cells[4].frame(width: 54, alignment: .trailing)
            cells[5].frame(width: 56, alignment: .trailing)
            cells[6].frame(width: 60, alignment: .trailing)
            cells[7].frame(width: 56, alignment: .trailing)
            cells[8].frame(width: 44, alignment: .trailing)
            cells[9].frame(width: 34)
        }
    }

    private var summary: String {
        "\(report.passed) of \(report.lines.count) passed \u{00B7} \(report.test.title) \u{00B7} "
            + "\(EngineSettings.titles[report.model] ?? report.model) \u{00B7} \(report.date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// For the same line rendered ten times: how far its pitch and length wander.
    private var spread: String {
        let pitches = report.lines.compactMap { $0.version.scores?.pitchHz }.filter { $0 > 0 }
        let lengths = report.lines.map(\.version.duration)
        guard let low = pitches.min(), let high = pitches.max(), let short = lengths.min(), let long = lengths.max() else { return "" }
        return String(format: "Pitch %.0f\u{2013}%.0f Hz \u{00B7} length %.1f\u{2013}%.1f s", low, high, short, long)
    }

    private func pitch(_ scores: Scores?) -> String {
        guard let pitch = scores?.pitchHz, let reference = scores?.referencePitchHz, pitch > 0, reference > 0 else { return "" }
        return String(format: "%+.1f st", 12 * log2(pitch / reference))
    }

    private func pace(_ scores: Scores?) -> String {
        guard let pace = scores?.pace, let reference = scores?.referencePace, reference > 0 else { return "" }
        return String(format: "%+.0f%%", (pace / reference - 1) * 100)
    }
}

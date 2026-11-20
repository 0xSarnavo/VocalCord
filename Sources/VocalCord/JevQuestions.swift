/// Everything VocalCord asks Jev, in one file to audit: the model, the questions, their criteria and the thresholds.
/// Jev judges each line; code turns the answers into what the script shows (`JevResult.status`).
/// Jev reads text only, so it judges the script's words, never audio.
enum JevQuestions {
    /// The newest Jev release in the TypeSafe docs (Nov 2026). Pinned rather than `jev-latest`, so answers don't shift
    /// under the thresholds when the alias moves.
    static let model = "jev-1.14.0"

    /// A Noul at or above `yes` passes and at or below `no` fails; between them the check is unsettled.
    static let yes = 0.7, no = 0.3

    static func verdict(_ noul: Double) -> Verdict { noul >= yes ? .yes : noul <= no ? .no : .unsettled }

    /// How each tone is spoken, from the engine's directions (`STYLES` in engine/vocalcord_engine/tts.py).
    static let toneMeaning = [
        "Neutral": "naturally, at a relaxed conversational pace",
        "Confident": "with quiet confidence, a steady pace and firm, natural emphasis",
        "Happy": "in a pleased, upbeat way, at the speaker's usual pitch",
        "Sad": "softly and more slowly, with restrained sadness",
        "Angry": "with controlled anger and firm emphasis, without shouting",
        "Soft": "gently and quietly, with a close, conversational delivery",
        "Slow": "clearly, at a measured, slower pace with natural pauses",
        "Hesitant": "with occasional small hesitations and thoughtful pauses",
    ]

    enum Check: String, CaseIterable, Sendable {
        case spoken, fitsTone = "fits_tone", keepsMeaning = "keeps_meaning"
    }

    /// The checks for one line: the meaning check only when an agent rewrote it.
    /// Fit with the tone only while tones show (`Tone.enabled`): a tone the user can't change isn't theirs to fix.
    static func checks(_ subject: JevSubject) -> [Check] {
        (subject.original == nil ? [.spoken, .fitsTone] : Check.allCases).filter { Tone.enabled || $0 != .fitsTone }
    }

    /// One line's request. The line's text is the whole state; each question carries the context only it needs.
    static func body(_ subject: JevSubject) -> [String: Any] {
        let meaning = toneMeaning[subject.tone] ?? subject.tone.lowercased()
        var questions: [String: Any] = [:]
        for check in checks(subject) {
            switch check {
            case .spoken:
                questions[check.rawValue] = noul(
                    "Does `line` read like something a person would say aloud?",
                    yes: "A person could say `line` out loud as written, as in a voiceover or a conversation.",
                    no: "`line` reads like written text that would sound awkward spoken, such as a heading, a list fragment, "
                        + "a URL, or a long sentence of nested clauses.")
            case .fitsTone:
                questions[check.rawValue] = noul(
                    "Does `line` suit being spoken in a \(subject.tone) tone?",
                    yes: "The words of `line` suit being spoken \(meaning).",
                    no: "The words of `line` call for a different feeling or pace than being spoken \(meaning).")
            case .keepsMeaning:
                questions[check.rawValue] = noul(
                    ["question": "Does `line` keep the meaning of `original`?", "original": subject.original ?? ""],
                    yes: "`line` says the same thing as `original`, even if it is shorter, split up or reworded for speaking.",
                    no: "`line` drops, adds or changes a fact, claim or intent that `original` has.")
            }
        }
        return ["model": model, "state": ["line": subject.text], "questions": questions]
    }

    private static func noul(_ instructions: Any, yes: String, no: String) -> [String: Any] {
        ["type": "noul", "instructions": instructions, "criteria": ["true": yes, "false": no]]
    }

    /// What a check's verdict means to the user, shown on hover and returned to the agents.
    static func note(_ check: Check, _ verdict: Verdict, tone: String) -> String {
        switch (check, verdict) {
        case (.spoken, .yes): "Reads as speech"
        case (.spoken, .unsettled): "May read like written text"
        case (.spoken, .no): "Reads like written text, not speech"
        case (.fitsTone, .yes): "Fits \(tone)"
        case (.fitsTone, .unsettled): "May not fit \(tone)"
        case (.fitsTone, .no): "Doesn't fit \(tone)"
        case (.keepsMeaning, .yes): "Keeps the original meaning"
        case (.keepsMeaning, .unsettled): "May change the original meaning"
        case (.keepsMeaning, .no): "Changes the original meaning"
        }
    }
}

enum Verdict: String, Encodable, Sendable { case yes, unsettled, no }

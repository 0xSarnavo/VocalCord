import AppKit

/// What a new voice reads out loud in one go, about two minutes, before uploading the recording.
///
/// Written for how Breeze clones (see the voice-direction skill): each render copies one 10-20 s take, so every
/// paragraph is one take of 30-38 words, about 12-15 s at a normal pace. The reader stops for about two seconds at each
/// [pause], which is longer than the 1.5 s a clip may span (`MAX_INSIDE_PAUSE` in `engine/vocalcord_engine/clips.py`),
/// so the cutter ends each clip there, in silence, never mid-word. It's warm, everyday talk in one mood, because
/// renders copy the take's delivery: no tongue-twisters, short sentences, contractions, a question, numbers as words
/// and a spread of English sounds.
enum CloneScript {
    static let paragraphs = [
        "Hi, this is my voice, recorded so an app on my Mac can copy how I sound. I'm going to read at my normal pace, "
            + "the way I'd talk to a friend across the table.",
        "Most mornings start the same way. I make coffee, check the weather, and look at the long list of things I "
            + "promised to finish yesterday. Some days the list wins. Some days I do.",
        "Have you ever noticed how a good idea shows up when you're not looking for it? In the shower, on a walk, or "
            + "right before you fall asleep. That's why I keep a notebook nearby.",
        "Last year I tried to learn the guitar. Three chords in, my fingers hurt and the neighbors probably wished I'd "
            + "stop. But after a few weeks, the songs started to sound like actual music.",
        "Here's something simple that works. Break a big job into small pieces, finish one piece, and then take a short "
            + "break. It sounds obvious, but it's the only thing that gets me through a busy week.",
        "The train was twenty minutes late, so I sat on the bench and watched people. A child was explaining dinosaurs "
            + "to her very patient grandfather. Honestly, she knew more than I do.",
        "If you're building something, show it to people early. They'll find the problems you can't see, and they'll "
            + "ask questions you never thought of. It's a little scary, but it saves months of work.",
        "Weekends are for slowing down. A long breakfast, a walk by the river, maybe a film in the evening. Nothing "
            + "fancy, just the simple pleasure of having nowhere to be.",
        "So that's it. Thanks for listening to me ramble for a couple of minutes. If this works, the next thing you "
            + "hear in my voice won't be me at all, and hopefully you won't be able to tell.",
    ]

    /// How to record it, in order: set up, read, pause, and get the file onto this Mac.
    static let steps = [
        "Record with anything: Voice Memos, QuickTime or your phone. Use a quiet room, with the mic about a hand's "
            + "width from your mouth.",
        "Wait a second, then read it in one go at your normal pace, like you're talking to a friend.",
        "At each pause, stop for about two seconds. If you trip over a word, stop, then read that sentence again.",
        "Send the recording to this Mac (AirDrop works), then click Upload recording or drop it here.",
    ]

    /// For the clipboard, to read from a phone: the paragraphs with [pause] between them.
    static var text: String { paragraphs.joined(separator: "\n\n[pause]\n\n") }

    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

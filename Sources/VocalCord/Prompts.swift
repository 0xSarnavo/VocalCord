/// Text the user reads aloud while cloning.
enum Prompts {
    static let fastClone = "I'm recording this so VocalCord can learn my voice. I'll read at my usual pace, clearly and calmly, as if I'm talking to a friend across the table. That should take about fifteen seconds."

    /// Together these cover every English consonant and vowel sound.
    static let sentences = [
        "She sells fresh fish by the harbor each June.",
        "A big brown dog jumped over the muddy hedge.",
        "We watched the yellow kite drift toward the bridge.",
        "His usual measure of beige paint was not enough.",
        "Choose the cheapest juice in the shop, then chill it.",
        "The thick fog rolled through the valley at dawn.",
        "Our boat rode the waves while the wind howled.",
        "Vivid photos of the zoo were stored in a shoebox.",
        "Please bring the singing bird back inside tonight.",
        "Each judge thought the treasure looked genuine.",
        "The young child hugged a woolly toy sheep.",
        "The quiet morning gave us time to think.",
        "Paul fixed the squeaky hinge with oil and a cloth.",
        "Ripe red cherries hung low over the garden path.",
        "Few people knew the view from the tower was so huge.",
        "The farmer's lazy goat chewed through the rope.",
        "I'd rather walk along the shore than drive.",
        "Thin threads of smoke rose from the chimney.",
        "A pleasant breeze blew over the boys on the beach.",
        "The clever hawk dove sharply toward the field.",
        "Jack's rough voice echoed across the empty hall.",
        "Join us for a cup of hot cocoa at noon.",
        "The vision of the azure sea stayed with her.",
        "Wet leaves clung to the window after the storm.",
        "Ask the bakery for six whole wheat rolls.",
        "Thursday's lecture covered birds and their nests.",
        "The ship's anchor sank deep into the soft sand.",
        "Bright lights flickered on the quiet street at night.",
        "Good books often push us to change our minds.",
        "Ice cubes rattled in the tall glass of lemonade.",
    ]

    static let topics = [
        "Describe a place you love and why you go there.",
        "Tell the story of a day that didn't go to plan.",
    ]

    static let toneSentences = [
        "Confident": ["We can ship this today.", "I know exactly what to do next.", "This plan will work, and here is why.",
                      "Trust me, we have done this before.", "The numbers speak for themselves."],
        "Happy": ["That's great news!", "I'm really glad it worked!", "What a lovely surprise this is.",
                  "We finally did it, and it feels amazing.", "I can't wait to show everyone."],
        "Sad": ["It's a bit disappointing.", "I really thought it would go better.", "We lost something important today.",
                "I miss how things used to be.", "There's nothing more we can do."],
        "Angry": ["This is not acceptable.", "I told you this would happen.", "Stop wasting my time.",
                  "Who approved this without asking me?", "I am done making excuses for them."],
        "Soft": ["Just take your time.", "It's okay, I'm right here.", "Close your eyes and breathe slowly.",
                 "Everything will be fine tonight.", "Let's keep this between us."],
        "Slow": ["Let's go through it step by step.", "First, open the menu on the left.",
                 "Read each line carefully before you answer.", "There is no need to rush this part.",
                 "Now, wait a moment, and then continue."],
        "Hesitant": ["I'm not sure, but maybe we could try.", "Well, um, I guess that might work.",
                     "I don't know if this is the right time.", "Could we, perhaps, think about it more?",
                     "It's possible, I suppose, if nothing changes."],
    ]

    static let toneTopics = [
        "Confident": "Explain something you're great at.",
        "Happy": "Describe a moment that made you laugh.",
        "Sad": "Talk about something you miss.",
        "Angry": "Describe something that really annoys you.",
        "Soft": "Comfort a friend who had a long day.",
        "Slow": "Explain, step by step, how to make tea.",
        "Hesitant": "Answer a question you're unsure about.",
    ]

    static func sentence(for tone: String) -> String {
        toneSentences[tone]?.randomElement() ?? sentences.randomElement()!
    }
}

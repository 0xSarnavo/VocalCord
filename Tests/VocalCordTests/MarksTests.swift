import Foundation
import Testing
@testable import VocalCord

/// Each chip's text as written in the line.
private func chipTexts(_ text: String) -> [String] { Marks.parse(text).chips.map { String(text[$0.range]) } }

private func removing(chip: Int, from text: String) -> String { Marks.removeChip(at: Marks.parse(text).chips[chip].range, in: text) }

private func setting(_ value: String, chip: Int, in text: String) throws -> String {
    try Marks.setChipValue(value, at: Marks.parse(text).chips[chip].range, in: text)
}

private func near(_ times: [WordTime]?, _ expected: [WordTime]) -> Bool {
    guard let times, times.count == expected.count else { return false }
    return zip(times, expected).allSatisfy { abs($0.start - $1.start) < 1e-9 && abs($0.end - $1.end) < 1e-9 }
}

/// Words back to back, each `durations[i]` long, with extra silence after the words in `gaps`.
private func timed(_ durations: [Double], gaps: [Int: Double] = [:]) -> [WordTime] {
    var at = 0.0
    return durations.enumerated().map { index, length in
        defer { at += length + (gaps[index] ?? 0) }
        return WordTime(start: at, end: at + length)
    }
}

private let eight = "one two three four five six seven eight"

// MARK: Parsing

@Test func parsesEveryTagForm() throws {
    let text = "[confident] Hi [pause 0.5] there, [breath] [speed 80%]slow words[/speed] and [stress]free[/stress], [say Koo-ber]Kuber[/say]."
    let parsed = Marks.parse(text)
    #expect(parsed.text == text && parsed.problems.isEmpty)
    #expect(parsed.tokens.map(\.text) == ["Hi", "there,", "slow", "words", "and", "free,", "Kuber."])
    #expect(parsed.chips.map(\.kind) == [.direction("confident"), .pause(0.5), .breath, .speed(0.8), .speedEnd, .stress, .stressEnd,
                                         .say("Koo-ber"), .sayEnd])
    #expect(chipTexts(text) == ["[confident]", "[pause 0.5]", "[breath]", "[speed 80%]", "[/speed]", "[stress]", "[/stress]",
                                "[say Koo-ber]", "[/say]"])
    // A token's range spans a tag inside the word.
    #expect(parsed.tokens.map { String(text[$0.range]) } == ["Hi", "there,", "slow", "words", "and", "free[/stress],", "Kuber[/say]."])

    #expect(parsed.spokenTokens == ["Hi", "there,", "slow", "words", "and", "free,", "Koo-ber."])
    #expect(parsed.spokenText == "[confident] Hi there, slow words and free, Koo-ber.")
    #expect(parsed.stressWords == ["free"])
    #expect(parsed.renderKey == "[confident] Hi there, slow words and free, Koo-ber.\nstress: free")
    #expect(parsed.marks == ScriptMarks(pauses: [.init(after: 0, seconds: 0.5), .init(after: 1, seconds: Marks.breathSeconds)],
                                        speeds: [.init(first: 2, last: 3, rate: 0.8)], stresses: [.init(first: 5, last: 5)]))
    #expect(parsed.tokens.map(\.speed) == [nil, nil, 0.8, 0.8, nil, nil, nil])
    #expect(parsed.tokens.map(\.stress) == [false, false, false, false, false, true, false])
    #expect(parsed.tokens.map(\.say) == [nil, nil, nil, nil, nil, nil, "Koo-ber"])
    #expect(parsed.tokens.map(\.spoken) == (0..<7).map { $0..<$0 + 1 })
    #expect(Marks.plain(text) == "Hi there, slow words and free, Kuber.")
}

@Test func marksRequestMatchesTheEngine() throws {
    let marks = ScriptMarks(pauses: [.init(after: 3, seconds: 0.5)], speeds: [.init(first: 5, last: 7, rate: 0.8)],
                            stresses: [.init(first: 2, last: 2)])
    let request = marks.request()
    #expect(Set(request.keys) == ["pauses", "speeds", "stresses"] && JSONSerialization.isValidJSONObject(request))
    let pauses = try #require(request["pauses"] as? [[String: Any]])
    let speeds = try #require(request["speeds"] as? [[String: Any]])
    let stresses = try #require(request["stresses"] as? [[String: Any]])
    #expect(pauses.count == 1 && Set(pauses[0].keys) == ["after", "seconds"])
    #expect(pauses[0]["after"] as? Int == 3 && pauses[0]["seconds"] as? Double == 0.5)
    #expect(speeds.count == 1 && Set(speeds[0].keys) == ["first", "last", "rate"])
    #expect(speeds[0]["first"] as? Int == 5 && speeds[0]["last"] as? Int == 7 && speeds[0]["rate"] as? Double == 0.8)
    #expect(stresses.count == 1 && Set(stresses[0].keys) == ["first", "last"])
    #expect(stresses[0]["first"] as? Int == 2 && stresses[0]["last"] as? Int == 2)
    #expect(!marks.isEmpty && ScriptMarks().isEmpty && Marks.parse("No tags here.").marks.isEmpty)
    #expect((ScriptMarks().request()["pauses"] as? [[String: Any]])?.isEmpty == true)
}

@Test func tagsAllowSpacesAndAnyCase() {
    let text = "[ PAUSE   0.25 ] a [Pause .5s] b [BREATH] [Speed 1.2]c[ / SPEED ] [SPEED 120 %]d[/speed] [speed 80]e[/speed] "
        + "[ Stress ]f[/Stress] [SAY  koo  ber ]g[/say] [Whisper   this  part]"
    let parsed = Marks.parse(text)
    #expect(parsed.problems.isEmpty)
    #expect(parsed.chips.map(\.kind) == [.pause(0.25), .pause(0.5), .breath, .speed(1.2), .speedEnd, .speed(1.2), .speedEnd, .speed(0.8),
                                         .speedEnd, .stress, .stressEnd, .say("koo ber"), .sayEnd, .direction("Whisper this part")])
    #expect(parsed.tokens.map(\.text) == ["a", "b", "c", "d", "e", "f", "g"])
    #expect(parsed.spokenTokens == ["a", "b", "c", "d", "e", "f", "koo", "ber"])
    #expect(parsed.spokenText == "a b c d e f koo ber [Whisper this part]")
    #expect(parsed.marks.pauses == [.init(after: -1, seconds: 0.25), .init(after: 0, seconds: 0.5), .init(after: 1, seconds: 0.4)])
    #expect(parsed.marks.speeds == [.init(first: 2, last: 2, rate: 1.2), .init(first: 3, last: 3, rate: 1.2), .init(first: 4, last: 4, rate: 0.8)])
    #expect(parsed.marks.stresses == [.init(first: 5, last: 5)])
    // Words that only start like a command are directions.
    #expect(Marks.parse("[speedy] [saying hi] [pauses] [stress it] go").chips.map(\.kind)
        == [.direction("speedy"), .direction("saying hi"), .direction("pauses"), .direction("stress it")])
}

@Test func problemsAreReportedNotThrown() {
    func check(_ text: String) -> ParsedLine { Marks.parse(text) }

    let unclosed = check("[speed 80%]a b")
    #expect(unclosed.problems == ["A [speed] isn't closed."] && unclosed.marks.isEmpty && unclosed.tokens.allSatisfy { $0.speed == nil })
    #expect(unclosed.spokenText == "a b")
    #expect(check("a[/stress] b").problems == ["A [/stress] has no [stress] before it."])
    let unclosedSay = check("[stress]a [say X]b")
    #expect(unclosedSay.problems == ["A [stress] isn't closed.", "A [say] isn't closed."] && unclosedSay.spokenTokens == ["a", "b"])

    // A wrap nested in its own kind does nothing; the outer one holds.
    let nested = check("[speed 80%]a [speed 120%]b[/speed] c[/speed]")
    #expect(nested.problems == ["A [speed] can't sit inside another [speed]."])
    #expect(nested.marks.speeds == [.init(first: 0, last: 2, rate: 0.8)] && nested.tokens.allSatisfy { $0.speed == 0.8 })
    #expect(check("[stress]a [stress]b[/stress][/stress]").problems == ["A [stress] can't sit inside another [stress]."])

    // Values out of range are clamped and reported once; unreadable ones do nothing.
    let long = check("[pause 12] a [pause 0.01] b")
    #expect(long.problems == ["Pause must be 0.05 to 10 seconds."] && long.chips.map(\.kind) == [.pause(12), .pause(0.01)])
    #expect(long.marks.pauses == [.init(after: -1, seconds: 10), .init(after: 0, seconds: 0.05)])
    let unreadable = check("[pause soon] a [pause] b")
    #expect(unreadable.problems == ["Write a pause in seconds, as [pause 0.5]."] && unreadable.marks.isEmpty)
    #expect(unreadable.chips.map(\.kind) == [.pause(0), .pause(0)] && unreadable.spokenText == "a b")
    let fast = check("[speed 300%]a[/speed]")
    #expect(fast.problems == ["Speed must be 50% to 200%."] && fast.marks.speeds == [.init(first: 0, last: 0, rate: 2)])
    #expect(fast.chips.map(\.kind) == [.speed(3), .speedEnd])
    let vague = check("[speed fast]a[/speed]")
    #expect(vague.problems == ["Write a speed as a percent, as [speed 80%]."] && vague.marks.isEmpty && vague.chips.map(\.kind) == [.speed(1), .speedEnd])
    let blank = check("[say]Kuber[/say]")
    #expect(blank.problems == ["Write how to say it, as [say Koo-ber]Kuber[/say]."] && blank.spokenTokens == ["Kuber"] && blank.tokens[0].say == nil)
    let empty = check("[stress][/stress] a")
    #expect(empty.problems == ["A [stress] has no words in it."] && empty.marks.isEmpty)
    let stray = check("a [b c")
    #expect(stray.problems == ["A [ or ] isn't part of a tag."] && stray.tokens.map(\.text) == ["a", "[b", "c"])
    #expect(check("a [] b").problems == ["A [ or ] isn't part of a tag."])

    // Stress and say may sit inside a speed.
    let inside = check("[speed 80%]a [stress]b[/stress] [say C]c[/say][/speed]")
    #expect(inside.problems.isEmpty && inside.spokenTokens == ["a", "b", "C"])
    #expect(inside.marks.speeds == [.init(first: 0, last: 2, rate: 0.8)] && inside.marks.stresses == [.init(first: 1, last: 1)])
}

@Test func renderKeyIgnoresWhatsDoneAfterRendering() {
    let base = Marks.parse("Take it slow, friend.")
    #expect(base.renderKey == "Take it slow, friend." && base.marks.isEmpty)
    for text in ["Take it [pause 0.5] slow, friend.", "[speed 80%]Take it[/speed] slow, friend.", "Take it slow, [breath] friend.",
                 "Take   it slow,\tfriend. [pause 2]", "[speed 120%]Take it slow, friend.[/speed]"] {
        let parsed = Marks.parse(text)
        #expect(parsed.spokenText == base.spokenText && parsed.renderKey == base.renderKey && !parsed.marks.isEmpty)
    }
    // Stress asks the voice for emphasis, so new stressed words need a new render. The lift is a mark: stressing another
    // "the", or the comma moving out of the wrap, doesn't.
    let stressed = Marks.parse("Take [stress]it[/stress] slow, friend.")
    #expect(stressed.renderKey != base.renderKey && stressed.renderKey == "Take it slow, friend.\nstress: it")
    let first = Marks.parse("[stress]the[/stress] cat and the dog"), second = Marks.parse("the cat and [stress]the[/stress] dog")
    #expect(first.renderKey == second.renderKey && first.marks.stresses != second.marks.stresses)
    #expect(Marks.parse("[stress]free,[/stress] now").renderKey == Marks.parse("[stress]free[/stress], now").renderKey)
    // Directions and respellings change what the voice reads.
    let directed = Marks.parse("[whisper] Take it slow, friend.")
    #expect(directed.spokenText == "[whisper] Take it slow, friend." && directed.renderKey != base.renderKey)
    #expect(Marks.parse("Take it [say slo]slow[/say], friend.").spokenText == "Take it slo, friend.")
    // Parentheses are plain text.
    let sigh = Marks.parse("Well (sigh) okay")
    #expect(sigh.tokens.map(\.text) == ["Well", "(sigh)", "okay"] && sigh.spokenText == "Well (sigh) okay" && Marks.plain("Well (sigh) okay") == "Well (sigh) okay")
    // A tag splits words, but punctuation stays with its word.
    let glued = Marks.parse("Hello[confident], world a[calm]b")
    #expect(glued.tokens.map(\.text) == ["Hello,", "world", "a", "b"] && glued.spokenText == "Hello, [confident] world a [calm] b")
    #expect(Marks.plain("[confident] Hi [pause 0.5] [say Koo-ber]Kuber[/say], (sigh) okay") == "Hi Kuber, (sigh) okay")
}

@Test func spokenTokensAreTheSpokenTextsWords() {
    for text in ["[confident] Hi [pause 0.5] there, [speed 80%]slow [stress]words[/stress][/speed] and [say Koo ber]Kuber[/say].",
                 "“[say Ha-vee-er]Javier[/say],” she said [whisper this part] softly[calm].", "[breath]", ""] {
        let parsed = Marks.parse(text)
        let words = parsed.spokenText.replacing(/\[[^\[\]]*\]/, with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
        #expect(words == parsed.spokenTokens)
        #expect(parsed.marks.pauses.allSatisfy { (-1..<parsed.spokenTokens.count).contains($0.after) })
    }
}

@Test func sayGroupsShareTheirSpokenWords() {
    // Several display words, several spoken words; the comma outside the wrap stays.
    let javier = Marks.parse("Meet [say Ha-vee-er Gar-see-a]Javier García[/say], please.")
    #expect(javier.tokens.map(\.text) == ["Meet", "Javier", "García,", "please."])
    #expect(javier.spokenTokens == ["Meet", "Ha-vee-er", "Gar-see-a,", "please."])
    #expect(javier.tokens.map(\.spoken) == [0..<1, 1..<3, 1..<3, 3..<4])
    #expect(javier.tokens.map(\.say) == [nil, "Ha-vee-er Gar-see-a", "Ha-vee-er Gar-see-a", nil])
    #expect(Marks.plain(javier.text) == "Meet Javier García, please.")

    // Two display words, one spoken.
    #expect(Marks.parse("Meet [say Ja-vier]Javier Garcia[/say] now").tokens.map(\.spoken) == [0..<1, 1..<2, 1..<2, 2..<3])
    // One display word, two spoken: the marks count spoken words.
    let kuber = Marks.parse("[say Koo ber]Kuber[/say] runs [pause 0.5] fast")
    #expect(kuber.spokenTokens == ["Koo", "ber", "runs", "fast"] && kuber.tokens.map(\.spoken) == [0..<2, 2..<3, 3..<4])
    #expect(kuber.marks.pauses == [.init(after: 2, seconds: 0.5)])
    #expect(Marks.parse("[speed 80%][say Koo ber]Kuber[/say] runs[/speed] fast").marks.speeds == [.init(first: 0, last: 2, rate: 0.8)])
    // Stress words are the display words; the lift covers the respelling.
    let stressed = Marks.parse("[stress][say Koo-ber]Kuber[/say][/stress] runs")
    #expect(stressed.stressWords == ["Kuber"] && stressed.marks.stresses == [.init(first: 0, last: 0)] && stressed.spokenText == "Koo-ber runs")
    // Quotes outside the wrap are kept.
    let quoted = Marks.parse("“[say Koo-ber]Kuber[/say]”")
    #expect(quoted.tokens.map(\.text) == ["“Kuber”"] && quoted.spokenTokens == ["“Koo-ber”"])
    // A pause inside a group comes after it.
    let split = Marks.parse("[say Koo-ber]Ku [pause 0.5] ber[/say] now")
    #expect(split.spokenTokens == ["Koo-ber", "now"] && split.marks.pauses == [.init(after: 0, seconds: 0.5)])
}

@Test func unicodeIsIndexedByCharacter() throws {
    let text = "Café [pause 0.3] nai\u{308}ve “quotes” — 🎉 emoji, it’s [stress]résumé[/stress]! 👍🏽"
    let parsed = Marks.parse(text)
    #expect(parsed.problems.isEmpty)
    #expect(parsed.tokens.map(\.text) == ["Café", "naïve", "“quotes”", "—", "🎉", "emoji,", "it’s", "résumé!", "👍🏽"])
    #expect(parsed.tokens.map { String(text[$0.range]) }[7] == "résumé[/stress]!")
    #expect(chipTexts(text) == ["[pause 0.3]", "[stress]", "[/stress]"])
    #expect(parsed.stressWords == ["résumé"] && parsed.marks.stresses == [.init(first: 7, last: 7)])
    #expect(parsed.marks.pauses == [.init(after: 0, seconds: 0.3)])
    #expect(parsed.spokenText == "Café naïve “quotes” — 🎉 emoji, it’s résumé! 👍🏽")

    #expect(try Marks.setStress(tokens: 2...2, in: text)
        == "Café [pause 0.3] nai\u{308}ve “[stress]quotes[/stress]” — 🎉 emoji, it’s [stress]résumé[/stress]! 👍🏽")
    #expect(try Marks.addPause(0.5, after: 4, in: text) == "Café [pause 0.3] nai\u{308}ve “quotes” — 🎉 [pause 0.5] emoji, it’s [stress]résumé[/stress]! 👍🏽")
    #expect(try Marks.addPause(0.5, after: 8, in: text).hasSuffix("! 👍🏽 [pause 0.5]"))
    #expect(try Marks.setSay("its", tokens: 6...6, in: text).contains(" [say its]it’s[/say] "))
    #expect(try Marks.setStress(tokens: 4...4, in: text).contains(" [stress]🎉[/stress] "))   // all punctuation: wrapped whole
    #expect(removing(chip: 1, from: text) == "Café [pause 0.3] nai\u{308}ve “quotes” — 🎉 emoji, it’s résumé! 👍🏽")
}

// MARK: Editing

@Test func addPauseAndBreathKeepTidySpaces() throws {
    let text = "Hello there friend"
    #expect(try Marks.addPause(0.5, after: 0, in: text) == "Hello [pause 0.5] there friend")
    #expect(try Marks.addPause(0.5, after: -1, in: text) == "[pause 0.5] Hello there friend")
    #expect(try Marks.addPause(0.5, after: 2, in: text) == "Hello there friend [pause 0.5]")
    #expect(try Marks.addPause(20, after: 0, in: text) == "Hello [pause 10] there friend")
    #expect(try Marks.addPause(0.01, after: 0, in: text) == "Hello [pause 0.05] there friend")
    #expect(try Marks.addPause(1 / 3, after: 0, in: text) == "Hello [pause 0.33] there friend")
    #expect(try Marks.addBreath(after: 1, in: text) == "Hello there [breath] friend")
    #expect(Marks.parse(try Marks.addPause(1.5, after: 1, in: text)).marks.pauses == [.init(after: 1, seconds: 1.5)])

    #expect(try Marks.addPause(0.5, after: 0, in: "Hello   there") == "Hello [pause 0.5] there")
    #expect(try Marks.addPause(0.5, after: -1, in: "  Hello there") == "[pause 0.5] Hello there")
    // After a word, outside the wraps closing on it; at the start, outside the wraps opening there.
    #expect(try Marks.addPause(0.5, after: 0, in: "[stress]free[/stress], now") == "[stress]free[/stress], [pause 0.5] now")
    #expect(try Marks.addPause(0.5, after: 1, in: "[speed 80%]a b[/speed] c") == "[speed 80%]a b[/speed] [pause 0.5] c")
    #expect(try Marks.addPause(0.5, after: -1, in: "[stress]Hi[/stress] you") == "[pause 0.5] [stress]Hi[/stress] you")
    // Inside a say group, after the group.
    #expect(try Marks.addPause(0.5, after: 0, in: "[say Ja-vier]Javier Garcia[/say] came") == "[say Ja-vier]Javier Garcia[/say] [pause 0.5] came")
    #expect(try Marks.addPause(0.5, after: -1, in: "") == "[pause 0.5]")
    #expect(try Marks.addBreath(after: -1, in: "[confident]") == "[confident] [breath]")

    for token in [3, -2] { #expect(throws: AppError.self) { try Marks.addPause(0.5, after: token, in: text) } }
    #expect(throws: AppError.self) { try Marks.addBreath(after: 3, in: text) }
    for seconds in [Double.nan, .infinity] { #expect(throws: AppError.self) { try Marks.addPause(seconds, after: 0, in: text) } }
}

@Test func wrapsHugTheWordsWithPunctuationOutside() throws {
    let text = "I am free, really"
    #expect(try Marks.setStress(tokens: 2...2, in: text) == "I am [stress]free[/stress], really")
    #expect(try Marks.setStress(tokens: 1...2, in: text) == "I [stress]am free[/stress], really")
    #expect(try Marks.setStress(tokens: 0...0, in: "“free”") == "“[stress]free[/stress]”")
    #expect(try Marks.setSpeed(0.8, tokens: 0...1, in: "Hello, world.") == "[speed 80%]Hello, world[/speed].")
    #expect(try Marks.setSay("Koo-ber", tokens: 1...1, in: "Meet Kuber, now") == "Meet [say Koo-ber]Kuber[/say], now")
    #expect(try Marks.setSay("  Koo   ber ", tokens: 0...0, in: "Kuber") == "[say Koo ber]Kuber[/say]")

    // A new wrap replaces one of its kind it overlaps, and leaves others.
    #expect(try Marks.setStress(tokens: 1...1, in: "[stress]totally free[/stress] now") == "totally [stress]free[/stress] now")
    #expect(try Marks.setSpeed(1.5, tokens: 1...2, in: "[speed 80%]a b[/speed] c") == "a [speed 150%]b c[/speed]")
    #expect(try Marks.setSpeed(1.2, tokens: 2...2, in: "[speed 80%]a[/speed] b c") == "[speed 80%]a[/speed] b [speed 120%]c[/speed]")
    #expect(try Marks.setSay("B", tokens: 0...1, in: "[say A]x[/say] y") == "[say B]x y[/say]")

    // Speed goes outside stress, stress outside say, unless that would cross a wrap.
    #expect(try Marks.setSpeed(0.8, tokens: 0...0, in: "[stress]free[/stress], now") == "[speed 80%][stress]free[/stress][/speed], now")
    #expect(try Marks.setStress(tokens: 0...0, in: "[speed 80%]free[/speed], now") == "[speed 80%][stress]free[/stress][/speed], now")
    #expect(try Marks.setSay("Koo-ber", tokens: 0...0, in: "[speed 80%][stress]Kuber[/stress][/speed]")
        == "[speed 80%][stress][say Koo-ber]Kuber[/say][/stress][/speed]")
    #expect(try Marks.setSpeed(0.8, tokens: 0...0, in: "[stress]a b[/stress]") == "[stress][speed 80%]a[/speed] b[/stress]")
    #expect(try Marks.setSpeed(0.8, tokens: 0...1, in: "[stress]a b[/stress]") == "[speed 80%][stress]a b[/stress][/speed]")
    #expect(Marks.parse(try Marks.setSpeed(0.8, tokens: 0...0, in: "[stress]a b[/stress]")).problems.isEmpty)

    // Speeds are clamped and written as a percent.
    #expect(try Marks.setSpeed(5, tokens: 0...0, in: "go") == "[speed 200%]go[/speed]")
    #expect(try Marks.setSpeed(0.1, tokens: 0...0, in: "go") == "[speed 50%]go[/speed]")

    for range in [0...4, -1...0, 4...4] { #expect(throws: AppError.self) { try Marks.setStress(tokens: range, in: text) } }
    #expect(throws: AppError.self) { try Marks.setSpeed(.nan, tokens: 0...0, in: text) }
    #expect(throws: AppError.self) { try Marks.setSay("", tokens: 0...0, in: text) }
    #expect(throws: AppError.self) { try Marks.setSay("Koo[ber", tokens: 0...0, in: text) }
}

@Test func removingAChipTakesItsPartner() {
    let speed = "[speed 80%]a b[/speed] c"
    #expect(removing(chip: 0, from: speed) == "a b c" && removing(chip: 1, from: speed) == "a b c")
    #expect(removing(chip: 0, from: "[speed 80%] a b [/speed] c") == "a b c")
    #expect(removing(chip: 0, from: "[stress]free[/stress], now") == "free, now")
    #expect(removing(chip: 1, from: "Meet [say Koo-ber]Kuber[/say], now") == "Meet Kuber, now")
    #expect(removing(chip: 0, from: "a [pause 0.5] b") == "a b")
    #expect(removing(chip: 0, from: "[pause 0.5] a") == "a")
    #expect(removing(chip: 0, from: "a [breath]") == "a")
    #expect(removing(chip: 0, from: "[confident] go") == "go")
    #expect(removing(chip: 0, from: "a[confident]b") == "a b")   // still two words
    #expect(removing(chip: 0, from: "a [/stress] b") == "a b")
    // A nested pair goes as a pair.
    #expect(removing(chip: 1, from: "[speed 80%]a [speed 120%]b[/speed] c[/speed]") == "[speed 80%]a b c[/speed]")
    // A range that isn't a tag changes nothing.
    let text = "a [pause 0.5] b"
    #expect(Marks.removeChip(at: text.startIndex..<text.index(after: text.startIndex), in: text) == text)
}

@Test func chipValuesCanBeChanged() throws {
    let pause = "a [pause 0.5] b"
    #expect(try setting("1.25", chip: 0, in: pause) == "a [pause 1.25] b")
    #expect(try setting(" 2s ", chip: 0, in: pause) == "a [pause 2] b")
    #expect(try setting("20", chip: 0, in: pause) == "a [pause 10] b")
    let speed = "[speed 80%]a[/speed]"
    #expect(try setting("120", chip: 0, in: speed) == "[speed 120%]a[/speed]")
    #expect(try setting("75%", chip: 0, in: speed) == "[speed 75%]a[/speed]")
    #expect(try setting("0.9", chip: 0, in: speed) == "[speed 90%]a[/speed]")
    #expect(try setting("1.5x", chip: 0, in: speed) == "[speed 150%]a[/speed]")
    #expect(try setting("Koo-burr", chip: 0, in: "[say Koo-ber]Kuber[/say]") == "[say Koo-burr]Kuber[/say]")

    #expect(throws: AppError.self) { try setting("soon", chip: 0, in: pause) }
    #expect(throws: AppError.self) { try setting("fast", chip: 0, in: speed) }
    #expect(throws: AppError.self) { try setting("90", chip: 1, in: speed) }   // the closing tag
    #expect(throws: AppError.self) { try setting(" ", chip: 0, in: "[say Koo-ber]Kuber[/say]") }
    for chip in [0, 1] { #expect(throws: AppError.self) { try setting("1", chip: chip, in: "[breath] a [confident]") } }
    #expect(throws: AppError.self) { try Marks.setChipValue("1", at: pause.startIndex..<pause.index(after: pause.startIndex), in: pause) }
}

// MARK: Word times

@Test func displayTimesShareASayGroupByLength() {
    let plain = Marks.parse("a b c"), times = timed([0.5, 0.5, 0.5])
    #expect(Marks.displayTimes(plain, spoken: times) == times)

    // One spoken word read as two display words, split 2:8 by length.
    let group = Marks.parse("Meet [say Josmithers]Jo Smithers[/say] now")
    let spoken = [WordTime(start: 0, end: 0.5), WordTime(start: 1, end: 2), WordTime(start: 2.5, end: 3)]
    #expect(near(Marks.displayTimes(group, spoken: spoken), [WordTime(start: 0, end: 0.5), WordTime(start: 1, end: 1.2),
                                                             WordTime(start: 1.2, end: 2), WordTime(start: 2.5, end: 3)]))
    // Two spoken words read as one display word.
    let kuber = Marks.parse("[say Koo ber]Kuber[/say] runs")
    #expect(near(Marks.displayTimes(kuber, spoken: [WordTime(start: 0, end: 0.4), WordTime(start: 0.4, end: 0.9), WordTime(start: 1, end: 1.5)]),
                 [WordTime(start: 0, end: 0.9), WordTime(start: 1, end: 1.5)]))

    // Times made for other text.
    #expect(Marks.displayTimes(group, spoken: timed([0.5, 0.5, 0.5, 0.5])) == nil)
    #expect(Marks.displayTimes(Marks.parse("a b"), spoken: times) == nil)
    #expect(Marks.displayTimes(kuber, spoken: timed([0.5, 0.5])) == nil)
}

// MARK: Pace

@Test func paceAgainstTheTarget() throws {
    let steady = try #require(Pace.report(Marks.parse(eight), times: timed(Array(repeating: 0.5, count: 8)), target: 120))
    #expect(steady == PaceReport(wordsPerMinute: 120, target: 120, rushed: [], dragging: [], gaps: [], verdict: nil))
    // Speech inside a speed span is judged as played.
    #expect(Pace.report(Marks.parse("[speed 50%]one two three four[/speed] five six seven eight"),
                        times: timed(Array(repeating: 0.5, count: 8)), target: 120) == steady)

    // Fast at the end: windows from word 3 on are over 25% faster. Window 2 is exactly 25% and doesn't count.
    let ten = "one two three four five six seven eight nine ten"
    let rushed = try #require(Pace.report(Marks.parse(ten), times: timed(Array(repeating: 0.5, count: 5) + Array(repeating: 0.25, count: 5)), target: 120))
    #expect(rushed.rushed == [3...9] && rushed.dragging.isEmpty && rushed.wordsPerMinute == 160)
    #expect(rushed.verdict == "160 words a minute, 33% faster than your usual 120.")
    let dragging = try #require(Pace.report(Marks.parse(ten), times: timed(Array(repeating: 0.5, count: 5) + Array(repeating: 1, count: 5)), target: 120))
    #expect(dragging.dragging == [3...9] && dragging.rushed.isEmpty && dragging.wordsPerMinute == 80)
    #expect(dragging.verdict == "80 words a minute, 33% slower than your usual 120.")

    #expect(Pace.report(Marks.parse("one two three"), times: timed([0.5, 0.5, 0.5]), target: 120) == nil)
    #expect(Pace.report(Marks.parse(eight), times: timed([0.5, 0.5, 0.5, 0.5]), target: 120) == nil)
    #expect(Pace.report(Marks.parse(eight), times: timed(Array(repeating: 0.5, count: 8)), target: 0) == nil)
}

@Test func paceLeavesOutTheScriptsOwnPauses() throws {
    let halves = Array(repeating: 0.5, count: 8)
    // The second of silence the script asked for isn't speaking time or a gap.
    let paused = try #require(Pace.report(Marks.parse("one two three four [pause 1] five six seven eight"),
                                          times: timed(halves, gaps: [3: 1]), target: 120))
    #expect(paused.wordsPerMinute == 120 && paused.gaps.isEmpty && paused.verdict == nil && paused.dragging.isEmpty)
    let breath = try #require(Pace.report(Marks.parse("one two three four [breath] five six seven eight"),
                                          times: timed(halves, gaps: [3: Marks.breathSeconds]), target: 120))
    #expect(abs(breath.wordsPerMinute - 120) < 1e-9 && breath.gaps.isEmpty)

    // Unasked silence over 1.2 s is a gap, and not slow speech; under it is neither.
    let gap = try #require(Pace.report(Marks.parse(eight), times: timed(halves, gaps: [3: 1.5]), target: 120))
    #expect(gap.gaps == [PaceReport.Gap(after: 3, seconds: 1.5)] && gap.dragging.isEmpty)
    #expect(abs(gap.wordsPerMinute - 8 / 5.5 * 60) < 1e-9)
    #expect(try #require(Pace.report(Marks.parse(eight), times: timed(halves, gaps: [3: 1]), target: 120)).gaps.isEmpty)
    // A longer silence than the script asked for: the rest is a gap.
    let longer = try #require(Pace.report(Marks.parse("one two three four [pause 1] five six seven eight"),
                                          times: timed(halves, gaps: [3: 2.5]), target: 120))
    #expect(longer.gaps == [PaceReport.Gap(after: 3, seconds: 1.5)])
}

@Test func paceTargetPrefersTheProjects() {
    #expect(Pace.target(projectOverride: 130, referencePace: 2.5) == 130)
    #expect(Pace.target(projectOverride: nil, referencePace: 2.5) == 150)
    #expect(Pace.target(projectOverride: 0, referencePace: 2.5) == 150)
    #expect(Pace.target(projectOverride: .nan, referencePace: nil) == nil)
    #expect(Pace.target(projectOverride: nil, referencePace: 0) == nil)
    #expect(Pace.target(projectOverride: nil, referencePace: nil) == nil)
}

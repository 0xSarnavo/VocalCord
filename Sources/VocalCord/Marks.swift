import Foundation

// Script commands live in a line's text as bracketed tags: [pause 0.5], [breath], [speed 80%]…[/speed],
// [stress]…[/stress] and [say Koo-ber]Kuber[/say]. Any other [label] is a tone direction, read by the engine as before.
// The voice is given the words with each respelling swapped in and the stressed words named. Pauses, speed changes and
// the stress lift are applied to the render afterwards, so changing them needs no new render.

/// When a word starts and ends in a render, in seconds.
struct WordTime: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
}

/// What's done to a render after it's made, in `ParsedLine.spokenTokens` indices: the engine's `apply_marks` "marks".
struct ScriptMarks: Hashable, Sendable {
    struct Pause: Hashable, Sendable {
        var after: Int          // -1: before the first word
        var seconds: Double
    }
    struct Span: Hashable, Sendable {
        var first: Int
        var last: Int
        var rate: Double?       // speeds only
    }
    var pauses: [Pause] = []
    var speeds: [Span] = []
    var stresses: [Span] = []

    var isEmpty: Bool { pauses.isEmpty && speeds.isEmpty && stresses.isEmpty }

    func request() -> [String: Any] {
        ["pauses": pauses.map { ["after": $0.after, "seconds": $0.seconds] as [String: Any] },
         "speeds": speeds.map { ["first": $0.first, "last": $0.last, "rate": $0.rate ?? 1] as [String: Any] },
         "stresses": stresses.map { ["first": $0.first, "last": $0.last] }]
    }
}

/// One line's text read for the editor, the render and the marks.
struct ParsedLine: Hashable, Sendable {
    struct Token: Hashable, Sendable {
        var text: String                 // the display word as written, punctuation attached: "Kuber," or "it's"
        var range: Range<String.Index>   // in the line's text; it spans any tag inside the word, as in `free[/stress],`
        var spoken: Range<Int>           // in spokenTokens; a say group's words all have the group's range
        var stress: Bool
        var speed: Double?
        var say: String?                 // the respelling, inside [say …]
    }
    /// Every tag, for the editor to draw as a chip.
    struct Chip: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case pause(Double), breath, speed(Double), speedEnd, stress, stressEnd, say(String), sayEnd, direction(String)
        }
        var kind: Kind
        var range: Range<String.Index>   // the tag's text, brackets included
    }
    var text: String
    var tokens: [Token]                  // display words, tags left out
    var chips: [Chip]
    var spokenTokens: [String]           // the words the voice gets: each say group as its respelling's words
    var spokenText: String               // what's rendered: post-render tags out, respellings in, directions kept
    var stressWords: [String]            // display words inside [stress], punctuation trimmed, for the render request
    var marks: ScriptMarks
    var renderKey: String                // equal keys read the same to the voice: only the marks differ
    var problems: [String]               // plain messages; parsing never throws
}

enum Marks {
    /// No voice has a breath recording yet, so a breath is a short pause.
    static let breathSeconds = 0.4
    static let speeds = 0.5...2.0
    static let pauses = 0.05...10.0

    static func parse(_ text: String) -> ParsedLine { Scan(text).parsed }

    /// Plain text: tags removed, say groups show their display words. For Jev, word counts, the words score and the agents.
    static func plain(_ text: String) -> String { parse(text).tokens.map(\.text).joined(separator: " ") }

    // MARK: Editing

    // Token indices are display-token indices. Each edit returns the new text or throws, and values out of range are
    // clamped, as the timeline's are.

    /// `token` -1 is the start of the line.
    static func addPause(_ seconds: Double, after token: Int, in text: String) throws -> String {
        guard seconds.isFinite else { throw AppError("The pause must be a number.") }
        return try insert("[pause \(format(seconds.clamped(pauses)))]", after: token, in: text)
    }

    static func addBreath(after token: Int, in text: String) throws -> String { try insert("[breath]", after: token, in: text) }

    /// Replaces any speed overlapping those words.
    static func setSpeed(_ rate: Double, tokens: ClosedRange<Int>, in text: String) throws -> String {
        guard rate.isFinite else { throw AppError("The speed must be a number.") }
        return try wrap(.speed, open: "[speed \(percent(rate))%]", tokens: tokens, in: text)
    }

    /// Replaces any stress overlapping those words.
    static func setStress(tokens: ClosedRange<Int>, in text: String) throws -> String {
        try wrap(.stress, open: "[stress]", tokens: tokens, in: text)
    }

    /// Replaces any say overlapping those words.
    static func setSay(_ spoken: String, tokens: ClosedRange<Int>, in text: String) throws -> String {
        let respelled = try respelling(spoken)
        return try wrap(.say, open: "[say \(respelled)]", tokens: tokens, in: text)
    }

    /// Removing either end of a wrap removes the other end too; the words stay. A range that isn't a tag changes nothing.
    static func removeChip(at range: Range<String.Index>, in text: String) -> String {
        let scan = Scan(text)
        guard let tag = scan.tags.firstIndex(where: { $0.range == range }) else { return text }
        return scan.removing([tag, scan.tags[tag].partner ?? tag])
    }

    /// A pause's seconds ("0.75"), a speed's percent ("80", "80%" or "0.8") or a say's respelling.
    static func setChipValue(_ value: String, at range: Range<String.Index>, in text: String) throws -> String {
        let scan = Scan(text)
        guard let index = scan.tags.firstIndex(where: { $0.range == range }) else { throw AppError("That tag is no longer in the line.") }
        let tag: String
        switch scan.tags[index].chip {
        case .pause:
            guard let seconds = seconds(value) else { throw AppError("Write the pause in seconds, such as 0.5.") }
            tag = "[pause \(format(seconds.clamped(pauses)))]"
        case .speed:
            guard let rate = rate(value) else { throw AppError("Write the speed as a percent, such as 80%.") }
            tag = "[speed \(percent(rate))%]"
        case .say:
            tag = "[say \(try respelling(value))]"
        default:
            throw AppError("That tag has no value to change.")
        }
        var text = text
        text.replaceSubrange(range, with: tag)
        return text
    }

    // MARK: Word times

    /// Display-token times from spoken-token times (the engine returns one per spokenTokens entry). A say group's span
    /// is shared across its display words by character count. Nil when the counts don't match: the text has changed.
    static func displayTimes(_ parsed: ParsedLine, spoken: [WordTime]) -> [WordTime]? {
        guard spoken.count == parsed.spokenTokens.count else { return nil }
        let tokens = parsed.tokens
        var times: [WordTime] = []
        var first = 0
        while first < tokens.count {
            let range = tokens[first].spoken
            var end = first + 1
            while end < tokens.count, tokens[end].spoken == range { end += 1 }
            guard !range.isEmpty, range.upperBound <= spoken.count else { return nil }
            let start = spoken[range.lowerBound].start, finish = spoken[range.upperBound - 1].end
            let lengths = tokens[first..<end].map { Double(max($0.text.count, 1)) }
            let total = lengths.reduce(0, +)
            var done = 0.0, at = start
            for (index, length) in lengths.enumerated() {
                done += length
                let next = index == lengths.count - 1 ? finish : start + (finish - start) * done / total
                times.append(WordTime(start: at, end: next))
                at = next
            }
            first = end
        }
        return times
    }

    // MARK: Helpers

    /// A pause's seconds: "0.5", ".5", "2s".
    fileprivate static func seconds(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        return text.wholeMatch(of: /(\d+(?:\.\d+)?|\.\d+)\s*s?/).flatMap { Double($0.1) }
    }

    /// A speed's rate: "80%", "0.8" or "0.8x". No rate is over 10, so a bare number over 10 is a percent: "80" is 80%.
    fileprivate static func rate(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = text.wholeMatch(of: /(\d+(?:\.\d+)?|\.\d+)\s*(%|x)?/), let number = Double(match.1) else { return nil }
        return match.2 == "%" || (match.2 == nil && number > 10) ? number / 100 : number
    }

    fileprivate static func collapse(_ text: Substring) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Seconds to two decimals without trailing zeros: 0.5, 1.25, 10.
    private static func format(_ seconds: Double) -> String { String(format: "%g", (seconds * 100).rounded() / 100) }

    private static func percent(_ rate: Double) -> Int { Int((rate.clamped(speeds) * 100).rounded()) }

    private static func respelling(_ text: String) throws -> String {
        let words = collapse(text[...])
        guard !words.isEmpty else { throw AppError("Write how to say it, such as Koo-ber.") }
        guard !words.contains(where: { $0 == "[" || $0 == "]" }) else { throw AppError("Leave [ and ] out of how to say it.") }
        return words
    }

    private static func insert(_ tag: String, after token: Int, in text: String) throws -> String {
        let scan = Scan(text)
        guard (-1..<scan.words.count).contains(token) else { throw AppError("That word is no longer in the line.") }
        // The voice says a respelling as one, so a pause inside a say group goes after it.
        let last = scan.groups.first { $0.contains(token) }.map { $0.upperBound - 1 } ?? token
        var draft = Draft(text)
        draft.insert(spaced: tag, at: scan.offset(scan.point(boundary: last + 1)))
        return draft.text
    }

    private static func wrap(_ wrap: Wrap, open: String, tokens: ClosedRange<Int>, in text: String) throws -> String {
        let scan = Scan(text)
        guard tokens.lowerBound >= 0, tokens.upperBound < scan.words.count else { throw AppError("Those words are no longer in the line.") }
        // Wraps of one kind can't overlap, so the new one replaces any it touches. An empty one counts as on the word after it.
        let replaced = scan.tags.indices.filter { index in
            let tag = scan.tags[index]
            guard tag.wrap == wrap, tag.opens, let close = tag.partner else { return false }
            return tag.boundary <= tokens.upperBound && max(scan.tags[close].boundary, tag.boundary + 1) > tokens.lowerBound
        }
        let cleared = Scan(scan.removing(replaced.flatMap { [$0, scan.tags[$0].partner ?? $0] }))
        guard tokens.upperBound < cleared.words.count else { throw AppError("Those words are no longer in the line.") }
        let points = cleared.wrapPoints(tokens, wrap)
        let before = String(cleared.text[..<points.lowerBound]) + open
        return before + cleared.text[points] + "[/\(wrap.name)]" + cleared.text[points.upperBound...]
    }
}

// MARK: Reading a line

extension Marks {
    /// A wrap's kind, outermost first: a new speed goes around a stress or say on the same words, a stress around a say.
    fileprivate enum Wrap: Int, CaseIterable {
        case speed, stress, say
        var name: String { ["speed", "stress", "say"][rawValue] }
    }

    /// One bracketed tag.
    fileprivate struct Tag {
        var range: Range<String.Index>
        var chip: ParsedLine.Chip.Kind
        var wrap: Wrap?
        var opens = false
        var value: Double?          // a pause's seconds or a speed's rate, within range; nil when it can't be read
        var problem: String?
        var boundary = 0            // it sits before display token `boundary`; the token count is after the last
        var inside = false          // between two pieces of one display token, as `[/stress]` in `free[/stress],`
        var partner: Int?           // the wrap's other end
        var paired = false          // a wrap that takes effect, not one nested in another of its kind

        init(_ label: String, range: Range<String.Index>) {
            self.range = range
            let lower = label.lowercased()
            if let command = label.wholeMatch(of: /(?i)(pause|speed|say)\b\s*(.*)/) {
                let rest = String(command.2)
                switch command.1.lowercased() {
                case "pause":
                    let seconds = Marks.seconds(rest)
                    chip = .pause(seconds ?? 0)
                    value = seconds?.clamped(Marks.pauses)
                    if let seconds {
                        if !Marks.pauses.contains(seconds) { problem = "Pause must be 0.05 to 10 seconds." }
                    } else {
                        problem = "Write a pause in seconds, as [pause 0.5]."
                    }
                case "speed":
                    let rate = Marks.rate(rest)
                    chip = .speed(rate ?? 1)
                    wrap = .speed
                    opens = true
                    value = rate?.clamped(Marks.speeds)
                    if let rate {
                        if !Marks.speeds.contains(rate) { problem = "Speed must be 50% to 200%." }
                    } else {
                        problem = "Write a speed as a percent, as [speed 80%]."
                    }
                default:
                    chip = .say(rest)
                    wrap = .say
                    opens = true
                    if rest.isEmpty { problem = "Write how to say it, as [say Koo-ber]Kuber[/say]." }
                }
            } else if lower == "breath" {
                chip = .breath
                value = Marks.breathSeconds
            } else if lower == "stress" {
                chip = .stress
                wrap = .stress
                opens = true
            } else if let close = lower.wholeMatch(of: /\/\s*(speed|stress|say)\b.*/) {
                wrap = close.1 == "speed" ? .speed : close.1 == "stress" ? .stress : .say
                chip = close.1 == "speed" ? .speedEnd : close.1 == "stress" ? .stressEnd : .sayEnd
            } else {
                chip = .direction(label)
            }
        }
    }

    /// Text between tags, split at whitespace.
    fileprivate enum Atom { case piece(Range<String.Index>), space, tag(Int) }

    /// A line read into display tokens and tags, with what the edits need to place and remove tags.
    fileprivate struct Scan {
        struct Word {
            var pieces: [Range<String.Index>]   // its text between tags: `free` and `,` in `[stress]free[/stress],`
            var alnum: Bool                      // has a letter or digit, not only punctuation
            var range: Range<String.Index> { pieces[0].lowerBound..<pieces[pieces.count - 1].upperBound }
        }

        let text: String
        private(set) var tags: [Tag] = []
        private(set) var words: [Word] = []
        private(set) var groups: [Range<Int>] = []     // the display tokens each say replaces
        private(set) var parsed: ParsedLine

        init(_ text: String) {
            self.text = text
            var tags: [Tag] = [], atoms: [Atom] = []
            var position = text.startIndex
            for match in text.matches(of: /\[[^\[\]]*\]/) {
                let label = Marks.collapse(text[match.range].dropFirst().dropLast())
                guard !label.isEmpty else { continue }     // [] is text, as the engine reads it
                Self.split(text[position..<match.range.lowerBound], into: &atoms)
                atoms.append(.tag(tags.count))
                tags.append(Tag(label, range: match.range))
                position = match.range.upperBound
            }
            Self.split(text[position...], into: &atoms)
            let words = Self.words(atoms, in: text, tags: &tags)
            var problems = tags.compactMap(\.problem)
            Self.pair(&tags, problems: &problems)
            if words.contains(where: { $0.pieces.contains { text[$0].contains { $0 == "[" || $0 == "]" } } }) {
                problems.append("A [ or ] isn't part of a tag.")
            }

            // What each wrap does to its words.
            let count = words.count
            let texts = words.map { word in word.pieces.map { String(text[$0]) }.joined() }
            var stress = [Bool](repeating: false, count: count), speed = [Double?](repeating: nil, count: count)
            var say = [String?](repeating: nil, count: count)
            var speedSpans: [(words: Range<Int>, rate: Double)] = [], stressSpans: [Range<Int>] = []
            var groups: [Int: (end: Int, said: [String])] = [:]
            for open in tags.indices where tags[open].opens && tags[open].paired {
                guard let close = tags[open].partner, let wrap = tags[open].wrap else { continue }
                let span = tags[open].boundary..<tags[close].boundary
                guard !span.isEmpty else {
                    problems.append("A [\(wrap.name)] has no words in it.")
                    continue
                }
                switch wrap {
                case .speed:
                    guard let rate = tags[open].value else { continue }
                    for index in span { speed[index] = rate }
                    speedSpans.append((span, rate))
                case .stress:
                    for index in span { stress[index] = true }
                    stressSpans.append(span)
                case .say:
                    guard case .say(let respelling) = tags[open].chip, !respelling.isEmpty else { continue }
                    // Punctuation outside the wrap stays with the words: “[say Koo-ber]Kuber[/say]”, says “Koo-ber”.
                    let before = words[span.lowerBound].pieces.filter { $0.upperBound <= tags[open].range.lowerBound }
                    let after = words[span.upperBound - 1].pieces.filter { $0.lowerBound >= tags[close].range.upperBound }
                    var said = respelling.split(separator: " ").map(String.init)
                    said[0] = before.map { String(text[$0]) }.joined() + said[0]
                    said[said.count - 1] += after.map { String(text[$0]) }.joined()
                    groups[span.lowerBound] = (span.upperBound, said)
                    for index in span { say[index] = respelling }
                }
            }

            // The words the voice gets, with each direction before the word it sits before.
            var spokenTokens: [String] = [], spoken = [Range<Int>](repeating: 0..<0, count: count)
            var said = [[String]](repeating: [], count: count + 1)
            for tag in tags { if case .direction(let label) = tag.chip { said[tag.boundary].append("[\(label)]") } }
            var index = 0
            while index < count {
                let group = groups[index] ?? (index + 1, [texts[index]])
                for word in index..<group.end { spoken[word] = spokenTokens.count..<spokenTokens.count + group.said.count }
                spokenTokens += group.said
                said[index] += group.said
                index = group.end
            }

            var marks = ScriptMarks()
            for tag in tags {
                guard let seconds = tag.value, tag.wrap == nil else { continue }   // pauses and breaths
                marks.pauses.append(.init(after: tag.boundary == 0 ? -1 : spoken[tag.boundary - 1].upperBound - 1, seconds: seconds))
            }
            marks.speeds = speedSpans.map {
                .init(first: spoken[$0.words.lowerBound].lowerBound, last: spoken[$0.words.upperBound - 1].upperBound - 1, rate: $0.rate)
            }
            marks.stresses = stressSpans.map {
                .init(first: spoken[$0.lowerBound].lowerBound, last: spoken[$0.upperBound - 1].upperBound - 1, rate: nil)
            }

            let stressWords = (0..<count).filter { stress[$0] }.map { String(Self.core(texts[$0])) }.filter { !$0.isEmpty }
            let spokenText = said.joined().joined(separator: " ")
            var seen = Set<String>()
            self.tags = tags
            self.words = words
            self.groups = groups.map { $0.key..<$0.value.end }.sorted { $0.lowerBound < $1.lowerBound }
            parsed = ParsedLine(
                text: text,
                tokens: (0..<count).map {
                    .init(text: texts[$0], range: words[$0].range, spoken: spoken[$0], stress: stress[$0], speed: speed[$0], say: say[$0])
                },
                chips: tags.map { .init(kind: $0.chip, range: $0.range) },
                spokenTokens: spokenTokens,
                spokenText: spokenText,
                stressWords: stressWords,
                marks: marks,
                renderKey: stressWords.isEmpty ? spokenText : spokenText + "\nstress: " + stressWords.joined(separator: " "),
                problems: problems.filter { seen.insert($0).inserted })
        }

        private static func split(_ part: Substring, into atoms: inout [Atom]) {
            var start: String.Index?
            for index in part.indices {
                if part[index].isWhitespace {
                    if let piece = start { atoms.append(.piece(piece..<index)) }
                    start = nil
                    if case .space? = atoms.last {} else { atoms.append(.space) }
                } else if start == nil {
                    start = index
                }
            }
            if let piece = start { atoms.append(.piece(piece..<part.endIndex)) }
        }

        /// Groups the text into display tokens and places each tag between them. Whitespace always splits tokens, and so
        /// does a tag, except that punctuation stays with the word it touches: `[stress]free[/stress],` is one token.
        private static func words(_ atoms: [Atom], in text: String, tags: inout [Tag]) -> [Word] {
            var words: [Word] = []
            var last: (word: Int, alnum: Bool)?     // the piece before, with no whitespace since
            var waiting: [Int] = []                 // tags since that piece
            for atom in atoms + [.space] {
                switch atom {
                case .tag(let tag):
                    waiting.append(tag)
                case .space:
                    for tag in waiting { tags[tag].boundary = words.count }
                    waiting = []
                    last = nil
                case .piece(let range):
                    let alnum = text[range].contains(where: \.isWordy)
                    if let previous = last, !previous.alnum || !alnum {
                        // A tag before the word's first letter sits before it; after a letter, after it.
                        for tag in waiting {
                            tags[tag].boundary = words[previous.word].alnum ? previous.word + 1 : previous.word
                            tags[tag].inside = true
                        }
                        words[previous.word].pieces.append(range)
                        words[previous.word].alnum = words[previous.word].alnum || alnum
                        last = (previous.word, alnum)
                    } else {
                        for tag in waiting { tags[tag].boundary = words.count }
                        words.append(Word(pieces: [range], alnum: alnum))
                        last = (words.count - 1, alnum)
                    }
                    waiting = []
                }
            }
            return words
        }

        /// Matches each wrap's ends. One nested in another of its kind is matched with its own end but does nothing.
        private static func pair(_ tags: inout [Tag], problems: inout [String]) {
            var open: [Wrap: Int] = [:], nested: [Wrap: [Int]] = [:]
            for index in tags.indices {
                guard let wrap = tags[index].wrap else { continue }
                if tags[index].opens {
                    if open[wrap] == nil {
                        open[wrap] = index
                    } else {
                        nested[wrap, default: []].append(index)
                        problems.append("A [\(wrap.name)] can't sit inside another [\(wrap.name)].")
                    }
                } else if let inner = nested[wrap]?.popLast() {
                    tags[inner].partner = index
                    tags[index].partner = inner
                } else if let outer = open[wrap] {
                    tags[outer].partner = index
                    tags[index].partner = outer
                    tags[outer].paired = true
                    tags[index].paired = true
                    open[wrap] = nil
                } else {
                    problems.append("A [/\(wrap.name)] has no [\(wrap.name)] before it.")
                }
            }
            for index in open.values.sorted() { problems.append("A [\(tags[index].wrap?.name ?? "")] isn't closed.") }
        }

        /// The word without punctuation at either end.
        static func core(_ word: String) -> Substring {
            guard let first = word.firstIndex(where: \.isWordy), let last = word.lastIndex(where: \.isWordy) else { return "" }
            return word[first...last]
        }

        // MARK: For edits

        func offset(_ index: String.Index) -> Int { text.distance(from: text.startIndex, to: index) }

        /// Where a pause goes to sit at `boundary`: after the word before it and any wraps closing on that word, or at
        /// the start, before any wraps opening on the first word.
        func point(boundary: Int) -> String.Index {
            guard !words.isEmpty else { return text.endIndex }
            if boundary == 0 {
                var point = words[0].range.lowerBound
                while let tag = tags.first(where: { $0.range.upperBound == point }), tag.opens { point = tag.range.lowerBound }
                return point
            }
            var point = words[boundary - 1].range.upperBound
            while let tag = tags.first(where: { $0.range.lowerBound == point }), tag.wrap != nil, !tag.opens { point = tag.range.upperBound }
            return point
        }

        /// Where a new wrap's tags go around `tokens`: tight on the words with punctuation outside, and around any wraps
        /// of an inner kind that lie wholly on those words, so nothing crosses.
        func wrapPoints(_ tokens: ClosedRange<Int>, _ wrap: Wrap) -> Range<String.Index> {
            var start = words[tokens.lowerBound].range.lowerBound, end = words[tokens.upperBound].range.upperBound
            if let first = words[tokens.lowerBound].pieces.lazy.compactMap({ self.text[$0].firstIndex(where: \.isWordy) }).first {
                start = first
            }
            if let last = words[tokens.upperBound].pieces.reversed().lazy.compactMap({ self.text[$0].lastIndex(where: \.isWordy) }).first {
                end = text.index(after: last)
            }
            func inner(_ tag: Tag) -> Bool { (tag.wrap?.rawValue ?? -1) > wrap.rawValue && tag.partner != nil }
            while let tag = tags.first(where: { $0.range.upperBound == start }), tag.opens, inner(tag),
                  let close = tag.partner, tags[close].boundary <= tokens.upperBound + 1 {
                start = tag.range.lowerBound
            }
            while let tag = tags.first(where: { $0.range.lowerBound == end }), !tag.opens, inner(tag),
                  let open = tag.partner, tags[open].boundary >= tokens.lowerBound {
                end = tag.range.upperBound
            }
            return start..<end
        }

        /// The text without these tags, tidying the spaces they leave.
        func removing(_ indices: [Int]) -> String {
            var draft = Draft(text)
            // Tags are in text order, so the last goes first and the earlier offsets stay right.
            for index in Set(indices).sorted(by: >) {
                let range = tags[index].range
                draft.remove(offset(range.lowerBound)..<offset(range.upperBound), keepApart: !tags[index].inside)
            }
            return draft.text
        }
    }

    /// A line's characters while an edit changes them.
    fileprivate struct Draft {
        var chars: [Character]
        init(_ text: String) { chars = Array(text) }
        var text: String { String(chars) }

        /// One space each side of the tag, or none at an end of the line.
        mutating func insert(spaced tag: String, at offset: Int) {
            var low = offset, high = offset
            while low > 0, chars[low - 1].isWhitespace { low -= 1 }
            while high < chars.count, chars[high].isWhitespace { high += 1 }
            chars.replaceSubrange(low..<high, with: Array((low == 0 ? "" : " ") + tag + (high == chars.count ? "" : " ")))
        }

        /// Spaces at an end of the line go with the tag, and spaces either side become one. A tag glued between two
        /// words leaves a space, so they stay two words.
        mutating func remove(_ range: Range<Int>, keepApart: Bool) {
            var low = range.lowerBound, high = range.upperBound
            while low > 0, chars[low - 1].isWhitespace { low -= 1 }
            while high < chars.count, chars[high].isWhitespace { high += 1 }
            if low == 0 || high == chars.count {
                chars.removeSubrange(low..<high)
            } else if low < range.lowerBound || high > range.upperBound || keepApart {
                chars.replaceSubrange(low..<high, with: [" "])
            } else {
                chars.removeSubrange(range)
            }
        }
    }
}

extension Character {
    fileprivate var isWordy: Bool { isLetter || isNumber }
}

// MARK: Pace

/// How a played version's pace compares with the speaker's usual pace.
struct PaceReport: Hashable, Sendable {
    struct Gap: Hashable, Sendable {
        var after: Int          // display token
        var seconds: Double
    }
    var wordsPerMinute: Double
    var target: Double                       // words per minute
    var rushed: [ClosedRange<Int>]           // display tokens noticeably faster than the target
    var dragging: [ClosedRange<Int>]         // noticeably slower
    var gaps: [Gap]                          // natural silences over `Pace.longGap` the script didn't ask for
    var verdict: String?                     // one plain sentence; nil when on pace
}

enum Pace {
    static let rushedOver = 1.25, draggingUnder = 0.7, window = 5, longGap = 1.2

    /// From display-token times of the version actually played. Pauses and breaths the script asked for don't count as
    /// speaking time or as gaps; speech inside a speed span is judged as played. Nil with fewer than 4 timed tokens.
    static func report(_ parsed: ParsedLine, times: [WordTime], target: Double) -> PaceReport? {
        let count = parsed.tokens.count
        guard times.count == count, count >= 4, target.isFinite, target > 0,
              times.allSatisfy({ $0.start.isFinite && $0.end.isFinite }) else { return nil }
        // The script's own seconds after each display token.
        var asked = [Double](repeating: 0, count: count)
        for pause in parsed.marks.pauses where pause.after >= 0 {
            if let token = parsed.tokens.lastIndex(where: { $0.spoken.contains(pause.after) }) { asked[token] += pause.seconds }
        }
        // Each silence between words: the part the script asked for, as far as the times show it, and the rest.
        var excused = [Double](repeating: 0, count: count), natural = [Double](repeating: 0, count: count)
        for index in 0..<count - 1 {
            let gap = max(0, times[index + 1].start - times[index].end)
            excused[index] = min(asked[index], gap)
            natural[index] = gap - excused[index]
        }
        let speaking = times[count - 1].end - times[0].start - excused.reduce(0, +)
        guard speaking > 0 else { return nil }
        let wordsPerMinute = Double(count) / speaking * 60
        let gaps = (0..<count - 1).filter { natural[$0] > longGap }.map { PaceReport.Gap(after: $0, seconds: natural[$0]) }

        // Each run of `window` words against the target. A long gap is reported as a gap, not as slow speech.
        var rushed: [ClosedRange<Int>] = [], dragging: [ClosedRange<Int>] = []
        if count >= window {
            for first in 0...(count - window) {
                let last = first + window - 1
                let silence = (first..<last).reduce(0.0) { $0 + excused[$1] + (natural[$1] > longGap ? natural[$1] : 0) }
                let seconds = times[last].end - times[first].start - silence
                guard seconds > 0 else { continue }
                let ratio = Double(window) / seconds * 60 / target
                if ratio > rushedOver { merge(first...last, into: &rushed) }
                if ratio < draggingUnder { merge(first...last, into: &dragging) }
            }
        }

        let ratio = wordsPerMinute / target
        var verdict: String?
        if ratio > rushedOver || ratio < draggingUnder {
            let change = Int((abs(ratio - 1) * 100).rounded())
            verdict = "\(Int(wordsPerMinute.rounded())) words a minute, \(change)% \(ratio > 1 ? "faster" : "slower") than your usual "
                + "\(Int(target.rounded()))."
        }
        return PaceReport(wordsPerMinute: wordsPerMinute, target: target, rushed: rushed, dragging: dragging, gaps: gaps, verdict: verdict)
    }

    /// The project's own target, else the take's pace (words a second, `Scores.referencePace`) as words a minute.
    static func target(projectOverride: Double?, referencePace: Double?) -> Double? {
        if let projectOverride, projectOverride.isFinite, projectOverride > 0 { return projectOverride }
        if let referencePace, referencePace.isFinite, referencePace > 0 { return referencePace * 60 }
        return nil
    }

    /// Overlapping or touching windows make one range.
    private static func merge(_ range: ClosedRange<Int>, into ranges: inout [ClosedRange<Int>]) {
        if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
            ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
        } else {
            ranges.append(range)
        }
    }
}

import AppKit
import SwiftUI

// A script line with each tag drawn as a chip. Canonical text (tags written out, as Marks reads them) goes in and comes
// out. Inside, each tag is one attachment character carrying its tag text, and the text going out is always rebuilt
// from those, so what's shown can't drift from what's saved.

/// One line of the script, edited in a row (`.row`) or read along while it plays (`.read`). Values in, closures out.
struct ScriptTextView: NSViewRepresentable {
    enum Style {
        /// Editable, 13 pt like the rest of a table row, wraps and grows in height like a vertical TextField.
        case row
        /// Not editable but selectable, large, with generous line height.
        case read
    }

    var text: String
    var style: Style
    /// Display tokens lit so far while this line plays: tokens up to and including `lit` draw in Theme.text, the rest
    /// in Theme.secondary. Nil when the line isn't playing. Ignored while the user is editing.
    var lit: Int? = nil
    var placeholder = "Text"
    /// Every edit, as canonical text.
    var onChange: (String) -> Void = { _ in }
    /// Return (no newline is inserted) or losing focus, only when the text changed since focus or the last commit.
    var onCommit: () -> Void = {}
    /// A command from the menu or the [ list changed the text: apply it and commit it right away.
    var onCommand: (String) -> Void = { _ in }
    /// `.read`: a click, not a drag, on a display word.
    var onWordClick: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> ScriptTextNSView {
        let view = ScriptTextNSView(style: style)
        update(view)
        return view
    }

    func updateNSView(_ view: ScriptTextNSView, context: Context) { update(view) }

    static func dismantleNSView(_ view: ScriptTextNSView, coordinator: ()) { view.closeOverlays() }

    /// The column's width, and the height of the wrapped lines at that width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ScriptTextNSView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? view.naturalWidth()
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    private func update(_ view: ScriptTextNSView) {
        view.style = style
        view.placeholder = placeholder
        view.onChange = onChange
        view.onCommit = onCommit
        view.onCommand = onCommand
        view.onWordClick = onWordClick
        view.update(text: text)
        view.setLit(lit)
    }
}

extension NSAttributedString.Key {
    /// On a chip's attachment character: the tag's text, brackets included.
    static let scriptTag = NSAttributedString.Key("VocalCordScriptTag")
}

// MARK: Display

/// A line's canonical text as the view shows it: each tag one attachment character. Offsets are UTF-16, as
/// NSTextView's are. "Canonical" offsets are in the line's text, "display" offsets in what's shown.
struct ScriptDisplay: Sendable {
    struct Chip: Hashable, Sendable {
        var kind: ParsedLine.Chip.Kind
        var tag: String                     // as written, brackets included
        var range: Range<String.Index>      // in the line's text, for Marks
        var canonical: NSRange
        var location: Int                   // its attachment character
    }
    struct Word: Hashable, Sendable {
        var range: NSRange                  // spans a chip inside the word, as the token's does: `free[/stress],`
        var pieces: [NSRange]               // the word's own characters, chips left out
    }
    enum Wrap: Int, CaseIterable, Sendable { case speed, stress, say }
    struct Underline: Hashable, Sendable {
        var wrap: Wrap
        var level: Int                      // 0 sits nearest the words; a wrap holding inner kinds sits lower
        var ranges: [NSRange]
    }
    /// What a command acts on.
    struct Target: Hashable, Sendable {
        var words: ClosedRange<Int>?        // nil only in a line with no words
        var after: Int                      // where a pause goes: after this word, -1 at the start
    }

    static let attachment: Character = "\u{FFFC}"

    let text: String
    let parsed: ParsedLine
    let string: String
    let length: Int
    let chips: [Chip]
    let words: [Word]
    let underlines: [Underline]

    init(_ text: String) {
        let parsed = Marks.parse(text)
        var string = "", chips: [Chip] = [], position = text.startIndex, length = 0
        for chip in parsed.chips {
            let before = text[position..<chip.range.lowerBound]
            string += before
            length += before.utf16.count
            chips.append(Chip(kind: chip.kind, tag: String(text[chip.range]), range: chip.range,
                              canonical: NSRange(chip.range, in: text), location: length))
            string.append(Self.attachment)
            length += 1
            position = chip.range.upperBound
        }
        string += text[position...]
        length += text[position...].utf16.count
        let words = parsed.tokens.map { Self.word(Self.display(NSRange($0.range, in: text), chips: chips), chips: chips) }
        self.text = text
        self.parsed = parsed
        self.string = string
        self.length = length
        self.chips = chips
        self.words = words
        underlines = Self.underlines(parsed.tokens, words: words, in: string as NSString)
    }

    // MARK: Offsets

    /// A canonical offset inside a tag lands before its chip.
    func display(_ offset: Int) -> Int { Self.display(offset, chips: chips) }

    func display(_ range: NSRange) -> NSRange { Self.display(range, chips: chips) }

    func canonical(_ offset: Int) -> Int {
        offset + chips.reduce(0) { $1.location < offset ? $0 + $1.canonical.length - 1 : $0 }
    }

    func canonical(_ range: NSRange) -> NSRange {
        let low = canonical(range.location)
        return NSRange(location: low, length: canonical(NSMaxRange(range)) - low)
    }

    private static func display(_ offset: Int, chips: [Chip]) -> Int {
        var shift = 0
        for chip in chips {
            if offset >= NSMaxRange(chip.canonical) {
                shift += chip.canonical.length - 1
            } else {
                if offset > chip.canonical.location { return chip.location }
                break
            }
        }
        return offset - shift
    }

    private static func display(_ range: NSRange, chips: [Chip]) -> NSRange {
        let low = display(range.location, chips: chips)
        return NSRange(location: low, length: max(0, display(NSMaxRange(range), chips: chips) - low))
    }

    private static func word(_ range: NSRange, chips: [Chip]) -> Word {
        var pieces: [NSRange] = [], start = range.location
        for chip in chips where NSLocationInRange(chip.location, range) {
            if chip.location > start { pieces.append(NSRange(location: start, length: chip.location - start)) }
            start = chip.location + 1
        }
        if NSMaxRange(range) > start { pieces.append(NSRange(location: start, length: NSMaxRange(range) - start)) }
        return Word(range: range, pieces: pieces)
    }

    // MARK: Words

    /// The display word whose own characters include `index`; nil on a chip or a space.
    func word(at index: Int) -> Int? { words.firstIndex { $0.pieces.contains { NSLocationInRange(index, $0) } } }

    func chip(at index: Int) -> Int? { chips.firstIndex { $0.location == index } }

    /// The words a selection touches. A selection holding only chips and spaces touches none.
    func words(in selection: NSRange) -> ClosedRange<Int>? {
        let touched = words.indices.filter { words[$0].pieces.contains { NSIntersectionRange($0, selection).length > 0 } }
        guard let first = touched.first, let last = touched.last else { return nil }
        return first...last
    }

    /// The last word starting before a caret, the one it sits in or follows; -1 when none does.
    func word(before caret: Int) -> Int { words.lastIndex { $0.range.location < caret } ?? -1 }

    /// The selected words; with only a caret, the word before it, or the first word at the start.
    func target(selection: NSRange) -> Target {
        if let selected = words(in: selection) { return Target(words: selected, after: selected.upperBound) }
        let before = word(before: selection.location)
        if before >= 0 { return Target(words: before...before, after: before) }
        return Target(words: words.isEmpty ? nil : 0...0, after: -1)
    }

    /// The word under the pointer; elsewhere, as for a caret there.
    func target(at index: Int) -> Target {
        if let word = word(at: index) { return Target(words: word...word, after: word) }
        return target(selection: NSRange(location: index, length: 0))
    }

    /// Where the words a target names sit, for anchoring a popover.
    func range(of words: ClosedRange<Int>) -> NSRange {
        let low = self.words[words.lowerBound].range.location
        return NSRange(location: low, length: NSMaxRange(self.words[words.upperBound].range) - low)
    }

    /// The words' own characters to draw lit (up to and including `lit`) and dim (the rest). Chips keep their colours.
    func litRanges(_ lit: Int?) -> (lit: [NSRange], dim: [NSRange]) {
        guard let lit else { return ([], []) }
        var on: [NSRange] = [], off: [NSRange] = []
        for (index, word) in words.enumerated() {
            if index <= lit { on += word.pieces } else { off += word.pieces }
        }
        return (on, off)
    }

    /// Each run of words a wrap covers, under its letters, joined across spaces but broken at chips.
    private static func underlines(_ tokens: [ParsedLine.Token], words: [Word], in string: NSString) -> [Underline] {
        func covers(_ wrap: Wrap, _ token: Int) -> Bool {
            switch wrap {
            case .speed: tokens[token].speed != nil
            case .stress: tokens[token].stress
            case .say: tokens[token].say != nil
            }
        }
        var result: [Underline] = []
        for wrap in Wrap.allCases {
            var first = 0
            while first < tokens.count {
                guard covers(wrap, first) else { first += 1; continue }
                var last = first
                while last + 1 < tokens.count, covers(wrap, last + 1) { last += 1 }
                let run = first...last
                // A speed around a stress sits below it, so the two lines never cross.
                let level = Wrap.allCases.filter { inner in inner.rawValue > wrap.rawValue && run.contains { covers(inner, $0) } }.count
                var ranges: [NSRange] = []
                for piece in run.flatMap({ words[$0].pieces }) {
                    let start = string.rangeOfCharacter(from: .alphanumerics, options: [], range: piece)
                    guard start.location != NSNotFound else { continue }
                    let end = string.rangeOfCharacter(from: .alphanumerics, options: .backwards, range: piece)
                    let core = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
                    if let previous = ranges.last, core.location >= NSMaxRange(previous),
                       string.substring(with: NSRange(location: NSMaxRange(previous), length: core.location - NSMaxRange(previous)))
                           .allSatisfy(\.isWhitespace) {
                        ranges[ranges.count - 1] = NSRange(location: previous.location, length: NSMaxRange(core) - previous.location)
                    } else {
                        ranges.append(core)
                    }
                }
                if !ranges.isEmpty { result.append(Underline(wrap: wrap, level: level, ranges: ranges)) }
                first = last + 1
            }
        }
        return result
    }

    // MARK: Edits

    /// The text after replacing a display range that holds chips, or nil when it holds none and the view can make the
    /// edit itself. A chip goes as one, and a wrap's end takes its other end with it through Marks.removeChip.
    /// `caret` is a canonical offset in the new text.
    func replacing(_ range: NSRange, with replacement: String) -> (text: String, caret: Int)? {
        let gone = chips.indices.filter { NSLocationInRange(chips[$0].location, range) }
        guard !gone.isEmpty else { return nil }
        let removed = (string as NSString).substring(with: range)
        if replacement.isEmpty, removed.allSatisfy({ $0 == Self.attachment || $0.isWhitespace }) {
            // Only chips: Marks removes each, partners too, and tidies the spaces they leave.
            let anchor = solid(before: range.location)
            var text = self.text, alive = Array(chips.indices)
            for chip in gone.reversed() {
                guard let index = alive.firstIndex(of: chip) else { continue }   // already gone with its partner
                let current = Marks.parse(text)
                guard index < current.chips.count else { break }
                let next = Marks.removeChip(at: current.chips[index].range, in: text)
                let lost = current.chips.count - Marks.parse(next).chips.count
                alive.remove(at: index)
                if lost == 2, let partner = partner(of: chip), let other = alive.firstIndex(of: partner) { alive.remove(at: other) }
                text = next
            }
            let after = ScriptDisplay(text)
            return (text, after.canonical(after.offset(afterSolid: anchor)))
        }
        // Words and chips: the edit as typed, then each wrap end left without its partner goes too.
        let edit = canonical(range)
        let partners = Set(gone.compactMap(partner(of:))).subtracting(gone).sorted(by: >)
        let shift = replacement.utf16.count - edit.length
        var text = (self.text as NSString).replacingCharacters(in: edit, with: replacement)
        let typed = ScriptDisplay(text)
        let anchor = typed.solid(before: typed.display(edit.location + replacement.utf16.count))
        for partner in partners {
            let old = chips[partner].canonical
            let moved = NSRange(location: old.location >= NSMaxRange(edit) ? old.location + shift : old.location, length: old.length)
            guard let chip = Marks.parse(text).chips.first(where: { NSRange($0.range, in: text) == moved }),
                  String(text[chip.range]) == chips[partner].tag else { continue }
            text = Marks.removeChip(at: chip.range, in: text)
        }
        let after = ScriptDisplay(text)
        return (text, after.canonical(after.offset(afterSolid: anchor)))
    }

    /// A wrap end's other end: the one whose removal leaves the same text, as Marks removes both together.
    func partner(of index: Int) -> Int? {
        func wrap(_ kind: ParsedLine.Chip.Kind) -> Bool {
            switch kind {
            case .speed, .speedEnd, .stress, .stressEnd, .say, .sayEnd: true
            default: false
            }
        }
        guard wrap(chips[index].kind) else { return nil }
        let without = Marks.removeChip(at: chips[index].range, in: text)
        guard Marks.parse(without).chips.count == chips.count - 2 else { return nil }
        return chips.indices.first { $0 != index && wrap(chips[$0].kind) && Marks.removeChip(at: chips[$0].range, in: text) == without }
    }

    /// Words and punctuation before a display offset, and whether spaces or chips sit between the last of them and it.
    /// Removing tags changes neither count, so it finds the same place in the text after.
    private func solid(before offset: Int) -> (count: Int, gap: Bool) {
        let units = Array(string.utf16.prefix(offset))
        return (units.filter { !Self.blank($0) }.count, units.last.map(Self.blank) ?? false)
    }

    /// After a gap, the place is before the next word, past whatever spaces and chips are left.
    private func offset(afterSolid anchor: (count: Int, gap: Bool)) -> Int {
        let units = Array(string.utf16)
        var index = 0, seen = 0
        while index < units.count, seen < anchor.count {
            if !Self.blank(units[index]) { seen += 1 }
            index += 1
        }
        if anchor.gap {
            while index < units.count, Self.blank(units[index]) { index += 1 }
        }
        return index
    }

    /// A space or a chip: what removing tags may take away.
    private static func blank(_ unit: UInt16) -> Bool {
        unit == 0xFFFC || Unicode.Scalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }

    /// Where a canonical offset lands after the text changes from `old` to `new`: as it was before the change, shifted
    /// after it, and at the end of the new part when it was inside or at the edge of the change.
    static func moved(_ offset: Int, from old: String, to new: String) -> Int {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if offset < prefix { return offset }
        if offset > a.count - suffix { return min(b.count, offset + b.count - a.count) }
        return b.count - suffix
    }

    /// What picking from the `[` list does. `typed` is where the typed `[` sits, taken out first; nil when words were
    /// selected, as the `[` is held back then. Pauses go at the caret, wraps on the selection or the word before the caret.
    static func bracket(_ command: ScriptCommand, in text: String, typed: Int?, selection: NSRange) throws -> String {
        var text = text, selection = selection
        if let typed {
            let display = ScriptDisplay(text)
            guard typed >= 0, typed < display.length, (display.string as NSString).character(at: typed) == 0x5B else {
                throw AppError("The [ is no longer there.")
            }
            text = (text as NSString).replacingCharacters(in: NSRange(location: display.canonical(typed), length: 1), with: "")
            selection = NSRange(location: typed, length: 0)
        }
        return try command.applied(to: text, target: ScriptDisplay(text).target(selection: selection))
    }

    /// The canonical text of what a text view holds, and each display offset's canonical offset (one more than its
    /// length). An attachment character without a tag isn't part of the line and is dropped.
    static func read(_ attributed: NSAttributedString) -> (text: String, offsets: [Int]) {
        let string = attributed.string as NSString
        var units: [UInt16] = [], offsets: [Int] = []
        units.reserveCapacity(string.length)
        attributed.enumerateAttribute(.scriptTag, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            for index in range.location..<NSMaxRange(range) {
                offsets.append(units.count)
                let unit = string.character(at: index)
                if unit != 0xFFFC {
                    units.append(unit)
                } else if let tag = value as? String {
                    units += tag.utf16
                }
            }
        }
        offsets.append(units.count)
        return (String(decoding: units, as: UTF16.self), offsets)
    }

    // MARK: Chip text

    /// A chip's label: an SF Symbol, its text, and whether it's a direction (drawn in italics). Nil for a wrap's end,
    /// drawn as a small cap.
    static func label(_ kind: ParsedLine.Chip.Kind) -> (symbol: String?, text: String, italic: Bool)? {
        switch kind {
        case .pause(let seconds): ("pause.fill", "\(format(seconds))s", false)
        case .breath: (nil, "breath", false)
        case .speed(let rate): (rate < 1 ? "tortoise.fill" : rate > 1 ? "hare.fill" : nil, "\(percent(rate))%", false)
        case .stress: ("arrow.up", "stress", false)
        case .say(let spoken): (nil, "say: \(spoken)", false)
        case .direction(let label): (nil, label, true)
        case .speedEnd, .stressEnd, .sayEnd: nil
        }
    }

    static func accessibilityLabel(_ kind: ParsedLine.Chip.Kind) -> String {
        switch kind {
        case .pause(let seconds): "Pause, \(format(seconds)) \(seconds == 1 ? "second" : "seconds")"
        case .breath: "Breath"
        case .speed(let rate): "\(rate < 1 ? "Slower" : rate > 1 ? "Faster" : "Speed"), \(percent(rate)) percent"
        case .speedEnd: "End of speed"
        case .stress: "Stress"
        case .stressEnd: "End of stress"
        case .say(let spoken): "Say it like \(spoken)"
        case .sayEnd: "End of say it like"
        case .direction(let label): "Direction, \(label)"
        }
    }

    /// Seconds to two decimals without trailing zeros, as Marks writes them: 0.5, 1.25, 10.
    static func format(_ seconds: Double) -> String { String(format: "%g", (seconds * 100).rounded() / 100) }

    static func percent(_ rate: Double) -> Int { Int((rate * 100).rounded()) }
}

// MARK: Commands

/// A script command, from the menu or the `[` list.
enum ScriptCommand: Hashable, Sendable {
    case pause(Double), breath, speed(Double), stress, say(String)

    /// Pauses and breaths go after the target's word, wraps on its words.
    func applied(to text: String, target: ScriptDisplay.Target) throws -> String {
        switch self {
        case .pause(let seconds): try Marks.addPause(seconds, after: target.after, in: text)
        case .breath: try Marks.addBreath(after: target.after, in: text)
        case .speed(let rate): try Marks.setSpeed(rate, tokens: words(target), in: text)
        case .stress: try Marks.setStress(tokens: words(target), in: text)
        case .say(let spoken): try Marks.setSay(spoken, tokens: words(target), in: text)
        }
    }

    private func words(_ target: ScriptDisplay.Target) throws -> ClosedRange<Int> {
        guard let words = target.words else { throw AppError("Write a word first.") }
        return words
    }

    /// A typed pause: "0.5", ".5" or "2s". Marks would clamp one out of range; here it's an error to fix.
    static func seconds(_ value: String) throws -> Double {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = text.wholeMatch(of: /(\d+(?:\.\d+)?|\.\d+)\s*s?/), let seconds = Double(match.1) else {
            throw AppError("Write the pause in seconds, such as 0.5.")
        }
        guard Marks.pauses.contains(seconds) else { throw AppError("Pause must be 0.05 to 10 seconds.") }
        return seconds
    }

    /// A typed speed: "80%", "80", "0.8" or "0.8x", as Marks reads one.
    static func rate(_ value: String) throws -> Double {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard let match = text.wholeMatch(of: /(\d+(?:\.\d+)?|\.\d+)\s*(%|x)?/), let number = Double(match.1) else {
            throw AppError("Write the speed as a percent, such as 80%.")
        }
        let rate = match.2 == "%" || (match.2 == nil && number > 10) ? number / 100 : number
        guard Marks.speeds.contains(rate) else { throw AppError("Speed must be 50% to 200%.") }
        return rate
    }
}

/// The `[` list, in order.
enum ScriptBracketItem: CaseIterable, Sendable {
    case pause, breath, slower, faster, stress, say

    var title: String {
        switch self {
        case .pause: "Pause 0.5 s"
        case .breath: "Breath"
        case .slower: "Slower 80%"
        case .faster: "Faster 120%"
        case .stress: "Stress"
        case .say: "Say it like…"
        }
    }

    /// Nil for Say it like…, which asks for the respelling first.
    var command: ScriptCommand? {
        switch self {
        case .pause: .pause(0.5)
        case .breath: .breath
        case .slower: .speed(0.8)
        case .faster: .speed(1.2)
        case .stress: .stress
        case .say: nil
        }
    }

    var kind: ParsedLine.Chip.Kind {
        switch self {
        case .pause: .pause(0.5)
        case .breath: .breath
        case .slower: .speed(0.8)
        case .faster: .speed(1.2)
        case .stress: .stress
        case .say: .say("")
        }
    }
}

// MARK: Look

/// Fonts, colours and chip sizes for a style.
struct ScriptTextMetrics {
    let font: NSFont
    let paragraph: NSParagraphStyle
    let lineMultiple: CGFloat
    let lineGap: CGFloat               // between wrapped lines, never after the last
    let color: NSColor                 // words when not playing
    let lit = NSColor(Theme.text)
    let dim = NSColor(Theme.secondary)
    let chipFont: NSFont
    let chipHeight: CGFloat
    let chipRadius: CGFloat            // a quarter of the height: rounded rectangles, never pills
    let chipBaseline: CGFloat          // the chip's bottom, from the text's baseline
    let chipPadding: CGFloat
    let chipMargin: CGFloat
    let chipMaxLabel: CGFloat
    let symbolGap: CGFloat
    let endWidth: CGFloat
    let underlineOffset: CGFloat       // below the baseline
    let underlineStep: CGFloat
    let underlineThickness: CGFloat

    init(_ style: ScriptTextView.Style) {
        let paragraph = NSMutableParagraphStyle()
        switch style {
        case .row:
            // The row's body font: 13 pt with monospaced digits.
            font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            chipFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            lineMultiple = 1
            // Room for a nested wrap's lower underline above the next line's chips.
            lineGap = 3
            color = NSColor(Theme.text)
            chipHeight = 16
            chipRadius = 4
            chipPadding = 6
            chipMargin = 2
            chipMaxLabel = 220
            symbolGap = 3
            endWidth = 3.5
            underlineOffset = 2.5
            underlineStep = 2.5
            underlineThickness = 1.25
        case .read:
            font = .systemFont(ofSize: 26, weight: .regular)
            chipFont = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
            lineMultiple = 1.3
            lineGap = 0
            color = NSColor(Theme.secondary)
            chipHeight = 26
            chipRadius = 6
            chipPadding = 9
            chipMargin = 3
            chipMaxLabel = 360
            symbolGap = 5
            endWidth = 5
            underlineOffset = 4
            underlineStep = 4
            underlineThickness = 2
        }
        paragraph.lineHeightMultiple = lineMultiple
        self.paragraph = paragraph
        // The chip centred on the text's capitals, so it sits on the line like a word.
        chipBaseline = ((font.capHeight - chipHeight) / 2).rounded()
    }

    var attributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: color, .paragraphStyle: paragraph] }

    /// Each kind's tint, muted for the dark theme. Data hues, not accents; amber stays for warnings, so stress is rose.
    static func tint(_ kind: ParsedLine.Chip.Kind) -> NSColor {
        switch kind {
        case .pause, .breath: rgb(0xA4A9AF)
        case .speed, .speedEnd: rgb(0x7FA8E0)
        case .stress, .stressEnd: rgb(0xD99BB0)
        case .say, .sayEnd: rgb(0x85C7A0)
        case .direction: rgb(0xB8A2E8)
        }
    }

    static func tint(_ wrap: ScriptDisplay.Wrap) -> NSColor {
        switch wrap {
        case .speed: tint(.speed(1))
        case .stress: tint(ParsedLine.Chip.Kind.stress)
        case .say: tint(.say(""))
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Draws one chip: a small tinted rounded rectangle, or a narrow cap for a wrap's end.
final class ScriptChipCell: NSTextAttachmentCell {
    let kind: ParsedLine.Chip.Kind
    // Set once in init; the text system asks for the size from outside the main actor's view of things.
    nonisolated(unsafe) private let metrics: ScriptTextMetrics
    private let tint: NSColor
    nonisolated(unsafe) private let label: NSAttributedString?
    private let symbol: NSImage?

    init(_ kind: ParsedLine.Chip.Kind, metrics: ScriptTextMetrics) {
        self.kind = kind
        self.metrics = metrics
        let tint = ScriptTextMetrics.tint(kind)
        self.tint = tint
        if let parts = ScriptDisplay.label(kind) {
            let text = tint.blended(withFraction: 0.2, of: .white) ?? tint
            var font = metrics.chipFont
            if parts.italic {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
            }
            let label = NSMutableAttributedString(string: parts.text, attributes: [.font: font, .foregroundColor: text])
            if case .say = kind {
                // "say:" quieter than the respelling it introduces.
                label.addAttribute(.foregroundColor, value: text.withAlphaComponent(0.6), range: NSRange(location: 0, length: 4))
            }
            self.label = label
            let configuration = NSImage.SymbolConfiguration(pointSize: metrics.chipFont.pointSize * 0.8, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [text]))
            symbol = parts.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) }
        } else {
            label = nil
            symbol = nil
        }
        super.init()
        setAccessibilityLabel(ScriptDisplay.accessibilityLabel(kind))
    }

    required init(coder: NSCoder) { fatalError("Chips are made in code.") }

    override func cellSize() -> NSSize {
        guard let label else { return NSSize(width: metrics.endWidth + metrics.chipMargin * 1.5, height: metrics.chipHeight) }
        let symbolWidth = symbol.map { $0.size.width + metrics.symbolGap } ?? 0
        let width = min(ceil(label.size().width), metrics.chipMaxLabel) + symbolWidth + metrics.chipPadding * 2
        return NSSize(width: ceil(width + metrics.chipMargin * 2), height: metrics.chipHeight)
    }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: metrics.chipBaseline) }

    override func wantsToTrackMouse() -> Bool { false }

    override func wantsToTrackMouse(for event: NSEvent, in frame: NSRect, of view: NSView?, atCharacterIndex index: Int) -> Bool { false }

    override func draw(withFrame frame: NSRect, in view: NSView?, characterIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: frame, in: view)
    }

    override func draw(withFrame frame: NSRect, in view: NSView?, characterIndex: Int) { draw(withFrame: frame, in: view) }

    override func draw(withFrame frame: NSRect, in view: NSView?) {
        guard let label else {
            // A wrap's end: a slim cap just after the word before it, shorter than a chip so it doesn't read as one.
            let height = (frame.height * 0.62).rounded()
            let cap = NSRect(x: frame.minX + metrics.chipMargin / 2, y: frame.midY - height / 2, width: metrics.endWidth, height: height)
            tint.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: cap, xRadius: 1, yRadius: 1).fill()
            return
        }
        let box = frame.insetBy(dx: metrics.chipMargin, dy: 0)
        let pill = box.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: pill, xRadius: metrics.chipRadius, yRadius: metrics.chipRadius)
        tint.withAlphaComponent(0.15).setFill()
        path.fill()
        tint.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 1
        path.stroke()

        var x = box.minX + metrics.chipPadding
        if let symbol {
            let size = symbol.size
            symbol.draw(in: NSRect(x: x, y: (pill.midY - size.height / 2).rounded(), width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += size.width + metrics.symbolGap
        }
        // Centred on the label's capitals and x-height, so short lowercase labels don't ride low.
        let font = metrics.chipFont
        let middle = (font.capHeight + font.xHeight) / 4
        let top = view?.isFlipped ?? true ? pill.midY + middle - font.ascender : pill.midY - middle - font.descender
        // Its own width, not what's left of the pill: rounding would cut the last letter.
        let width = min(ceil(label.size().width) + 1, metrics.chipMaxLabel)
        label.draw(with: NSRect(x: x, y: top, width: width, height: font.ascender - font.descender),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: Text view

/// The text view behind ScriptTextView. It is its own delegate and keeps its own undo history of canonical texts.
final class ScriptTextNSView: NSTextView, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
    var style: ScriptTextView.Style {
        didSet {
            guard style != oldValue else { return }
            configure()
            set(display, selection: NSRange(location: 0, length: 0))
        }
    }
    var placeholder = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    var onChange: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onCommand: (String) -> Void = { _ in }
    var onWordClick: ((Int) -> Void)?

    private(set) var display = ScriptDisplay("")
    private(set) var lit: Int?
    private var metrics: ScriptTextMetrics
    private var outside: String?               // the text last given from outside
    private var committed = ""                 // at focus or the last commit
    private var edited = false                 // typed since focus or the last commit
    private var applying = false               // the view is setting its own text
    private var editing = false                // between shouldChangeText and textDidChange
    private var pending: (text: String, selection: NSRange, coalesce: Bool)?
    private var coalescing = false             // typing joins the last undo step
    private let history = UndoManager()
    // A second layout of the same text, for measuring heights without disturbing the one on screen.
    private let measure = NSLayoutManager()
    private let measureContainer = NSTextContainer()
    private var list: ScriptCommandList?
    private var listState: (typed: Int?, selection: NSRange)?
    private var popover: ScriptValuePopover?

    init(style: ScriptTextView.Style) {
        self.style = style
        metrics = ScriptTextMetrics(style)
        // TextKit 1: temporary attributes relight words without touching the text, and line fragments place the underlines.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        measureContainer.lineFragmentPadding = 0
        measure.addTextContainer(measureContainer)
        storage.addLayoutManager(measure)
        delegate = self
        layout.delegate = self
        measure.delegate = self
        configure()
    }

    required init?(coder: NSCoder) { fatalError("ScriptTextNSView is made in code.") }

    private func configure() {
        metrics = ScriptTextMetrics(style)
        isEditable = style == .row
        isSelectable = true
        isRichText = true
        importsGraphics = false
        allowsUndo = false              // the view keeps its own history, of canonical texts
        usesFontPanel = false
        usesRuler = false
        usesFindBar = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        insertionPointColor = NSColor(Theme.text)
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityPlaceholderValue(placeholder)
    }

    /// Typing next to a chip must not pick up its attachment.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { metrics.attributes }
        set {}
    }

    private var isEditingText: Bool { style == .row && window?.firstResponder === self }

    // MARK: From outside

    /// Shows the text given from outside when it differs, but not over the user's own edits: mid-edit, only when the
    /// outside text changed and the user has typed nothing since the last commit.
    func update(text: String) {
        defer { outside = text }
        guard text != display.text else { return }
        if isEditingText, text == outside || edited { return }
        closeOverlays()
        history.removeAllActions()
        coalescing = false
        let old = display.text, selection = display.canonical(selectedRange())
        let low = ScriptDisplay.moved(selection.location, from: old, to: text)
        let high = ScriptDisplay.moved(NSMaxRange(selection), from: old, to: text)
        set(ScriptDisplay(text), selection: NSRange(location: low, length: max(0, high - low)))
        committed = text
        edited = false
    }

    func setLit(_ lit: Int?) {
        guard lit != self.lit else { return }
        self.lit = lit
        applyLit()
    }

    func closeOverlays() {
        closeList()
        popover?.close()
        popover = nil
    }

    /// The text view's whole text, with the selection in the new text's canonical offsets.
    private func set(_ next: ScriptDisplay, selection: NSRange) {
        applying = true
        textStorage?.setAttributedString(Self.attributed(next, metrics: metrics))
        display = next
        let low = min(next.display(selection.location), next.length)
        let high = min(next.display(NSMaxRange(selection)), next.length)
        setSelectedRange(NSRange(location: low, length: max(0, high - low)))
        applying = false
        changed()
    }

    static func attributed(_ display: ScriptDisplay, metrics: ScriptTextMetrics) -> NSAttributedString {
        let result = NSMutableAttributedString(string: display.string, attributes: metrics.attributes)
        for chip in display.chips {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = ScriptChipCell(chip.kind, metrics: metrics)
            result.addAttributes([.attachment: attachment, .scriptTag: chip.tag], range: NSRange(location: chip.location, length: 1))
        }
        return result
    }

    /// Words get the style's look again after an edit; chips keep theirs.
    private func restyle() {
        guard let storage = textStorage, storage.length == display.length else { return }
        storage.beginEditing()
        var start = 0
        for chip in display.chips {
            if chip.location > start { storage.setAttributes(metrics.attributes, range: NSRange(location: start, length: chip.location - start)) }
            start = chip.location + 1
        }
        if storage.length > start { storage.setAttributes(metrics.attributes, range: NSRange(location: start, length: storage.length - start)) }
        storage.endEditing()
    }

    private func changed() {
        applyLit()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// Lit words as temporary attributes: no relayout and no change to the text, so it can follow playback.
    private func applyLit(editing: Bool? = nil) {
        guard let layout = layoutManager, let storage = textStorage else { return }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        guard !(editing ?? isEditingText), storage.length == display.length else { return }
        let ranges = display.litRanges(lit)
        for range in ranges.lit { layout.addTemporaryAttribute(.foregroundColor, value: metrics.lit, forCharacterRange: range) }
        for range in ranges.dim { layout.addTemporaryAttribute(.foregroundColor, value: metrics.dim, forCharacterRange: range) }
    }

    // MARK: Size

    func height(forWidth width: CGFloat) -> CGFloat {
        measureContainer.size = NSSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        measure.ensureLayout(for: measureContainer)
        let line = ceil(measure.defaultLineHeight(for: metrics.font) * metrics.lineMultiple)
        return max(ceil(measure.usedRect(for: measureContainer).height), line)
    }

    func naturalWidth() -> CGFloat {
        measureContainer.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        measure.ensureLayout(for: measureContainer)
        return ceil(measure.usedRect(for: measureContainer).width)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : naturalWidth()))
    }

    /// Space between wrapped lines only, so one line stays as tall as the TextField's.
    func layoutManager(_ layoutManager: NSLayoutManager, lineSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        glyphIndex + 1 < layoutManager.numberOfGlyphs ? metrics.lineGap : 0
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawUnderlines()
        if textStorage?.length == 0, !placeholder.isEmpty {
            var attributes = metrics.attributes
            attributes[.foregroundColor] = NSColor(Theme.secondary)
            NSAttributedString(string: placeholder, attributes: attributes)
                .draw(with: NSRect(origin: textContainerOrigin, size: bounds.size), options: [.usesLineFragmentOrigin])
        }
    }

    /// A faint line in the wrap's tint under the words each speed, stress or say covers.
    private func drawUnderlines() {
        guard let layout = layoutManager, let container = textContainer, textStorage?.length == display.length else { return }
        let origin = textContainerOrigin
        for underline in display.underlines {
            ScriptTextMetrics.tint(underline.wrap).withAlphaComponent(0.6).setFill()
            for range in underline.ranges {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, line, _ in
                    let part = NSIntersectionRange(line, glyphs)
                    guard part.length > 0 else { return }
                    let box = layout.boundingRect(forGlyphRange: part, in: container)
                    let baseline = fragment.minY + layout.location(forGlyphAt: part.location).y
                    let y = origin.y + baseline + self.metrics.underlineOffset + CGFloat(underline.level) * self.metrics.underlineStep
                    let thickness = self.metrics.underlineThickness
                    NSBezierPath(roundedRect: NSRect(x: origin.x + box.minX, y: y, width: box.width, height: thickness),
                                 xRadius: thickness / 2, yRadius: thickness / 2).fill()
                }
            }
        }
        _ = container
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if style == .row {
            committed = display.text
            edited = false
            coalescing = false
            applyLit(editing: true)
        }
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        closeList()
        if style == .row {
            commitIfChanged()
            applyLit(editing: false)
        }
        return true
    }

    private func commitIfChanged() {
        guard display.text != committed else { return }
        committed = display.text
        edited = false
        coalescing = false
        onCommit()
    }

    // MARK: Editing

    func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
        guard !applying else { return true }
        guard let string else { return false }          // attribute changes: the look is the view's own
        guard textStorage?.string == display.string else { return true }
        if string.contains(where: \.isNewline) {
            // One line of script: line breaks come in as spaces.
            let flat = String(string.map { $0.isNewline ? " " : $0 })
            if shouldChangeText(in: range, replacementString: flat) {
                replaceCharacters(in: range, with: flat)
                didChangeText()
            }
            return false
        }
        if let edit = display.replacing(range, with: string) {
            closeList()
            record(display.text, display.canonical(selectedRange()), coalesce: false)
            set(ScriptDisplay(edit.text), selection: NSRange(location: edit.caret, length: 0))
            edited = true
            onChange(edit.text)
            return false
        }
        if pending == nil { pending = (display.text, display.canonical(selectedRange()), string.utf16.count <= 1) }
        editing = true
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !applying, let storage = textStorage else { return }
        defer { editing = false }
        let before = display.text
        let read = ScriptDisplay.read(storage)
        let next = ScriptDisplay(read.text)
        if next.string != storage.string, !hasMarkedText() {
            // A typed or pasted tag becomes a chip; the caret keeps its place in the text.
            let selection = selectedRange()
            let low = read.offsets[min(selection.location, read.offsets.count - 1)]
            let high = read.offsets[min(NSMaxRange(selection), read.offsets.count - 1)]
            set(next, selection: NSRange(location: low, length: high - low))
        } else {
            display = next
            if !hasMarkedText() { restyle() }
            changed()
        }
        if let pending, pending.text != read.text { record(pending.text, pending.selection, coalesce: pending.coalesce) }
        pending = nil
        guard read.text != before else { return }
        edited = true
        onChange(read.text)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // The caret moved by itself: the next typing is a new step to undo.
        if !applying, !editing { coalescing = false }
    }

    /// Return commits without a newline; Tab moves on, as in a text field; Esc does nothing rather than offer completions.
    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        if let list {
            switch selector {
            case #selector(moveUp(_:)):
                list.move(-1)
                return true
            case #selector(moveDown(_:)):
                list.move(1)
                return true
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                pick(ScriptBracketItem.allCases[list.selected])
                return true
            case #selector(cancelOperation(_:)):
                dismissList()
                return true
            default:
                dismissList()
            }
        }
        switch selector {
        case #selector(insertNewline(_:)):
            commitIfChanged()
            return true
        case #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertParagraphSeparator(_:)):
            return true
        case #selector(insertTab(_:)):
            window?.selectNextKeyView(nil)
            return true
        case #selector(insertBacktab(_:)):
            window?.selectPreviousKeyView(nil)
            return true
        case #selector(cancelOperation(_:)), #selector(complete(_:)):
            return true
        default:
            return false
        }
    }

    // MARK: Undo

    // NSWindow answers undo: with its own manager, so the view answers first while it has focus. The history isn't
    // offered as the view's undoManager: NSTextView would register its own typing steps there too.
    @objc func undo(_ sender: Any?) { history.undo() }

    @objc func redo(_ sender: Any?) { history.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): history.canUndo
        case #selector(redo(_:)): history.canRedo
        default: super.validateUserInterfaceItem(item)
        }
    }

    /// Only rows keep a history: in `.read` every change goes out as a command, and undoing one would only be an edit.
    private func record(_ text: String, _ selection: NSRange, coalesce: Bool) {
        guard style == .row, !(coalesce && coalescing) else { return }
        coalescing = coalesce
        history.registerUndo(withTarget: self) { view in
            MainActor.assumeIsolated { view.restore(text, selection) }
        }
    }

    private func restore(_ text: String, _ selection: NSRange) {
        let current = display.text, currentSelection = display.canonical(selectedRange())
        coalescing = false
        history.registerUndo(withTarget: self) { view in
            MainActor.assumeIsolated { view.restore(current, currentSelection) }
        }
        set(ScriptDisplay(text), selection: selection)
        edited = text != committed
        onChange(text)
    }

    /// A command's text, applied here at once and handed out to be applied and committed.
    private func perform(_ text: String) {
        guard text != display.text else { return }
        let old = display.text, selection = display.canonical(selectedRange())
        record(old, selection, coalesce: false)
        let low = ScriptDisplay.moved(selection.location, from: old, to: text)
        let high = ScriptDisplay.moved(NSMaxRange(selection), from: old, to: text)
        set(ScriptDisplay(text), selection: NSRange(location: low, length: max(0, high - low)))
        committed = text
        edited = false
        onCommand(text)
    }

    // MARK: Pasteboard

    // Plain text only, with tags written out, so chips copy and paste as their tags.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, textStorage?.length == display.length else { return false }
        let range = display.canonical(selectedRange())
        return pboard.setString((display.text as NSString).substring(with: range), forType: .string)
    }

    // MARK: The [ list

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if list != nil { dismissList() }
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        guard typed == "[", style == .row, isEditable, !hasMarkedText(), replacementRange.location == NSNotFound else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()
        if display.words(in: selection) != nil {
            // Held back, so the selected words can be wrapped; typed after all if the list closes without a pick.
            openList(typed: nil, selection: selection)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        let at = selectedRange().location - 1
        guard at >= 0, at < display.length, (display.string as NSString).character(at: at) == 0x5B else { return }
        openList(typed: at, selection: NSRange(location: at, length: 0))
    }

    private func openList(typed: Int?, selection: NSRange) {
        guard let window else { return }
        let caret = NSRange(location: typed.map { $0 + 1 } ?? selection.location, length: 0)
        let list = ScriptCommandList(items: ScriptBracketItem.allCases.map { ($0.title, ScriptTextMetrics.tint($0.kind)) }) { [weak self] index in
            self?.pick(ScriptBracketItem.allCases[index])
        }
        list.show(below: firstRect(forCharacterRange: caret, actualRange: nil), in: window)
        self.list = list
        listState = (typed, selection)
    }

    /// A click, a menu or losing focus: the list goes, and a held-back [ with it.
    private func closeList() {
        list?.close()
        list = nil
        listState = nil
    }

    /// Esc or other typing: the list goes and the typed [ stays. A held-back [ is typed now, over the selection.
    private func dismissList() {
        guard let state = listState else { return }
        closeList()
        if state.typed == nil { super.insertText("[", replacementRange: state.selection) }
    }

    private func pick(_ item: ScriptBracketItem) {
        guard let state = listState else { return }
        guard let command = item.command else {
            closeList()
            // Say it like… asks for the respelling; the [ stays until it's applied.
            let anchor = state.typed.map { NSRange(location: $0, length: 1) } ?? state.selection
            ask("Say it like", value: "", placeholder: "Koo-ber", at: anchor) { [weak self] value in
                guard let self else { return }
                perform(try ScriptDisplay.bracket(.say(value), in: display.text, typed: state.typed, selection: state.selection))
            }
            return
        }
        do {
            let text = try ScriptDisplay.bracket(command, in: display.text, typed: state.typed, selection: state.selection)
            closeList()
            perform(text)
        } catch {
            list?.problem = error.localizedDescription
        }
    }

    // MARK: Mouse and menu

    override func mouseDown(with event: NSEvent) {
        closeList()
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        // NSTextView tracks the drag itself, so the button is up here; a click leaves nothing selected.
        guard style == .read, let onWordClick, event.clickCount == 1, selectedRange().length == 0,
              let index = characterIndex(at: point), let word = display.word(at: index) else { return }
        let up = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        guard hypot(up.x - point.x, up.y - point.y) < 4 else { return }
        onWordClick(word)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        closeList()
        let point = convert(event.locationInWindow, from: nil)
        let selection = selectedRange()
        let under = characterIndex(at: point)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let inSelection = under.map { NSLocationInRange($0, selection) } ?? false
        let selectedChip = selection.length == 1 ? display.chip(at: selection.location) : nil
        if let chip = selectedChip ?? (inSelection && display.words(in: selection) != nil ? nil : under.flatMap(display.chip(at:))) {
            chipItems(chip).forEach(menu.addItem)
        } else if display.words(in: selection) != nil {
            commandItems(display.target(selection: selection), anchor: selection).forEach(menu.addItem)
        } else {
            let index = under ?? characterIndexForInsertion(at: point)
            let target = display.target(at: index)
            commandItems(target, anchor: target.words.map(display.range(of:)) ?? NSRange(location: index, length: 0)).forEach(menu.addItem)
        }
        menu.addItem(.separator())
        if style == .row {
            menu.addItem(standardItem("Cut", #selector(cut(_:)), enabled: selection.length > 0))
            menu.addItem(standardItem("Copy", #selector(copy(_:)), enabled: selection.length > 0))
            menu.addItem(standardItem("Paste", #selector(paste(_:)), enabled: NSPasteboard.general.string(forType: .string) != nil))
        } else {
            menu.addItem(standardItem("Copy", #selector(copy(_:)), enabled: selection.length > 0))
        }
        return menu
    }

    private func commandItems(_ target: ScriptDisplay.Target, anchor: NSRange) -> [NSMenuItem] {
        var problems: [String] = []
        func item(_ title: String, _ command: ScriptCommand) -> NSMenuItem {
            do {
                let text = try command.applied(to: display.text, target: target)
                return actionItem(title) { [weak self] in self?.perform(text) }
            } catch {
                if !problems.contains(error.localizedDescription) { problems.append(error.localizedDescription) }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            }
        }
        func custom(_ title: String, prompt: String, value: String = "", placeholder: String,
                    make: @escaping (String) throws -> ScriptCommand) -> NSMenuItem {
            actionItem(title) { [weak self] in
                self?.ask(prompt, value: value, placeholder: placeholder, at: anchor) { [weak self] input in
                    guard let self else { return }
                    perform(try make(input).applied(to: display.text, target: target))
                }
            }
        }
        let said = target.words.flatMap { display.parsed.tokens[$0.lowerBound].say } ?? ""
        var items = [
            submenu("Pause after", [item("0.25 s", .pause(0.25)), item("0.5 s", .pause(0.5)), item("1 s", .pause(1)),
                                    custom("Custom…", prompt: "Pause after, in seconds", placeholder: "0.75") { .pause(try ScriptCommand.seconds($0)) }]),
            item("Breath after", .breath),
            submenu("Slower", [item("90%", .speed(0.9)), item("80%", .speed(0.8)), item("70%", .speed(0.7)),
                               custom("Custom…", prompt: "Slower, as a percent", placeholder: "75%") { .speed(try ScriptCommand.rate($0)) }]),
            submenu("Faster", [item("110%", .speed(1.1)), item("120%", .speed(1.2)), item("130%", .speed(1.3)),
                               custom("Custom…", prompt: "Faster, as a percent", placeholder: "125%") { .speed(try ScriptCommand.rate($0)) }]),
            item("Stress", .stress),
            custom("Say it like…", prompt: "Say it like", value: said, placeholder: "Koo-ber") { .say($0) },
        ]
        if !problems.isEmpty {
            items.insert(contentsOf: problems.map { problem in
                let item = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            } + [.separator()], at: 0)
        }
        return items
    }

    private func chipItems(_ index: Int) -> [NSMenuItem] {
        let chip = display.chips[index]
        var items: [NSMenuItem] = []
        let change: (prompt: String, value: String, check: (String) throws -> Void)? = switch chip.kind {
        case .pause(let seconds): ("Pause, in seconds", ScriptDisplay.format(seconds), { _ = try ScriptCommand.seconds($0) })
        case .speed(let rate): ("Speed, as a percent", "\(ScriptDisplay.percent(rate))%", { _ = try ScriptCommand.rate($0) })
        case .say(let spoken): ("Say it like", spoken, { _ in })
        default: nil
        }
        if let change {
            let anchor = NSRange(location: chip.location, length: 1)
            items.append(actionItem("Change…") { [weak self] in
                self?.ask(change.prompt, value: change.value, placeholder: change.value, at: anchor) { [weak self] value in
                    guard let self else { return }
                    try change.check(value)
                    guard index < display.chips.count, display.chips[index].tag == chip.tag else {
                        throw AppError("That tag is no longer in the line.")
                    }
                    perform(try Marks.setChipValue(value, at: display.chips[index].range, in: display.text))
                }
            })
        }
        let removed = Marks.removeChip(at: chip.range, in: display.text)
        items.append(actionItem("Remove") { [weak self] in self?.perform(removed) })
        return items
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private func actionItem(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuAction(run)
        return item
    }

    private func standardItem(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) { (sender.representedObject as? MenuAction)?.run() }

    /// The character whose glyph is under a point in the view, or nil past a line's end or in an empty line.
    func characterIndex(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, display.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: nil)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    // MARK: Popover

    private func ask(_ title: String, value: String, placeholder: String, at range: NSRange, apply: @escaping (String) throws -> Void) {
        popover?.close()
        let popover = ScriptValuePopover(title: title, value: value, placeholder: placeholder, apply: apply)
        popover.onClose = { [weak self, weak popover] in
            if let self, self.popover === popover { self.popover = nil }
        }
        self.popover = popover
        popover.show(relativeTo: anchorRect(range), of: self)
    }

    /// The first line's rect of a range, in the view.
    private func anchorRect(_ range: NSRange) -> NSRect {
        guard let window else { return bounds }
        let screen = firstRect(forCharacterRange: range, actualRange: nil)
        let rect = convert(window.convertFromScreen(screen), from: nil)
        return rect.width < 1 ? rect.insetBy(dx: -1, dy: 0) : rect
    }

    // MARK: Accessibility

    override func accessibilityValue() -> String? { Marks.plain(display.text) }
}

private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

// MARK: Command list

/// The small list the `[` key opens at the caret. It never takes key focus: the text view keeps the keyboard and
/// passes arrows, Return and Esc on to it.
@MainActor
final class ScriptCommandList {
    private let panel: NSPanel
    private let view: ListView
    var selected: Int { view.selected }
    var problem: String? {
        get { view.problem }
        set {
            view.problem = newValue
            resize()
        }
    }

    init(items: [(title: String, tint: NSColor)], pick: @escaping (Int) -> Void) {
        view = ListView(items: items, pick: pick)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
    }

    func show(below caret: NSRect, in parent: NSWindow) {
        let size = view.size
        var origin = NSPoint(x: caret.minX - 6, y: caret.minY - size.height - 4)
        if let screen = parent.screen?.visibleFrame, origin.y < screen.minY { origin.y = caret.maxY + 4 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        parent.addChildWindow(panel, ordered: .above)
        panel.invalidateShadow()
    }

    func move(_ step: Int) {
        view.selected = (view.selected + step + view.items.count) % view.items.count
        view.needsDisplay = true
    }

    func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func resize() {
        let top = panel.frame.maxY, size = view.size
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        view.needsDisplay = true
        panel.invalidateShadow()
    }

    private final class ListView: NSView {
        let items: [(title: String, tint: NSColor)]
        let pick: (Int) -> Void
        var selected = 0
        var problem: String?
        private let row: CGFloat = 24, inset: CGFloat = 4, width: CGFloat = 188
        private let font = NSFont.systemFont(ofSize: 13)

        init(items: [(title: String, tint: NSColor)], pick: @escaping (Int) -> Void) {
            self.items = items
            self.pick = pick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("Made in code.") }

        override var isFlipped: Bool { true }

        var size: NSSize {
            NSSize(width: width, height: inset * 2 + row * CGFloat(items.count) + (problemHeight.map { $0 + 8 } ?? 0))
        }

        private var problemHeight: CGFloat? {
            problem.map { ceil(problemText($0).boundingRect(with: NSSize(width: width - 24, height: 200), options: .usesLineFragmentOrigin).height) }
        }

        private func problemText(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(Theme.amber)])
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseMoved(with event: NSEvent) {
            guard let index = index(at: convert(event.locationInWindow, from: nil)), index != selected else { return }
            selected = index
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            if let index = index(at: convert(event.locationInWindow, from: nil)) { pick(index) }
        }

        private func index(at point: NSPoint) -> Int? {
            let index = Int(floor((point.y - inset) / row))
            return (0..<items.count).contains(index) && point.y >= inset ? index : nil
        }

        override func draw(_ dirtyRect: NSRect) {
            // A card's radius, and its items concentric inside it: 8 − 4.
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.card, yRadius: Radius.card)
            NSColor(srgbRed: 0.105, green: 0.112, blue: 0.122, alpha: 0.98).setFill()
            shape.fill()
            NSColor(white: 1, alpha: 0.12).setStroke()
            shape.stroke()
            for (index, item) in items.enumerated() {
                let rect = NSRect(x: inset, y: inset + row * CGFloat(index), width: bounds.width - inset * 2, height: row)
                if index == selected {
                    NSColor(white: 1, alpha: 0.1).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: Radius.card - inset, yRadius: Radius.card - inset).fill()
                }
                item.tint.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 9, y: rect.midY - 3, width: 6, height: 6)).fill()
                let title = NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: NSColor(Theme.text)])
                title.draw(at: NSPoint(x: rect.minX + 24, y: rect.midY - title.size().height / 2))
            }
            if let problem, let height = problemHeight {
                let top = inset + row * CGFloat(items.count) + 4
                problemText(problem).draw(with: NSRect(x: 12, y: top, width: bounds.width - 24, height: height), options: .usesLineFragmentOrigin)
            }
        }
    }
}

// MARK: Value popover

/// One text field and Apply, anchored at the words a command acts on. Return applies; an error shows under the field
/// and the popover stays open to fix it.
@MainActor
final class ScriptValuePopover: NSObject, NSPopoverDelegate {
    var onClose: () -> Void = {}
    private let popover = NSPopover()
    private let field: NSTextField
    private let message = NSTextField(wrappingLabelWithString: "")
    private let stack: NSStackView
    private let apply: (String) throws -> Void
    private var done = false

    init(title: String, value: String, placeholder: String, apply: @escaping (String) throws -> Void) {
        self.apply = apply
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(Theme.secondary)
        field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.cell?.sendsActionOnEndEditing = false
        field.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let button = NSButton(title: "Apply", target: nil, action: nil)
        button.keyEquivalent = "\r"
        let cancel = NSButton(title: "", target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        cancel.isHidden = true
        message.font = .systemFont(ofSize: 11)
        message.textColor = NSColor(Theme.amber)
        message.preferredMaxLayoutWidth = 250
        message.isHidden = true
        let row = NSStackView(views: [field, button, cancel])
        row.spacing = 8
        stack = NSStackView(views: [label, row, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        super.init()
        field.target = self
        field.action = #selector(submit(_:))
        button.target = self
        button.action = #selector(submit(_:))
        cancel.target = self
        cancel.action = #selector(dismiss(_:))
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
        popover.contentSize = stack.fittingSize
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func close() { popover.close() }

    @objc private func submit(_ sender: Any?) {
        guard !done else { return }
        do {
            try apply(field.stringValue)
            done = true
            popover.close()
        } catch {
            message.stringValue = error.localizedDescription
            message.isHidden = false
            popover.contentSize = stack.fittingSize
        }
    }

    @objc private func dismiss(_ sender: Any?) { popover.close() }

    func popoverDidClose(_ notification: Notification) { onClose() }
}

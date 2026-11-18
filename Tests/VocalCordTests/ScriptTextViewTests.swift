import AppKit
import Foundation
import Testing
@testable import VocalCord

private let sample = "Meet VocalCord [pause 0.5] — your voice, [speed 80%]cloned and [stress]free[/stress][/speed]. "
    + "Say [say Koo-ber]Kuber[/say] [confident] right."

/// Lines with every chip kind, unicode of several UTF-16 widths, and text that only looks like tags.
private let lines = [
    sample,
    "[confident] Héllo wörld 👋🏽 [pause 0.25] naïve, [breath] [speed 120%]日本語 fast[/speed] and [stress]Ünïcode[/stress]! "
        + "[say Ko͞o-ber]Kuber[/say] 🇬🇧",
    "[stress][say Koo-ber]Kuber[/say][/stress]",
    "[pause 1][breath][breath]",
    "half [pause 0.5 and [] brackets ]",
    "plain words only",
    "",
]

/// Where `needle` first appears in what's shown, which writes each chip as one U+FFFC.
private func at(_ needle: String, in display: ScriptDisplay) -> Int { (display.string as NSString).range(of: needle).location }

private func chip(_ kind: ParsedLine.Chip.Kind, in display: ScriptDisplay) -> ScriptDisplay.Chip { display.chips.first { $0.kind == kind }! }

// MARK: Display

@Test func everyChipKindBecomesOneAttachmentCharacter() {
    for text in lines {
        let display = ScriptDisplay(text)
        let parsed = Marks.parse(text)
        #expect(display.chips.map(\.tag) == parsed.chips.map { String(text[$0.range]) })
        #expect(display.chips.map(\.kind) == parsed.chips.map(\.kind))
        #expect(display.string.filter { $0 == ScriptDisplay.attachment }.count == parsed.chips.count)
        #expect(display.length == display.string.utf16.count)
        #expect(display.words.count == parsed.tokens.count)
    }
    #expect(ScriptDisplay(sample).chips.map(\.kind) == [.pause(0.5), .speed(0.8), .stress, .stressEnd, .speedEnd, .say("Koo-ber"), .sayEnd,
                                                       .direction("confident")])
    #expect(ScriptDisplay("half [pause 0.5 and [] brackets ]").chips.isEmpty)
}

@MainActor @Test func canonicalTextRoundTripsThroughTheTextView() {
    for style in [ScriptTextView.Style.row, .read] {
        for text in lines {
            let display = ScriptDisplay(text)
            let attributed = ScriptTextNSView.attributed(display, metrics: ScriptTextMetrics(style))
            #expect(attributed.string == display.string)
            let read = ScriptDisplay.read(attributed)
            #expect(read.text == text)
            #expect(read.offsets == (0...display.length).map(display.canonical))
            for chip in display.chips {
                #expect(attributed.attribute(.scriptTag, at: chip.location, effectiveRange: nil) as? String == chip.tag)
                let cell = (attributed.attribute(.attachment, at: chip.location, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell
                #expect((cell as? ScriptChipCell)?.kind == chip.kind)
                #expect((cell as? NSCell)?.accessibilityLabel() == ScriptDisplay.accessibilityLabel(chip.kind))
            }
        }
    }
    // An attachment character without a tag isn't part of the line.
    #expect(ScriptDisplay.read(NSAttributedString(string: "a\u{FFFC}b")).text == "ab")
}

@Test func offsetsMapBetweenTheTextAndTheDisplay() {
    let display = ScriptDisplay("Hi [pause 0.5] there")
    #expect(display.string == "Hi \u{FFFC} there")
    #expect(display.chips[0].location == 3 && display.chips[0].canonical == NSRange(location: 3, length: 11))
    #expect(display.display(3) == 3 && display.display(14) == 4 && display.display(20) == 10)
    #expect((4...13).allSatisfy { display.display($0) == 3 })       // inside the tag: before its chip
    #expect(display.canonical(3) == 3 && display.canonical(4) == 14 && display.canonical(10) == 20)
    #expect(display.canonical(NSRange(location: 2, length: 3)) == NSRange(location: 2, length: 13))

    // UTF-16 widths: the emoji is four units, the flag four, the accent one.
    let emoji = ScriptDisplay("👋🏽 [breath] é [stress]日本[/stress] 🇬🇧")
    #expect(emoji.chips.map(\.location) == [5, 9, 12])
    #expect(emoji.canonical(6) == 13 && emoji.display(13) == 6)
    for text in lines {
        let display = ScriptDisplay(text)
        for offset in 0...display.length { #expect(display.display(display.canonical(offset)) == offset) }
        for (word, token) in zip(display.words, display.parsed.tokens) {
            #expect(display.canonical(word.range) == NSRange(token.range, in: text))
        }
    }
}

@Test func selectionsMapToDisplayWords() {
    let display = ScriptDisplay(sample)
    #expect(display.parsed.tokens.map(\.text) == ["Meet", "VocalCord", "—", "your", "voice,", "cloned", "and", "free.", "Say", "Kuber", "right."])
    let pause = chip(.pause(0.5), in: display).location
    let stressEnd = chip(.stressEnd, in: display).location
    let cord = at("Cord", in: display), loned = at("loned", in: display)

    #expect(display.words(in: NSRange(location: pause, length: 1)) == nil)                     // only a chip
    #expect(display.words(in: NSRange(location: pause - 1, length: 3)) == nil)                 // a chip and its spaces
    #expect(display.words(in: NSRange(location: cord, length: pause + 1 - cord)) == 1...1)     // part of a word and a chip
    #expect(display.words(in: NSRange(location: stressEnd, length: 2)) == nil)                 // the two end caps inside "free."
    #expect(display.words(in: NSRange(location: stressEnd, length: 3)) == 7...7)               // ...and its full stop
    #expect(display.words(in: NSRange(location: loned, length: stressEnd - loned)) == 5...7)
    #expect(display.words(in: NSRange(location: 0, length: display.length)) == 0...10)
    #expect(display.words(in: NSRange(location: 2, length: 0)) == nil)

    #expect(display.target(selection: NSRange(location: loned, length: 3)) == .init(words: 5...5, after: 5))
    #expect(display.target(selection: NSRange(location: cord, length: pause + 1 - cord)) == .init(words: 1...1, after: 1))
    #expect(display.range(of: 5...7) == NSRange(location: loned - 1, length: stressEnd + 3 - loned + 1))
}

@Test func theWordUnderAnIndex() {
    let display = ScriptDisplay(sample)
    let pause = chip(.pause(0.5), in: display).location
    let say = chip(.say("Koo-ber"), in: display).location
    #expect(display.word(at: 0) == 0 && display.word(at: 3) == 0 && display.word(at: 4) == nil)
    #expect(display.word(at: at("VocalCord", in: display) + 8) == 1)
    #expect(display.word(at: pause) == nil && display.chip(at: pause) == 0 && display.chip(at: 0) == nil)
    #expect(display.word(at: say + 1) == 9 && display.word(at: say) == nil)
    #expect(display.word(at: at(".", in: display)) == 7)

    // On a word, that word; on a chip or a space, as a caret there.
    #expect(display.target(at: 0) == .init(words: 0...0, after: 0))
    #expect(display.target(at: pause) == .init(words: 1...1, after: 1))
    #expect(display.target(selection: NSRange(location: 0, length: 0)) == .init(words: 0...0, after: -1))
    #expect(display.target(selection: NSRange(location: 2, length: 0)) == .init(words: 0...0, after: 0))
    #expect(display.target(selection: NSRange(location: display.length, length: 0)) == .init(words: 10...10, after: 10))
    #expect(ScriptDisplay("").target(selection: NSRange(location: 0, length: 0)) == .init(words: nil, after: -1))
}

// MARK: Edits

@Test func deletingAChipTakesItsPartner() throws {
    let display = ScriptDisplay(sample)
    func caret(after needle: String, in text: String) -> Int { NSMaxRange((text as NSString).range(of: needle)) }

    // Backspace on an opening chip removes its end too; the words stay.
    let stress = try #require(display.replacing(NSRange(location: chip(.stress, in: display).location, length: 1), with: ""))
    #expect(stress.text == "Meet VocalCord [pause 0.5] — your voice, [speed 80%]cloned and free[/speed]. Say [say Koo-ber]Kuber[/say] [confident] right.")
    #expect(stress.caret == caret(after: "cloned and ", in: stress.text))

    // ...and on a closing chip, its opening. The caret stays after the end cap before it.
    let speedEnd = try #require(display.replacing(NSRange(location: chip(.speedEnd, in: display).location, length: 1), with: ""))
    #expect(speedEnd.text == "Meet VocalCord [pause 0.5] — your voice, cloned and [stress]free[/stress]. Say [say Koo-ber]Kuber[/say] [confident] right.")
    #expect(speedEnd.caret == caret(after: "free[/stress]", in: speedEnd.text))

    // A pause goes alone and its spaces close up.
    let pause = try #require(display.replacing(NSRange(location: chip(.pause(0.5), in: display).location, length: 1), with: ""))
    #expect(pause.text == sample.replacingOccurrences(of: "[pause 0.5] ", with: ""))
    #expect(pause.caret == caret(after: "VocalCord ", in: pause.text))

    // Words and an opening chip selected: the end it leaves behind goes too.
    let and = at("and", in: display), free = at("free", in: display)
    let mixed = try #require(display.replacing(NSRange(location: and, length: free - and), with: ""))
    #expect(mixed.text == "Meet VocalCord [pause 0.5] — your voice, [speed 80%]cloned free[/speed]. Say [say Koo-ber]Kuber[/say] [confident] right.")
    #expect(mixed.caret == caret(after: "cloned ", in: mixed.text))

    // Typing over a chip replaces it and drops its partner.
    let typed = try #require(display.replacing(NSRange(location: chip(.say("Koo-ber"), in: display).location, length: 1), with: "x"))
    #expect(typed.text == "Meet VocalCord [pause 0.5] — your voice, [speed 80%]cloned and [stress]free[/stress][/speed]. Say xKuber [confident] right.")

    // Two chips at once, each with its partner.
    let caps = try #require(display.replacing(NSRange(location: chip(.stressEnd, in: display).location, length: 2), with: ""))
    #expect(caps.text == "Meet VocalCord [pause 0.5] — your voice, cloned and free. Say [say Koo-ber]Kuber[/say] [confident] right.")

    // No chip in the range: the view makes the edit itself.
    #expect(display.replacing(NSRange(location: 0, length: 4), with: "Greet") == nil)

    // Partners, as Marks pairs them.
    #expect(display.partner(of: 1) == 4 && display.partner(of: 4) == 1 && display.partner(of: 2) == 3 && display.partner(of: 5) == 6)
    #expect(display.partner(of: 0) == nil && display.partner(of: 7) == nil)
    #expect(ScriptDisplay("[stress]open only").partner(of: 0) == nil)
}

@Test func theBracketListActsAtTheCaretOrOnTheSelection() throws {
    let caret = NSRange(location: 0, length: 0)
    // A [ typed after "VocalCord ": it comes out, then the command goes in.
    let typed = "Meet VocalCord [today"
    func pick(_ command: ScriptCommand, _ text: String = typed, at offset: Int = 15) throws -> String {
        try ScriptDisplay.bracket(command, in: text, typed: offset, selection: NSRange(location: offset + 1, length: 0))
    }
    #expect(try pick(.pause(0.5)) == "Meet VocalCord [pause 0.5] today")
    #expect(try pick(.breath) == "Meet VocalCord [breath] today")
    #expect(try pick(.speed(0.8)) == "Meet [speed 80%]VocalCord[/speed] today")
    #expect(try pick(.speed(1.2)) == "Meet [speed 120%]VocalCord[/speed] today")
    #expect(try pick(.stress) == "Meet [stress]VocalCord[/stress] today")
    #expect(try pick(.say("Vocal Cord")) == "Meet [say Vocal Cord]VocalCord[/say] today")
    // In the middle of a word: pauses after it, wraps on it.
    #expect(try pick(.pause(0.5), "Meet Voc[alCord today", at: 8) == "Meet VocalCord [pause 0.5] today")
    #expect(try pick(.stress, "Meet Voc[alCord today", at: 8) == "Meet [stress]VocalCord[/stress] today")
    // At the start: a pause before every word, a wrap on the first word.
    #expect(try pick(.pause(0.5), "[Meet VocalCord", at: 0) == "[pause 0.5] Meet VocalCord")
    #expect(try pick(.stress, "[Meet VocalCord", at: 0) == "[stress]Meet[/stress] VocalCord")
    // After a chip, the word before it.
    let display = ScriptDisplay("Meet [pause 0.5] [VocalCord")
    #expect(try pick(.speed(0.8), display.text, at: 7) == "[speed 80%]Meet[/speed] [pause 0.5] VocalCord")

    // With words selected the [ was held back: wraps go on them, a pause after the last.
    let selected = NSRange(location: 5, length: 15)      // "VocalCord today"
    #expect(try ScriptDisplay.bracket(.speed(0.8), in: "Meet VocalCord today", typed: nil, selection: selected)
            == "Meet [speed 80%]VocalCord today[/speed]")
    #expect(try ScriptDisplay.bracket(.pause(0.5), in: "Meet VocalCord today", typed: nil, selection: selected)
            == "Meet VocalCord today [pause 0.5]")

    // An empty line takes a pause; a wrap there is an error to show, not a silent failure.
    #expect(try ScriptDisplay.bracket(.pause(0.5), in: "[", typed: 0, selection: caret) == "[pause 0.5]")
    #expect(throws: AppError.self) { try ScriptDisplay.bracket(.stress, in: "[", typed: 0, selection: caret) }
    #expect(throws: AppError.self) { try ScriptDisplay.bracket(.breath, in: "Meet", typed: 2, selection: caret) }

    #expect(ScriptBracketItem.allCases.map(\.title) == ["Pause 0.5 s", "Breath", "Slower 80%", "Faster 120%", "Stress", "Say it like…"])
    #expect(ScriptBracketItem.allCases.map(\.command) == [.pause(0.5), .breath, .speed(0.8), .speed(1.2), .stress, nil])
}

@Test func customValuesParseOrSayWhatsWrong() throws {
    #expect(try ScriptCommand.seconds("0.75") == 0.75)
    #expect(try ScriptCommand.seconds(".5") == 0.5)
    #expect(try ScriptCommand.seconds(" 2s ") == 2)
    #expect(throws: AppError.self) { try ScriptCommand.seconds("soon") }
    #expect(throws: AppError.self) { try ScriptCommand.seconds("20") }
    #expect(try ScriptCommand.rate("80%") == 0.8)
    #expect(try ScriptCommand.rate("80") == 0.8)
    #expect(try ScriptCommand.rate("0.8x") == 0.8)
    #expect(try ScriptCommand.rate("1.25") == 1.25)
    #expect(throws: AppError.self) { try ScriptCommand.rate("300%") }
    #expect(throws: AppError.self) { try ScriptCommand.rate("fast") }
    #expect(throws: AppError.self) { try ScriptCommand.say("[x]").applied(to: "word", target: .init(words: 0...0, after: 0)) }
}

@Test func caretsFollowChangesFromOutside() {
    let old = "Hello world", new = "Hello there world"
    #expect(ScriptDisplay.moved(2, from: old, to: new) == 2)        // before the change
    #expect(ScriptDisplay.moved(11, from: old, to: new) == 17)      // after it
    #expect(ScriptDisplay.moved(6, from: old, to: new) == 12)       // at it: after the new part
    #expect(ScriptDisplay.moved(8, from: old, to: "Hi") == 2)       // inside a deletion: where it ended
    #expect(ScriptDisplay.moved(3, from: old, to: old) == 3)
}

// MARK: Look

@Test func litRangesCoverWordsNotChips() {
    let display = ScriptDisplay(sample)
    let ns = display.string as NSString
    #expect(display.litRanges(nil).lit.isEmpty && display.litRanges(nil).dim.isEmpty)
    let four = display.litRanges(4)
    #expect(four.lit.map(ns.substring(with:)) == ["Meet", "VocalCord", "—", "your", "voice,"])
    #expect(four.dim.map(ns.substring(with:)) == ["cloned", "and", "free", ".", "Say", "Kuber", "right."])
    #expect((four.lit + four.dim).allSatisfy { range in !display.chips.contains { NSLocationInRange($0.location, range) } })
    #expect(display.litRanges(-1).lit.isEmpty && display.litRanges(-1).dim.count == four.lit.count + four.dim.count)
    #expect(display.litRanges(99).dim.isEmpty)
}

@Test func wrapsAreUnderlinedWithoutCrossing() {
    let display = ScriptDisplay(sample)
    let ns = display.string as NSString
    let lines = display.underlines
    #expect(lines.map(\.wrap) == [.speed, .stress, .say])
    // The speed holds a stress, so it sits a step lower; its line breaks at the stress chip.
    #expect(lines.map(\.level) == [1, 0, 0])
    #expect(lines.map { $0.ranges.map(ns.substring(with:)) } == [["cloned and", "free"], ["free"], ["Kuber"]])
    #expect(ScriptDisplay("plain words").underlines.isEmpty)
}

/// Rows at the table's 13 pt; chips are rounded rectangles a quarter as round as they're tall (never pills), and stress
/// is rose, as amber means a warning.
@Test func chipsAreRoundedRectanglesInDataHues() {
    let row = ScriptTextMetrics(.row), read = ScriptTextMetrics(.read)
    #expect(row.font.pointSize == 13 && read.font.pointSize == 26)
    #expect(row.chipHeight == 16 && row.chipRadius == 4)
    #expect(read.chipHeight == 26 && read.chipRadius == 6)
    for metrics in [row, read] {
        #expect(metrics.chipRadius == (metrics.chipHeight * 0.25).rounded(.toNearestOrEven))
        #expect(metrics.chipRadius < metrics.chipHeight / 2)
        #expect([11, 13, 15].contains(metrics.chipFont.pointSize))
    }
    let stress = ScriptTextMetrics.tint(ParsedLine.Chip.Kind.stress).usingColorSpace(.sRGB)!
    #expect(abs(stress.redComponent - 0xD9 / 255.0) < 0.002 && abs(stress.greenComponent - 0x9B / 255.0) < 0.002
        && abs(stress.blueComponent - 0xB0 / 255.0) < 0.002)
    let amber = NSColor(Theme.amber).usingColorSpace(.sRGB)!
    for kind in [ParsedLine.Chip.Kind.pause(1), .breath, .speed(0.8), .stress, .say("x"), .direction("calm")] {
        let tint = ScriptTextMetrics.tint(kind).usingColorSpace(.sRGB)!
        #expect(abs(tint.redComponent - amber.redComponent) + abs(tint.greenComponent - amber.greenComponent)
            + abs(tint.blueComponent - amber.blueComponent) > 0.1)
    }
}

@Test func chipLabelsAndAccessibility() {
    #expect(ScriptDisplay.label(.pause(0.5))?.text == "0.5s" && ScriptDisplay.label(.pause(0.5))?.symbol == "pause.fill")
    #expect(ScriptDisplay.label(.breath)?.text == "breath")
    #expect(ScriptDisplay.label(.speed(0.8))?.text == "80%" && ScriptDisplay.label(.speed(0.8))?.symbol == "tortoise.fill")
    #expect(ScriptDisplay.label(.speed(1.2))?.symbol == "hare.fill")
    #expect(ScriptDisplay.label(.stress)?.text == "stress")
    #expect(ScriptDisplay.label(.say("Koo-ber"))?.text == "say: Koo-ber")
    #expect(ScriptDisplay.label(.direction("confident"))?.text == "confident" && ScriptDisplay.label(.direction("x"))?.italic == true)
    #expect(ScriptDisplay.label(.speedEnd) == nil && ScriptDisplay.label(.stressEnd) == nil && ScriptDisplay.label(.sayEnd) == nil)

    #expect(ScriptDisplay.accessibilityLabel(.pause(0.5)) == "Pause, 0.5 seconds")
    #expect(ScriptDisplay.accessibilityLabel(.pause(1)) == "Pause, 1 second")
    #expect(ScriptDisplay.accessibilityLabel(.speed(0.8)) == "Slower, 80 percent")
    #expect(ScriptDisplay.accessibilityLabel(.speed(1.2)) == "Faster, 120 percent")
    #expect(ScriptDisplay.accessibilityLabel(.say("Koo-ber")) == "Say it like Koo-ber")
    #expect(ScriptDisplay.accessibilityLabel(.direction("confident")) == "Direction, confident")
}

// MARK: The real view

/// Drawing and windows need a window server; without one (a headless CI runner) these tests skip.
private let windowServer = CGSessionCopyCurrentDictionary() != nil

/// Snapshots go here, or to $SCRIPTTEXT_SNAPSHOTS.
private let snapshots = URL(filePath: ProcessInfo.processInfo.environment["SCRIPTTEXT_SNAPSHOTS"]
    ?? FileManager.default.temporaryDirectory.appending(path: "VocalCordSnapshots").path)

/// The view in an off-screen window, sized as SwiftUI would size it at `width`.
@MainActor
private func host(_ text: String, style: ScriptTextView.Style, lit: Int? = nil, width: CGFloat, pad: CGFloat = 24) -> (ScriptTextNSView, NSWindow) {
    _ = NSApplication.shared
    let view = ScriptTextNSView(style: style)
    view.placeholder = "Text"
    view.update(text: text)
    view.setLit(lit)
    let height = view.height(forWidth: width)
    let size = NSSize(width: width + pad * 2, height: height + pad * 2)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    let backdrop = Backdrop(frame: NSRect(origin: .zero, size: size))
    window.contentView = backdrop
    view.frame = NSRect(x: pad, y: pad, width: width, height: height)
    backdrop.addSubview(view)
    return (view, window)
}

private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.content).setFill()
        dirtyRect.fill()
    }
}

@MainActor @Test(.enabled(if: windowServer, "Needs a window server to draw."))
func snapshotsOfBothStyles() throws {
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    let shots: [(name: String, text: String, style: ScriptTextView.Style, lit: Int?, width: CGFloat)] = [
        ("row", sample, .row, nil, 520),
        ("row-narrow", sample, .row, nil, 300),
        ("row-empty", "", .row, nil, 300),
        ("read", sample, .read, nil, 720),
        ("read-lit4", sample, .read, 4, 720),
    ]
    for shot in shots {
        let (view, window) = host(shot.text, style: shot.style, lit: shot.lit, width: shot.width)
        let backdrop = try #require(window.contentView)
        // At 2x whatever the screen, so the chips' edges can be checked.
        let base = try #require(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(backdrop.bounds.width * 2),
                                                pixelsHigh: Int(backdrop.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: base.colorSpaceName, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = backdrop.bounds.size
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: snapshots.appending(path: "scripttext-\(shot.name).png"))
        #expect(view.frame.height > 0)
        window.close()
    }
}

@MainActor @Test(.enabled(if: windowServer, "Needs a window server to lay out text."))
func sizesLikeAVerticalTextField() {
    let (view, window) = host(sample, style: .row, width: 520)
    defer { window.close() }
    // One line is a 13 pt line, the row's body size; chips don't make a line taller.
    let line = ceil(NSLayoutManager().defaultLineHeight(for: .monospacedDigitSystemFont(ofSize: 13, weight: .regular)))
    #expect(line == 16)
    #expect(view.height(forWidth: 5000) == line)
    #expect(ScriptTextNSView(style: .row).height(forWidth: 300) == line)
    // Narrower wraps onto more lines.
    #expect(view.height(forWidth: 300) > view.height(forWidth: 520))
    #expect(view.height(forWidth: 120) > view.height(forWidth: 300))
    #expect(view.naturalWidth() > 520)
    #expect(ScriptTextNSView(style: .read).height(forWidth: 300) > 30)
}

@MainActor @Test(.enabled(if: windowServer, "Needs a window server for text views."))
func editingInTheView() throws {
    let (view, window) = host("Meet VocalCord today", style: .row, width: 400)
    defer { window.close() }
    var changes: [String] = [], commands: [String] = []
    view.onChange = { changes.append($0) }
    view.onCommand = { commands.append($0) }
    #expect(view.accessibilityValue() == "Meet VocalCord today")

    // Typing a tag by hand turns it into a chip at the closing ].
    view.setSelectedRange(NSRange(location: 14, length: 0))
    for character in " [pause 0.3]" { view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    #expect(changes.last == "Meet VocalCord [pause 0.3] today")
    #expect(view.string == "Meet VocalCord \u{FFFC} today")
    #expect(view.selectedRange() == NSRange(location: 16, length: 0))
    #expect(view.accessibilityValue() == "Meet VocalCord today")

    // Undo and redo go through the view's own history of canonical texts.
    view.undo(nil)
    #expect(view.display.text == "Meet VocalCord today" && changes.last == "Meet VocalCord today")
    view.redo(nil)
    #expect(view.display.text == "Meet VocalCord [pause 0.3] today" && view.selectedRange() == NSRange(location: 16, length: 0))

    // Backspace takes the chip as one, and a wrap's end takes its partner.
    view.deleteBackward(nil)
    #expect(changes.last == "Meet VocalCord today")
    view.update(text: "Meet [stress]VocalCord[/stress] today")
    #expect(view.string == "Meet \u{FFFC}VocalCord\u{FFFC} today")
    view.setSelectedRange(NSRange(location: 16, length: 0))      // after the end cap
    view.deleteBackward(nil)
    #expect(changes.last == "Meet VocalCord today")

    // A menu command goes out through onCommand.
    view.update(text: "Meet VocalCord today")
    view.setSelectedRange(NSRange(location: 5, length: 9))
    let point = view.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 6, length: 1), in: view.textContainer!).origin
    let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(NSPoint(x: point.x + 2, y: point.y + 8), to: nil),
                                                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1))
    let menu = try #require(view.menu(for: event))
    #expect(menu.items.map(\.title) == ["Pause after", "Breath after", "Slower", "Faster", "Stress", "Say it like…", "", "Cut", "Copy", "Paste"])
    let slower = try #require(menu.items[2].submenu?.items.map(\.title))
    #expect(slower == ["90%", "80%", "70%", "Custom…"])
    let eighty = try #require(menu.items[2].submenu?.items[1])
    _ = (eighty.target as AnyObject).perform(eighty.action, with: eighty)
    #expect(commands.last == "Meet [speed 80%]VocalCord[/speed] today")
    #expect(view.display.text == commands.last)

    // On a chip: Change… and Remove.
    let chipPoint = view.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 5, length: 1), in: view.textContainer!)
    view.setSelectedRange(NSRange(location: 0, length: 0))
    let onChip = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(NSPoint(x: chipPoint.midX, y: chipPoint.midY), to: nil),
                                                 modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1))
    let chipMenu = try #require(view.menu(for: onChip))
    #expect(chipMenu.items.prefix(2).map(\.title) == ["Change…", "Remove"])
    let remove = chipMenu.items[1]
    _ = (remove.target as AnyObject).perform(remove.action, with: remove)
    #expect(commands.last == "Meet VocalCord today")
}

@MainActor @Test(.enabled(if: windowServer, "Needs a window server for text views."))
func highlightingTouchesAttributesOnly() {
    let (view, window) = host(sample, style: .read, width: 600)
    defer { window.close() }
    let display = view.display
    let attachment = view.textStorage!.attribute(.attachment, at: display.chips[0].location, effectiveRange: nil) as AnyObject
    func color(_ word: Int) -> NSColor? {
        view.layoutManager!.temporaryAttributes(atCharacterIndex: display.words[word].pieces[0].location, effectiveRange: nil)[.foregroundColor] as? NSColor
    }
    #expect(color(0) == nil)
    view.setLit(4)
    #expect(color(4) == NSColor(Theme.text) && color(5) == NSColor(Theme.secondary))
    view.setLit(5)
    #expect(color(5) == NSColor(Theme.text))
    view.setLit(nil)
    #expect(color(5) == nil)
    // The text wasn't rebuilt: the same attachment is still in place.
    #expect(view.textStorage!.attribute(.attachment, at: display.chips[0].location, effectiveRange: nil) as AnyObject === attachment)

    // Outside text replaces it when the view isn't being edited.
    view.update(text: "New words")
    #expect(view.display.text == "New words" && view.string == "New words")
}

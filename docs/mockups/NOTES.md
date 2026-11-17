# VocalCord UI directions

These are image-generated, 16:10 concept screens for the Clone and Generate workspaces. The menu is shown open in Generate so all four helper choices are visible.

## A — Studio Ledger

- **Layout:** A compact take table and script rows make tone, transcript, score, and action easy to scan. The Generate workspace gives the script the largest pane.
- **Palette:** Near-black `#070809`, charcoal glass `#202526`, light text `#F1F3F0`, one muted mint accent `#79C8B6`.
- **Type:** SF Pro with restrained size changes, tabular numerals for scores and time, and short control labels.
- **Glass:** Frosted sidebar and inset panels; fine edge highlights define pane boundaries while solid dark row surfaces preserve contrast.

## B — Recording Console

- **Layout:** A two-column tone-module grid and waveform-led script strips put playback and recording controls at the center of the experience.
- **Palette:** Near-black `#080705`, warm charcoal glass `#24201D`, off-white text `#F0EDE8`, one muted copper accent `#D3A36B`.
- **Type:** SF Pro with strong module headings, compact transcripts, and prominent numeric scores.
- **Glass:** Each tone module and workspace pane has a frosted surface with a thin specular rim; the waveforms stay on darker surfaces for clarity.

## C — Editorial Track Sheet

- **Layout:** One featured Neutral tone sits above a compact tone index. Generate uses large script lines and thin rules instead of cards.
- **Palette:** Near-black `#050607`, neutral glass `#202326`, warm light text `#E6E4DF`, one desaturated coral accent `#C98172`.
- **Type:** SF Pro with a larger editorial script scale and smaller, quiet metadata; line numbers provide a clear reading order.
- **Glass:** Limited to the sidebars, selected take, and picker; the script canvas stays open and dark, with fine edge highlights around frosted areas.

## Design judgment

**Rank: 1. A, 2. C, 3. B.** A is the strongest starting point for v1 because it exposes the most editing state without making the window feel busy. Its weakness is wasted space: the Clone pronunciation inspector is too wide for one entry, and Generate shows only four lines above a large empty canvas. The mint treatment also makes selection, success, and the low-score warning look too similar.

C has the clearest reading flow and the most disciplined use of glass. Its script type and vertical spacing are too large for a working editor; the user would see too few lines in a longer voiceover. The featured Neutral take also gives that tone more visual importance than the others without a task reason.

B communicates audio immediately, but the repeated waveforms, level meters, and knobs in every script line consume space without helping the main task. The glass rims and copper highlights compete with the text; it feels closer to a hardware console than to a fast script editor.

### Changes to make in A

1. Narrow the Clone pronunciation inspector from roughly 320 px to 240 px and give that width to the take transcripts. Keep Pronunciations available as a collapsible inspector.
2. In Generate, reduce script row height to about 76 px and show at least seven lines at this window size, preserving the same voice, tone, pause, and score controls.
3. Add a visible `Pause` column heading. Align all three score values to fixed columns so low scores can be compared line to line.
4. Reserve mint fill for the active item and primary action. Mark low scores with an outlined row, warning icon, and bold value in neutral text, using no second accent color.
5. Keep the helper picker closed by default; opening it reveals Claude, Codex, OpenCode, and Manual. Retain the menu shown in the mockup as a state reference.

## Round 2

The three screens use A's aligned tables and output metadata, C's solid dark content canvas and limited glass, and B's small take waveforms. Active states are neutral grey. Each screen has one off-white primary button; Record uses the permitted red dot. The only other accent is the amber triangle beside Generate line 3's low score.

### Final Clone

- The take table has one `Like you` heading; cells contain percentages only. Neutral and Happy have radio controls in `Main`; single-take tones have blank cells. Every tone has an `Add take` action, and Hesitant has `Record`. The narrow Pronunciations inspector shows `Kuber → Koo-ber` and `Add`.
- Still wrong: the per-tone `Add take` actions sit in an unlabeled gutter beyond the stated five table columns. The top-level `Add take` action repeats the same control label by design. The central table has a prominent rounded frame, making the canvas slightly less open than intended.

### Final Generate

- One script header names `Like you`, `Human`, and `Words` once; eight rows show only numeric scores in percentage, 1.0–5.0, and percentage formats. Line 3 uses an amber warning triangle and a bold neutral `62%`. Each row has a re-render icon and version picker. The helper picker is closed, and Outputs shows name, format, duration, and date for three items.
- Still wrong: the re-render icons sit in an unlabeled control gutter after `Version`, and the script region has a fine enclosing frame rather than a completely edge-free canvas. The output dates are abbreviated to `Jan 26` without a year.

### Final Full Clone

- All five guided steps appear in order, with `Sentences` active and `12 / 30` shown once. The sentence, large `Record` button, input level meter, `Re-record previous`, and `Pause session` are present. The selected in-progress voice is `Untitled voice`, avoiding a duplicate `New voice` label. Glass stays on the toolbar and sidebar; the central area is solid dark.
- Still wrong: the level meter is a static mockup, so its live behavior cannot be judged from this image.

Files written:

- `docs/mockups/final-clone.png`
- `docs/mockups/final-generate.png`
- `docs/mockups/final-full-clone.png`
- `docs/mockups/NOTES.md`

## Round 3

The approved Round 2 composition, neutral grey selection, near-black palette, limited glass, single score headers, amber low-score warning, and red Record dot remain in place.

### Final Clone

- The top `Add take` button and all repeated table `Add take` buttons are gone. The hovered Confident row has a small `+` with an open `Record` / `Upload` menu. Hesitant has only compact `Record` (red dot) and `Upload` buttons. The toolbar keeps the gear without the sliders icon, and the Pronunciations `Add` button is centered.
- Still wrong: the rounded table frame and unlabeled action gutter from Round 2 remain. The open menu visually covers part of the Happy row, which is appropriate for this transient popover state but obscures that row in the static image.

### Final Generate

- The toolbar replaces the Claude picker with an active grey `Terminal` toggle while retaining the Clone / Generate switch, outlined `Render`, and primary `Export`. An open bottom Terminal panel has a drag handle, the three requested agent tabs, close button, and the complete monospace session. Line 3 shows the struck-through original, the proposed rewrite, and check / x decisions. Two other Text cells wrap. The Preview waveform has thin line boundaries.
- Still wrong: the row-end rerender icons remain in the unlabeled control gutter and the script keeps its enclosing frame, as in Round 2. Output dates still omit the year. The Terminal toggle is drawn as a switch inside a button; its active state is clear, but the control is visually busier than a simple filled button.

### Final Full Clone

- `Sentence 12` and `Input level` labels are removed while `12 / 30` and the meter remain. A smaller outlined `Upload` button sits beside the large primary `Record` button. The sentence, progress steps, and session controls remain in place.
- Still wrong: the static meter cannot demonstrate live level warnings or recording behavior.

Files written in Round 3:

- `docs/mockups/final-clone.png`
- `docs/mockups/final-generate.png`
- `docs/mockups/final-full-clone.png`
- `docs/mockups/NOTES.md`

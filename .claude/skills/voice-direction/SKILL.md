---
name: voice-direction
description: How to get natural voiceover from VocalCord's local voice model (Breeze TTS 2) - recording takes to clone from, writing scripts for the ear, choosing tones, reading scores and testing changes. Use when writing or fixing a voiceover script, judging or recording takes, changing tone directions or render settings, or when a render sounds unnatural, choppy, cut off or unlike the speaker.
---

# Voice direction

VocalCord clones a voice from one take per line. Most quality comes from the take and the script, not from settings.
The in-app agent can't load this skill: its short version of these rules is `Agent.instructions` in
`Sources/VocalCord/Terminal.swift`, and the rules code can check are `Script.warnings` (`ProjectStore.swift`) and
`AudioIssue.cutOff` (`Audio.swift`, `engine/vocalcord_engine/audio.py`). Change all three together.

## How a render works

- Breeze is an in-context model, the same family as Qwen3-TTS (it uses Qwen3-TTS's audio encoder). Each render gets
  one reference take and its exact transcript, then continues it with the new text. It copies the take's timbre,
  mood, pace and room, not just "the voice". There is no training on the user's voice.
- The take is the tone's main take (`Voice.reference`); a tone with no take uses the Neutral take plus a written
  direction (`STYLES` in `engine/vocalcord_engine/tts.py`) at `cfg_scale` 4. That multiplies the direction's effect, so
  a direction can move the voice: "brighter, slightly quicker" for Happy raised the pitch by up to 6 semitones in a
  test. Directions must not ask for pitch or speed changes; a real take in that tone beats any direction.
- Tones are hidden in the app for now (`Tone.enabled` in `VoiceStore.swift`): Neutral sounded best most of the time,
  so every line is Neutral, rendered from the Neutral main take with no direction.
- Every `generate` call is a fresh take. Within one call the voice keeps its flow; across calls mood, pace and
  intonation restart. Text over 600 characters and a mid-line tone direction (`[confident]`) split a line into separate
  calls. Script commands don't: the app renders the line whole, times each word with Whisper, then inserts
  `[pause 0.5]`/`[breath]`, stretches `[speed 80%]…[/speed]` and lifts `[stress]…[/stress]` (`engine/vocalcord_engine/marks.py`).
- Limits: 12.5 sound frames a second, at most 750 per call, so 60 s is the hard cap of one call (it cuts off mid-word).
  About 600 characters (35-40 s) is the practical line length; keep slow lines to 300-400 characters.
- Speed on an 8 GB M1: 4-bit renders a short line in roughly 10-70 s, 8-bit about 3-4 times slower.

## Takes (what to record)

1. 10-15 s, up to 20. Longer adds little and can make Qwen-family models loop or hang.
2. Half a second of silence before and after. A take that starts or ends mid-word is the strongest single sign of a
   bad reference: the model carries the last sound into the start of every render. `cut_off` flags it.
3. Clean beats long: a hand's width from the mic, a quiet room with soft furnishings, no fan or music. Echo and noise
   are cloned as if they were the voice.
4. One mood per take, spoken the way the output should sound: a flat take gives flat renders, a storytelling take
   gives storytelling renders. While tones are hidden, a voice's takes all come from one natural reading of the
   in-app script (`CloneScript.swift`), cut at its pauses (`clips.py`); with tones back, record a take per tone.
5. The transcript must match the words exactly; clear speech whose Whisper transcript is confident clones best.
6. Choose takes by what they render, not by how clean they sound. `audition` renders a test line from the top
   candidates per tone and scores them.

## Scripts (what to write)

- One paragraph per line, up to 600 characters; a new line at a change of scene or tone.
- Short sentences, one idea each, under 25 words, with a very short one now and then ("It shouldn't.").
- Pauses come from punctuation: comma short, full stop longer, colon sets up, ellipsis adds weight (rarely),
  question mark rises. Longer gaps go in the line's pause after. Add `[pause]` for a beat after a key idea, not as
  a replacement for punctuation; it goes in after rendering, so it no longer breaks the take.
- Pace a phrase with `[speed 85%]…[/speed]` (instant, no new render); past about 70-130% it sounds stretched. Stress
  one word a line at most; the model follows `[stress]` loosely, so the app adds a small lift too.
- Put the stressed word at the end of its sentence; English stresses the last content word.
- Contractions ("don't"). Numbers, symbols and abbreviations as spoken words ("four ninety-nine", "Doctor").
- Let the words carry the emotion, and give the line the tone they call for.
- About 150 words is a minute. Keep a normal pace and pause after new ideas; don't slow everything down.
- Respell words the voice says wrong: for every line in the voice's pronunciations (Kuber as Koo-ber), for one line
  with `[say Koo-ber]Kuber[/say]` (needs a new render).

## Judging a render

- Scores (`engine/README.md`): like_you under 70%, words under 90%, or human more than 0.5 below the take's own are
  low. like_you is unreliable under 3 s of audio.
- Delivery checks (`Version.flags` in `ProjectStore.swift`): pitch more than 1.5 semitones off the take
  (`scoring.pitch`), pace more than 35% off the take's on lines of 6 s or more (`Scores.paced`), and a gap over 1.2 s
  mid-line (`scoring.longest_pause`). Slow and Hesitant skip pace and gaps.
- Nothing renders on its own. Render in Generate (the toolbar, ⌘R) reads the whole script as one take per run of
  consecutive lines in one voice, up to 600 characters (`OneTake.swift`), and cuts it into the lines at Whisper word
  times, so the lines share one flow. Rows have no voice render, only Apply for marks; an edit applies changed pauses
  and speeds at once but leaves new words for Render (`commitLine(render:)`). `render_line` renders once for the agent. Voice check in
  Clone (`VoiceCheck.swift`) renders ten test lines once each and shows its time estimate first, from `RenderSpeed`
  (measured seconds of rendering per second of audio).
- Each render comes out a little different: render again before rewriting. Listen on a phone speaker too.
- One voice across lines: each line is a fresh take, so one can come out lower, faster or less like the voice than
  the rest. `Consistency.notes` (`Consistency.swift`) flags a line more than 1.5 semitones, 30% in pace or 10 Like you
  points off the other lines' median (pace and Like you from 3 s), and get_script hands it to the agent as
  `different_from_other_lines`. Render that line again first.
- Choppy or cut pauses: check for mid-line directions (they split the take) and for a take that is cut off; renders
  fade at part edges and drop a stray pop after dead air (`audio.fade`, `audio.trim_outer_silence`). An inserted
  pause or speed join that clicks means Whisper's word times were off there (low `matched` in `get_pacing`).
- Pace check (`Pace.report` in `Marks.swift`): words a minute against the take's pace or the project's target, with
  rushed and dragging phrases; the script's own pauses don't count.

## Testing a change

Scores from two renders are noise (like_you was 78 and 98 for the same line and settings). Before changing a direction,
cfg or default, render the same 2-3 lines with 2+ seeds per variant from the same take, then compare like_you, pitch
(median F0 against the take's) and the user's ears, blind if possible. Load the model as `worker.py` does
(`mlx_audio.tts.load`) and score with `scoring.Scorer`; close other apps on 8 GB.

## Sources

- [What makes a good audio prompt for zero-shot TTS](https://arxiv.org/html/2610.40372v1) (take choice, ending in silence)
- [Breeze TTS 2 model card](https://huggingface.co/BreezeBlue/Breeze-TTS-2)
- [Qwen3-TTS cloning guide](https://ocdevel.com/blog/20260302-qwen-tts-voice-cloning) (10-15 s, transcripts, looping)
- [ElevenLabs best practices](https://elevenlabs.io/docs/overview/capabilities/text-to-speech/best-practices) (pauses, normalisation)
- [Writing for AI voices](https://kveeky.com/resources/ai-voice-pacing-emphasis-breath) (stress, sentence length, pace)

# VoiceDesk

A small, on-demand macOS voice controller. Press **Control–Option–Space** to start
recording and press it again to send the request. The microphone and Apple's
on-device speech recognizer run only while recording.

## Commands

- “Open Safari” opens a matching installed app.
- “Find budget on my Mac” searches Spotlight and reveals the first match in Finder.
- “Search the web for …” asks the signed-in Codex CLI to research the question.
- “Dictate Hello there” pastes “Hello there” into the app that was focused when
  recording started.
- “Start dictation” enters dictation mode. Subsequent recordings are pasted as
  text until “Stop dictation.”

Other requests go to Codex in a read-only sandbox. The app speaks a short
completion message after the request finishes and shows the full answer on
screen. Web answers use the existing ChatGPT sign-in for Codex CLI, subject to
that account's limits. The app does not use an OpenAI API key.

## Build and run

Requires macOS 26 or later, Xcode command line tools, and a signed-in Codex CLI
for web requests. Run `./build.sh`, then open `VoiceDesk.app`. macOS will ask for
Microphone, Speech Recognition, and Accessibility permissions. Accessibility is
needed only to paste dictated text into another app.

The first run may need to download an Apple speech model for your locale. The
app never falls back to cloud speech recognition. The app uses the macOS system
voice for low-latency spoken replies on an 8 GB Mac. Web answers also appear in
a window.

## Direct each part of a video

`directed_voice.py` uses the already installed Breeze TTS 2 MLX model and your
private voice reference. It loads the model only while rendering. The
locally installed Breeze weights and their outputs are licensed for **research
and noncommercial use only**; use this renderer for personal, nonmonetized
videos. See the [model license](https://huggingface.co/BreezeBlue/Breeze-TTS-2/blob/main/LICENSE).

Open **VoiceDesk → Video voiceover…** from the menu bar, or launch the app with
`--video-window` to open the editor immediately. Paste your script and choose
**Directed voiceover** to follow the direction tags, or **Compare styles** to
render the same words in neutral, confident, sad, and happy voices. The compare
mode keeps pauses and recorded breaths but replaces the direction tags. Each
result appears in the window with its own **Play** and **Show** buttons.

The app uses the local 8-bit Breeze model by default; choose 4-bit for a faster
render. The sliders set direction strength, final loudness, and the length added
by the **Pause** button. Results are saved automatically in `~/Movies/VoiceDesk`
with distinct filenames and matching `.json` timing files. Rendering loads the
model on demand and does not download it again. The video editor itself needs
no sign-in or API key.

## Voice library

Open **VoiceDesk → Voice library…** to listen to your saved reference voice,
create another voice from your own recording, or add more takes to an existing
voice. Record or import audio, then enter the exact words spoken in that take.
You can edit the transcript later with **Edit words**. Recordings must be 3–60
seconds. All takes and their transcripts stay under
`~/Library/Application Support/VoiceDesk/Voices`.

Select a take and label its delivery as neutral, confident, happy, sad, angry,
soft, slow, or hesitant. **Clean selected take** makes a separate denoised and
normalized copy; the original stays in the library. Select a new take, enter a
short test line, and choose **Generate comparison**. The app renders Current and
New take with one model load and gives each version a Play button. Test WAVs and
timing files go to `~/Movies/VoiceDesk/Voice tests`. Choose **Use** beside the
take you prefer to make it the current reference.

The video voiceover window now lets you choose a saved voice. A script section
tagged `[sad]`, for example, uses a saved sad take for that voice when available.
Other sections use the current reference. These speaking-style labels select
reference recordings; they do not train Breeze or improve audio by themselves.
The Breeze model still uses one reference recording and its exact transcript
for each generated section.

Use tags before each part. Tags can be on separate lines or within one line:

```text
[confident] We built a faster way to find what matters.
[pause 0.30]
[sad] But the first attempt failed.
[pause 0.35]
[happy] Then we found a better answer.
```

The built-in directions are `neutral`, `confident`, `sad`, and `happy`. You can
write any custom direction in the brackets, such as `[Speak quietly, as if
sharing a secret]`. `[pause 0.30]` inserts exactly 0.30 seconds of silence.
`(sigh)` asks Breeze to generate a sigh inside a spoken part. For an exact,
audible inhale, record your breath in the app (or choose a short WAV), then
insert `[breath]`. The script editor has buttons for these tags.
Render the included demonstration with:

```sh
~/voice/venv/bin/python directed_voice.py \
  --script samples/directed-demo.txt \
  --reference samples/reference.wav \
  --reference-text-file samples/reference.txt \
  --model ~/voice/models/Breeze-TTS-2-mlx-8bit \
  --output samples/directed-demo.wav
```

For a script containing `[breath]`, add `--breath-audio path/to/short-inhale.wav`.
The breath WAV must be between 0.05 and 2 seconds. The app prompts you to
choose it before rendering.

Add `--all-styles` to the command above to render four WAV files from one model
load. Their names end in `-neutral`, `-confident`, `-sad`, and `-happy`.

The output WAV is normalized for listening, and a JSON file with the same name
records each section's start and end time for editing or video sync. The model
stays downloaded at `~/voice/models/Breeze-TTS-2-mlx-8bit` (or the lighter
`~/voice/models/Breeze-TTS-2-mlx-4bit`) and never needs to download again.

The app replaces the clipboard when it pastes dictation. Quit from the menu bar
to stop the shortcut listener.

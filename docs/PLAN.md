# VocalCord v1 plan

VocalCord is a Mac app for making voiceovers in your own cloned voices. Everything
runs on your Mac except the optional terminal agents and the Jev plugin.

Status: draft for sign-off. Nothing below is built yet.

For: personal, non-commercial videos on an Apple Silicon Mac with macOS 26.

## Clone

**Voice list:** every voice with its tones and best score. **New voice** sits at
the top. Click a voice to open its page.

**New voice** offers two paths:

- **Fast clone:** one 10–20 second clip, recorded or uploaded. Whisper writes
  the transcript; you fix any wrong word.
- **Full clone:** a guided session you can pause and resume.
  1. Room check: 10 seconds of silence. Warns when background noise is high.
  2. About 30 sentences that cover every English sound, shown one at a time.
  3. Free speech: two 1-minute rounds on a suggested topic. Whisper transcribes
     it and cuts it into clips at natural pauses.
  4. Tones: for each tone, about 5 sentences written for that emotion and
     30 seconds of free speech.
  5. Audition: renders one test line from the top 5 candidates per tone, scores
     them, and makes the best one the main take for that tone.

  Natural voice takes about 8 minutes; each tone adds about 2. Any step also
  accepts uploaded audio or video of any length; Whisper cuts it into clips at
  natural pauses, and the clips join the audition.

**Voice page** holds everything for one voice:

- Takes grouped by tone, each with play, editable transcript, score, and delete.
- The main take for each tone. Record or upload missing tones or more takes,
  then audition again.
- **Pronunciations:** words and the spelling the model says correctly, such as
  Kuber → Koo-ber. Applied to every render in this voice.
- Rename or delete the voice.

**Tones:** Neutral, Confident, Happy, Sad, Angry, Soft, Slow, Hesitant.

While recording, a level meter warns about audio that is too quiet, clipped, or
noisy; uploads get the same checks. Creating a voice asks you to confirm it is your voice or that you have the
speaker's permission. Raw recordings are always kept.

## Generate

A workspace with three panes.

**Projects** (left): each project is a script and its outputs. Autosaved.

**Script** (centre):

- Paste or import `.txt` or `.md`. VocalCord splits it into lines; each line has
  a voice, a tone, a pause after it, and its text.
- One script can use several voices, such as a narrator and a guest.
- **Terminal** (optional): Claude Code, Codex, or OpenCode, in a panel under the
  script, rewrites it for speaking, with shorter sentences, pauses, breaths, and
  a tone per line (see [Terminal](#terminal)).
- **Manual:** buttons for voice, tone, pause, breath, and sigh tags.
- Render the whole script or one line. Each line shows its scores (see
  [Scores](#scores)); low-scoring lines are flagged.
- **Compare styles:** the same script in several tones, using recorded tone
  takes. A tone with no recorded take falls back to a written direction and is
  labelled that way.

**Preview and outputs** (right):

- **Preview:** a waveform of the whole voiceover. Click a line to play it, or
  play from any point. Drop in a video to watch the voiceover over it, with a
  start offset to line them up.
- **Outputs:** every render and export in the project, newest first, with play,
  compare two, show in Finder, and delete. Re-rendering a line adds a version
  here; you pick the one the voiceover uses.
- **Export:** WAV or M4A, loudness preset (−16 LUFS by default), optional file
  per line or per voice, SRT captions, and a timing JSON.

## Terminal

A **Terminal** button in the toolbar opens a panel under the script, with a tab
for each installed agent: Claude Code, Codex, OpenCode. Each tab runs the real
CLI with the user's own login, so signing in happens there too. Off-topic
requests get "I only help with voiceover scripts."

The agent can call only these tools, served by VocalCord:

| Tool | Purpose |
|---|---|
| `get_voices` | Voice names with their tones and takes (no audio) |
| `get_script`, `update_script` | Read the script and propose changes |
| `render_line` | Render one line |
| `get_scores` | Scores for a line, including what Whisper heard |
| `check_script` | Jev checks; present only when the Jev plugin is added |

Proposed changes appear in the script; you accept or reject each changed line.
An agent can render, read the scores, fix a line, and check again.

- **Claude Code:** built-in tools off and only VocalCord tools allowed. The
  user's settings, CLAUDE.md, and MCP servers are not loaded.
- **OpenCode:** a VocalCord agent with built-in tools off.
- **Codex:** its shell cannot be turned off, so it runs read-only in an empty
  temporary folder and ignores the user's config.

The CLI starts a small bridge that forwards tool calls to the running app over a
local socket. The app owns the one engine, so a render never loads a second
model, and script changes show up live. The panel uses SwiftTerm (MIT licence).

## Jev plugin

Settings → Plugins → Add Jev asks for an API key and stores it in the Keychain.
Jev reads text only, so it checks the script, not audio:

- Does each line read like something a person would say aloud?
- Did an agent's rewrite keep the meaning?
- Does each line fit its tone?

Without the plugin, Jev results and `check_script` do not appear.

## Scores

All scores are computed on the Mac at no cost:

- **Sounds like you:** a speaker-similarity model compares the render with the
  line's voice, as a percentage.
- **Sounds human:** a naturalness predictor, from 1 to 5.
- **Words right:** Whisper's transcript compared with the script, in code.

The exact models are chosen during the engine milestone and must fit in 8 GB.

## Engine and storage

- SwiftUI app with Liquid Glass on black.
- A Python worker process using mlx-audio: Breeze for speech, Whisper for
  transcripts, and the scoring models. The model stays loaded while you work and
  unloads after 2 idle minutes, so re-rendering one line does not reload it.
- Data: `~/Library/Application Support/VocalCord` (voices, projects, engine).
  Exports: `~/Movies/VocalCord`.
- First run checks the Mac and free disk space (about 7 GB), installs Python
  packages with uv, and downloads Breeze, Whisper, and the scoring models, with
  progress shown. Breeze comes in Best quality (8-bit, 4.3 GB, default) or Fast
  (4-bit, 2.8 GB); Settings can switch later.

## Distribution

- GitHub repo under 0xSarnavo with an unsigned DMG in Releases. Users
  right-click → Open the first time.
- Code license: PolyForm Noncommercial 1.0.0. The README says "free for personal
  use", not "open source". Breeze has its own research, non-commercial license;
  each user downloads it from Hugging Face.
- The repo is created only after sign-off, once the name is checked.

## Not in v1

- **Training on your voice:** teaching the model itself your voice from
  20–60 minutes of recordings, instead of copying one clip per line. Breeze ships
  no training code, and training needs far more than 8 GB of memory. Full clone
  keeps raw recordings so they are ready if that changes.
- Windows and cloud rendering.

## Build order

One commit per milestone.

| # | Milestone | Skills |
|---|---|---|
| 1 | Move the assistant to `~/Development/VoiceAssistant`; rename to VocalCord; add license | ponytail |
| 2 | Codex makes 2–3 mockups; critique; you pick one | frontend-design, taste-skill, impeccable, design-critique, ux-copy, no-ai-slop |
| 3 | Engine: worker, Whisper transcripts, scores | ponytail |
| 4 | Clone: voice list, new voice, voice page | ponytail |
| 5 | Generate: projects and script, several voices, rendering | ponytail |
| 6 | Generate: preview, video, outputs, export | ponytail |
| 7 | Terminal panel and tool bridge | ponytail |
| 8 | Jev plugin | typesafe-ai |
| 9 | First-run setup, DMG, README | code-review |

## Risks

- Rendering on 8 GB is slow; an audition or a full script takes minutes.
- Good scoring models may need PyTorch, adding about 700 MB.
- Breeze may have no speed control; time-stretching can lower quality.
- Respelled pronunciations are untested with Breeze.
- The consent prompt cannot verify whose voice it is.

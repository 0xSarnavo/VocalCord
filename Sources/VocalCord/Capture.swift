import SwiftUI
import UniformTypeIdentifiers

/// Live input level as bars, newest on the right.
struct LevelMeter: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let step = size.width / CGFloat(levels.count)
            for (index, level) in levels.enumerated() {
                let height = max(5, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(index) * step + step * 0.3, y: (size.height - height) / 2,
                                  width: max(2, step * 0.4), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.white.opacity(0.72)))
            }
        }
        .accessibilityLabel("Input level")
    }
}

/// Large primary Record button that turns into Stop with a timer.
struct RecordButton: View {
    let recording: Bool
    let elapsed: Double
    var large = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: large ? 16 : 10) {
                if recording {
                    RoundedRectangle(cornerRadius: 3).fill(.red).frame(width: large ? 18 : 12, height: large ? 18 : 12)
                    Text("Stop")
                    Text(formatTime(elapsed)).monospacedDigit().foregroundStyle(Theme.onPrimary.opacity(0.55))
                } else {
                    RecordDot(size: large ? 18 : 12)
                    Text("Record")
                }
            }
            .frame(minWidth: large ? 260 : 150)
        }
        .buttonStyle(.primary(height: large ? 76 : 48))
    }
}

struct WarningRow: View {
    let issues: [AudioIssue]
    var extra: [String] = []

    var body: some View {
        HStack(spacing: 18) {
            ForEach(issues.map(\.label) + extra, id: \.self) { Warning(text: $0) }
        }
        .frame(height: 22)
    }
}

/// Record or upload one take, then fix its transcript. Used by Fast clone and by Record on the voice page.
struct TakeCapture: View {
    @Environment(VoiceStore.self) private var store
    @Environment(Player.self) private var player
    @Environment(Waveforms.self) private var waveforms
    let voiceID: String
    let tone: String
    let prompt: String
    let minSeconds: Double
    let maxSeconds: Double
    var allowsUpload = false
    let saveTitle: String
    var large = true
    var onCancel: (() -> Void)?
    let onSave: (String) -> Void

    private struct Review {
        var url: URL
        var duration: Double
        var issues: [AudioIssue]
        var transcript: String
    }

    @State private var recorder = Recorder()
    @State private var review: Review?
    @State private var working = Progress()
    @State private var picking = false

    var body: some View {
        VStack(spacing: large ? 36 : 22) {
            Spacer(minLength: 0)
            if working.active {
                VStack(spacing: 12) {
                    ProgressView(value: working.value > 0 ? working.value : nil).frame(width: 220)
                    Text("Transcribing…").foregroundStyle(Theme.secondary)
                }
            } else if let review {
                reviewView(review)
            } else {
                captureView
            }
            Spacer(minLength: 0)
        }
        .padding(large ? 48 : 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { Task { await upload(url) } }
        }
        .onDisappear { _ = recorder.stop() }
    }

    private var captureView: some View {
        VStack(spacing: large ? 36 : 22) {
            Text(prompt)
                .font(.system(size: large ? 26 : 20, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 760)
            HStack(spacing: 20) {
                RecordButton(recording: recorder.isRecording, elapsed: recorder.elapsed, large: large, action: toggleRecording)
                if allowsUpload {
                    Button("Upload") { picking = true }
                        .buttonStyle(.outline(height: 48))
                        .disabled(recorder.isRecording)
                }
            }
            WarningRow(issues: recorder.issues)
            LevelMeter(levels: recorder.levels).frame(width: large ? 560 : 440, height: large ? 60 : 44)
            if let onCancel {
                Button("Cancel") { _ = recorder.stop(); onCancel() }.buttonStyle(.outline(height: 32))
            }
        }
    }

    private func reviewView(_ review: Review) -> some View {
        let short = review.duration < minSeconds
        return VStack(spacing: large ? 28 : 18) {
            HStack(spacing: 14) {
                Button { player.toggle(review.url) } label: {
                    Image(systemName: player.playing == review.url ? "stop.fill" : "play.fill")
                        .frame(width: 38, height: 30)
                        .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 8))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.playing == review.url ? "Stop" : "Play")
                SmallWaveform(url: review.url).frame(width: 200, height: 30)
                Text(formatTime(review.duration)).monospacedDigit().foregroundStyle(Theme.secondary)
            }
            TextField("Transcript", text: Binding(get: { self.review?.transcript ?? "" },
                                                  set: { self.review?.transcript = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: large ? 20 : 16))
                .lineLimit(2...6)
                .padding(14)
                .frame(maxWidth: 700)
                .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            WarningRow(issues: review.issues, extra: short ? ["Too short"] : [])
            HStack(spacing: 14) {
                if let onCancel { Button("Cancel", action: onCancel).buttonStyle(.outline(height: 34)) }
                Button("Record again") { self.review = nil }.buttonStyle(.outline(height: 34))
                Button(saveTitle) { save(review) }
                    .buttonStyle(.primary)
                    .disabled(short || review.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func toggleRecording() {
        if recorder.isRecording { finishRecording(); return }
        Task {
            do {
                try await recorder.start(to: store.newRawURL(voiceID), maxSeconds: maxSeconds) { finishRecording() }
            } catch {
                store.error = error.localizedDescription
            }
        }
    }

    private func finishRecording() {
        guard let recording = recorder.stop() else { return }
        Task {
            working.start()
            working.value = 0
            defer { working.active = false }
            do {
                let text = try await store.engine.transcribe(recording.url)
                review = Review(url: recording.url, duration: recording.duration, issues: recording.issues, transcript: text)
            } catch {
                store.error = "Couldn't transcribe this take. \(error.localizedDescription)"
            }
        }
    }

    /// Keeps the original in raw/; the engine cuts it and the first clip is reviewed.
    private func upload(_ url: URL) async {
        working.start()
        defer { working.active = false }
        do {
            let raw = try store.keepRaw(url, voiceID: voiceID)
            let clip = try await store.split(raw, minSeconds: minSeconds, maxSeconds: maxSeconds, progress: working.callback)[0]
            let check = try await store.engine.checkAudio(clip.url)
            review = Review(url: clip.url, duration: clip.duration, issues: check.issues, transcript: clip.transcript)
        } catch {
            store.error = "Couldn't use this file. \(error.localizedDescription)"
        }
    }

    private func save(_ review: Review) {
        do {
            onSave(try store.addTake(voiceID, file: review.url, tone: tone, transcript: review.transcript,
                                     issues: review.issues, duration: review.duration))
        } catch {
            store.error = "Couldn't save this take. \(error.localizedDescription)"
        }
    }
}

struct FastCloneView: View {
    @Environment(VoiceStore.self) private var store
    let voiceID: String
    let onDone: () -> Void

    var body: some View {
        TakeCapture(voiceID: voiceID, tone: "Neutral", prompt: Prompts.fastClone, minSeconds: 10, maxSeconds: 20,
                    allowsUpload: true, saveTitle: "Save voice") { takeID in
            if let take = store.voice(voiceID)?.takes.first(where: { $0.id == takeID }) {
                store.setMain(take, voiceID: voiceID)
            }
            onDone()
        }
    }
}

// MARK: Full clone

enum FullClone {
    static let steps = ["Room check", "Sentences", "Free speech", "Tones", "Audition"]
    static let tones = Array(Tone.all.dropFirst())
    /// 5 sentences and 30 s of free speech per tone.
    static let perTone = 6

    struct Item {
        var prompt: String
        var tone = "Neutral"
        var seconds: Double = 30
        var split = false
    }

    static func count(_ step: Int) -> Int {
        [1, Prompts.sentences.count, Prompts.topics.count, tones.count * perTone, 1][step]
    }

    static func item(_ session: Session) -> Item {
        switch session.step {
        case 0: return Item(prompt: "Stay quiet for 10 seconds.", seconds: 10)
        case 1: return Item(prompt: Prompts.sentences[session.index])
        case 2: return Item(prompt: Prompts.topics[session.index], seconds: 60, split: true)
        case 3:
            let tone = tones[session.index / perTone], part = session.index % perTone
            return part < perTone - 1
                ? Item(prompt: Prompts.toneSentences[tone]![part], tone: tone)
                : Item(prompt: Prompts.toneTopics[tone]!, tone: tone, split: true)
        default: return Item(prompt: "Pick the main take for each tone.")
        }
    }

    static func next(_ session: Session, previous: [String]) -> Session {
        var next = session
        next.index += 1
        if next.index >= count(next.step) { next.step += 1; next.index = 0 }
        next.previous = previous
        return next
    }

    /// Jumps past the current step, or the current tone in Tones.
    static func skip(_ session: Session) -> Session {
        var next = session
        next.previous = []
        if session.step == 3 { next.index = (session.index / perTone + 1) * perTone } else { next.index = count(session.step) }
        if next.index >= count(next.step) { next.step += 1; next.index = 0 }
        return next
    }

    static func back(_ session: Session) -> Session {
        var previous = session
        previous.previous = []
        if previous.index > 0 { previous.index -= 1 } else if previous.step > 0 {
            previous.step -= 1
            previous.index = count(previous.step) - 1
        }
        return previous
    }
}

struct FullCloneView: View {
    @Environment(VoiceStore.self) private var store
    let voiceID: String
    let onExit: () -> Void
    @State private var recorder = Recorder()
    @State private var working = Progress()
    @State private var roomNoise = false
    @State private var picking = false

    private var session: Session { store.voice(voiceID)?.session ?? Session() }

    var body: some View {
        let session = session
        let item = FullClone.item(session)
        VStack(spacing: 0) {
            StepBar(current: session.step)
                .padding(.top, 28)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    Text(countText(session))
                        .font(.system(size: 17, weight: .medium).monospacedDigit())
                        .padding(.top, 36)
                        .padding(.trailing, 32)
                }
            Spacer()
            if session.step == 3 {
                Text(item.tone).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary).padding(.bottom, 12)
            }
            Text(item.prompt)
                .font(.system(size: 34, weight: .semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 860)
                .padding(.horizontal, 32)
            Spacer().frame(height: 52)
            controls(session, item)
            Spacer().frame(height: 28)
            if working.active {
                ProgressView(value: working.value).frame(width: 260).frame(height: 22)
            } else if roomNoise {
                HStack(spacing: 14) {
                    Warning(text: "Background noise")
                    Button("Continue") { roomNoise = false; store.setSession(voiceID, FullClone.skip(session)) }
                        .buttonStyle(.outline(height: 26))
                }
                .frame(height: 22)
            } else {
                WarningRow(issues: recorder.issues)
            }
            LevelMeter(levels: recorder.levels).frame(width: 600, height: 64).padding(.top, 18)
            Spacer()
            HStack(spacing: 32) {
                Button("Re-record previous") { rerecordPrevious() }
                    .disabled(session.previous.isEmpty || recorder.isRecording || working.active)
                if session.step == 3 {
                    Button("Skip tone") { store.setSession(voiceID, FullClone.skip(session)) }
                        .disabled(recorder.isRecording || working.active)
                }
                Button("Pause session") { _ = recorder.stop(); onExit() }
            }
            .buttonStyle(.outline(height: 44))
            .padding(.bottom, 44)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { Task { await upload(url, item: item) } }
        }
        .onDisappear { _ = recorder.stop() }
    }

    @ViewBuilder private func controls(_ session: Session, _ item: FullClone.Item) -> some View {
        if session.step == 4 {
            Button { Task { await audition() } } label: {
                HStack(spacing: 14) { Image(systemName: "play.fill"); Text("Audition") }.frame(minWidth: 260)
            }
            .buttonStyle(.primary(height: 76))
            .disabled(working.active)
        } else {
            HStack(spacing: 26) {
                RecordButton(recording: recorder.isRecording, elapsed: recorder.elapsed) { toggleRecording(item) }
                    .disabled(working.active)
                if session.step > 0 {
                    Button("Upload") { picking = true }
                        .buttonStyle(.outline(height: 54))
                        .disabled(recorder.isRecording || working.active)
                }
            }
        }
    }

    private func countText(_ session: Session) -> String {
        switch session.step {
        case 3: "\(session.index % FullClone.perTone + 1) / \(FullClone.perTone)"
        case 4: ""
        default: "\(session.index + 1) / \(FullClone.count(session.step))"
        }
    }

    private func toggleRecording(_ item: FullClone.Item) {
        if recorder.isRecording { finish(); return }
        roomNoise = false
        Task {
            do {
                try await recorder.start(to: store.newRawURL(voiceID), maxSeconds: item.seconds) { finish() }
            } catch {
                store.error = error.localizedDescription
            }
        }
    }

    private func finish() {
        guard let recording = recorder.stop() else { return }
        let session = session
        let item = FullClone.item(session)
        if session.step == 0 {
            roomNoise = recording.issues.contains(.noisy)
            if !roomNoise { store.setSession(voiceID, FullClone.next(session, previous: [])) }
            return
        }
        Task {
            working.start()
            defer { working.active = false }
            do {
                let ids = item.split
                    ? try await store.addClips(from: recording.url, voiceID: voiceID, tone: item.tone, progress: working.callback)
                    : [try store.addTake(voiceID, file: recording.url, tone: item.tone, transcript: item.prompt,
                                         issues: recording.issues, duration: recording.duration)]
                store.setSession(voiceID, FullClone.next(session, previous: ids))
            } catch {
                store.error = "Couldn't save this recording. \(error.localizedDescription)"
            }
        }
    }

    /// An upload finishes the current step, or the current tone in Tones.
    private func upload(_ url: URL, item: FullClone.Item) async {
        let session = session
        working.start()
        defer { working.active = false }
        do {
            _ = try await store.importMedia(url, voiceID: voiceID, tone: item.tone, progress: working.callback)
            store.setSession(voiceID, FullClone.skip(session))
        } catch {
            store.error = "Couldn't import this file. \(error.localizedDescription)"
        }
    }

    private func rerecordPrevious() {
        let session = session
        store.removeTakes(session.previous, from: voiceID)
        store.setSession(voiceID, FullClone.back(session))
    }

    private func audition() async {
        working.start()
        defer { working.active = false }
        do {
            try await store.audition(voiceID, progress: working.callback)
            store.setSession(voiceID, nil)
            onExit()
        } catch {
            store.error = "Audition failed. \(error.localizedDescription)"
        }
    }
}

struct StepBar: View {
    let current: Int
    private let width: CGFloat = 150

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(FullClone.steps.enumerated()), id: \.offset) { index, name in
                VStack(spacing: 12) {
                    ZStack {
                        if index < current {
                            Circle().fill(Theme.secondary)
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.onPrimary)
                        } else if index == current {
                            Circle().fill(Color(hex: 0xC9CBCE))
                        } else {
                            Circle().strokeBorder(Theme.text.opacity(0.8), lineWidth: 1.5).background(Circle().fill(Theme.content))
                        }
                    }
                    .frame(width: 24, height: 24)
                    Text(name)
                        .font(.system(size: 15, weight: index == current ? .medium : .regular))
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(index == current ? Theme.selection : .clear, in: .capsule)
                }
                .frame(width: width)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == current ? .isSelected : [])
            }
        }
        .background(alignment: .top) {
            Rectangle().fill(Theme.text.opacity(0.35)).frame(height: 1)
                .padding(.horizontal, width / 2)
                .padding(.top, 12)
        }
    }
}

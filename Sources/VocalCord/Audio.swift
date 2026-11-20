import AVFoundation
import Observation

/// Raw values match the engine's `check_audio` warnings.
enum AudioIssue: String, Codable, Sendable, CaseIterable {
    case quiet, clipped, noisy, cutOff = "cut_off"

    var label: String {
        switch self {
        case .quiet: "Too quiet"
        case .clipped: "Clipping"
        case .noisy: "Background noise"
        case .cutOff: "Cut off: record again with half a second of silence before and after"
        }
    }
}

/// Loudness of one short block of samples.
struct BlockLevel: Sendable {
    var rms: Float
    var clipped: Int
    var count: Int
    var seconds: Double

    init(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        var sum: Float = 0, clipped = 0
        for sample in samples {
            sum += sample * sample
            if abs(sample) >= 0.99 { clipped += 1 }
        }
        rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
        self.clipped = clipped
        count = samples.count
        seconds = Double(samples.count) / sampleRate
    }

    var decibels: Float { 20 * log10(max(rms, 1e-6)) }
}

/// File checks, with the engine's `check_audio` thresholds so both warn alike.
struct LevelAnalyzer: Sendable {
    private(set) var seconds: Double = 0
    private var blocks: [Float] = []
    private var clipped = 0
    private var count = 0

    mutating func add(_ block: BlockLevel) {
        seconds += block.seconds
        blocks.append(block.decibels)
        clipped += block.clipped
        count += block.count
    }

    /// Feeds whole samples in 50 ms blocks.
    mutating func add(_ samples: [Float], sampleRate: Double) {
        let size = max(1, Int(sampleRate / 20))
        samples.withUnsafeBufferPointer { all in
            for start in stride(from: 0, to: all.count, by: size) {
                add(BlockLevel(UnsafeBufferPointer(rebasing: all[start..<min(start + size, all.count)]), sampleRate: sampleRate))
            }
        }
    }

    var issues: [AudioIssue] {
        guard seconds >= 2 else { return [] }
        let sorted = blocks.sorted()
        func percentile(_ p: Double) -> Float { sorted[Int(Double(sorted.count - 1) * p)] }
        var found: [AudioIssue] = []
        if percentile(0.95) < -35 { found.append(.quiet) }
        if Double(clipped) / Double(max(count, 1)) >= 0.0001 { found.append(.clipped) }
        if percentile(0.1) > -50 { found.append(.noisy) }
        // Starts or stops mid-word: the model carries a take's last sound into the start of every render.
        if blocks.count >= 2, max(blocks[0], blocks[blocks.count - 1]) > percentile(0.95) - 20 { found.append(.cutOff) }
        return found
    }
}

/// Decodes any audio or video file to mono float samples.
nonisolated func loadSamples(_ url: URL, rate: Double = 24000) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
        throw AppError("This file has no audio.")
    }
    // The reader blocks while it decodes. On Swift's few shared threads, a voice's takes loading at once took every
    // one of them and the decoder, waiting for one, never finished; a dispatch queue adds threads instead.
    // The track goes to that queue alone and is never shared.
    nonisolated(unsafe) let handedOff = track
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try readSamples(asset, track: handedOff, rate: rate) })
        }
    }
}

nonisolated private func readSamples(_ asset: AVURLAsset, track: AVAssetTrack, rate: Double) throws -> [Float] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? AppError("Couldn't read this file.") }
    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = buffer.dataBuffer else { continue }
        let data = try block.dataBytes()
        data.withUnsafeBytes { samples.append(contentsOf: $0.bindMemory(to: Float.self)) }
    }
    if reader.status == .failed { throw reader.error ?? AppError("Couldn't read this file.") }
    return samples
}

/// Writes mono 16-bit PCM WAV.
nonisolated func writeWAV(_ samples: ArraySlice<Float>, rate: Double, to url: URL) throws {
    guard !samples.isEmpty,
          let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
        throw AppError("Nothing to write.")
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
    let file = try AVAudioFile(forWriting: url, settings: wavSettings(rate), commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    file.close()
}

nonisolated func wavSettings(_ rate: Double) -> [String: Any] {
    [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
     AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
}

nonisolated func audioDuration(_ url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url) else { return 0 }
    return Double(file.length) / file.processingFormat.sampleRate
}

/// Plays one file at a time, so starting anything stops the rest.
@MainActor @Observable
final class Player: NSObject, AVAudioPlayerDelegate {
    private(set) var playing: URL?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playing == url { pause() } else { play(url, from: 0) }
    }

    func play(_ url: URL, from time: Double) {
        if player?.url != url {
            player?.stop()
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        player?.currentTime = max(0, time)
        playing = player?.play() == true ? url : nil
    }

    func pause() {
        player?.pause()
        playing = nil
    }

    /// Seconds into the loaded file.
    var time: Double { player?.currentTime ?? 0 }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playing = nil }
    }
}

/// Small waveform bars per file, computed once.
@MainActor @Observable
final class Waveforms {
    private(set) var bars: [URL: [Float]] = [:]

    func load(_ url: URL, count: Int = 18) async {
        guard bars[url] == nil, let samples = try? await loadSamples(url, rate: 8000), !samples.isEmpty else { return }
        let size = max(1, samples.count / count)
        let peaks = (0..<count).map { bar in
            samples[min(bar * size, samples.count - 1)..<min((bar + 1) * size, samples.count)].reduce(0) { max($0, abs($1)) }
        }
        let top = max(peaks.max() ?? 1, 0.0001)
        bars[url] = peaks.map { $0 / top }
    }
}

/// Lets a @Sendable progress callback update the UI.
@MainActor @Observable
final class Progress {
    var active = false
    var value = 0.0

    nonisolated var callback: @Sendable (Double) -> Void {
        { value in Task { @MainActor in self.value = value } }
    }

    func start() { value = 0; active = true }
}

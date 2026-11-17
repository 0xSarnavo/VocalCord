import CryptoKit
import SwiftUI

/// The installed engine: a Python 3.13 venv that the bundled uv makes under Application Support, running the
/// engine code inside VocalCord.app.
struct EngineInstall: Sendable {
    var folder: URL
    var source: URL
    var uv: URL
    var cache: URL

    static let standard = EngineInstall(
        folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VocalCord/Engine", directoryHint: .isDirectory),
        source: Bundle.main.resourceURL!.appending(path: "engine", directoryHint: .isDirectory),
        uv: Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "uv"),
        cache: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "VocalCord/uv", directoryHint: .isDirectory))

    var stateFile: URL { folder.appending(path: "setup.json") }
    private var venv: URL { folder.appending(path: "venv", directoryHint: .isDirectory) }
    private var requirements: URL { source.appending(path: "requirements.txt") }

    var location: EngineLocation {
        // Bytecode goes here, so the app bundle stays as signed.
        EngineLocation(python: venv.appending(path: "bin/python"), source: source,
                       environment: ["PYTHONPYCACHEPREFIX": folder.appending(path: "pycache").path])
    }

    /// The pins plus the engine version, so an app update reinstalls only when one of them changes.
    func key() throws -> String {
        let module = try String(contentsOf: source.appending(path: "vocalcord_engine/__init__.py"), encoding: .utf8)
        let version = module.firstMatch(of: /__version__ = "([^"]+)"/)?.1 ?? ""
        let digest = SHA256.hash(data: try Data(contentsOf: requirements) + Data(version.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Makes the venv with a Python 3.13 that uv downloads (the Mac needs none), then installs the pinned packages.
    func install(output: @escaping @Sendable (String) -> Void) async throws {
        try await uv(["venv", "--python", "3.13", "--managed-python", "--clear", venv.path], output)
        // Wheels only: building a package from source would need Xcode's tools.
        try await uv(["pip", "install", "--python", location.python.path, "--only-binary", ":all:", "-r", requirements.path], output)
    }

    private func uv(_ arguments: [String], _ output: @escaping @Sendable (String) -> Void) async throws {
        let process = Process()
        process.executableURL = uv
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "UV_PYTHON_INSTALL_DIR": folder.appending(path: "python").path,
            "UV_CACHE_DIR": cache.path,
            "UV_NO_CONFIG": "1",
        ]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lines = EngineClient.lines(pipe.fileHandleForReading)
        try process.run()
        let failure = await withTaskCancellationHandler {
            var failure = ""
            for await line in lines {
                output(line)
                // uv's first `error:` line says what failed; the `Caused by:` lines under it go into detail.
                if failure.isEmpty, line.hasPrefix("error: ") { failure = String(line.dropFirst(7)) }
            }
            return failure
        } onCancel: {
            process.terminate()
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw EngineError(message: "The engine didn't install. \(failure.isEmpty ? "uv stopped with code \(process.terminationStatus)." : failure)")
        }
    }
}

/// First-run setup for the installed app: checks the Mac, installs the engine, downloads the models. Settings
/// uses it to download a model the first time it's chosen. A dev engine skips all of it.
@MainActor @Observable
final class Setup {
    struct Progress: Equatable {
        var step: String
        var detail: String
        var fraction: Double?
    }

    /// Kept in the engine folder, so deleting that folder starts setup over.
    private struct State: Codable {
        var engine: String?
        var models: [String] = []
    }

    static let neededSpace: Int64 = 8_000_000_000
    /// Download sizes, for the Download button.
    private static let engineSize = 0.2e9
    private static let modelSizes = ["4bit": 4.4e9, "8bit": 5.9e9]

    private(set) var done = true
    private(set) var blockers: [String] = []
    private(set) var progress: Progress?
    private(set) var error: String?
    private(set) var paused = false
    /// The model Settings is downloading.
    private(set) var switching: String?

    @ObservationIgnored private let engine: EngineClient
    @ObservationIgnored private let install: EngineInstall?
    @ObservationIgnored private var state = State()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(engine: EngineClient, install: EngineInstall?) {
        self.engine = engine
        self.install = install
        if let install, let data = try? Data(contentsOf: install.stateFile) {
            state = (try? JSONDecoder().decode(State.self, from: data)) ?? State()
        }
        done = engineInstalled && isReady(EngineSettings.model)
    }

    private var engineInstalled: Bool {
        guard let install else { return true }
        return state.engine == (try? install.key()) && FileManager.default.isExecutableFile(atPath: install.location.python.path)
    }

    /// True when `model` needs no download.
    func isReady(_ model: String) -> Bool { install == nil || state.models.contains(model) }

    /// What setup will download, at most.
    var downloadSize: String {
        let model = EngineSettings.model
        return Self.size((engineInstalled ? 0 : Self.engineSize) + (isReady(model) ? 0 : Self.modelSizes[model] ?? 0))
    }

    /// Fills `blockers` with what this Mac lacks. True when it has everything.
    @discardableResult
    func check() -> Bool {
        blockers = Self.checks(space: Self.freeSpace())
        return blockers.isEmpty
    }

    /// Checks the Mac, then installs the engine and downloads the models, skipping what's already done.
    func start() {
        guard task == nil, let install, check() else { return }
        error = nil
        paused = false
        task = Task {
            defer {
                task = nil
                progress = nil
            }
            do {
                if !engineInstalled {
                    progress = Progress(step: "Installing the engine", detail: "Python and its packages", fraction: nil)
                    let key = try install.key()
                    try await install.install { line in
                        guard line.hasPrefix("Downloading ") else { return }
                        let detail = line.replacing(" (download)", with: "")
                        Task { @MainActor in self.progress?.detail = detail }
                    }
                    state.engine = key
                    try save()
                }
                let model = EngineSettings.model
                if !isReady(model) { try await download(model, step: "Downloading the models") }
                done = true
            } catch is CancellationError {
                paused = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Settings' model choice: switches at once if `model` is ready, else downloads it first.
    func choose(_ model: String) {
        guard task == nil else { return }
        error = nil
        guard !isReady(model) else { return UserDefaults.standard.set(model, forKey: EngineSettings.modelKey) }
        switching = model
        task = Task {
            defer {
                task = nil
                progress = nil
                switching = nil
            }
            do {
                try await download(model, step: "Downloading \(EngineSettings.titles[model] ?? model)")
                UserDefaults.standard.set(model, forKey: EngineSettings.modelKey)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    private func download(_ model: String, step: String) async throws {
        progress = Progress(step: step, detail: "Checking what's needed", fraction: nil)
        do {
            try await engine.prepare(model: model) { done, total in
                Task { @MainActor in
                    self.progress?.detail = "\(Self.size(done)) of \(Self.size(total))"
                    self.progress?.fraction = total > 0 ? done / total : nil
                }
            }
        } catch let error as EngineError {
            throw EngineError(message: "The models didn't download. \(error.message)")
        }
        state.models.append(model)
        try save()
    }

    private func save() throws {
        guard let install else { return }
        try FileManager.default.createDirectory(at: install.folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: install.stateFile, options: .atomic)
    }

    static func checks(space: Int64?, appleSilicon: Bool = Setup.appleSilicon) -> [String] {
        var missing: [String] = []
        if !appleSilicon { missing.append("VocalCord needs a Mac with Apple silicon (M1 or later).") }
        if let space, space < neededSpace {
            missing.append("VocalCord needs 8 GB of free space, and this Mac has \(size(Double(space))). Free up space, then check again.")
        }
        return missing
    }

    private static var appleSilicon: Bool {
        var value: Int32 = 0
        var length = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &length, nil, 0) == 0 && value == 1
    }

    private static func freeSpace() -> Int64? {
        try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    static func size(_ bytes: Double) -> String { Int64(bytes).formatted(.byteCount(style: .file)) }
}

/// Shown instead of Clone and Generate until setup is done.
struct SetupView: View {
    @Environment(Setup.self) private var setup

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Set up VocalCord")
                .font(.system(size: 30, weight: .bold))
                .padding(.top, 16)
            Text("VocalCord runs on this Mac. Setup downloads the voice engine and its models once.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Group {
                if let progress = setup.progress {
                    working(progress)
                } else if !setup.blockers.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(setup.blockers, id: \.self) { Warning(text: $0).fixedSize(horizontal: false, vertical: true) }
                        Button("Check again") { setup.check() }.buttonStyle(.outline)
                    }
                } else if let error = setup.error {
                    VStack(spacing: 16) {
                        Warning(text: error).fixedSize(horizontal: false, vertical: true)
                        Button("Retry", action: setup.start).buttonStyle(.primary)
                    }
                } else if setup.paused {
                    VStack(spacing: 16) {
                        Text("Setup paused. Retry continues from where it stopped.").foregroundStyle(Theme.secondary)
                        Button("Retry", action: setup.start).buttonStyle(.primary)
                    }
                } else {
                    Button("Download (about \(setup.downloadSize))", action: setup.start).buttonStyle(.primary(height: 40))
                }
            }
            .font(.system(size: 13))
            // A fixed height keeps the title still as the content below changes.
            .frame(height: 150, alignment: .top)
            .padding(.top, 40)
        }
        .frame(width: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.content)
        .onAppear { setup.check() }
    }

    private func working(_ progress: Setup.Progress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(progress.step).font(.system(size: 15, weight: .semibold))
            ProgressView(value: progress.fraction)
            HStack {
                Text(progress.detail).monospacedDigit().foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer()
                Button("Cancel", action: setup.cancel).buttonStyle(.outline)
            }
        }
    }
}

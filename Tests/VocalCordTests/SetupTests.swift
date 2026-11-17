import Foundation
import Testing
@testable import VocalCord

@MainActor @Test func checksSayWhatIsMissing() {
    #expect(Setup.checks(space: 9_000_000_000, appleSilicon: true).isEmpty)
    let missing = Setup.checks(space: 3_200_000_000, appleSilicon: false)
    #expect(missing.count == 2)
    #expect(missing[0].contains("Apple silicon"))
    #expect(missing[1].contains("3.2 GB"))
}

@MainActor @Test func setupIsDoneOnlyWithTheSameEngineAndTheModel() throws {
    let folder = try tempFolder()
    let source = folder.appending(path: "engine")
    try FileManager.default.createDirectory(at: source.appending(path: "vocalcord_engine"), withIntermediateDirectories: true)
    try "mlx==1\n".write(to: source.appending(path: "requirements.txt"), atomically: true, encoding: .utf8)
    try "__version__ = \"0.1.0\"\n".write(to: source.appending(path: "vocalcord_engine/__init__.py"), atomically: true, encoding: .utf8)
    let install = EngineInstall(folder: folder.appending(path: "Engine"), source: source,
                                uv: URL(filePath: "/missing/uv"), cache: folder.appending(path: "cache"))
    let engine = EngineClient(location: install.location)
    #expect(!Setup(engine: engine, install: install).done)

    // A finished setup: the venv's python exists, and the engine key and the model are recorded.
    let python = install.location.python
    try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    let key = try install.key()
    let state = ["engine": key, "models": [EngineSettings.model]] as [String: Any]
    try JSONSerialization.data(withJSONObject: state).write(to: install.stateFile)
    let setup = Setup(engine: engine, install: install)
    #expect(setup.done)
    #expect(!setup.isReady(EngineSettings.model == "4bit" ? "8bit" : "4bit"))

    // New pins or a new engine version mean a reinstall.
    try "mlx==2\n".write(to: source.appending(path: "requirements.txt"), atomically: true, encoding: .utf8)
    #expect(try install.key() != key)
    #expect(!Setup(engine: engine, install: install).done)

    // A dev engine needs no setup.
    #expect(Setup(engine: engine, install: nil).done)
}

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var videoVoiceWindow: VideoVoiceWindowController?
    private var voiceLibraryWindow: VoiceLibraryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        VoiceLibraryStore.copyOldVoicesIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VocalCord")
        let menu = NSMenu()
        let video = NSMenuItem(title: "Video voiceover…", action: #selector(openVideoVoiceover), keyEquivalent: "")
        video.target = self
        menu.addItem(video)
        let library = NSMenuItem(title: "Voice library…", action: #selector(openVoiceLibrary), keyEquivalent: "")
        library.target = self
        menu.addItem(library)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit VocalCord", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        if CommandLine.arguments.contains("--video-window") { openVideoVoiceover() }
        if CommandLine.arguments.contains("--library-window") { openVoiceLibrary() }
    }

    @objc private func openVideoVoiceover() {
        if videoVoiceWindow == nil { videoVoiceWindow = VideoVoiceWindowController() }
        videoVoiceWindow?.show()
    }
    @objc private func openVoiceLibrary() {
        if voiceLibraryWindow == nil {
            voiceLibraryWindow = VoiceLibraryWindowController(onOpenVoiceover: { [weak self] in self?.openVideoVoiceover() })
        }
        voiceLibraryWindow?.show()
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

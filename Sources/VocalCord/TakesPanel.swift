import SwiftUI
import UniformTypeIdentifiers

/// A take dragged from the Takes panel onto Timeline's track: its version ID behind a prefix, so other text dropped
/// there is ignored.
enum TakeDrag {
    static let prefix = "vocalcord-take:"

    static func provider(_ versionID: String) -> NSItemProvider { NSItemProvider(object: (prefix + versionID) as NSString) }

    static func versionID(_ text: String) -> String? { text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : nil }
}

/// Every take of every line, under Generate's script and under Timeline's track: the lines (and Exports) on the left,
/// the chosen one's takes on the right, each to play, rename, tag, put in use or delete, and in Timeline to drag onto the
/// track. Compare plays a line's takes one after another.
struct TakesPanel: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(Player.self) private var player
    let project: Project
    /// The line shown, or `TakesPanel.exports`; nil or a line that's gone shows the first line with takes.
    @Binding var selection: String?
    /// Takes drag out onto the track (Timeline).
    var draggable = false
    let onFold: () -> Void
    @State private var naming: TakeNaming?
    @State private var deleting: Version?
    @State private var comparing: Task<Void, Never>?
    @State private var hovered: String?

    static let exports = "exports"
    static let listWidth = 180.0

    /// The take columns: fixed widths, the name takes the rest.
    enum Column {
        static let play: CGFloat = 32, tag: CGFloat = 80, length: CGFloat = 44
        static let like: CGFloat = 64, human: CGFloat = 52, words: CGFloat = 56, use: CGFloat = 68
        /// The name keeps room for "Take 12" even in a narrow window.
        static let name: CGFloat = 72
    }

    private var shown: String? {
        if let selection, selection == Self.exports || project.line(selection) != nil { return selection }
        return (project.lines.first { !$0.visibleVersions.isEmpty } ?? project.lines.first)?.id
    }

    var body: some View {
        let shown = shown, line = shown.flatMap { project.line($0) }
        VStack(spacing: 0) {
            PanelHeader("Takes") {
                if let line, line.visibleVersions.count > 1 {
                    Button(comparing == nil ? "Compare" : "Stop") { compare(line) }
                        .buttonStyle(.vc(.secondary, .s))
                        .help(comparing == nil ? "Play this line's takes one after another" : "Stop comparing")
                }
                FoldButton(label: "takes", systemImage: "chevron.down", action: onFold)
            }
            HStack(spacing: 0) {
                lineList(shown).frame(width: Self.listWidth)
                PaneDivider()
                Group {
                    if shown == Self.exports {
                        ExportsList(project: project)
                    } else if let line {
                        takes(line)
                    } else {
                        EmptyState(title: "No lines yet", message: "Add a line to the script, then render it.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .sidePanel()
        .onChange(of: shown) { stopComparing() }
        .onDisappear { stopComparing() }
        .takeNaming($naming, in: project.id)
        .confirmationDialog("Delete \(deleting.flatMap { version in project.lines.first { $0.versions.contains(version) }?.title(version) } ?? "take")?",
                            isPresented: Binding(present: $deleting), titleVisibility: .visible, presenting: deleting) { version in
            Button("Delete take", role: .destructive) { projects.deleteTake(version.id, in: project.id) }
        } message: { version in
            let line = project.lines.first { $0.versions.contains(version) }
            let next = line?.chosen == version.id ? line?.visibleVersions.last { $0.id != version.id } : nil
            Text("Its audio goes to the Trash." + (next.map { " \(line?.title($0) ?? "The newest take") will be the one in use." } ?? ""))
        }
    }

    // MARK: Lines

    private func lineList(_ shown: String?) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(project.lines.enumerated()), id: \.element.id) { index, line in
                    listRow(id: line.id, selected: shown == line.id, count: line.visibleVersions.count) {
                        Text("\(index + 1)").font(.vcCaption.monospacedDigit()).foregroundStyle(Theme.secondary).frame(width: 18, alignment: .leading)
                        let text = Marks.plain(line.text)
                        Text(text.isEmpty ? "Empty line" : text).foregroundStyle(text.isEmpty ? Theme.tertiary : Theme.text)
                    }
                    .accessibilityLabel("Line \(index + 1), \(line.visibleVersions.count) takes")
                }
                listRow(id: Self.exports, selected: shown == Self.exports, count: project.exports?.count ?? 0) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 18, alignment: .leading)
                    Text("Exports").foregroundStyle(Theme.text)
                }
                .padding(.top, 8)
                .accessibilityLabel("Exports, \(project.exports?.count ?? 0)")
            }
            .padding(8)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func listRow(id: String, selected: Bool, count: Int, @ViewBuilder label: () -> some View) -> some View {
        HStack(spacing: 6) {
            label().lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if count > 0 { Text("\(count)").font(.vcCaption.monospacedDigit()).foregroundStyle(Theme.secondary) }
        }
        .font(.vcBody)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(selected ? Theme.selection : hovered == id ? Theme.hover : .clear, in: .rect(cornerRadius: Radius.row))
        .contentShape(.rect)
        .onHover { if $0 { hovered = id } else if hovered == id { hovered = nil } }
        .onTapGesture { selection = id }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Takes

    private func takes(_ line: Line) -> some View {
        let number = (project.lines.firstIndex { $0.id == line.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Line \(number)").font(.vcBodyBold).foregroundStyle(Theme.text)
                Text(Marks.plain(line.text)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
            }
            .font(.vcBody)
            .padding(.horizontal, 12)
            .frame(height: 32)
            if line.visibleVersions.isEmpty {
                EmptyState(title: "No takes yet", message: "Click Render on line \(number) in Generate.")
            } else {
                headings
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(line.visibleVersions) { version in
                            TakeEntry(project: project, line: line, version: version, draggable: draggable, hovered: hovered == version.id,
                                    onRename: { naming = TakeNaming(version, in: line, kind: .rename) },
                                    onNewTag: { naming = TakeNaming(version, in: line, kind: .tag) },
                                    onDelete: { deleting = version },
                                    onPlay: stopComparing)
                                .onHover { if $0 { hovered = version.id } else if hovered == version.id { hovered = nil } }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var headings: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Column.play)
            Text("Take").frame(minWidth: Column.name, maxWidth: .infinity, alignment: .leading)
            Text("Tag").frame(width: Column.tag, alignment: .leading)
            Text("Length").padding(.trailing, 8).frame(width: Column.length + 8, alignment: .trailing)
            Text("Like you").padding(.trailing, 8).frame(width: Column.like, alignment: .trailing)
            Text("Human").padding(.trailing, 8).frame(width: Column.human, alignment: .trailing)
            Text("Words").padding(.trailing, 8).frame(width: Column.words, alignment: .trailing)
            Color.clear.frame(width: Column.use)
        }
        .font(.vcCaptionBold)
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 24)
    }

    // MARK: Compare

    /// Plays the line's takes in order, a beat apart, each lit while it plays. Playing anything else stops it.
    private func compare(_ line: Line) {
        if comparing != nil { return stopComparing() }
        let urls = line.visibleVersions.map { projects.audioURL($0, projectID: project.id) }
        comparing = Task {
            for url in urls {
                player.play(url, from: 0)
                while !Task.isCancelled, player.playing == url { try? await Task.sleep(for: .milliseconds(50)) }
                if Task.isCancelled || player.playing != nil { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            comparing = nil
        }
    }

    private func stopComparing() {
        guard let task = comparing else { return }
        task.cancel()
        comparing = nil
        player.pause()
    }
}

/// One take: play, its name and tag, length and scores, and whether it's the line's take in use.
private struct TakeEntry: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(Player.self) private var player
    let project: Project
    let line: Line
    let version: Version
    let draggable: Bool
    let hovered: Bool
    let onRename: () -> Void
    let onNewTag: () -> Void
    let onDelete: () -> Void
    let onPlay: () -> Void

    private typealias Column = TakesPanel.Column

    var body: some View {
        let url = projects.audioURL(version, projectID: project.id)
        let playing = player.playing == url
        let scores = version.scores
        let title = line.title(version)
        HStack(spacing: 0) {
            Button {
                onPlay()
                player.toggle(url)
            } label: { Image(systemName: playing ? "stop.fill" : "play.fill") }
                .buttonStyle(.icon(.s))
                .frame(width: Column.play, alignment: .leading)
                .help(playing ? "Stop" : "Play")
                .accessibilityLabel("\(playing ? "Stop" : "Play") \(title)")
            Text(title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(minWidth: Column.name, maxWidth: .infinity, alignment: .leading)
                .onTapGesture(count: 2, perform: onRename)
                .help("Double-click to rename")
            Group {
                if let tag = version.tag { TagChip(tag: tag) } else { Color.clear }
            }
            .frame(width: Column.tag, alignment: .leading)
            Text(formatTime(version.duration)).font(.vcBody.monospacedDigit()).foregroundStyle(Theme.secondary)
                .padding(.trailing, 8).frame(width: Column.length + 8, alignment: .trailing)
            ScoreCell(value: scores.map { "\($0.likeYou)%" }, flag: version.likeYouFlag ?? version.pitchFlag, dim: !version.likeYouJudged,
                      help: version.likeYouJudged ? nil : "Too short to judge").frame(width: Column.like)
            ScoreCell(value: scores.map { String(format: "%.1f", $0.human) }, flag: version.humanFlag ?? version.paceFlag ?? version.gapFlag)
                .frame(width: Column.human)
            ScoreCell(value: scores.map { "\($0.words)%" }, flag: version.wordsFlag).frame(width: Column.words)
            Group {
                if line.chosen == version.id {
                    Label("In use", systemImage: "checkmark").labelStyle(.titleAndIcon).font(.vcCaption).foregroundStyle(Theme.secondary)
                        .help("Line \((project.lines.firstIndex { $0.id == line.id } ?? 0) + 1) plays and exports this take")
                } else {
                    Button("Use") { projects.choose(version.id, line: line.id, in: project.id) }
                        .buttonStyle(.vc(.ghost, .s))
                        .help("Make this the take the line plays and exports")
                }
            }
            .frame(width: Column.use, alignment: .trailing)
        }
        .font(.vcBody.monospacedDigit())
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(playing ? Theme.selection : hovered ? Theme.hover : .clear, in: .rect(cornerRadius: Radius.row))
        .contentShape(.rect)
        .modifier(DragOut(versionID: version.id, enabled: draggable))
        .contextMenu {
            Button(playing ? "Stop" : "Play") {
                onPlay()
                player.toggle(url)
            }
            Button("Rename\u{2026}", action: onRename)
            TakeTagMenu(projectID: project.id, version: version, tags: project.tags, onNew: onNewTag)
            Button("Use this take") { projects.choose(version.id, line: line.id, in: project.id) }.disabled(line.chosen == version.id)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            if let reason = projects.whyKept(version.id, in: project.id) {
                Button("Can\u{2019}t delete: \(reason)") {}.disabled(true)
            } else {
                Button("Delete\u{2026}", role: .destructive, action: onDelete)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel([title, version.tag, line.chosen == version.id ? "in use" : nil].compactMap(\.self).joined(separator: ", "))
    }
}

/// In Timeline, a take row drags out onto the track.
private struct DragOut: ViewModifier {
    let versionID: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag { TakeDrag.provider(versionID) }.help("Drag onto the track")
        } else {
            content
        }
    }
}

/// The project's exports, newest first: play, Show in Finder, Move to Trash.
private struct ExportsList: View {
    @Environment(ProjectStore.self) private var projects
    @Environment(Player.self) private var player
    let project: Project

    var body: some View {
        let exports = (project.exports ?? []).sorted { $0.createdAt > $1.createdAt }
        if exports.isEmpty {
            EmptyState(title: "No exports yet", message: "Export puts the timeline, or each line\u{2019}s take in use, into one file.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(exports) { export in
                        let url = URL(filePath: export.files[0])
                        let playing = player.playing == url
                        HStack(spacing: 8) {
                            Button { player.toggle(url) } label: { Image(systemName: playing ? "stop.fill" : "play.fill") }
                                .buttonStyle(.icon(.s))
                                .accessibilityLabel(playing ? "Stop" : "Play \(url.lastPathComponent)")
                            Text(url.deletingPathExtension().lastPathComponent).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(Self.details(export, url: url)).font(.vcCaption.monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        .font(.vcBody)
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .background(playing ? Theme.selection : .clear, in: .rect(cornerRadius: Radius.row))
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Button("Move to Trash") { projects.deleteExport(export.id, in: project.id) }
                        }
                    }
                }
                .padding(8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// "WAV · 0:02 · 18 Nov 2026": the date with its year, in the user's own order.
    static func details(_ export: Export, url: URL) -> String {
        [url.pathExtension.uppercased(), formatTime(export.duration), export.createdAt.formatted(.dateTime.day().month(.abbreviated).year())]
            .joined(separator: " \u{00B7} ")
    }
}

// MARK: Rename and tag

/// A Rename or New tag alert for a take, from the Takes panel or a Timeline clip.
struct TakeNaming: Identifiable, Equatable {
    enum Kind { case rename, tag }
    var versionID: String
    /// "Take 2", the placeholder and the default title.
    var title: String
    var name: String
    var kind: Kind
    var id: String { "\(versionID)-\(kind)" }

    init(_ version: Version, in line: Line, kind: Kind) {
        (versionID, title, name, self.kind) = (version.id, line.title(version), version.name ?? "", kind)
    }
}

private struct TakeNamingAlert: ViewModifier {
    @Environment(ProjectStore.self) private var projects
    @Binding var request: TakeNaming?
    let projectID: String
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { text = request?.kind == .rename ? request?.name ?? "" : "" }
            .alert(request?.kind == .tag ? "New tag" : "Rename \(request?.title ?? "take")", isPresented: Binding(present: $request),
                   presenting: request) { request in
                TextField(request.kind == .tag ? "Intro, Hook\u{2026}" : request.title, text: $text)
                Button(request.kind == .tag ? "Add tag" : "Rename") {
                    if request.kind == .tag {
                        projects.setTakeTag(text, version: request.versionID, in: projectID)
                    } else {
                        projects.renameTake(text, version: request.versionID, in: projectID)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(request.kind == .tag ? "A short label takes share, shown in Takes and on Timeline clips."
                     : "Leave it empty to show \u{201C}\(request.title)\u{201D}.")
            }
    }
}

extension View {
    func takeNaming(_ request: Binding<TakeNaming?>, in projectID: String) -> some View {
        modifier(TakeNamingAlert(request: request, projectID: projectID))
    }
}

/// A take's Tag menu: the project's tags to pick from, a new one, or none.
struct TakeTagMenu: View {
    @Environment(ProjectStore.self) private var projects
    let projectID: String
    let version: Version
    let tags: [String]
    let onNew: () -> Void

    var body: some View {
        Menu("Tag") {
            ForEach(tags, id: \.self) { tag in
                Toggle(tag, isOn: Binding(get: { version.tag == tag },
                                          set: { projects.setTakeTag($0 ? tag : nil, version: version.id, in: projectID) }))
            }
            if !tags.isEmpty { Divider() }
            Button("New tag\u{2026}", action: onNew)
            if version.tag != nil { Button("Remove tag") { projects.setTakeTag(nil, version: version.id, in: projectID) } }
        }
    }
}

// MARK: Footer

/// The bar along the bottom of Clone and Timeline, like the one under Generate's script: the screen's counts on the right.
struct StatusFooter: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 8)
            Text(text).font(.vcCaption.monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// "1 take", "3 clips".
func counted(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

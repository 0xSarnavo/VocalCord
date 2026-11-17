import SwiftUI
import UniformTypeIdentifiers

struct GenerateView: View {
    @Environment(VoiceStore.self) private var voices
    @Environment(ProjectStore.self) private var projects
    @Environment(Preview.self) private var preview
    @AppStorage("project") private var selection = ""
    @State private var naming: NameRequest?
    @State private var name = ""
    @State private var deleting: String?
    @State private var exporting = false
    @AppStorage("terminalOpen") private var terminalOpen = false
    @AppStorage("terminalHeight") private var terminalHeight = 300.0

    /// The New project and Rename alerts share one text field.
    private enum NameRequest: Identifiable {
        case new, rename(String)
        var id: String { if case .rename(let id) = self { id } else { "new" } }
    }

    var body: some View {
        SidebarLayout {
            ProjectsSidebar(selection: $selection, onNew: { name = ""; naming = .new },
                            onRename: { id in name = projects.project(id)?.name ?? ""; naming = .rename(id) },
                            onDelete: { deleting = $0 })
        } detail: {
            Group {
                if let project = projects.project(selection) {
                    let timeline = Timeline(project) { projects.audioURL($0, projectID: project.id) }
                    HStack(spacing: 0) {
                        GeometryReader { proxy in
                            VStack(alignment: .leading, spacing: 12) {
                                ScriptPane(project: project).id(project.id)
                                if terminalOpen {
                                    // The script keeps room for its header and a few lines.
                                    TerminalPanel(height: $terminalHeight, maxHeight: proxy.size.height - 230)
                                }
                            }
                            // Columns stop stretching on wide windows.
                            .frame(maxWidth: 1160, maxHeight: .infinity, alignment: .topLeading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Less on the right, where the panels add their own margin.
                            .padding(.leading, 24)
                            .padding(.trailing, 8)
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        }
                        VStack(spacing: 8) {
                            PreviewPane(project: project)
                            OutputsPane(project: project).id(project.id)
                        }
                        .frame(width: 300)
                        .padding(8)
                        // The panels fit their content rather than fill the column.
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .task(id: timeline) { await preview.load(timeline) }
                    .onChange(of: project.video, initial: true) { preview.setVideo(project.video) }
                } else {
                    Text("No projects").foregroundStyle(Theme.secondary)
                }
            }
            .onDisappear { preview.pause() }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $exporting) { ExportSheet(projectID: selection) }
        .onAppear { if projects.project(selection) == nil { selection = projects.projects.first?.id ?? "" } }
        .alert(naming.map { if case .new = $0 { "New project" } else { "Rename project" } } ?? "",
               isPresented: Binding(present: $naming), presenting: naming) { request in
            TextField("Name", text: $name)
            switch request {
            case .new: Button("Create") { selection = projects.create(name: name) }
            case .rename(let id): Button("Rename") { projects.rename(id, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \u{201C}\(projects.project(deleting)?.name ?? "")\u{201D}?",
                            isPresented: Binding(present: $deleting), titleVisibility: .visible, presenting: deleting) { id in
            Button("Delete project", role: .destructive) {
                projects.delete(id)
                if selection == id { selection = projects.projects.first?.id ?? "" }
            }
        } message: { _ in
            Text("Its renders move to the Trash.")
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { TerminalButton() }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            if let progress = projects.progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress).frame(width: 90)
                    Button("Cancel") { projects.cancel() }.buttonStyle(.outline(height: 32))
                }
            } else {
                Button { projects.renderNeeded(selection, voices: voices) } label: { Label("Render", systemImage: "play.fill") }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.outline(height: 32))
                    .disabled(!(projects.project(selection)?.lines.contains(where: \.needsRender) ?? false))
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Button { exporting = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.primary(height: 32))
                .disabled(!(projects.project(selection)?.lines.contains { $0.chosenVersion != nil } ?? false))
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { SettingsButton() }
    }
}

struct ProjectsSidebar: View {
    @Environment(ProjectStore.self) private var projects
    @Binding var selection: String
    let onNew: () -> Void
    let onRename: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Projects").font(.system(size: 17, weight: .bold)).padding(.horizontal, 8)
            Button(action: onNew) { Label("New project", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(.outline(height: 40))
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(projects.projects) { project in
                        Button { selection = project.id } label: {
                            Label(project.name, systemImage: "folder")
                                .font(.system(size: 14))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .frame(height: 38)
                                .background(selection == project.id ? Theme.selection : .clear, in: .rect(cornerRadius: 10))
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == project.id ? .isSelected : [])
                        .contextMenu {
                            Button("Rename…") { onRename(project.id) }
                            Button("Delete…", role: .destructive) { onDelete(project.id) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}

// MARK: Script

/// Fixed widths; Text takes the rest.
private enum Column {
    static let number: CGFloat = 22
    static let voice: CGFloat = 84
    static let tone: CGFloat = 92
    static let pause: CGFloat = 44
    static let like: CGFloat = 60
    static let human: CGFloat = 52
    static let words: CGFloat = 52
    static let jev: CGFloat = 40
    static let version: CGFloat = 84
    static let gutter: CGFloat = 30
}

struct ScriptPane: View {
    @Environment(VoiceStore.self) private var voices
    @Environment(ProjectStore.self) private var projects
    @Environment(Jev.self) private var jev
    let project: Project
    @State private var splitText: String?
    @State private var importing = false
    @State private var comparing: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Script").font(.system(size: 22, weight: .bold))
                Spacer()
                let pending = project.lines.filter { $0.proposal != nil }.map(\.id)
                if pending.count > 1 {
                    Button("Accept all") { projects.accept(pending, in: project.id) }.buttonStyle(.outline(height: 28))
                    Button("Reject all") { projects.reject(pending, in: project.id) }.buttonStyle(.outline(height: 28))
                }
                if jev.added {
                    Button(jev.isChecking ? "Checking…" : "Check script") {
                        let subjects = project.lines.map(JevSubject.init)
                        Task { await jev.check(subjects) }
                    }
                    .buttonStyle(.outline(height: 28))
                    .disabled(jev.isChecking || renderable.isEmpty)
                }
                Button("Compare styles…") { comparing = renderable.map(\.id) }
                    .buttonStyle(.outline(height: 28))
                    .disabled(renderable.isEmpty || projects.progress != nil)
            }
            .frame(height: 34)
            .padding(.bottom, 14)
            ScrollView {
                // The header scrolls with the rows, so a scroll bar that takes room can't shift the rows under it.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(project.lines.enumerated()), id: \.element.id) { index, line in
                            LineRow(projectID: project.id, line: line, number: index + 1, isLast: index == project.lines.count - 1,
                                    onCompare: { comparing = [line.id] })
                            Theme.rule.frame(height: 1)
                        }
                        footer
                    } header: {
                        VStack(spacing: 0) {
                            header
                            Theme.rule.frame(height: 1)
                        }
                        .background(Theme.content)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
        }
        .sheet(isPresented: Binding(present: $splitText)) {
            SplitSheet(text: splitText ?? "") { lines in projects.addLines(lines, to: project.id, voices: voices) }
        }
        .sheet(isPresented: Binding(present: $comparing)) {
            CompareSheet(lines: project.lines.filter { comparing?.contains($0.id) ?? false },
                         title: comparing?.count == 1 ? "Line \((project.lines.firstIndex { $0.id == comparing?.first } ?? 0) + 1)" : "Whole script") { tones in
                projects.compare(comparing ?? [], tones: tones, in: project.id, voices: voices)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { splitText = try String(contentsOf: url, encoding: .utf8) } catch {
                projects.error = "Couldn't read this file. \(error.localizedDescription)"
            }
        }
    }

    private var renderable: [Line] { project.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty } }

    private var header: some View {
        HStack(spacing: 0) {
            Text("#").frame(width: Column.number)
            Text("Text").padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
            Text("Voice").padding(.horizontal, 8).frame(width: Column.voice, alignment: .leading)
            Text("Tone").padding(.horizontal, 8).frame(width: Column.tone, alignment: .leading)
            Text("Pause").frame(width: Column.pause)
            Text("Like you").frame(width: Column.like)
            Text("Human").frame(width: Column.human)
            Text("Words").frame(width: Column.words)
            if jev.added { Text("Jev").frame(width: Column.jev) }
            Text("Version").padding(.horizontal, 8).frame(width: Column.version, alignment: .leading)
            Color.clear.frame(width: Column.gutter)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: 34)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { projects.addLines([""], to: project.id, voices: voices) } label: { Label("Add line", systemImage: "plus") }
            Button("Paste…") { splitText = NSPasteboard.general.string(forType: .string) ?? "" }
            Button("Import…") { importing = true }
        }
        .buttonStyle(.outline(height: 28))
        .padding(.horizontal, 6)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LineRow: View {
    @Environment(VoiceStore.self) private var voices
    @Environment(ProjectStore.self) private var projects
    @Environment(Jev.self) private var jev
    @Environment(Player.self) private var player
    @Environment(Preview.self) private var preview
    let projectID: String
    let line: Line
    let number: Int
    let isLast: Bool
    let onCompare: () -> Void

    var body: some View {
        let version = line.chosenVersion
        let scores = version?.scores
        // A pending change takes room from the version cell for its Accept and Reject buttons.
        let decision: CGFloat = line.proposal == nil ? 0 : 22
        HStack(spacing: 0) {
            Text("\(number)").frame(width: Column.number)
            Group {
                if let proposal = line.proposal {
                    ProposalText(line: line, proposal: proposal)
                } else {
                    TextField("Text", text: Binding(get: { line.text }, set: { projects.setText($0, line: line.id, in: projectID) }), axis: .vertical)
                        .textFieldStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            voiceMenu.frame(width: Column.voice)
            toneMenu.frame(width: Column.tone)
            pauseField.frame(width: Column.pause)
            ScoreCell(value: scores.map { "\($0.likeYou)%" }, flag: version?.likeYouFlag, dim: version?.likeYouJudged == false,
                      help: version?.likeYouJudged == false ? "Too short to judge" : nil).frame(width: Column.like)
            ScoreCell(value: scores.map { String(format: "%.1f", $0.human) }, flag: version?.humanFlag).frame(width: Column.human)
            ScoreCell(value: scores.map { "\($0.words)%" }, flag: version?.wordsFlag,
                      help: scores.map { "Heard: \u{201C}\($0.heard)\u{201D}" }).frame(width: Column.words)
            if jev.added { JevCell(subject: JevSubject(line)).frame(width: Column.jev) }
            versionControl.frame(width: Column.version - decision)
            Group {
                if line.proposal != nil {
                    DecisionButtons(label: "change to line \(number)",
                                    onAccept: { projects.accept([line.id], in: projectID) },
                                    onReject: { projects.reject([line.id], in: projectID) })
                } else {
                    rerenderButton
                }
            }
            .frame(width: Column.gutter + decision)
        }
        .font(.system(size: 14).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
        .background { RoundedRectangle(cornerRadius: 8).fill(preview.currentLine == line.id ? Theme.selection : .clear).padding(.horizontal, 4) }
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded { preview.seek(toLine: line.id) })
        .contextMenu {
            Button("Compare styles…", action: onCompare).disabled(line.text.isEmpty || projects.progress != nil)
            Divider()
            Button("Move up") { projects.moveLine(line.id, by: -1, in: projectID) }.disabled(number == 1)
            Button("Move down") { projects.moveLine(line.id, by: 1, in: projectID) }.disabled(isLast)
            Divider()
            Button("Delete line", role: .destructive) { projects.deleteLine(line.id, in: projectID) }
        }
    }

    private var voiceMenu: some View {
        Menu {
            ForEach(voices.voices) { voice in
                Button(voice.name) { projects.setVoice(voice.id, line: line.id, in: projectID) }
            }
        } label: {
            MenuBox(title: voices.voice(line.voiceID)?.name ?? "Choose", dim: voices.voice(line.voiceID) == nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 3)
        .accessibilityLabel("Voice")
    }

    private var toneMenu: some View {
        Menu {
            ForEach(Tone.all, id: \.self) { tone in
                Button(tone) { projects.setTone(tone, line: line.id, in: projectID) }
            }
        } label: {
            MenuBox(title: line.tone)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 3)
        .accessibilityLabel("Tone")
    }

    private var pauseField: some View {
        HStack(spacing: 0) {
            TextField("Pause", value: Binding(get: { line.pauseAfter }, set: { projects.setPause($0, line: line.id, in: projectID) }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 30)
            Text("s")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pause after, seconds")
    }

    /// The label plays the chosen version; the chevron picks another, which then plays.
    /// A pending change narrows the cell, so it gets smaller type.
    @ViewBuilder private var versionControl: some View {
        let compact = line.proposal != nil
        if let version = line.chosenVersion, let index = line.versions.firstIndex(of: version) {
            let url = projects.audioURL(version, projectID: projectID)
            HStack(spacing: 0) {
                Button { player.toggle(url) } label: {
                    HStack(spacing: 4) {
                        Text("v\(index + 1) of \(line.versions.count)").lineLimit(1).minimumScaleFactor(0.8)
                        if version.direction {
                            Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.leading, compact ? 6 : 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(versionTitle(version, index))
                .accessibilityLabel(player.playing == url ? "Stop" : "Play version \(index + 1)")
                Menu {
                    ForEach(Array(line.versions.enumerated()), id: \.element.id) { offset, item in
                        Button(versionTitle(item, offset)) {
                            projects.choose(item.id, line: line.id, in: projectID)
                            let url = projects.audioURL(item, projectID: projectID)
                            if player.playing != url { player.toggle(url) }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: compact ? 14 : 22, height: 28)
                        .contentShape(.rect)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Versions")
            }
            .font(.system(size: compact ? 11 : 13).monospacedDigit())
            .frame(height: 28)
            .background(player.playing == url ? Theme.selection : .clear, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.outline))
            .padding(.horizontal, compact ? 2 : 4)
        } else {
            Text("–").foregroundStyle(Theme.secondary).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func versionTitle(_ version: Version, _ index: Int) -> String {
        (["v\(index + 1)", version.tone] + (version.direction ? ["direction"] : [])).joined(separator: " · ")
    }

    @ViewBuilder private var rerenderButton: some View {
        if projects.renderingLine == line.id {
            ProgressView().controlSize(.small)
        } else {
            Button { projects.rerender(line.id, in: projectID, voices: voices) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.outline))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(line.text.trimmingCharacters(in: .whitespaces).isEmpty || projects.progress != nil)
            .help("Render again")
            .accessibilityLabel("Render line \(number) again")
        }
    }
}

/// ✓ and ✕ for a change an agent proposed.
struct DecisionButtons: View {
    /// What is decided, for VoiceOver: "Accept change to line 3".
    let label: String
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            button("checkmark", help: "Accept", action: onAccept).accessibilityLabel("Accept \(label)")
            button("xmark", help: "Reject", action: onReject).accessibilityLabel("Reject \(label)")
        }
    }

    private func button(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.outline))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A line's pending change: the old text struck through above the new, and any tone or pause change.
private struct ProposalText: View {
    let line: Line
    let proposal: Proposal

    var body: some View {
        let changes = [
            proposal.tone == line.tone ? nil : "\(line.tone) → \(proposal.tone)",
            proposal.pauseAfter == line.pauseAfter ? nil : "\(seconds(line.pauseAfter)) → \(seconds(proposal.pauseAfter))",
        ].compactMap(\.self)
        VStack(alignment: .leading, spacing: 3) {
            if proposal.text != line.text {
                Text(line.text).strikethrough().foregroundStyle(Theme.secondary)
            }
            Text(proposal.text)
            if !changes.isEmpty {
                Text(changes.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((["Proposed: \(proposal.text)"] + (proposal.text == line.text ? [] : ["was: \(line.text)"]) + changes).joined(separator: ", "))
    }

    private func seconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) + "s" }
}

/// A menu's label: title and chevron in a thin outline.
private struct MenuBox: View {
    let title: String
    var dim = false

    var body: some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1).foregroundStyle(dim ? Theme.secondary : Theme.text).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6)
        .frame(height: 28)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.outline))
        .contentShape(.rect)
    }
}

/// A score as a number; a low one gets the amber triangle, a bold value and its reason on hover.
/// A dim one is shown but not judged.
private struct ScoreCell: View {
    let value: String?
    let flag: String?
    var dim = false
    var help: String?

    var body: some View {
        HStack(spacing: 4) {
            if flag != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Theme.amber)
            }
            Text(value ?? "–")
                .fontWeight(flag == nil ? .regular : .bold)
                .foregroundStyle(value == nil || dim ? Theme.secondary : Theme.text)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .help(flag ?? help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([value ?? "None", flag ?? (dim ? help : nil)].compactMap(\.self).joined(separator: ", "))
    }
}

/// A line's Jev checks: quiet when they pass, the amber triangle when one fails, a neutral mark when one is unsettled.
/// A failed call is shown as an error, never as a failed check. The reasons show on hover.
private struct JevCell: View {
    @Environment(Jev.self) private var jev
    let subject: JevSubject

    var body: some View {
        let result = jev.results[subject], error = jev.failures[subject]
        let help = error.map { "Check failed. \($0)" } ?? result?.notes(tone: subject.tone).joined(separator: "\n")
            ?? (subject.text.isEmpty ? "" : "Not checked")
        Group {
            if jev.checking.contains(subject) {
                ProgressView().controlSize(.mini)
            } else if error != nil {
                mark("exclamationmark.icloud", Theme.secondary)
            } else if let result {
                switch result.status {
                case .no: mark("exclamationmark.triangle.fill", Theme.amber)
                case .unsettled: mark("questionmark.circle", Theme.secondary)
                case .yes: mark("checkmark", Theme.secondary)
                }
            } else {
                Text("–").foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help.isEmpty ? "Jev: not checked" : "Jev: " + help.replacing("\n", with: ", "))
    }

    private func mark(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
    }
}

// MARK: Sheets

struct SplitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let onAdd: ([String]) -> Void
    @State private var split = ScriptSplit.sentences

    var body: some View {
        let lines = Script.lines(Script.plainText(text), by: split)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Split into lines").font(.system(size: 22, weight: .bold))
                Spacer()
                Picker("Split", selection: $split) {
                    ForEach(ScriptSplit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                .frame(height: 280)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.outline(height: 32)).keyboardShortcut(.cancelAction)
                Button(lines.count == 1 ? "Add 1 line" : "Add \(lines.count) lines") {
                    onAdd(lines)
                    dismiss()
                }
                .buttonStyle(.primary(height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(lines.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(Theme.content)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
    }
}

struct CompareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VoiceStore.self) private var voices
    let lines: [Line]
    let title: String
    let onRender: ([String]) -> Void
    @State private var tones: Set<String> = []

    var body: some View {
        let count = lines.count * tones.count
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare styles").font(.system(size: 22, weight: .bold))
                Text(title).foregroundStyle(Theme.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 10) {
                ForEach(Tone.all, id: \.self) { tone in
                    Toggle(isOn: Binding(get: { tones.contains(tone) },
                                         set: { if $0 { tones.insert(tone) } else { tones.remove(tone) } })) {
                        HStack(spacing: 6) {
                            Text(tone)
                            if !recorded(tone) { Text("direction").foregroundStyle(Theme.secondary) }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.outline(height: 32)).keyboardShortcut(.cancelAction)
                Button(count == 1 ? "Render 1 version" : "Render \(count) versions") {
                    onRender(Tone.all.filter(tones.contains))
                    dismiss()
                }
                .buttonStyle(.primary(height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Theme.content)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onAppear {
            // Recorded tone takes first; with none, two contrasting directions.
            let own = Set(lines.map(\.tone))
            let recordedTones = Tone.all.filter { recorded($0) && !own.contains($0) }
            tones = Set(recordedTones.isEmpty ? ["Confident", "Happy"] : recordedTones)
        }
    }

    /// Every line's voice has a take in this tone.
    private func recorded(_ tone: String) -> Bool {
        lines.allSatisfy { !(voices.voice($0.voiceID)?.takes(tone).isEmpty ?? true) }
    }
}

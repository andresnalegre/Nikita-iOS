import Nikita
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Nikita's chat screen. A capable model over a plain HTTPS link -- no local
// runtime, no streaming assembly -- so the view stays simple: a scroll of
// messages, expandable tool rows, a live cost/token footer, and a Send/Stop
// control that mirrors the desktop's.
struct NikitaView: View {
    // Optional message to send automatically when the chat opens (e.g. "Check
    // with Nikita" from the log viewer hands the log in for analysis).
    var initialMessage: String?

    // The same bridge the CLI screen uses, so a connection made there is one
    // Nikita can use too.
    @StateObject private var agent = NikitaAgent(
        bridge: LiveDeviceBridge(),
        machine: MailboxMachineBridge())
    @State private var draft = ""
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool
    @State private var hasKey = NikitaSettings.shared.hasApiKey
    @State private var planExpanded = false
    @State private var pulse = false
    @StateObject private var dictation = NikitaDictation()
    // Files/images staged for the next message, shown as a strip above the
    // input bar until sent. Images go to Kimi as vision parts; text files are
    // inlined into the prompt.
    @State private var pending: [NikitaAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    // The "+" menu sub-sheets.
    @State private var showQuick = false
    @State private var showSkill = false
    @State private var showPlugins = false
    // Holds the app awake for the OS-allotted window (tens of seconds, and
    // a few minutes) so a turn already in flight keeps running when the user
    // switches to another app, instead of being frozen mid-thought. iOS does
    // not grant unlimited background time to work like this, so a very long
    // turn can still be suspended -- but the common case of glancing at another
    // app while Nikita finishes now survives.
    @State private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var body: some View {
        VStack(spacing: 0) {
            if !hasKey {
                NikitaSetupBanner { showSettings = true }
            }
            planStrip
            fragmentsStrip
            messagesList
            footer
            if dictation.listening {
                NikitaWaveform(levels: dictation.levels)
                    .frame(height: 40)
                    .padding(.horizontal)
                    .transition(.opacity)
            }
            if !pending.isEmpty {
                pendingStrip
            }
            inputBar
        }
        .task {
            // Bring the MCP servers up before the first message, so their
            // tools are known when the model is first asked to do something
            // rather than discovered halfway through a turn.
            await agent.connectMcp()
            if let initialMessage, agent.messages.isEmpty {
                agent.send(initialMessage)
            }
        }
        .navigationBarTitle("Nikita", displayMode: .inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        agent.clear()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            hasKey = NikitaSettings.shared.hasApiKey
        }) {
            NavigationView { NikitaSettingsView() }
        }
        .sheet(isPresented: $showQuick) {
            NikitaQuickCommandsSheet { prompt in
                showQuick = false
                if dictation.listening { dictation.stop() }
                agent.send(prompt)
            }
        }
        .sheet(isPresented: $showSkill) {
            NikitaAddSkillSheet()
        }
        .sheet(isPresented: $showPlugins) {
            NikitaPluginsSheet()
        }
        .onChange(of: agent.thinking) { thinking in
            if thinking { beginBackgroundHold() } else { endBackgroundHold() }
        }
    }

    // NIKITA's own list of steps, written with update_plan and kept on disk.
    // It sits above the conversation rather than inside the settings because
    // it is the answer to "what is it doing" -- and because it survives the
    // app closing, so on the next launch this strip is what says the job is
    // still open when the conversation looks finished.
    //
    // Collapsed to the current step by default: while it is working, the next
    // thing is the only line anyone reads.
    @ViewBuilder
    private var planStrip: some View {
        if !agent.planItems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("PLAN")
                        .font(.system(
                            size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.accentColor)
                    Text(agent.planOpenCount > 0
                         ? "\(agent.planItems.count - agent.planOpenCount)/"
                           + "\(agent.planItems.count) done"
                         : "all done")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(
                            agent.planOpenCount > 0 ? .secondary : .green)
                    if !planExpanded, let now = currentPlanItem {
                        Text("· \(now)")
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: planExpanded
                          ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                if planExpanded {
                    ForEach(agent.planItems) { item in
                        HStack(alignment: .top, spacing: 6) {
                            Text(mark(for: item.status))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(colour(for: item.status))
                            Text(item.text)
                                .font(.system(
                                    size: 10,
                                    weight: item.status == .inProgress
                                        ? .semibold : .regular,
                                    design: .monospaced))
                                .foregroundColor(colour(for: item.status))
                            Spacer()
                        }
                    }
                    if !agent.planNote.isEmpty {
                        Text(agent.planNote)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Button("Clear plan") { agent.clearPlan() }
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.10))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    planExpanded.toggle()
                }
            }
        }
    }

    // The parallel Nikita fragments spun off with spawn_task. Each is the same
    // Nikita working a sub-task in the background; a running one pulses (green
    // dot), a finished one shows done/failed. This is the visible half of "N
    // agentes completos" on the phone, matching qFlipper's fragments strip.
    @ViewBuilder
    private var fragmentsStrip: some View {
        if !agent.fragments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("✦ FRAGMENTS")
                        .font(.system(
                            size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.accentColor)
                    Text(agent.runningFragmentCount > 0
                         ? "\(agent.runningFragmentCount) running" : "all done")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(
                            agent.runningFragmentCount > 0 ? .accentColor : .green)
                    Spacer()
                    if agent.runningFragmentCount == 0 {
                        Button("Clear") { agent.clearFinishedFragments() }
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                ForEach(agent.fragments) { frag in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(fragColour(frag.state))
                            .frame(width: 7, height: 7)
                            .padding(.top, 3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(frag.title)
                                .font(.system(
                                    size: 10, weight: .semibold,
                                    design: .monospaced))
                                .lineLimit(1)
                            if !frag.status.isEmpty {
                                Text(frag.status)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if frag.state == .running {
                            Button("stop") { agent.stopFragment(id: frag.id) }
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    private func fragColour(_ state: NikitaFragment.State) -> Color {
        switch state {
        case .running: return .accentColor
        case .done: return .green
        case .failed, .stopped: return .red
        }
    }

    private var currentPlanItem: String? {
        if let doing = agent.planItems.first(where: {
            $0.status == .inProgress
        }) { return doing.text }
        return agent.planItems.first { $0.status == .pending }?.text
    }

    private func mark(for status: NikitaPlanItem.Status) -> String {
        switch status {
        case .done: return "[x]"
        case .inProgress: return "[>]"
        case .pending: return "[ ]"
        }
    }

    private func colour(for status: NikitaPlanItem.Status) -> Color {
        switch status {
        case .done: return .secondary
        case .inProgress: return .primary
        case .pending: return .secondary
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if agent.messages.isEmpty {
                        NikitaEmptyState()
                            .padding(.top, 60)
                    }
                    ForEach(agent.messages) { message in
                        NikitaMessageRow(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: agent.messages.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // The live status line, mirroring qFlipper's footer: a pulsing dot, the
    // elapsed seconds ticking, the tokens climbing, the running cost, and what
    // it is doing this moment -- all on one line under the conversation. When
    // idle it collapses to just the session total.
    @ViewBuilder
    private var footer: some View {
        if agent.thinking || agent.usage.sessionCostUSD > 0 {
            HStack(spacing: 6) {
                if agent.thinking {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .opacity(pulse ? 0.3 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.7).repeatForever(),
                            value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                    Text(agent.turnElapsedText)
                    if agent.turnTokens > 0 {
                        Text("· \(compact(agent.turnTokens)) tok")
                    }
                    if agent.usage.turnCostUSD > 0 {
                        Text(String(
                            format: "· $%.4f", agent.usage.turnCostUSD))
                    }
                    let phase = agent.turnStatus.isEmpty
                        ? "thinking" : agent.turnStatus
                    Text("· \(phase)")
                        .lineLimit(1)
                    if agent.runningFragmentCount > 0 {
                        Text("· +\(agent.runningFragmentCount) frag")
                            .foregroundColor(.accentColor)
                    }
                    Spacer()
                } else {
                    Spacer()
                    Text(costText)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    // 1234 -> "1.2k", so a long turn's count stays one glanceable token.
    private func compact(_ n: Int) -> String {
        n < 1000 ? "\(n)" : String(format: "%.1fk", Double(n) / 1000)
    }

    private var costText: String {
        let session = agent.usage.sessionCostUSD
        let tokens = agent.usage.promptTokens + agent.usage.completionTokens
        return String(format: "%@ tok · $%.4f", compact(tokens), session)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Attach an image or a file for Nikita to look at. Images become
            // vision input; a photo comes from the library, a file from the
            // document picker.
            if !agent.thinking {
                Menu {
                    PhotosPicker(
                        selection: $photoItems,
                        maxSelectionCount: 4,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Label("Add photo or video", systemImage: "photo")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Add file", systemImage: "doc")
                    }
                    Divider()
                    Button {
                        showQuick = true
                    } label: {
                        Label("Quick commands", systemImage: "bolt")
                    }
                    Button {
                        showSkill = true
                    } label: {
                        Label("Add New Skill", systemImage: "sparkles")
                    }
                    Button {
                        showPlugins = true
                    } label: {
                        Label("Plugins", systemImage: "powerplug")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 26))
                        .foregroundColor(.accentColor)
                }
                .disabled(!hasKey)
            }

            TextField("Message Nikita…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .focused($inputFocused)
                .disabled(!hasKey)

            // Speak instead of type. While listening, the recognised words
            // stream straight into the draft (see onChange below) so the user
            // watches their message appear and can send the instant they stop.
            if !agent.thinking {
                Button {
                    dictation.toggle()
                } label: {
                    Image(systemName: dictation.listening
                          ? "mic.fill" : "mic")
                        .font(.system(size: 26))
                        .foregroundColor(dictation.listening
                                         ? .red : .accentColor)
                }
                .disabled(!hasKey)
            }

            if agent.thinking {
                Button {
                    agent.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.red)
                }
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(canSend ? .accentColor : .gray)
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onChange(of: dictation.transcript) { text in
            if !text.isEmpty { draft = text }
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { loadFiles(urls) }
        }
    }

    // MARK: attachments

    private var pendingStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pending) { att in
                    NikitaAttachmentChip(attachment: att) {
                        pending.removeAll { $0.id == att.id }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(
                type: Data.self) else { continue }
            let isVideo = item.supportedContentTypes.contains {
                $0.conforms(to: .movie) || $0.conforms(to: .video)
            }
            if isVideo {
                if data.count > 12 * 1024 * 1024 {
                    await MainActor.run {
                        agent.noteError("That video is too large to send inline "
                            + "(~12 MB max). Trim or lower the resolution first.")
                    }
                    continue
                }
                let mime = "video/mp4"
                let b64 = data.base64EncodedString()
                let att = NikitaAttachment(
                    kind: .video, filename: "video.mp4", mime: mime,
                    dataURL: "data:\(mime);base64,\(b64)", byteCount: data.count)
                await MainActor.run { pending.append(att) }
            } else {
                let mime = "image/jpeg"
                let b64 = data.base64EncodedString()
                let att = NikitaAttachment(
                    kind: .image, filename: "photo.jpg", mime: mime,
                    dataURL: "data:\(mime);base64,\(b64)", byteCount: data.count)
                await MainActor.run { pending.append(att) }
            }
        }
        await MainActor.run { photoItems = [] }
    }

    private func loadFiles(_ urls: [URL]) {
        for url in urls {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
            let videoExts = ["mp4", "mov", "webm", "m4v", "mpeg", "mpg"]
            if imageExts.contains(ext) {
                let mime = ext == "png" ? "image/png"
                    : (ext == "webp" ? "image/webp" : "image/jpeg")
                let b64 = data.base64EncodedString()
                pending.append(NikitaAttachment(
                    kind: .image, filename: name, mime: mime,
                    dataURL: "data:\(mime);base64,\(b64)",
                    byteCount: data.count))
            } else if videoExts.contains(ext) {
                // Base64 video only works for small clips; cap ~12 MB.
                guard data.count <= 12 * 1024 * 1024 else {
                    agent.noteError("Video \(name) is too large to send inline "
                        + "(~12 MB max). Trim or lower the resolution first.")
                    continue
                }
                let mime = ext == "mov" ? "video/quicktime"
                    : (ext == "webm" ? "video/webm" : "video/mp4")
                let b64 = data.base64EncodedString()
                pending.append(NikitaAttachment(
                    kind: .video, filename: name, mime: mime,
                    dataURL: "data:\(mime);base64,\(b64)",
                    byteCount: data.count))
            } else if let text = String(data: data, encoding: .utf8) {
                pending.append(NikitaAttachment(
                    kind: .text, filename: name, mime: "text/plain",
                    textContent: String(text.prefix(100_000)),
                    byteCount: data.count))
            } else {
                pending.append(NikitaAttachment(
                    kind: .file, filename: name,
                    mime: "application/octet-stream",
                    byteCount: data.count))
            }
        }
    }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty
        return (hasText || !pending.isEmpty) && hasKey
    }

    private func beginBackgroundHold() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(
            withName: "nikita-turn") {
            endBackgroundHold()
        }
    }

    private func endBackgroundHold() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    private func send() {
        // If the mic is still open, close it first so the final words land and
        // the recognizer releases the audio session before the turn starts.
        if dictation.listening { dictation.stop() }
        let text = draft
        let attachments = pending
        draft = ""
        pending = []
        agent.send(text, attachments: attachments)
    }
}

// MARK: waveform

// The live voice waveform shown while dictating: a row of bars whose heights
// follow recent microphone loudness, newest on the right, so the user sees the
// mic is hearing them. Purely a level meter -- the words themselves stream into
// the draft via the recognizer.
private struct NikitaWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geo in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 3
            let barWidth = max(
                2, (geo.size.width - spacing * CGFloat(count - 1))
                    / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(
                            width: barWidth,
                            height: max(3, level * geo.size.height))
                }
            }
            .frame(
                width: geo.size.width, height: geo.size.height,
                alignment: .trailing)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}

// MARK: attachment chip

private struct NikitaAttachmentChip: View {
    let attachment: NikitaAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image,
                   let img = decodedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: attachment.kind == .video
                              ? "film.fill" : "doc.fill")
                            .font(.system(size: 20))
                        Text(attachment.filename)
                            .font(.system(size: 8))
                            .lineLimit(1)
                    }
                    .frame(width: 56, height: 56)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .offset(x: 5, y: -5)
        }
    }

    private var decodedImage: UIImage? {
        guard let comma = attachment.dataURL.firstIndex(of: ",") else {
            return nil
        }
        let b64 = String(attachment.dataURL[
            attachment.dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: Rows

private struct NikitaMessageRow: View {
    let message: NikitaChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.attachments) { att in
                                NikitaBubbleAttachment(attachment: att)
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .padding(10)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundColor(.orange)
                .padding(10)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        default:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(message.toolCalls) { call in
                    NikitaToolRow(call: call)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// A sent attachment shown inside the user's chat bubble: image as a thumbnail,
// anything else as a small file card.
private struct NikitaBubbleAttachment: View {
    let attachment: NikitaAttachment

    var body: some View {
        if attachment.kind == .image, let img = decodedImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            HStack(spacing: 6) {
                Image(systemName: attachment.kind == .video
                      ? "film.fill" : "doc.fill")
                Text(attachment.kind == .video
                     ? "video" : attachment.filename).lineLimit(1)
            }
            .font(.caption)
            .padding(8)
            .background(Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var decodedImage: UIImage? {
        guard let comma = attachment.dataURL.firstIndex(of: ",") else {
            return nil
        }
        let b64 = String(attachment.dataURL[
            attachment.dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }
}

private struct NikitaToolRow: View {
    let call: NikitaToolInvocation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                        .font(.caption)
                    Text(call.pretty)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded && !call.result.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(call.result)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                }
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusIcon: String {
        call.result.isEmpty ? "circle.dotted"
            : (call.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
    }
    private var statusColor: Color {
        call.result.isEmpty ? .secondary : (call.ok ? .green : .red)
    }
}

// MARK: Empty state / setup

private struct NikitaEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            Text("Nikita")
                .font(.title2.bold())
            Text("Your Flipper, driven by chat. Ask it to read the SD card, "
                 + "write a script, open an app, or drive the screen — over "
                 + "Bluetooth.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct NikitaSetupBanner: View {
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "key.fill")
                Text("Add your Kimi API key to enable Nikita")
                    .font(.footnote)
                Spacer()
                Image(systemName: "chevron.right")
            }
            .padding()
            .background(Color.yellow.opacity(0.15))
        }
        .buttonStyle(.plain)
    }
}

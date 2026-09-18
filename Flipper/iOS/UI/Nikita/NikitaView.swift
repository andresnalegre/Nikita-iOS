import Nikita
import SwiftUI
import UIKit

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
            messagesList
            footer
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
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasKey
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
        draft = ""
        agent.send(text)
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
                Text(message.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
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

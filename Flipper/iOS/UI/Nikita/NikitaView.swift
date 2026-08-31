import Nikita
import SwiftUI

// Nikita's chat screen. A capable model over a plain HTTPS link -- no local
// runtime, no streaming assembly -- so the view stays simple: a scroll of
// messages, expandable tool rows, a live cost/token footer, and a Send/Stop
// control that mirrors the desktop's.
struct NikitaView: View {
    // Optional message to send automatically when the chat opens (e.g. "Check
    // with Nikita" from the log viewer hands the log in for analysis).
    var initialMessage: String?

    @StateObject private var agent = NikitaAgent(bridge: LiveDeviceBridge())
    @State private var draft = ""
    @State private var showSettings = false
    @FocusState private var inputFocused: Bool
    @State private var hasKey = NikitaSettings.shared.hasApiKey

    var body: some View {
        VStack(spacing: 0) {
            if !hasKey {
                NikitaSetupBanner { showSettings = true }
            }
            messagesList
            footer
            inputBar
        }
        .task {
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

    @ViewBuilder
    private var footer: some View {
        if agent.thinking || agent.usage.sessionCostUSD > 0 {
            HStack(spacing: 12) {
                if agent.thinking {
                    ProgressView().scaleEffect(0.7)
                    Text(agent.turnStatus.isEmpty ? "thinking…" : agent.turnStatus)
                }
                Spacer()
                if agent.usage.sessionCostUSD > 0 {
                    Text(costText)
                }
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    private var costText: String {
        let session = agent.usage.sessionCostUSD
        let tokens = agent.usage.promptTokens + agent.usage.completionTokens
        return String(format: "%d tok · $%.4f", tokens, session)
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
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasKey
    }

    private func send() {
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

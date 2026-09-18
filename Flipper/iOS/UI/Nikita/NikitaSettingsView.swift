import Nikita
import SwiftUI

// Setup for Nikita: the Kimi API key (write-only to the UI, stored in the
// Keychain), the model picker, the per-family access filters, and the MCP tool
// servers. "Erase" wipes the key, the servers and their tokens and turns every
// filter off -- erase means disconnect, the same contract as the desktop.
struct NikitaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let settings = NikitaSettings.shared

    @State private var keyDraft = ""
    @State private var showKey = false
    @State private var model = NikitaSettings.shared.model
    @State private var filters: [String: Bool] = [:]
    @State private var hasStoredKey = NikitaSettings.shared.hasApiKey
    @State private var showEraseConfirm = false
    @State private var braveDraft = ""
    @State private var hasBrave = NikitaSettings.shared.hasBraveKey

    // Its own client, not the agent's: this screen needs to show whether a
    // server actually answers, and it has to be able to try again after an
    // edit. The agent keeps its own and reads the same stored config.
    @StateObject private var mcp = NikitaMcp()
    @State private var mcpOn = NikitaSettings.shared.mcpEnabled
    @State private var servers = NikitaSettings.shared.mcpServers
    @State private var showAddServer = false
    @State private var draftName = ""
    @State private var draftURL = ""
    @State private var draftToken = ""

    var body: some View {
        Form {
            Section {
                if hasStoredKey && keyDraft.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("API key saved")
                        Spacer()
                        Button("Replace") { hasStoredKey = false }
                            .font(.footnote)
                    }
                } else {
                    HStack {
                        if showKey {
                            TextField("sk-…", text: $keyDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("sk-…", text: $keyDraft)
                        }
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Save key") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(
                            in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Moonshot Kimi API key")
            } footer: {
                Text("Your key is stored in the iOS Keychain on this device and "
                     + "sent only to api.moonshot.ai. Get one at platform.moonshot.ai.")
            }

            Section("Model") {
                Picker("Model", selection: $model) {
                    ForEach(KimiClient.models) { m in
                        Text(m.label).tag(m.id)
                    }
                }
                .onChange(of: model) { settings.model = $0 }
            }

            // The Flipper itself, over Bluetooth. On by default: this is what
            // the assistant is for, and none of it leaves the device.
            Section {
                ForEach(flipperFamilies, id: \.id) { family in
                    row(family)
                }
            } header: {
                Text("The Flipper")
            } footer: {
                Text("Turn a family off and Nikita refuses those tools with an "
                     + "honest message instead of using them.")
            }

            // Everything that reaches past Bluetooth. Off until switched on:
            // these need nikita-flipper-bridge running on a computer, and they
            // reach that computer, not just the Flipper.
            Section {
                ForEach(bridgeFamilies, id: \.id) { family in
                    row(family)
                }
            } header: {
                Text("Through the bridge")
            } footer: {
                Text("These need nikita-flipper-bridge running on the computer "
                     + "holding your Flipper on USB. They are off until you "
                     + "turn them on, and \"run commands\" is a shell on that "
                     + "computer -- give it out as carefully as you would your "
                     + "own terminal.")
            }

            Section {
                if hasBrave && braveDraft.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("Brave key saved — deep search on")
                        Spacer()
                        Button("Replace") { hasBrave = false }
                            .font(.footnote)
                    }
                    Button("Remove key", role: .destructive) {
                        settings.clearBraveKey()
                        hasBrave = false
                        braveDraft = ""
                    }
                } else {
                    SecureField("Brave Search API key", text: $braveDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        settings.setBraveKey(braveDraft)
                        braveDraft = ""
                        hasBrave = settings.hasBraveKey
                    }
                    .disabled(braveDraft.trimmingCharacters(
                        in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Web search")
            } footer: {
                Text("Optional. A free Brave Search key (2000/mo at "
                     + "brave.com/search/api) gives real ranked results, no "
                     + "captcha. Without it, search falls back to keyless "
                     + "sources that cover topics but not private people.")
            }

            mcpSection

            Section {
                Button("Allow everything") { setAll(true) }
                Button("Allow nothing", role: .destructive) { setAll(false) }
            }

            Section {
                Button(role: .destructive) {
                    showEraseConfirm = true
                } label: {
                    Label("Erase Nikita data", systemImage: "trash")
                }
            } footer: {
                Text("Removes the API key and the MCP servers, and switches "
                     + "every access filter off.")
            }
        }
        .navigationTitle("Nikita")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            loadFilters()
            Task { await mcp.reload() }
        }
        .sheet(isPresented: $showAddServer) { addServerSheet }
        .confirmationDialog(
            "Erase all Nikita data?",
            isPresented: $showEraseConfirm,
            titleVisibility: .visible
        ) {
            Button("Erase", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: MCP
    //
    // Tool servers, over the same protocol Claude Code speaks. HTTP only, and
    // that is a platform fact rather than a choice: the usual MCP transport is
    // a child process on stdin/stdout, and an iOS app cannot start one. A
    // stdio-only server goes behind a small HTTP proxy on the computer and
    // this talks to that.

    @ViewBuilder
    private var mcpSection: some View {
        Section {
            Toggle("Use MCP servers", isOn: Binding(
                get: { mcpOn },
                set: {
                    mcpOn = $0
                    settings.mcpEnabled = $0
                    Task { await mcp.reload() }
                }))

            if mcpOn {
                ForEach(mcp.states) { state in
                    serverRow(state)
                }
                // A configured server that has not answered yet still needs a
                // row, or removing it is impossible until it connects.
                ForEach(servers.filter { s in
                    !mcp.states.contains { $0.name == s.name }
                }) { server in
                    HStack {
                        Text(server.name)
                        Spacer()
                        Text("not connected")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .onDelete(perform: removeServer)

                Button {
                    draftName = ""
                    draftURL = ""
                    draftToken = ""
                    showAddServer = true
                } label: {
                    Label("Add a server", systemImage: "plus")
                }

                if !mcp.states.isEmpty {
                    Button {
                        Task { await mcp.reload() }
                    } label: {
                        Label(mcp.busy ? "Connecting…" : "Reconnect",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(mcp.busy)
                }
            }
        } header: {
            Text("MCP servers")
        } footer: {
            Text(mcpOn
                 ? mcp.statusLine + ". Their tools are offered to Nikita "
                   + "alongside its own, named mcp__<server>__<tool>."
                 : "Off: no MCP tools are offered.")
        }
    }

    @ViewBuilder
    private func serverRow(_ state: NikitaMcp.State) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(colour(for: state.status))
                    .frame(width: 8, height: 8)
                Text(state.name)
                Spacer()
                Text(state.status == "ready"
                     ? "\(state.toolCount) tool(s)" : state.status)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if !state.error.isEmpty {
                Text(state.error)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            } else if !state.label.isEmpty {
                Text(state.label)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                delete(named: state.name)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func colour(for status: String) -> Color {
        switch status {
        case "ready": return .green
        case "failed": return .orange
        case "connecting": return .yellow
        default: return .secondary
        }
    }

    @ViewBuilder
    private var addServerSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. github", text: $draftName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("https://…/mcp", text: $draftURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    Text("The name becomes part of every tool's name, so keep "
                         + "it short and stable.")
                }
                Section {
                    SecureField("Bearer token (optional)", text: $draftToken)
                } footer: {
                    Text("Sent as the Authorization header and stored in the "
                         + "iOS Keychain, never in plain settings.")
                }
            }
            .navigationTitle("Add MCP server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddServer = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveServer() }
                        .disabled(!draftIsUsable)
                }
            }
        }
    }

    private var draftIsUsable: Bool {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let url = draftURL.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && URL(string: url)?.scheme != nil
    }

    private func saveServer() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let url = draftURL.trimmingCharacters(in: .whitespaces)
        let token = draftToken.trimmingCharacters(in: .whitespaces)
        settings.addOrUpdateMcpServer(
            .init(name: name, url: url),
            token: token.isEmpty ? nil : token)
        servers = settings.mcpServers
        showAddServer = false
        Task { await mcp.reload() }
    }

    private func removeServer(at offsets: IndexSet) {
        let pending = servers.filter { s in
            !mcp.states.contains { $0.name == s.name }
        }
        for i in offsets where pending.indices.contains(i) {
            delete(named: pending[i].name)
        }
    }

    private func delete(named name: String) {
        settings.removeMcpServer(named: name)
        servers = settings.mcpServers
        Task { await mcp.reload() }
    }

    // Split the way the risk splits: what stays on the Flipper, and what
    // reaches the computer behind it.
    private var flipperFamilies: [NikitaSettings.Family] {
        NikitaSettings.families.filter { !$0.defaultsOff }
    }

    private var bridgeFamilies: [NikitaSettings.Family] {
        NikitaSettings.families.filter(\.defaultsOff)
    }

    @ViewBuilder
    private func row(_ family: NikitaSettings.Family) -> some View {
        Toggle(isOn: binding(for: family.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(family.label)
                // The blurb is the part that says what the switch actually
                // permits. A label alone ("Computer: run commands") reads as a
                // feature rather than as a grant.
                Text(family.blurb)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func setAll(_ on: Bool) {
        for family in NikitaSettings.families {
            filters[family.id] = on
            settings.setAllowed(family.id, on)
        }
    }

    private func binding(for family: String) -> Binding<Bool> {
        Binding(
            get: { filters[family] ?? settings.isAllowed(family) },
            set: { filters[family] = $0; settings.setAllowed(family, $0) })
    }

    private func loadFilters() {
        for f in NikitaSettings.filterableTools {
            filters[f] = settings.isAllowed(f)
        }
    }

    private func saveKey() {
        settings.setApiKey(keyDraft)
        keyDraft = ""
        showKey = false
        hasStoredKey = settings.hasApiKey
        settings.enabled = hasStoredKey
    }

    private func erase() {
        settings.wipe()
        braveDraft = ""
        hasBrave = false
        keyDraft = ""
        hasStoredKey = false
        model = settings.model
        servers = []
        mcpOn = settings.mcpEnabled
        loadFilters()
        Task { await mcp.reload() }
    }
}

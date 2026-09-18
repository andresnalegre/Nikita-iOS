import Nikita
import SwiftUI

// The three "+" menu sheets on iOS, mirroring qFlipper's panels: a Quick
// commands catalog, Add New Skill (learn from a GitHub repo), and Plugins
// (register external HTTP APIs Nikita can call).

// MARK: Quick commands

struct NikitaQuickCommandsSheet: View {
    @StateObject private var extras = NikitaExtras.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newPrompt = ""
    // Called with the chosen prompt; the parent sends it.
    let onPick: (String) -> Void

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(extras.quickCommands) { qc in
                        Button {
                            onPick(qc.prompt)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(qc.label)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(qc.prompt)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .swipeActions {
                            if !qc.builtin {
                                Button(role: .destructive) {
                                    extras.removeQuickCommand(id: qc.id)
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                    }
                } footer: {
                    Text("Tap one to send it right away.")
                }
                Section("Add your own") {
                    HStack {
                        TextField("a prompt you use often…", text: $newPrompt)
                        Button("Add") {
                            extras.addQuickCommand(label: "", prompt: newPrompt)
                            newPrompt = ""
                        }
                        .disabled(newPrompt.trimmingCharacters(
                            in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Quick commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: Add New Skill

struct NikitaAddSkillSheet: View {
    @StateObject private var extras = NikitaExtras.shared
    @Environment(\.dismiss) private var dismiss
    @State private var repoURL = ""

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Paste a GitHub repo link. Nikita reads it, distills "
                        + "what it does, and keeps it as a skill she can use.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField(
                            "https://github.com/owner/repo", text: $repoURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button(extras.learnBusy ? "…" : "Learn") {
                            learn()
                        }
                        .disabled(repoURL.trimmingCharacters(
                            in: .whitespaces).isEmpty || extras.learnBusy)
                    }
                    if !extras.learnStatus.isEmpty {
                        Text(extras.learnStatus)
                            .font(.system(size: 12))
                            .foregroundColor(
                                extras.learnBusy ? .secondary : .green)
                    }
                }
                Section("Skills you've learned") {
                    if extras.skills.isEmpty {
                        Text("None yet.")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                    ForEach(extras.skills) { skill in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                                .font(.system(size: 14, weight: .semibold))
                            Text(skill.summary)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text(skill.repo)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                extras.removeSkill(name: skill.name)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("Add New Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func learn() {
        let key = NikitaSettings.shared.revealApiKey()
        let model = NikitaSettings.shared.model
        let url = repoURL
        Task { await extras.learnSkill(
            repoURL: url, apiKey: key, model: model) }
    }
}

// MARK: Plugins

struct NikitaPluginsSheet: View {
    @StateObject private var extras = NikitaExtras.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseUrl = ""
    @State private var authHeader = ""
    @State private var authValue = ""
    @State private var desc = ""

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Register an HTTP API so Nikita can call it. She gets "
                        + "a call_plugin tool; the base URL and auth header are "
                        + "added for her.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("New plugin") {
                    TextField("name (e.g. weather)", text: $name)
                        .autocorrectionDisabled()
                    TextField("base URL (https://…)", text: $baseUrl)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("auth header (optional)", text: $authHeader)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("auth value (optional)", text: $authValue)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("what it does / when to use it", text: $desc)
                    Button("Add plugin") {
                        extras.addPlugin(
                            name: name, baseUrl: baseUrl,
                            authHeader: authHeader, authValue: authValue,
                            description: desc)
                        name = ""; baseUrl = ""; authHeader = ""
                        authValue = ""; desc = ""
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                        || baseUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section("Registered") {
                    if extras.plugins.isEmpty {
                        Text("None yet.")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                    ForEach(extras.plugins) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                                .font(.system(size: 14, weight: .semibold))
                            Text(p.baseUrl)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            if !p.description.isEmpty {
                                Text(p.description)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                extras.removePlugin(name: p.name)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("Plugins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

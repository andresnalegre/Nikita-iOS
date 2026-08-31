import Nikita
import SwiftUI

// Setup for Nikita: the Kimi API key (write-only to the UI, stored in the
// Keychain), the model picker, and the per-family access filters. "Erase"
// wipes the key and turns every filter off -- erase means disconnect, the same
// contract as the desktop.
struct NikitaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let settings = NikitaSettings.shared

    @State private var keyDraft = ""
    @State private var showKey = false
    @State private var model = NikitaSettings.shared.model
    @State private var filters: [String: Bool] = [:]
    @State private var hasStoredKey = NikitaSettings.shared.hasApiKey
    @State private var showEraseConfirm = false

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

            Section {
                ForEach(NikitaSettings.filterableTools, id: \.self) { family in
                    Toggle(label(family), isOn: binding(for: family))
                }
            } header: {
                Text("What Nikita may touch")
            } footer: {
                Text("Turn a family off and Nikita refuses those tools with an "
                     + "honest message instead of using them.")
            }

            Section {
                Button(role: .destructive) {
                    showEraseConfirm = true
                } label: {
                    Label("Erase Nikita data", systemImage: "trash")
                }
            } footer: {
                Text("Removes the API key and switches every access filter off.")
            }
        }
        .navigationTitle("Nikita")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear(perform: loadFilters)
        .confirmationDialog(
            "Erase all Nikita data?",
            isPresented: $showEraseConfirm,
            titleVisibility: .visible
        ) {
            Button("Erase", role: .destructive) { erase() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func label(_ family: String) -> String {
        switch family {
        case "files": return "SD-card files"
        case "screen": return "Read the screen"
        case "buttons": return "Press buttons"
        case "apps": return "Open / close apps"
        case "memory": return "Remember facts"
        default: return family.capitalized
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
        keyDraft = ""
        hasStoredKey = false
        model = settings.model
        loadFilters()
    }
}

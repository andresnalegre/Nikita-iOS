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
        keyDraft = ""
        hasStoredKey = false
        model = settings.model
        loadFilters()
    }
}

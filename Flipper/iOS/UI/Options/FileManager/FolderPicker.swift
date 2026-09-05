import Core
import Peripheral

import SwiftUI

// Pick a directory on the Flipper. Used as the destination for move and copy,
// which the file manager had no way to express: rename could only keep a file
// where it was.
//
// Its own browser rather than a reuse of the listing: this one shows folders
// only, has no per-row actions, and every tap means "go deeper" instead of
// "open". Sharing the listing would have meant a mode flag threaded through
// all of it.
struct FolderPicker: View {
    @EnvironmentObject var fileManager: RemoteFileManager
    @Environment(\.dismiss) private var dismiss

    let title: String
    let onPick: (Peripheral.Path) -> Void

    @State private var path: Peripheral.Path = .init()
    @State private var directories: [Directory] = []
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(path.isEmpty ? "/" : path.string)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.black40)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                if isBusy {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if let error {
                    Spacer()
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.sRed)
                        .padding()
                    Spacer()
                } else {
                    List {
                        if !path.isEmpty {
                            Button("..") { goUp() }
                                .foregroundColor(.primary)
                        }
                        ForEach(directories, id: \.name) { directory in
                            Button {
                                path = path.appending(directory.name)
                                Task { await load() }
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(directory.name)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.black40)
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // The folder you are looking at is the destination -- there
                    // is nothing to select in the list, which is why the button
                    // says "here" rather than "Choose".
                    Button("Move here") {
                        onPick(path)
                        dismiss()
                    }
                    .disabled(path.isEmpty)
                }
            }
        }
        .task { await load() }
    }

    private func goUp() {
        guard !path.isEmpty else { return }
        path = path.removingLastComponent
        Task { await load() }
    }

    private func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            directories = try await fileManager.list(at: path).compactMap {
                guard case .directory(let directory) = $0 else { return nil }
                return directory
            }
            error = nil
        } catch {
            self.error = String(describing: error)
        }
    }
}

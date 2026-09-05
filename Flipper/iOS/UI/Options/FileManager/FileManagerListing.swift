import Core
import Peripheral

import SwiftUI
import UniformTypeIdentifiers

extension FileManagerView {
    struct FileManagerListing: View {
        @Environment(\.path) var navigationPath

        let path: Peripheral.Path

        @EnvironmentObject var fileManager: RemoteFileManager
        @Environment(\.dismiss) var dismiss

        @State private var elements: [Element] = []
        @State private var error: String?
        @State private var isBusy = false

        @State private var name = ""
        @State private var isNewFile = false
        @State private var isNewDirectory = false
        @FocusState var isNameFocused: Bool
        var namePlaceholder: String {
            "\(isNewFile ? "file" : "directory") name"
        }

        // The element being renamed, and the name being typed for it. Rename
        // is a move within the same directory, which the RPC has always
        // supported -- it simply was not offered anywhere in the app.
        @State private var renaming: Element?
        @State private var renameText = ""

        // Multi-select, driven by the List's own edit mode. Elements are
        // identified by their description, the same key the ForEach uses.
        @State private var selection: Set<String> = []
        @State private var editMode: EditMode = .inactive

        // Destination picker for move and copy. `copying` decides which of the
        // two the picked folder performs.
        @State private var isPickingDestination = false
        @State private var copying = false

        @State private var progressNote: String?

        @State private var selectedIndexSet: IndexSet?
        @State private var isForceDeletePresented = false
        @State private var isFileImporterPresented = false

        var body: some View {
            VStack {
                if isBusy {
                    ProgressView()
                } else if let error = error {
                    Text(error)
                } else {
                    List(selection: $selection) {
                        if !path.isEmpty {
                            Button("..") {
                                dismiss()
                            }
                            .foregroundColor(.primary)
                        }
                        if isNewFile || isNewDirectory {
                            TextField(namePlaceholder, text: $name)
                                .onSubmit {
                                    submitNewElement()
                                }
                                .focused($isNameFocused)
                        }
                        ForEach(elements, id: \.description) { element in
                            Group {
                                switch element {
                                case .directory(let directory):
                                    NavigationLink(value: Destination.listing(
                                        path.appending(directory.name)
                                    )) {
                                        DirectoryRow(directory: directory)
                                    }
                                    .foregroundColor(.primary)
                                case .file(let file):
                                    // The whole row opens the file. The
                                    // download arrow that used to sit at the
                                    // end of it made a tap near the trailing
                                    // edge start a transfer instead, so a file
                                    // could be pulled off the device by
                                    // reaching for it. Exporting is on the
                                    // context menu, where it is chosen rather
                                    // than hit.
                                    FileRow(file: file)
                                        .frame(maxWidth: .infinity,
                                               alignment: .leading)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            // A tap gesture on the row swallows
                                            // the one the List uses to tick it,
                                            // so selection is done by hand here.
                                            guard editMode != .active else {
                                                toggle(element)
                                                return
                                            }
                                            navigationPath.append(
                                                Destination.editor(
                                                    path.appending(file.name)
                                                )
                                            )
                                        }
                                }
                            }
                            // Long press for the things a row can do. Export
                            // and delete were already reachable, but only as an
                            // icon and a swipe; rename had nowhere to live at
                            // all until now.
                            .tag(element.description)
                            .contextMenu {
                                Button {
                                    beginRename(element)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }

                                Button {
                                    Task {
                                        switch element {
                                        case .file(let file):
                                            await downloadFile(file)
                                        case .directory(let directory):
                                            await exportDirectory(directory)
                                        }
                                    }
                                } label: {
                                    Label(
                                        "Export",
                                        systemImage: "square.and.arrow.up")
                                }

                                Button(role: .destructive) {
                                    Task { await delete(element) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { indexSet in
                            Task {
                                await delete(indexSet)
                            }
                        }
                    }
                }
            }
            .alert(
                "Rename",
                isPresented: .init(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } })
            ) {
                TextField("name", text: $renameText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    Task { await commitRename() }
                }
            }
            .environment(\.editMode, $editMode)
            .refreshable {
                await reloadQuietly()
            }
            .sheet(isPresented: $isPickingDestination) {
                FolderPicker(title: copying ? "Copy to" : "Move to") { target in
                    Task { await transferSelection(to: target) }
                }
                .environmentObject(fileManager)
            }
            .safeAreaInset(edge: .bottom) {
                if editMode == .active && !selection.isEmpty {
                    HStack(spacing: 18) {
                        Button {
                            copying = false
                            isPickingDestination = true
                        } label: {
                            Label("Move", systemImage: "folder")
                        }
                        Button {
                            copying = true
                            isPickingDestination = true
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button {
                            Task { await exportSelection() }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await deleteSelection() }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .foregroundColor(.sRed)
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
                }
            }
            .overlay {
                if let progressNote {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(progressNote)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.black40)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(
                        cornerRadius: 12))
                }
            }
            .navigationBarBackground(Color.background)
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LeadingToolbarItems {
                    if editMode == .active {
                        Button("Done") {
                            editMode = .inactive
                            selection = []
                        }
                    } else {
                        BackButton {
                            dismiss()
                        }
                    }
                }
                PrincipalToolbarItems(alignment: .leading) {
                    Title(path.lastComponent ?? "/")
                }
                TrailingToolbarItems {
                    if !path.isEmpty {
                        NavBarMenu {
                            Button {
                                newElement(isDirectory: false)
                            } label: {
                                Text("File")
                            }

                            Button {
                                newElement(isDirectory: true)
                            } label: {
                                Text("Folder")
                            }

                            Button {
                                isFileImporterPresented = true
                            } label: {
                                Text("Import")
                            }

                            Button {
                                selection = []
                                editMode = .active
                            } label: {
                                Text("Select")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .alert(
                "Directory is not empty",
                isPresented: $isForceDeletePresented,
                presenting: selectedIndexSet
            ) { selectedIndexSet in
                Button("Force Delete", role: .destructive) {
                    Task {
                        await delete(selectedIndexSet, force: true)
                    }
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [UTType.item]
            ) { result in
                if case .success(let url) = result {
                    Task {
                        await importFile(url)
                    }
                }
            }
            .task {
                await list()
            }
        }

        // Refresh without the full-screen spinner: pull-to-refresh has its own
        // indicator, and swapping the List out for a ProgressView mid-gesture
        // tears the control out from under the finger.
        func reloadQuietly() async {
            do {
                elements = try await fileManager.list(at: path)
                error = nil
            } catch {
                self.error = String(describing: error)
            }
        }

        func showingProgress(_ task: () async throws -> Void) async throws {
            isBusy = true
            defer { isBusy = false }
            try await task()
        }

        func list() async {
            do {
                try await showingProgress {
                    elements = try await fileManager.list(at: path)
                }
            } catch {
                self.error = String(describing: error)
            }
        }

        func delete(_ indexSet: IndexSet, force: Bool = false) async {
            guard let index = indexSet.first else { return }
            let element = elements.remove(at: index)
            do {
                try await fileManager.delete(element, at: path, force: force)
            } catch let error as RemoteFileManager.Error
                        where error == .directoryIsNotEmpty && !force {
                elements.insert(element, at: index)
                self.selectedIndexSet = indexSet
                self.isForceDeletePresented = true
            } catch {
                self.error = String(describing: error)
                elements.insert(element, at: index)
            }
        }

        func newElement(isDirectory: Bool) {
            name = ""
            isNewFile = !isDirectory
            isNewDirectory = isDirectory
            isNameFocused = true
        }

        func submitNewElement() {
            if !name.isEmpty {
                let path = path.appending(name)
                let isDirectory = isNewDirectory
                Task {
                    do {
                        try await fileManager.create(
                            path: path,
                            isDirectory: isDirectory)
                        await list()
                    } catch {
                        self.error = String(describing: error)
                    }
                }
            }
            name = ""
            isNewFile = false
            isNewDirectory = false
        }

        func importFile(_ url: URL) async {
            do {
                try await showingProgress {
                    try await fileManager.importFile(url: url, at: path)
                }
                await list()
            } catch {
                self.error = String(describing: error)
            }
        }

        func beginRename(_ element: Element) {
            renameText = element.name
            renaming = element
        }

        func commitRename() async {
            guard let element = renaming else { return }
            renaming = nil
            do {
                try await fileManager.rename(
                    element, at: path, to: renameText)
                await list()
            } catch {
                self.error = String(describing: error)
            }
        }

        // Delete one element, as the context menu asks. The swipe path still
        // goes through the IndexSet version, which also handles the non-empty
        // directory prompt.
        func delete(_ element: Element) async {
            guard let index = elements.firstIndex(where: {
                $0.description == element.description
            }) else { return }
            await delete(IndexSet(integer: index))
        }

        // The elements the selection refers to, in listing order.
        var selectedElements: [Element] {
            elements.filter { selection.contains($0.description) }
        }

        // Selection by hand for rows whose own gesture would otherwise win.
        func toggle(_ element: Element) {
            if selection.contains(element.description) {
                selection.remove(element.description)
            } else {
                selection.insert(element.description)
            }
        }

        func finishSelecting() {
            selection = []
            editMode = .inactive
        }

        func deleteSelection() async {
            let targets = selectedElements
            finishSelecting()
            isBusy = true
            defer { isBusy = false }
            for element in targets {
                do {
                    // force: a directory picked deliberately in a multi-select
                    // is meant to go with what is in it.
                    try await fileManager.delete(element, at: path, force: true)
                } catch {
                    self.error = String(describing: error)
                }
            }
            await list()
        }

        func transferSelection(to destination: Peripheral.Path) async {
            let targets = selectedElements
            let isCopy = copying
            finishSelecting()
            for element in targets {
                progressNote = "\(isCopy ? "Copying" : "Moving") \(element.name)"
                do {
                    if isCopy {
                        try await fileManager.copy(
                            element, from: path, to: destination)
                    } else {
                        try await fileManager.move(
                            element, from: path, to: destination)
                    }
                } catch {
                    self.error = String(describing: error)
                }
            }
            progressNote = nil
            await list()
        }

        // Everything selected, exported as one item: a single file shares as
        // itself, anything else is gathered into a folder and zipped, because
        // the share sheet takes one URL and a folder is not one.
        func exportSelection() async {
            let targets = selectedElements
            finishSelecting()
            guard !targets.isEmpty else { return }

            do {
                if targets.count == 1, case .file(let file) = targets[0] {
                    await downloadFile(file)
                    return
                }

                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("flipper-export-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: staging, withIntermediateDirectories: true)

                for element in targets {
                    switch element {
                    case .file(let file):
                        progressNote = "Exporting \(file.name)"
                        let bytes = try await fileManager.readRaw(
                            at: path.appending(file.name))
                        try Data(bytes).write(
                            to: staging.appendingPathComponent(file.name))
                    case .directory(let directory):
                        try await fileManager.exportDirectory(
                            directory,
                            at: path,
                            to: staging.appendingPathComponent(directory.name)
                        ) { name in
                            Task { @MainActor in
                                progressNote = "Exporting \(name)"
                            }
                        }
                    }
                }

                progressNote = "Compressing"
                let zip = try FileManager.default.zip(staging)
                progressNote = nil
                share(zip) {
                    try? FileManager.default.removeItem(at: staging)
                    try? FileManager.default.removeItem(at: zip)
                }
            } catch {
                progressNote = nil
                self.error = String(describing: error)
            }
        }

        // A whole folder, straight from its context menu.
        func exportDirectory(_ directory: Directory) async {
            do {
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("flipper-export-\(UUID().uuidString)")
                try await fileManager.exportDirectory(
                    directory,
                    at: path,
                    to: staging.appendingPathComponent(directory.name)
                ) { name in
                    Task { @MainActor in progressNote = "Exporting \(name)" }
                }
                progressNote = "Compressing"
                let zip = try FileManager.default.zip(staging)
                progressNote = nil
                share(zip) {
                    try? FileManager.default.removeItem(at: staging)
                    try? FileManager.default.removeItem(at: zip)
                }
            } catch {
                progressNote = nil
                self.error = String(describing: error)
            }
        }

        func downloadFile(_ file: File) async {
            isBusy = true
            defer { isBusy = false }
            do {
                let bytes = try await fileManager.readRaw(
                    at: path.appending(file.name))
                let url = try FileManager.default.createTempFile(
                    name: file.name,
                    data: .init(bytes))
                share(url) {
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}

extension FileManagerView.FileManagerListing {
    struct DirectoryRow: View {
        let directory: Directory

        var body: some View {
            HStack {
                Image(systemName: "folder.fill")
                    .frame(width: 20)

                Text(directory.name)
            }
        }
    }

    struct FileRow: View {
        let file: File

        var body: some View {
            HStack {
                Image(systemName: "doc")
                    .frame(width: 20)
                Text(file.name)
                Spacer()
                Text("\(file.size) bytes")
            }
            .contentShape(Rectangle())
        }
    }

}

import Foundation

extension FileManager {
    public func createTempFile(name: String, content: String) throws -> URL {
        try createTempFile(name: name, data: .init(content.utf8))
    }

    public func createTempFile(name: String, data: Data) throws -> URL {
        let fileURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(atPath: fileURL.path)
        }

        try data.write(to: fileURL)

        return fileURL
    }
}

extension FileManager {
    // Zip a folder, so a multi-file or whole-directory export can be handed to
    // the share sheet -- which takes exactly one URL, and a folder is not one.
    //
    // NSFileCoordinator's .forUploading option is what does the compressing.
    // It hands back a temporary archive that is deleted the moment the
    // coordinated read returns, so it is copied somewhere durable inside the
    // block rather than after it. No zip library needed.
    public func zip(_ directory: URL) throws -> URL {
        var archiveError: Swift.Error?
        var result: URL?

        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: [.forUploading],
            error: &coordinatorError
        ) { archive in
            do {
                let destination = temporaryDirectory
                    .appendingPathComponent(
                        directory.lastPathComponent + ".zip")
                if fileExists(atPath: destination.path) {
                    try removeItem(at: destination)
                }
                try copyItem(at: archive, to: destination)
                result = destination
            } catch {
                archiveError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let archiveError { throw archiveError }
        guard let result else {
            throw CocoaError(.fileWriteUnknown)
        }
        return result
    }
}

import Peripheral

import Combine
import Foundation

@MainActor
public class RemoteFileManager: ObservableObject {
    private let storage: StorageAPI

    private var supportedExtensions: [String] = [
        ".ibtn", ".nfc", ".shd", ".sub", ".rfid", ".ir",
        ".fmf", ".txt", "log", "fim"
    ]

    public enum Error: Swift.Error, Equatable {
        case directoryIsNotEmpty
        case unknown(String)
    }

    public init(storage: StorageAPI) {
        self.storage = storage
    }

    // MARK: Directory

    public func list(at path: Path) async throws -> [Element] {
        do {
            return try await storage.list(at: path)
        } catch {
            logger.error("list directory: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    // MARK: File

    public func canRead(_ file: File) -> Bool {
        supportedExtensions.contains {
            file.name.hasSuffix($0)
        }
    }

    public func readFile(at path: Path) async throws -> String {
        do {
            let bytes = try await storage.read(at: path).drain()
            return .init(decoding: bytes, as: UTF8.self)
        } catch {
            logger.error("read file: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    public func readRaw(at path: Path) async throws -> [UInt8] {
        do {
            return try await storage.read(at: path).drain()
        } catch {
            logger.error("read raw: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    public func writeFile(_ content: String, at path: Path) async throws {
        do {
            try await storage.write(at: path, string: content).drain()
        } catch {
            logger.error("write file: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    // MARK: Import

    public func importFile(url: URL, at path: Path) async throws {
        do {
            guard let name = url.pathComponents.last else {
                logger.error("import file: invalid url \(url)")
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                logger.error("import file: unable to access \(url)")
                return
            }
            defer {
                url.stopAccessingSecurityScopedResource()
            }

            let path = path.appending(name)
            let bytes = try [UInt8](Data(contentsOf: url))
            try await storage.write(at: path, bytes: bytes).drain()
        } catch {
            logger.error("import file: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    // Create

    public func create(
        path: Path,
        isDirectory: Bool
    ) async throws {
        do {
            try await storage.create(at: path, isDirectory: isDirectory)
        } catch {
            logger.error("create file: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    // Rename

    // A rename is a move within the same directory -- the RPC has no separate
    // call, and the file manager never needed one.
    public func rename(
        _ element: Element,
        at path: Path,
        to newName: String
    ) async throws {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != element.name else { return }
        do {
            try await storage.move(
                at: path.appending(element.name),
                to: path.appending(name))
        } catch {
            logger.error("rename file: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    // Move and copy

    // Across directories rather than within one. The RPC has a single move
    // call for both, so a rename and a move differ only in the destination.
    public func move(
        _ element: Element,
        from source: Path,
        to destination: Path
    ) async throws {
        let from = source.appending(element.name)
        let to = destination.appending(element.name)
        guard from != to else { return }
        do {
            try await storage.move(at: from, to: to)
        } catch {
            logger.error("move file: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    // No RPC copy exists, so a copy is a read followed by a write, and a
    // directory is walked entry by entry. Sequential on purpose: these travel
    // over the same BLE link everything else uses, and running them in parallel
    // only makes them contend.
    public func copy(
        _ element: Element,
        from source: Path,
        to destination: Path
    ) async throws {
        let from = source.appending(element.name)
        let to = destination.appending(element.name)
        guard from != to else { return }
        do {
            switch element {
            case .file:
                let bytes = try await readRaw(at: from)
                try await storage.create(at: to, isDirectory: false)
                _ = try await storage.write(at: to, bytes: bytes).drain()
            case .directory:
                try await storage.create(at: to, isDirectory: true)
                for child in try await storage.list(at: from) {
                    try await copy(child, from: from, to: to)
                }
            }
        } catch {
            logger.error("copy file: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    // Export

    // Copy a whole directory off the device into a local folder, keeping its
    // shape. The caller turns that folder into something shareable.
    public func exportDirectory(
        _ directory: Directory,
        at path: Path,
        to localURL: URL,
        progress: @escaping (String) -> Void = { _ in }
    ) async throws {
        let remote = path.appending(directory.name)
        try FileManager.default.createDirectory(
            at: localURL, withIntermediateDirectories: true)

        for element in try await list(at: remote) {
            switch element {
            case .file(let file):
                progress(file.name)
                let bytes = try await readRaw(at: remote.appending(file.name))
                try Data(bytes).write(
                    to: localURL.appendingPathComponent(file.name))
            case .directory(let child):
                try await exportDirectory(
                    child,
                    at: remote,
                    to: localURL.appendingPathComponent(child.name),
                    progress: progress)
            }
        }
    }

    // Delete

    public func delete(
        _ element: Element,
        at path: Path,
        force: Bool = false
    ) async throws {
        do {
            let path = path.appending(element.name)
            try await storage.delete(at: path, force: force)
        } catch let error as Peripheral.Error
                    where error == .storage(.notEmpty) {
            throw Error.directoryIsNotEmpty
        } catch {
            logger.error("delete file: \(error)")
            throw Error.unknown(.init(describing: error))
        }
    }

    // Analytics

    func recordFileManager() {
        analytics.appOpen(target: .fileManager)
    }
}

public class Feedback {
    let loggerStorage: LoggerStorage

    public init(loggerStorage: LoggerStorage) {
        self.loggerStorage = loggerStorage
    }

    convenience public init() {
        self.init(loggerStorage: Dependencies.shared.loggerStorage)
    }

    private var logsLimit = 3

    // The same logs the report carries, in a shape usable outside this package:
    // Attachment is nested in an internal type, so it cannot cross the boundary.
    public struct LogFile {
        public let filename: String
        public let content: String
    }

    public var logFiles: [LogFile] {
        get async {
            await attachments.map { .init(filename: $0.filename, content: $0.content) }
        }
    }

    private var attachments: [Attachment] {
        get async {
            var result: [Attachment] = []
            for file in await loggerStorage.list().suffix(logsLimit) {
                let content = await loggerStorage
                    .read(file)
                    .joined(separator: "\n")
                result.append(.init(filename: "\(file).txt", content: content))
            }
            return result
        }
    }

    public func reportBug(
        subject: String,
        message: String,
        attachLogs: Bool
    ) async throws -> String {
         let event = Event(
            subject: subject,
            message: message,
            attachments: attachLogs ? await attachments : [])

        let client = CentryClient()
        let response = try await client.capture(event)

        return response.id
    }
}

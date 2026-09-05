import Backend
import Foundation

// The SDK versions the catalog will actually serve builds for.
//
// Needed because the catalog only knows the official firmware's SDKs, and
// refuses any request naming one it does not have (error 1001). Asking it what
// it does have is the only way to pick a version it will answer to.
public struct SDKsRequest: BackendRequest {
    public typealias Result = [SDK]

    public var path: String { "0/sdk" }
    public var queryItems: [URLQueryItem] = []

    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }
}

public struct SDK: Decodable, Equatable {
    public let name: String
    public let target: String
    public let api: String
    // Null on entries the catalog has not marked either way -- decoding this
    // as a plain Bool failed the whole list, which left every device falling
    // back to its own SDK and being rejected again.
    public let isLatestRelease: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case target
        case api
        case isLatestRelease = "is_latest_release"
    }

    public var isCurrentRelease: Bool { isLatestRelease ?? false }
}

extension SDK {
    // "87.1" -> (87, 1), for ordering. Anything unparseable sorts lowest so it
    // is never picked over a version that does parse.
    public var apiVersion: (major: Int, minor: Int) {
        let parts = api.split(separator: ".")
        guard
            parts.count == 2,
            let major = Int(parts[0]),
            let minor = Int(parts[1])
        else {
            return (-1, -1)
        }
        return (major, minor)
    }
}

import Foundation
import os

/// GET `https://api.anthropic.com/api/oauth/usage`. The User-Agent is load-bearing: without
/// `claude-cli/...` requests land in an aggressively rate-limited bucket with persistent 429s
/// and no `Retry-After`.
public struct UsageClient: Sendable {
    public static let userAgent = "claude-cli/2.1.175 (external, cli)"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let log = Logger(subsystem: "com.roy.claudemonitor", category: "http")

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            Self.log.error("usage endpoint \(http.statusCode) unauthorized")
            throw UsageError.unauthorized   // no retry-storm
        case 429:
            Self.log.error("usage endpoint 429 rate-limited")
            throw UsageError.rateLimited     // feeds the backoff ladder
        default:
            Self.log.error("usage endpoint HTTP \(http.statusCode)")
            throw UsageError.http(http.statusCode)
        }

        do {
            return try UsageSnapshot.decode(data)
        } catch {
            throw UsageError.decode(String(describing: error))
        }
    }
}

public enum UsageError: Error, Equatable {
    case unauthorized
    case rateLimited
    case http(Int)
    case transport(String)
    case decode(String)
}

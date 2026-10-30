import Foundation
import os

/// GET `https://api.anthropic.com/api/oauth/usage`. The User-Agent is load-bearing: without
/// `claude-cli/...` requests land in an aggressively rate-limited bucket with persistent 429s
/// and no `Retry-After`.
public struct UsageClient: Sendable {
    public static let userAgent = "claude-cli/2.1.175 (external, cli)"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let log = Logger(subsystem: "com.roy.agentsmonitor", category: "http")

    private let session: URLSession

    /// Usage is per account and must be live: URLCache keys on the URL only, which every account
    /// shares, so polls skip it entirely.
    public static let noCacheSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    public init(session: URLSession = UsageClient.noCacheSession) {
        self.session = session
    }

    /// `sharedFile` (local accounts): go through `SharedUsageCache` so this app and any other
    /// local poller of the same account make one request per window between them.
    public func fetch(accessToken: String, sharedFile: URL? = nil) async throws -> UsageSnapshot {
        guard let sharedFile else { return try await fetchNetwork(accessToken: accessToken, sharedFile: nil) }
        for _ in 0..<20 {   // up to ~10s while another reader's request is in flight
            switch SharedUsageCache.decide(SharedUsageCache.read(sharedFile)) {
            case .use(let body): return try Self.decode(Data(body.utf8))
            case .throttled: throw UsageError.rateLimited
            case .fetch:
                guard SharedUsageCache.tryLock(sharedFile) else {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                defer { SharedUsageCache.unlock(sharedFile) }
                return try await fetchNetwork(accessToken: accessToken, sharedFile: sharedFile)
            }
        }
        throw UsageError.rateLimited
    }

    private func fetchNetwork(accessToken: String, sharedFile: URL?) async throws -> UsageSnapshot {
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
            throw UsageError.unreachable(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("no response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            Self.log.error("usage endpoint \(http.statusCode) unauthorized")
            throw UsageError.unauthorized   // no retry-storm
        case 429:
            Self.log.error("usage endpoint 429 rate-limited")
            if let sharedFile {
                var entry = SharedUsageCache.read(sharedFile) ?? .init()
                let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                entry.throttled_until = Date().timeIntervalSince1970 + (retry ?? SharedUsageCache.defaultRetryAfter)
                SharedUsageCache.write(entry, to: sharedFile)
            }
            throw UsageError.rateLimited     // feeds the backoff ladder
        default:
            Self.log.error("usage endpoint HTTP \(http.statusCode)")
            throw UsageError.http(http.statusCode)
        }

        let snapshot = try Self.decode(data)
        if let sharedFile, let body = String(data: data, encoding: .utf8) {
            SharedUsageCache.write(.init(fetched_at: Date().timeIntervalSince1970, body: body, throttled_until: 0),
                                   to: sharedFile)
        }
        return snapshot
    }

    private static func decode(_ data: Data) throws -> UsageSnapshot {
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

extension UsageError {
    /// The account row's error line, in plain words. `company` runs the endpoint ("Anthropic",
    /// "OpenAI"); status codes and decode details stay in the log, not on screen.
    public func message(company: String) -> String {
        switch self {
        case .unauthorized: return "\(company) rejected the login"
        case .rateLimited: return "\(company) is limiting usage checks"
        case .http(let code) where code >= 500: return "\(company)'s servers are having problems"
        case .http: return "\(company) didn't accept the usage check"
        case .transport(let reason): return "Can't reach \(company): \(reason)"
        case .decode: return "\(company) sent usage data this version can't read"
        }
    }

    /// A failed request as a short reason ("timed out"), not URLError's full sentence.
    static func unreachable(_ error: Error) -> UsageError {
        switch (error as? URLError)?.code {
        case .timedOut?: return .transport("timed out")
        case .notConnectedToInternet?, .dataNotAllowed?: return .transport("no internet connection")
        case .networkConnectionLost?: return .transport("connection lost")
        case .cannotFindHost?, .dnsLookupFailed?: return .transport("server not found")
        case .cannotConnectToHost?: return .transport("connection refused")
        case .secureConnectionFailed?, .serverCertificateUntrusted?, .serverCertificateHasBadDate?,
             .serverCertificateNotYetValid?, .serverCertificateHasUnknownRoot?:
            return .transport("secure connection failed")
        default:
            let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return .transport(reason.prefix(1).lowercased() + reason.dropFirst())
        }
    }
}

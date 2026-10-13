import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport for `POST /v1/messages`. Swappable so the agent loop is tested without network.
public protocol MessagesTransport: Sendable {
    func send(_ body: JSONValue) async throws -> JSONValue
}

public enum AgentAPIError: Error, Equatable, CustomStringConvertible {
    case authentication(String)
    case permission(String)
    case invalidRequest(String)
    case rateLimited(retryAfter: Double?)
    case overloaded
    case server(status: Int, message: String)
    case network(String)
    case malformedResponse

    public var description: String {
        switch self {
        case .authentication(let m): "The API key was not accepted (\(m)). Use an API key from console.anthropic.com, not a claude.ai login."
        case .permission(let m): "The API key is not allowed to do this: \(m)"
        case .invalidRequest(let m): "The API rejected the request: \(m)"
        case .rateLimited(let after): "Rate limited" + (after.map { "; retry in \(Int($0)) s" } ?? "")
        case .overloaded: "The API is overloaded; try again shortly."
        case .server(let s, let m): "API error \(s): \(m)"
        case .network(let m): "Network error: \(m)"
        case .malformedResponse: "The API returned an unexpected response."
        }
    }

    /// Worth retrying automatically (transient).
    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .network: true
        case .server(let s, _): s >= 500
        default: false
        }
    }
}

/// Raw-HTTPS client for the Claude Messages API (there is no official Swift SDK).
/// The API key is held in memory only; the app loads it from the Keychain per session.
public struct AnthropicHTTPTransport: MessagesTransport {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Server-side refusal fallback (`fallbacks: "default"`) requires this beta header.
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let apiKey: String
    private let endpoint: URL
    private let maxRetries: Int

    public init(apiKey: String, endpoint: URL = AnthropicHTTPTransport.endpoint, maxRetries: Int = 2) {
        self.apiKey = apiKey; self.endpoint = endpoint; self.maxRetries = maxRetries
    }

    public func send(_ body: JSONValue) async throws -> JSONValue {
        var attempt = 0
        while true {
            do { return try await sendOnce(body) } catch let error as AgentAPIError where error.isRetryable && attempt < maxRetries {
                attempt += 1
                var delay = pow(2, Double(attempt))   // 2 s, 4 s
                if case .rateLimited(let after?) = error { delay = max(delay, min(after, 60)) }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func sendOnce(_ body: JSONValue) async throws -> JSONValue {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600   // long agentic turns; non-streaming
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if body["fallbacks"] != nil { request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try body.encoded()
        return try await Self.execute(request)
    }

    /// Checks the key without spending tokens (lists one model). Throws the same errors as `send`.
    public func verifyKey() async throws {
        var url = URLComponents(url: endpoint.deletingLastPathComponent().appendingPathComponent("models"),
                                resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "limit", value: "1")]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        _ = try await Self.execute(request)
    }

    private static func execute(_ request: URLRequest) async throws -> JSONValue {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await perform(request) } catch {
            throw AgentAPIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AgentAPIError.malformedResponse }
        let json = try? JSONValue.decode(data)
        if let failure = error(status: http.statusCode, body: json, retryAfter: http.value(forHTTPHeaderField: "retry-after")) {
            throw failure
        }
        guard let json else { throw AgentAPIError.malformedResponse }
        return json
    }

    /// Maps an HTTP status and error body to a typed error (nil for success). The API's own
    /// message is kept so users see e.g. "invalid x-api-key" or "model: ... not found".
    static func error(status: Int, body: JSONValue?, retryAfter: String?) -> AgentAPIError? {
        guard !(200..<300).contains(status) else { return nil }
        let message = body?["error"]?["message"]?.string ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 400, 404, 413, 422: return .invalidRequest(message)
        case 401: return .authentication(message)
        case 403: return .permission(message)
        case 429: return .rateLimited(retryAfter: retryAfter.flatMap(Double.init))
        case 529: return .overloaded
        default: return .server(status: status, message: message)
        }
    }

    /// Continuation wrapper so the same code runs on Apple platforms and swift-corelibs-foundation.
    private static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, let response { continuation.resume(returning: (data, response)) }
                else { continuation.resume(throwing: URLError(.badServerResponse)) }
            }.resume()
        }
    }
}

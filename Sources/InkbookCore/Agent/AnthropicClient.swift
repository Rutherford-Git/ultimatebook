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
        case .authentication: "The API key was rejected. Check it in Agent settings."
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
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try body.encoded()

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await Self.perform(request) } catch {
            throw AgentAPIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AgentAPIError.malformedResponse }
        let json = try? JSONValue.decode(data)
        guard (200..<300).contains(http.statusCode) else {
            let message = json?["error"]?["message"]?.string ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            switch http.statusCode {
            case 400, 404, 413, 422: throw AgentAPIError.invalidRequest(message)
            case 401: throw AgentAPIError.authentication(message)
            case 403: throw AgentAPIError.permission(message)
            case 429: throw AgentAPIError.rateLimited(retryAfter: (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init))
            case 529: throw AgentAPIError.overloaded
            default: throw AgentAPIError.server(status: http.statusCode, message: message)
            }
        }
        guard let json else { throw AgentAPIError.malformedResponse }
        return json
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

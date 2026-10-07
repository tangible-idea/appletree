import Foundation

public enum TypeSafeError: Error, Equatable {
    case missingKey
    case unauthorized
    case http(Int)
    case invalidResponse
}

/// Calls TypeSafe's System One endpoint (https://docs.typesafe.ai/api).
public struct TypeSafeClient: Sendable {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    /// Info.plist key that `scripts/build-app.sh` fills from TYPESAFE_API_KEY or `.typesafe-api-key`.
    public static let infoPlistKey = "TypeSafeAPIKey"

    let apiKey: String
    let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// The key built into the app, or TYPESAFE_API_KEY from the environment during development.
    public static func bundled(_ bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> TypeSafeClient? {
        let key = (bundle.object(forInfoDictionaryKey: infoPlistKey) as? String) ?? environment["TYPESAFE_API_KEY"]
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return TypeSafeClient(apiKey: key)
    }

    /// Sends one evaluation request, retrying with backoff when the service is rate limited or overloaded.
    public func evaluate(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var delay: Duration = .milliseconds(500)
        for attempt in 1... {
            let (data, response) = try await session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { throw TypeSafeError.invalidResponse }
            switch status {
            case 200..<300: return data
            case 401, 403: throw TypeSafeError.unauthorized
            // A `where` clause binds only to the pattern before it, so each code gets its own.
            case 429 where attempt < 4, 529 where attempt < 4:
                try await Task.sleep(for: delay)
                delay *= 2
            default: throw TypeSafeError.http(status)
            }
        }
        throw TypeSafeError.invalidResponse
    }
}

import Foundation

// Vertex AI auth, ported from Meeting Scribe's GeminiService.
// Credentials are the `authorized_user` JSON produced by
// `gcloud auth application-default login`
// (~/.config/gcloud/application_default_credentials.json).
struct VertexCredentials: Equatable {
    let clientId: String
    let clientSecret: String
    let refreshToken: String

    static func parse(_ json: String) -> VertexCredentials? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let clientId = obj["client_id"] as? String, !clientId.isEmpty,
              let clientSecret = obj["client_secret"] as? String, !clientSecret.isEmpty,
              let refreshToken = obj["refresh_token"] as? String, !refreshToken.isEmpty
        else { return nil }
        return VertexCredentials(clientId: clientId, clientSecret: clientSecret, refreshToken: refreshToken)
    }
}

// Refreshes and caches the OAuth2 access token (tokens live ~1h).
actor VertexTokenProvider {
    static let shared = VertexTokenProvider()

    private var cachedToken: String?
    private var expiry: Date?
    private var cachedForRefreshToken: String?

    func accessToken(for creds: VertexCredentials) async throws -> String {
        if let token = cachedToken, let expiry, Date() < expiry,
           cachedForRefreshToken == creds.refreshToken {
            return token
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: creds.clientId),
            URLQueryItem(name: "client_secret", value: creds.clientSecret),
            URLQueryItem(name: "refresh_token", value: creds.refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        // percentEncodedQuery handles special chars (+, /, =) in tokens
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int
        else {
            throw ConversionError.vertexAuthFailed
        }

        cachedToken = token
        expiry = Date().addingTimeInterval(TimeInterval(expiresIn - 60))
        cachedForRefreshToken = creds.refreshToken
        return token
    }
}

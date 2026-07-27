import Foundation
import Security

// Vertex AI auth. Two credential shapes are accepted, both pasted into the same
// Settings > Credentials JSON field:
//
//   1. `authorized_user` - what `gcloud auth application-default login` writes to
//      ~/.config/gcloud/application_default_credentials.json. Carries a refresh
//      token; exchanged with a plain refresh_token grant.
//   2. `service_account` - a key from the GCP console or
//      `gcloud iam service-accounts keys create`. Carries an RSA private key;
//      exchanged by signing a JWT and using the jwt-bearer grant.
//
// Shape 2 (added v1.13) exists so a colleague can be set up by handing them one
// file, with no gcloud install and no terminal.
enum VertexCredentials: Equatable {
    case authorizedUser(clientId: String, clientSecret: String, refreshToken: String)
    case serviceAccount(clientEmail: String, privateKeyPEM: String, tokenURI: String, keyId: String?)

    static let scope = "https://www.googleapis.com/auth/cloud-platform"

    static func parse(_ json: String) -> VertexCredentials? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        // Dispatch on the fields actually present rather than on "type": ADC files
        // from older gcloud versions omit it, and the field pair is unambiguous.
        if let clientEmail = obj["client_email"] as? String, !clientEmail.isEmpty,
           let privateKey = obj["private_key"] as? String, !privateKey.isEmpty {
            let tokenURI = (obj["token_uri"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "https://oauth2.googleapis.com/token"
            let keyId = (obj["private_key_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .serviceAccount(clientEmail: clientEmail, privateKeyPEM: privateKey,
                                   tokenURI: tokenURI, keyId: keyId)
        }

        if let clientId = obj["client_id"] as? String, !clientId.isEmpty,
           let clientSecret = obj["client_secret"] as? String, !clientSecret.isEmpty,
           let refreshToken = obj["refresh_token"] as? String, !refreshToken.isEmpty {
            return .authorizedUser(clientId: clientId, clientSecret: clientSecret,
                                   refreshToken: refreshToken)
        }

        return nil
    }

    // Identifies the credential for token caching. Not a secret store: the
    // refresh token is reduced to a hash so the cache key is not itself a credential.
    var cacheKey: String {
        switch self {
        case let .authorizedUser(clientId, _, refreshToken):
            return "user:\(clientId):\(refreshToken.hashValue)"
        case let .serviceAccount(clientEmail, _, _, keyId):
            return "sa:\(clientEmail):\(keyId ?? "-")"
        }
    }

    // Shown in Settings after a successful test so it is obvious which identity is
    // configured (a shared service account vs the person's own login).
    var describedIdentity: String {
        switch self {
        case .authorizedUser: return "user login"
        case let .serviceAccount(clientEmail, _, _, _): return clientEmail
        }
    }
}

// Refreshes and caches the OAuth2 access token (tokens live ~1h).
actor VertexTokenProvider {
    static let shared = VertexTokenProvider()

    private var cachedToken: String?
    private var expiry: Date?
    private var cachedForKey: String?

    func accessToken(for creds: VertexCredentials) async throws -> String {
        if let token = cachedToken, let expiry, Date() < expiry,
           cachedForKey == creds.cacheKey {
            return token
        }

        let endpoint: String
        let form: [URLQueryItem]
        switch creds {
        case let .authorizedUser(clientId, clientSecret, refreshToken):
            endpoint = "https://oauth2.googleapis.com/token"
            form = [
                URLQueryItem(name: "client_id", value: clientId),
                URLQueryItem(name: "client_secret", value: clientSecret),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "grant_type", value: "refresh_token"),
            ]
        case let .serviceAccount(clientEmail, privateKeyPEM, tokenURI, keyId):
            endpoint = tokenURI
            let assertion = try Self.signedJWT(clientEmail: clientEmail,
                                               privateKeyPEM: privateKeyPEM,
                                               audience: tokenURI, keyId: keyId)
            form = [
                URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                URLQueryItem(name: "assertion", value: assertion),
            ]
        }

        guard let url = URL(string: endpoint) else { throw ConversionError.vertexAuthFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form
        // percentEncodedQuery handles special chars (+, /, =) in tokens and assertions
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
        cachedForKey = creds.cacheKey
        return token
    }

    // MARK: - Service account JWT

    // Builds the RS256-signed assertion Google expects for the jwt-bearer grant.
    static func signedJWT(clientEmail: String, privateKeyPEM: String,
                          audience: String, keyId: String?) throws -> String {
        var header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        if let keyId { header["kid"] = keyId }

        let now = Int(Date().timeIntervalSince1970)
        let claims: [String: Any] = [
            "iss": clientEmail,
            "scope": VertexCredentials.scope,
            "aud": audience,
            "iat": now,
            "exp": now + 3600,
        ]

        // sortedKeys only so one credential yields a byte-stable assertion, which
        // makes a failure reproducible; Google does not care about key order.
        guard let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
              let claimsData = try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        else { throw ConversionError.vertexAuthFailed }

        let signingInput = "\(base64URL(headerData)).\(base64URL(claimsData))"
        guard let inputData = signingInput.data(using: .utf8) else {
            throw ConversionError.vertexAuthFailed
        }
        return "\(signingInput).\(base64URL(try sign(inputData, pem: privateKeyPEM)))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sign(_ data: Data, pem: String) throws -> Data {
        let der = try derBody(fromPEM: pem)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            error?.release()
            throw ConversionError.vertexAuthFailed
        }
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error
        ) as Data? else {
            error?.release()
            throw ConversionError.vertexAuthFailed
        }
        return signature
    }

    // Security wants a bare PKCS#1 RSAPrivateKey. Google ships PKCS#8
    // ("-----BEGIN PRIVATE KEY-----"), so the PKCS#8 wrapper comes off first.
    private static func derBody(fromPEM pem: String) throws -> Data {
        let isPKCS1 = pem.contains("BEGIN RSA PRIVATE KEY")
        let base64 = pem
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let raw = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            throw ConversionError.vertexAuthFailed
        }
        if isPKCS1 { return raw }
        guard let unwrapped = pkcs1Body(fromPKCS8: [UInt8](raw)) else {
            throw ConversionError.vertexAuthFailed
        }
        return Data(unwrapped)
    }

    // Minimal DER walk: SEQUENCE { INTEGER version, SEQUENCE alg, OCTET STRING pkcs1 }
    private static func pkcs1Body(fromPKCS8 der: [UInt8]) -> [UInt8]? {
        guard let outer = tlv(der, 0), outer.tag == 0x30,
              let version = tlv(der, outer.start), version.tag == 0x02,
              let alg = tlv(der, version.next), alg.tag == 0x30,
              let octet = tlv(der, alg.next), octet.tag == 0x04
        else { return nil }
        return Array(der[octet.start ..< (octet.start + octet.len)])
    }

    private static func tlv(_ d: [UInt8], _ i: Int) -> (tag: UInt8, start: Int, len: Int, next: Int)? {
        guard i >= 0, i + 1 < d.count else { return nil }
        let tag = d[i]
        var j = i + 1
        var len = 0
        let first = d[j]
        j += 1
        if first & 0x80 == 0 {
            len = Int(first)
        } else {
            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, byteCount <= 4, j + byteCount <= d.count else { return nil }
            for _ in 0 ..< byteCount {
                len = (len << 8) | Int(d[j])
                j += 1
            }
        }
        guard j + len <= d.count else { return nil }
        return (tag, j, len, j + len)
    }
}

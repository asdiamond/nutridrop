import CryptoKit
import Foundation
import Security

struct ConnectClient {
    static let clientID = "client_01M1QJ50TXNKGVX06Q0CD98VPZ"
    static let issuer = "https://resilient-quest-95-staging.authkit.app"
    static let resource = "https://nutridrop-mcp-staging.diamondaleksandr.workers.dev/mcp"
    static let redirectURI = "app.nutridrop://auth/callback"

    func authorization() throws -> (url: URL, state: String, codeVerifier: String) {
        func randomString() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ConnectError.randomGeneration
            }
            return Data(bytes).base64URL
        }
        let verifier = try randomString()
        let state = try randomString()
        var url = URLComponents(string: "\(Self.issuer)/oauth2/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid offline_access"),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return (url.url!, state, verifier)
    }

    func tokens(code: String, verifier: String) async throws -> ConnectTokens {
        try await exchange([
            "grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "redirect_uri": Self.redirectURI,
        ])
    }

    func refresh(token: String) async throws -> ConnectTokens {
        try await exchange(["grant_type": "refresh_token", "refresh_token": token])
    }

    private func exchange(_ parameters: [String: String]) async throws -> ConnectTokens {
        var parameters = parameters
        parameters["client_id"] = Self.clientID
        parameters["resource"] = Self.resource
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = parameters.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "\(Self.issuer)/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ConnectError.invalidResponse("Token exchange returned no HTTP response")
        }
        guard response.statusCode == 200 else {
            let error = try? JSONDecoder().decode(OAuthError.self, from: data)
            throw ConnectError.oauth(error?.error ?? "HTTP \(response.statusCode)")
        }
        let tokens = try JSONDecoder().decode(ConnectTokens.self, from: data)
        guard tokens.tokenType.lowercased() == "bearer", !tokens.accessToken.isEmpty else {
            throw ConnectError.invalidResponse("Token exchange returned an empty access token or unsupported token type")
        }
        return tokens
    }

}

struct ConnectUser: Codable {
    let userId: String
}

struct ConnectTokens: Decodable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", tokenType = "token_type"
    }
}

private struct OAuthError: Decodable {
    let error: String
}

enum ConnectError: LocalizedError {
    case randomGeneration
    case invalidResponse(String)
    case oauth(String)

    var errorDescription: String? {
        switch self {
        case .randomGeneration: "Could not generate secure PKCE credentials."
        case .invalidResponse(let detail): "\(detail)."
        case .oauth(let code): "Connect token exchange failed: \(code)."
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

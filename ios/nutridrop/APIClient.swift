import Foundation

struct APIClient {
    private let baseURL = URL(string: "https://nutridrop-mcp-staging.diamondaleksandr.workers.dev")!

    func session(accessToken: String) async throws -> ConnectUser {
        var request = URLRequest(url: baseURL.appending(path: "v1/session"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch response.statusCode {
        case 200:
            return try JSONDecoder().decode(ConnectUser.self, from: data)
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.server(response.statusCode)
        }
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The backend returned an invalid response."
        case .unauthorized: "The backend did not accept this session."
        case .server(let status): "The backend returned status \(status)."
        }
    }
}

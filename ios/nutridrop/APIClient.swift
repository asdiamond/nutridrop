import Foundation

struct APIClient {
    private let baseURL = URL(string: "https://nutridrop-mcp-staging.diamondaleksandr.workers.dev")!

    func acknowledgeNutrition(recordID: String, accessToken: String, timeout: TimeInterval) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/nutrition/acknowledge"),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["recordIds": [recordID]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if response.statusCode == 401 { throw APIError.unauthorized }
        guard response.statusCode == 200 else { throw APIError.server(response.statusCode) }
        struct Result: Decodable { let acknowledgedIds: [String] }
        guard try JSONDecoder().decode(Result.self, from: data).acknowledgedIds.contains(recordID) else {
            throw APIError.invalidResponse
        }
    }

    func pendingNutrition(accessToken: String, cursor: String?, timeout: TimeInterval) async throws -> NutritionPage {
        var url = URLComponents(url: baseURL.appending(path: "v1/nutrition/pending"), resolvingAgainstBaseURL: false)!
        if let cursor { url.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if response.statusCode == 401 { throw APIError.unauthorized }
        guard response.statusCode == 200 else { throw APIError.server(response.statusCode) }
        let page = try JSONDecoder().decode(NutritionPage.self, from: data)
        guard page.records.count <= 50, page.records.allSatisfy({ $0.schemaVersion == 1 }) else {
            throw APIError.invalidResponse
        }
        return page
    }

    func updatePushToken(_ token: String, environment: String, accessToken: String, remove: Bool = false) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/push-token"))
        request.httpMethod = remove ? "DELETE" : "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": token, "environment": environment])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if response.statusCode == 401 { throw APIError.unauthorized }
        guard response.statusCode == 204 else { throw APIError.server(response.statusCode) }
    }

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

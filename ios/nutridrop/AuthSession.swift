import AuthenticationServices
import Observation
import Security
import UIKit

@MainActor
@Observable
final class AuthSession: NSObject {
    private static let callbackScheme = "app.nutridrop"

    private let client = ConnectClient()
    private let apiClient = APIClient()
    private var webAuthenticationSession: ASWebAuthenticationSession?
    private var refreshTask: Task<StoredSession, Error>?
    private var pushToken: String?
    private var pushUploadTask: Task<Void, Never>?
    var pushRegistrationStatus = "Waiting for APNs registration..."
    private(set) var lastPushRecordID: String?
    private(set) var lastPushReceivedAt: Date?
    private let nutritionStore = NutritionStore()
    private var nutritionSyncTask: Task<Bool, Error>?
    private var nutritionSyncRequested = false
    private(set) var nutritionRecords: [NutritionRecord] = []
    private(set) var nutritionSyncStatus = "Waiting for a push to download nutrition."
    private(set) var lastNutritionSyncAt: Date?

    private func loadNutrition() {
        guard let userID = user?.userId else { return }
        Task {
            do {
                let saved = try await nutritionStore.load(userID: userID)
                guard user?.userId == userID else { return }
                nutritionRecords = saved.records
                if let timestamp = UserDefaults.standard.dictionary(forKey: "nutritionSyncTimes")?[userID] as? Double {
                    lastNutritionSyncAt = Date(timeIntervalSince1970: timestamp)
                }
            } catch {
                guard user?.userId == userID else { return }
                nutritionSyncStatus = "Could not read saved nutrition: \(error.localizedDescription)"
            }
        }
    }

    func syncPendingNutrition() async -> UIBackgroundFetchResult {
        guard let userID = user?.userId else { return .noData }
        if let task = nutritionSyncTask {
            nutritionSyncRequested = true
            do { return try await task.value ? .newData : .noData }
            catch { return .failed }
        }
        nutritionSyncStatus = "Downloading pending nutrition..."
        let task = Task { () throws -> Bool in
            let deadline = Date().addingTimeInterval(20)
            var cursor = try await nutritionStore.load(userID: userID).nextCursor
            var changed = false
            repeat {
                if cursor == nil { nutritionSyncRequested = false }
                try Task.checkCancellation()
                guard user?.userId == userID else { throw CancellationError() }
                let token = try await accessToken()
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw URLError(.timedOut) }
                let page = try await apiClient.pendingNutrition(accessToken: token, cursor: cursor, timeout: min(10, remaining))
                try Task.checkCancellation()
                guard user?.userId == userID else { throw CancellationError() }
                let saved = try await nutritionStore.merge(page, userID: userID)
                try Task.checkCancellation()
                guard user?.userId == userID else { throw CancellationError() }
                nutritionRecords = saved.records
                changed = changed || saved.changed
                if let next = page.nextCursor, next == cursor { throw APIError.invalidResponse }
                cursor = page.nextCursor
            } while cursor != nil || nutritionSyncRequested
            return changed
        }
        nutritionSyncTask = task
        defer { nutritionSyncTask = nil }
        do {
            let changed = try await task.value
            guard user?.userId == userID else { return .failed }
            let completedAt = Date()
            lastNutritionSyncAt = completedAt
            var times = UserDefaults.standard.dictionary(forKey: "nutritionSyncTimes") ?? [:]
            times[userID] = completedAt.timeIntervalSince1970
            UserDefaults.standard.set(times, forKey: "nutritionSyncTimes")
            nutritionSyncStatus = "Nutrition saved locally. Not yet written to Apple Health."
            return changed ? .newData : .noData
        } catch {
            guard user?.userId == userID else { return .failed }
            nutritionSyncStatus = "Download incomplete: \(error.localizedDescription) Saved batches are kept; the next push will retry."
            return .failed
        }
    }

    func receivedPush(recordID: String) {
        guard let userID = user?.userId else { return }
        lastPushRecordID = recordID
        lastPushReceivedAt = Date()
        UserDefaults.standard.set([
            "userId": userID, "recordId": recordID, "receivedAt": Date().timeIntervalSince1970,
        ], forKey: "lastPushReceipt")
    }

    private var pushEnvironment: String {
        Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String ?? ""
    }

    func receivedPushToken(_ token: String) {
        pushToken = token
        uploadPushToken()
    }

    func uploadPushToken() {
        guard let token = pushToken, let userID = user?.userId else { return }
        pushUploadTask?.cancel()
        pushRegistrationStatus = "Registering push destination..."
        pushUploadTask = Task {
            do {
                let accessToken = try await accessToken()
                try Task.checkCancellation()
                guard user?.userId == userID else { return }
                try await apiClient.updatePushToken(token, environment: pushEnvironment, accessToken: accessToken)
                try Task.checkCancellation()
                guard user?.userId == userID else { return }
                pushRegistrationStatus = "Push destination registered"
            } catch {
                guard !Task.isCancelled, user?.userId == userID else { return }
                pushRegistrationStatus = "Push registration failed: \(error.localizedDescription)"
            }
        }
    }

    private(set) var user: ConnectUser?
    private(set) var isLoading = false
    private(set) var backendConnectionState = BackendConnectionState.idle
    private(set) var backendErrorMessage: String?
    var errorMessage: String?

    var isAuthenticated: Bool { user != nil }

    override init() {
        super.init()
        restoreSession()
        loadNutrition()
        if let receipt = UserDefaults.standard.dictionary(forKey: "lastPushReceipt"),
           let userID = user?.userId, receipt["userId"] as? String == userID {
            lastPushRecordID = receipt["recordId"] as? String
            if let timestamp = receipt["receivedAt"] as? Double {
                lastPushReceivedAt = Date(timeIntervalSince1970: timestamp)
            }
        }
    }

    func signIn() {
        guard !isLoading else { return }

        do {
            let authorization = try client.authorization()

            isLoading = true
            errorMessage = nil

            let session = ASWebAuthenticationSession(
                url: authorization.url,
                callbackURLScheme: Self.callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    await self?.completeSignIn(
                        callbackURL: callbackURL,
                        error: error,
                        expectedState: authorization.state,
                        codeVerifier: authorization.codeVerifier
                    )
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webAuthenticationSession = session

            guard session.start() else {
                throw AuthError.couldNotStart
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        nutritionSyncTask?.cancel()
        nutritionRecords = []
        lastNutritionSyncAt = nil
        nutritionSyncStatus = "Waiting for a push to download nutrition."
        lastPushRecordID = nil
        lastPushReceivedAt = nil
        UserDefaults.standard.removeObject(forKey: "lastPushReceipt")
        pushUploadTask?.cancel()
        // Conditional removal cannot delete another phone's newer registration.
        if let token = pushToken, let session = try? Keychain.load() {
            let environment = pushEnvironment
            Task {
                try? await apiClient.updatePushToken(token, environment: environment, accessToken: session.accessToken, remove: true)
            }
        }
        refreshTask?.cancel()
        refreshTask = nil
        webAuthenticationSession?.cancel()
        webAuthenticationSession = nil
        user = nil
        backendConnectionState = .idle
        backendErrorMessage = nil
        errorMessage = nil
        try? Keychain.delete()
    }

    func verifyBackendSession() async {
        guard isAuthenticated, backendConnectionState != .checking else { return }

        backendConnectionState = .checking
        backendErrorMessage = nil

        do {
            let verifiedUser = try await apiClient.session(accessToken: try await accessToken())
            guard isAuthenticated else { return }
            user = verifiedUser
            backendConnectionState = .connected
            UIApplication.shared.registerForRemoteNotifications()
            uploadPushToken()
        } catch AuthError.sessionExpired {
            signOut()
            errorMessage = "Your session expired. Please sign in again."
        } catch {
            backendConnectionState = .failed
            backendErrorMessage = error.localizedDescription
        }
    }

    private func completeSignIn(
        callbackURL: URL?,
        error: Error?,
        expectedState: String,
        codeVerifier: String
    ) async {
        defer {
            isLoading = false
            webAuthenticationSession = nil
        }

        if let error {
            let authenticationError = error as NSError
            if authenticationError.domain == ASWebAuthenticationSessionError.errorDomain,
               authenticationError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                return
            }
            errorMessage = error.localizedDescription
            return
        }

        do {
            guard let callbackURL,
                  callbackURL.scheme == Self.callbackScheme,
                  callbackURL.host == "auth",
                  callbackURL.path == "/callback" else {
                throw AuthError.invalidCallback
            }

            let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems
            guard queryItems?.first(where: { $0.name == "state" })?.value == expectedState else {
                throw AuthError.invalidState
            }
            if let message = queryItems?.first(where: { $0.name == "error_description" })?.value
                ?? queryItems?.first(where: { $0.name == "error" })?.value {
                throw AuthError.provider(message)
            }

            guard let code = queryItems?.first(where: { $0.name == "code" })?.value else {
                throw AuthError.missingCode
            }

            let authentication = try await client.tokens(code: code, verifier: codeVerifier)
            guard let refreshToken = authentication.refreshToken else {
                throw AuthError.refreshFailed
            }
            let authenticatedUser = try await apiClient.session(accessToken: authentication.accessToken)
            let storedSession = StoredSession(
                accessToken: authentication.accessToken,
                refreshToken: refreshToken,
                user: authenticatedUser
            )
            try Keychain.save(storedSession)
            user = authenticatedUser
            loadNutrition()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreSession() {
        do {
            user = try Keychain.load()?.user
        } catch {
            try? Keychain.delete()
            errorMessage = "Your saved session could not be restored. Please sign in again."
        }
    }

    private func accessToken() async throws -> String {
        guard let session = try Keychain.load() else {
            throw AuthError.sessionExpired
        }

        if Self.isAccessTokenUsable(session.accessToken) {
            return session.accessToken
        }

        if let refreshTask {
            return try await refreshTask.value.accessToken
        }

        let task = Task {
            let refreshed = try await Self.refresh(session: session)
            try Task.checkCancellation()
            try Keychain.save(refreshed)
            return refreshed
        }
        refreshTask = task
        defer { refreshTask = nil }

        let refreshed = try await task.value
        try Task.checkCancellation()
        guard user != nil else { throw AuthError.sessionExpired }
        user = refreshed.user
        return refreshed.accessToken
    }

    private static func isAccessTokenUsable(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }

        var encodedPayload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encodedPayload += String(repeating: "=", count: (4 - encodedPayload.count % 4) % 4)

        guard let data = Data(base64Encoded: encodedPayload),
              let claims = try? JSONDecoder().decode(AccessTokenClaims.self, from: data) else {
            return false
        }

        // Signature verification remains the backend's responsibility. This is
        // only used to refresh shortly before the current token expires.
        return claims.exp > Date().timeIntervalSince1970 + 60
    }

    private static func refresh(session: StoredSession) async throws -> StoredSession {
        let refreshed: ConnectTokens
        do {
            refreshed = try await ConnectClient().refresh(token: session.refreshToken)
        } catch ConnectError.oauth("invalid_grant") {
            throw AuthError.sessionExpired
        }
        return StoredSession(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? session.refreshToken,
            user: session.user
        )
    }
}

extension AuthSession: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }

        guard let windowScene = scenes.first else {
            preconditionFailure("Sign-in requires an active window scene.")
        }
        return windowScene.windows.first ?? ASPresentationAnchor(windowScene: windowScene)
    }
}

private struct StoredSession: Codable {
    let accessToken: String
    let refreshToken: String
    let user: ConnectUser
}

enum BackendConnectionState {
    case idle
    case checking
    case connected
    case failed
}

private struct AccessTokenClaims: Decodable {
    let exp: TimeInterval
}

private enum Keychain {
    private static let service = "app.nutridrop.auth"
    private static let account = "workos-connect-session"

    static func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let query = baseQuery
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AuthError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw AuthError.keychain(updateStatus)
        }
    }

    static func load() throws -> StoredSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AuthError.keychain(status)
        }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    static func delete() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychain(status)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private enum AuthError: LocalizedError {
    case couldNotStart
    case invalidCallback
    case invalidState
    case missingCode
    case provider(String)
    case keychain(OSStatus)
    case refreshFailed
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Could not open the sign-in page."
        case .invalidCallback:
            "WorkOS returned an invalid callback."
        case .invalidState:
            "The sign-in response could not be verified. Please try again."
        case .missingCode:
            "WorkOS did not return an authorization code."
        case .provider(let message):
            message
        case .keychain(let status):
            "Keychain operation failed (\(status))."
        case .refreshFailed:
            "Your session could not be refreshed. Please try again."
        case .sessionExpired:
            "Your session expired. Please sign in again."
        }
    }
}

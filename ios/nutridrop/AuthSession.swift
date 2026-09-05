import AuthenticationServices
import Observation
import Security
import UIKit
import HealthKit

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
    private let healthKit = HealthKitClient()
    private(set) var healthStates: [String: HealthRecordState] = [:]
    private(set) var healthAuthorizationInProgress = false
    private(set) var healthSyncEnabled = false
    private(set) var healthStatus = "Enable Apple Health to write your pending nutrition entries."

    func enableHealthKit() async {
        guard let userID = user?.userId, !healthAuthorizationInProgress,
              UIApplication.shared.applicationState == .active else { return }
        healthAuthorizationInProgress = true
        defer { healthAuthorizationInProgress = false }
        do {
            try await healthKit.requestAuthorization()
            guard user?.userId == userID else { return }
            // Authorization completion only means the sheet finished. Each
            // record's write permissions are checked separately before saving.
            healthSyncEnabled = true
            UserDefaults.standard.set(true, forKey: "healthSyncEnabled.\(userID)")
            healthStatus = "Apple Health enabled. Checking permissions for pending entries..."
            _ = await syncPendingNutrition()
        } catch {
            guard user?.userId == userID else { return }
            healthStatus = error.localizedDescription
        }
    }

    private func processHealthRecords(userID: String, deadline: Date) async throws -> Bool {
        guard healthSyncEnabled else { return false }
        let snapshot = try await nutritionStore.load(userID: userID)
        var changed = false
        for record in snapshot.records.reversed() {
            try Task.checkCancellation()
            guard user?.userId == userID else { throw CancellationError() }
            var state = snapshot.healthStates?[record.id] ?? HealthRecordState(stage: .downloaded)
            if state.stage == .synced { continue }
            guard deadline.timeIntervalSinceNow > 1 else { throw URLError(.timedOut) }
            if state.stage != .written {
                do {
                    try await healthKit.save(record, userID: userID)
                    state = HealthRecordState(stage: .written, writtenAt: Date())
                    changed = true
                } catch HealthWriteError.permissionRequired {
                    state = HealthRecordState(stage: .awaitingPermission, message: HealthWriteError.permissionRequired.localizedDescription)
                } catch {
                    state = HealthRecordState(stage: .writeFailed, message: error.localizedDescription)
                }
                // Persist success before attempting acknowledgement. If this
                // save fails, stable HK sync identifiers make replay safe.
                try await nutritionStore.setHealthState(state, recordID: record.id, userID: userID)
                try Task.checkCancellation()
                guard user?.userId == userID else { throw CancellationError() }
                healthStates[record.id] = state
            }
            guard state.stage == .written else { continue }
            do {
                let token = try await accessToken()
                try Task.checkCancellation()
                guard user?.userId == userID else { throw CancellationError() }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw URLError(.timedOut) }
                try await apiClient.acknowledgeNutrition(recordID: record.id, accessToken: token, timeout: min(8, remaining))
                state = HealthRecordState(stage: .synced, writtenAt: state.writtenAt, acknowledgedAt: Date())
            } catch {
                // Keep writtenAt and the written stage: next attempt only retries
                // the acknowledgement, even if permission has since been revoked.
                state.message = "Server confirmation pending: \(error.localizedDescription)"
            }
            try await nutritionStore.setHealthState(state, recordID: record.id, userID: userID)
            try Task.checkCancellation()
            guard user?.userId == userID else { throw CancellationError() }
            healthStates[record.id] = state
        }
        return changed
    }

    private func loadNutrition() {
        guard let userID = user?.userId else { return }
        healthSyncEnabled = UserDefaults.standard.bool(forKey: "healthSyncEnabled.\(userID)")
        Task {
            do {
                let saved = try await nutritionStore.load(userID: userID)
                guard user?.userId == userID else { return }
                nutritionRecords = saved.records
                healthStates = saved.healthStates ?? [:]
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
            var changed = try await processHealthRecords(userID: userID, deadline: deadline)
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
            healthStatus = healthSyncEnabled ? "Writing pending entries to Apple Health..." : "Enable Apple Health to write your pending nutrition entries."
            let healthChanged = try await processHealthRecords(userID: userID, deadline: deadline)
            changed = changed || healthChanged
            if healthSyncEnabled {
                let remaining = nutritionRecords.filter { healthStates[$0.id]?.stage != .synced }.count
                healthStatus = remaining == 0 ? "All downloaded entries are synced to Apple Health." : "\(remaining) entries still need permission, a write retry, or server confirmation."
            }
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
            nutritionSyncStatus = "Pending nutrition checked and saved locally."
            return changed ? .newData : .noData
        } catch {
            guard user?.userId == userID else { return .failed }
            nutritionSyncStatus = "Sync incomplete: \(error.localizedDescription) Progress is saved; retry or wait for the next push."
            healthStatus = "Unfinished entries remain pending."
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
        healthStates = [:]
        healthSyncEnabled = false
        healthStatus = "Enable Apple Health to write your pending nutrition entries."
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

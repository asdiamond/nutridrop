import AuthenticationServices
import Observation
import Security
import UIKit
import WorkOS

@MainActor
@Observable
final class AuthSession: NSObject {
    private static let clientID = "client_01M1M5XYKEKDP98RTMBQKMXC1H"
    private static let callbackScheme = "app.nutridrop"
    private static let redirectURI = "app.nutridrop://auth/callback"

    private let client = PublicClient(clientID: clientID)
    private var webAuthenticationSession: ASWebAuthenticationSession?

    private(set) var user: User?
    private(set) var isLoading = false
    var errorMessage: String?

    var isAuthenticated: Bool { user != nil }

    override init() {
        super.init()
        restoreSession()
    }

    func signIn() {
        guard !isLoading else { return }

        do {
            let authorization = try client.getAuthorizationUrlWithPKCE(
                redirectUri: Self.redirectURI,
                provider: "authkit"
            )

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
        webAuthenticationSession?.cancel()
        webAuthenticationSession = nil
        user = nil
        errorMessage = nil
        try? Keychain.delete()
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
            if let message = queryItems?.first(where: { $0.name == "error_description" })?.value
                ?? queryItems?.first(where: { $0.name == "error" })?.value {
                throw AuthError.provider(message)
            }

            guard queryItems?.first(where: { $0.name == "state" })?.value == expectedState else {
                throw AuthError.invalidState
            }
            guard let code = queryItems?.first(where: { $0.name == "code" })?.value else {
                throw AuthError.missingCode
            }

            let authentication = try await client.authenticateWithCode(
                code: code,
                codeVerifier: codeVerifier
            )
            let storedSession = StoredSession(
                accessToken: authentication.accessToken,
                refreshToken: authentication.refreshToken,
                user: authentication.user
            )
            try Keychain.save(storedSession)
            user = authentication.user
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
}

extension AuthSession: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }

        guard let windowScene = scenes.first else {
            preconditionFailure("AuthKit requires an active window scene.")
        }
        return windowScene.windows.first ?? ASPresentationAnchor(windowScene: windowScene)
    }
}

private struct StoredSession: Codable {
    let accessToken: String
    let refreshToken: String
    let user: User
}

private enum Keychain {
    private static let service = "app.nutridrop.auth"
    private static let account = "workos-session"

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
        let status = SecItemDelete(baseQuery as CFDictionary)
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
        }
    }
}

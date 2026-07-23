import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import BannyMedia
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct YouTubeOAuthConfiguration: Equatable, Sendable {
    static let scopes = [
        "https://www.googleapis.com/auth/youtube.upload",
        "https://www.googleapis.com/auth/youtube.force-ssl",
    ]

    let clientID: String
    let redirectURI: String

    init(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment)
        throws {
        func configured(_ environmentKey: String, _ infoKey: String) -> String? {
            let value = environment[environmentKey]
                ?? bundle.object(forInfoDictionaryKey: infoKey) as? String
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
            return trimmed
        }

        guard let clientID = configured(
            "BANNY_YOUTUBE_OAUTH_CLIENT_ID", "BannyYouTubeOAuthClientID")
        else { throw YouTubeAuthorizationError.notConfigured }
        guard let redirectURI = configured(
            "BANNY_YOUTUBE_OAUTH_REDIRECT_URI", "BannyYouTubeOAuthRedirectURI"),
              let url = URL(string: redirectURI),
              let callbackScheme = url.scheme,
              Self.registeredURLSchemes(in: bundle).contains(callbackScheme.lowercased())
        else { throw YouTubeAuthorizationError.invalidConfiguration }
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    var callbackScheme: String {
        URL(string: redirectURI)?.scheme ?? ""
    }

    private static func registeredURLSchemes(in bundle: Bundle) -> Set<String> {
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes")
            as? [[String: Any]] ?? []
        return Set(types.flatMap {
            $0["CFBundleURLSchemes"] as? [String] ?? []
        }.map { $0.lowercased() })
    }
}

enum YouTubeAuthorizationError: LocalizedError {
    case notConfigured
    case invalidConfiguration
    case couldNotStart
    case callbackMissingCode
    case stateMismatch
    case reconnectRequired
    case oauth(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "YouTube publishing needs its Google OAuth client ID in the release configuration."
        case .invalidConfiguration:
            "The YouTube OAuth redirect URI is invalid or its callback scheme is not registered."
        case .couldNotStart:
            "The secure Google sign-in window could not be opened."
        case .callbackMissingCode:
            "Google sign-in returned without an authorization code."
        case .stateMismatch:
            "Google sign-in could not be verified. Please try again."
        case .reconnectRequired:
            "The Google authorization expired. Connect YouTube again."
        case .oauth(let message):
            message
        case .keychain(let status):
            "The YouTube account could not be stored in Keychain (\(status))."
        }
    }
}

private struct YouTubeOAuthToken: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiration: Date
    var scope: String?

    var isFresh: Bool {
        expiration.timeIntervalSinceNow > 300
    }
}

private enum YouTubeTokenStore {
    static let service = "com.banny.BannyStudio.youtube.oauth"

    static func load(account: String) throws -> YouTubeOAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw YouTubeAuthorizationError.keychain(status)
        }
        return try JSONDecoder().decode(YouTubeOAuthToken.self, from: data)
    }

    static func save(_ token: YouTubeOAuthToken, account: String) throws {
        let data = try JSONEncoder().encode(token)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var inserted = query
            attributes.forEach { inserted[$0.key] = $0.value }
            let addStatus = SecItemAdd(inserted as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw YouTubeAuthorizationError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw YouTubeAuthorizationError.keychain(updateStatus)
        }
    }

    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw YouTubeAuthorizationError.keychain(status)
        }
    }
}

@MainActor
@Observable
final class YouTubeAccount {
    private(set) var channel: YouTubeChannel?
    private(set) var isAuthorizing = false
    private(set) var configurationError: String?

    private let configuration: YouTubeOAuthConfiguration?
    private var token: YouTubeOAuthToken?
    private var authenticationSession: ASWebAuthenticationSession?
    private let presentation = YouTubeWebAuthenticationPresentation()

    init() {
        let resolution: (YouTubeOAuthConfiguration?, YouTubeOAuthToken?, String?)
        do {
            let configuration = try YouTubeOAuthConfiguration()
            let token = try YouTubeTokenStore.load(account: configuration.clientID)
            resolution = (configuration, token, nil)
        } catch {
            resolution = (nil, nil, error.localizedDescription)
        }
        self.configuration = resolution.0
        self.token = resolution.1
        self.configurationError = resolution.2
    }

    var isConfigured: Bool { configuration != nil }
    var isConnected: Bool { token?.refreshToken != nil || token?.isFresh == true }

    func connect() async throws {
        guard let configuration else { throw YouTubeAuthorizationError.notConfigured }
        isAuthorizing = true
        defer { isAuthorizing = false }

        let verifier = try Self.randomURLSafeString(byteCount: 48)
        let state = try Self.randomURLSafeString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: YouTubeOAuthConfiguration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authorizationURL = components.url else {
            throw YouTubeAuthorizationError.invalidConfiguration
        }
        let callback = try await authorize(
            url: authorizationURL, callbackScheme: configuration.callbackScheme)
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let oauthError = query.first(where: { $0.name == "error" })?.value {
            throw YouTubeAuthorizationError.oauth(
                oauthError == "access_denied"
                    ? "Google sign-in was cancelled."
                    : "Google sign-in failed: \(oauthError)")
        }
        guard query.first(where: { $0.name == "state" })?.value == state else {
            throw YouTubeAuthorizationError.stateMismatch
        }
        guard let code = query.first(where: { $0.name == "code" })?.value else {
            throw YouTubeAuthorizationError.callbackMissingCode
        }
        let connectedToken = try await exchange(
            parameters: [
                "client_id": configuration.clientID,
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": configuration.redirectURI,
                "grant_type": "authorization_code",
            ],
            preservingRefreshToken: nil)
        token = connectedToken
        try YouTubeTokenStore.save(connectedToken, account: configuration.clientID)
        try await refreshChannel()
    }

    func disconnect() throws {
        guard let configuration else { return }
        try YouTubeTokenStore.delete(account: configuration.clientID)
        token = nil
        channel = nil
    }

    func validAccessToken() async throws -> String {
        guard let configuration, var token else {
            throw YouTubeAuthorizationError.reconnectRequired
        }
        if token.isFresh { return token.accessToken }
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw YouTubeAuthorizationError.reconnectRequired
        }
        token = try await exchange(
            parameters: [
                "client_id": configuration.clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ],
            preservingRefreshToken: refreshToken)
        self.token = token
        try YouTubeTokenStore.save(token, account: configuration.clientID)
        return token.accessToken
    }

    func refreshChannel() async throws {
        let accessToken = try await validAccessToken()
        channel = try await YouTubeUploadClient().channel(accessToken: accessToken)
    }

    private func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
                    Task { @MainActor in
                        self?.authenticationSession = nil
                        if let callback {
                            continuation.resume(returning: callback)
                        } else if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(throwing: YouTubeAuthorizationError.couldNotStart)
                        }
                    }
                }
            session.presentationContextProvider = presentation
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                authenticationSession = nil
                continuation.resume(throwing: YouTubeAuthorizationError.couldNotStart)
                return
            }
        }
    }

    private func exchange(parameters: [String: String],
                          preservingRefreshToken: String?) async throws -> YouTubeOAuthToken {
        guard configuration != nil else { throw YouTubeAuthorizationError.notConfigured }
        var components = URLComponents()
        components.queryItems = parameters.sorted(by: { $0.key < $1.key })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeAuthorizationError.oauth("Google returned an unreadable response.")
        }
        struct TokenResponse: Decodable {
            var access_token: String?
            var expires_in: Double?
            var refresh_token: String?
            var scope: String?
            var error_description: String?
            var error: String?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard (200..<300).contains(http.statusCode),
              let accessToken = decoded.access_token
        else {
            throw YouTubeAuthorizationError.oauth(
                decoded.error_description ?? decoded.error ?? "Google authorization failed.")
        }
        return YouTubeOAuthToken(
            accessToken: accessToken,
            refreshToken: decoded.refresh_token ?? preservingRefreshToken,
            expiration: Date().addingTimeInterval(decoded.expires_in ?? 3_600),
            scope: decoded.scope)
    }

    private static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw YouTubeAuthorizationError.keychain(status)
        }
        return Data(bytes).base64URLEncoded
    }
}

private final class YouTubeWebAuthenticationPresentation: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
            ?? UIWindow(frame: .zero)
        #endif
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

import Foundation
import Security

struct SavedAccounts: Codable {
    var active: String?
    var profiles: [Profile] = []
}

struct AccountStore {
    let service: String

    static let local = AccountStore(service: "dev.fuba.ianautomat.chatgpt")

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "registrations"
        ]
    }

    func load() throws -> SavedAccounts {
        var options = query
        options[kSecReturnData as String] = true
        options[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(options as CFDictionary, &result)
        if status == errSecItemNotFound { return SavedAccounts() }
        guard status == errSecSuccess, let data = result as? Data else { throw AppError.storage }
        return try JSONDecoder().decode(SavedAccounts.self, from: data)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }

    func save(_ accounts: SavedAccounts) throws {
        let data = try JSONEncoder().encode(accounts)
        let values = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw AppError.storage }
        var record = query
        record[kSecValueData as String] = data
        record[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(record as CFDictionary, nil) == errSecSuccess else { throw AppError.storage }
    }
}

@MainActor @Observable
final class Account {
    private(set) var saved = SavedAccounts()
    private(set) var models: [ModelOption] = []
    private(set) var busy = false
    private(set) var error: String?
    private(set) var isSigningIn = false
    private var loopback: Loopback?
    private var refresh: Task<Tokens, Error>?
    private var loaded = false
    private var epoch = UUID()
    var selectedModel = "" {
        didSet {
            if let id = saved.active { UserDefaults.standard.set(selectedModel, forKey: "model." + id) }
        }
    }

    var active: Profile? { saved.profiles.first { $0.id == saved.active } }
    var connected: Bool { active?.tokens != nil }

    func load() {
        guard !loaded else { return }
        do {
            saved = try AccountStore.local.load()
            loaded = true
            error = nil
        } catch {
            self.error = AppError.storage.localizedDescription
        }
    }

    func signIn(profile: Profile? = nil) async {
        load()
        guard loaded, !busy else { return }
        busy = true
        error = nil
        isSigningIn = true
        defer { busy = false; isSigningIn = false; loopback = nil }
        do {
            let listener = try Loopback()
            loopback = listener
            let port = try await listener.listen()
            let defaults = UserDefaults.standard
            let host = defaults.string(forKey: "agentHost") ?? "urn:uuid:" + UUID().uuidString.lowercased()
            defaults.set(host, forKey: "agentHost")
            let attempt = try OAuthAttempt(port: port, host: host, previous: profile)
            let grant = try await listener.awaitGrant(attempt, openBrowser: listener.openBrowser)
            isSigningIn = false
            let response = try await Self.tokenResponse([
                "grant_type": "authorization_code", "client_id": grant.client, "code": grant.code,
                "code_verifier": attempt.verifier, "redirect_uri": attempt.redirect, "resource": OpenAI.resource
            ])
            let tokens = try Tokens(response)
            guard let jwt = tokens.idToken else { throw AppError.security }
            let jwks = try await OpenAI.data(OpenAI.request(OpenAI.issuer + "/.well-known/jwks.json"))
            let identity = try TokenVerifier.verify(jwt, jwks: jwks, client: grant.client, nonce: attempt.nonce)
            if let previous = saved.profiles.first(where: { $0.id == grant.client }) {
                guard previous.subject == identity.sub else { throw AppError.security }
            }
            var next = saved
            next.profiles.removeAll { $0.id == grant.client }
            next.profiles.append(Profile(id: grant.client, subject: identity.sub, email: identity.email, tokens: tokens))
            next.active = grant.client
            try AccountStore.local.save(next)
            saved = next
            epoch = UUID()
            models = []
            try await updateModels()
        } catch is CancellationError {
            return
        } catch {
            self.error = displayError(error)
        }
    }

    func cancelSignIn() {
        if isSigningIn { loopback?.stop() }
    }

    func activate(_ profile: Profile) async {
        guard !busy else { return }
        guard profile.tokens != nil else { await signIn(profile: profile); return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            var next = saved
            next.active = profile.id
            try AccountStore.local.save(next)
            saved = next
            epoch = UUID()
            models = []
            try await updateModels()
        } catch {
            self.error = displayError(error)
        }
    }

    func reloadModels() async {
        guard connected, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { try await updateModels() }
        catch { self.error = displayError(error) }
    }

    func signOut() async {
        guard let profile = active, let tokens = profile.tokens, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        var next = saved
        guard let index = next.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        next.profiles[index].tokens = nil
        do {
            try AccountStore.local.save(next)
            saved = next
            epoch = UUID()
            models = []
        } catch {
            self.error = AppError.storage.localizedDescription
            return
        }
        var confirmed = false
        for index in 0..<3 {
            do {
                _ = try await OpenAI.data(OpenAI.form("/api/accounts/oauth/revoke", [
                    "token": tokens.refreshToken, "token_type_hint": "refresh_token", "client_id": profile.id
                ]))
                confirmed = true
                break
            } catch {
                guard index < 2, !(error is CancellationError) else { break }
                if let failure = error as? AppError, !failure.retryable { break }
                try? await Task.sleep(for: .seconds(index + 1))
            }
        }
        if !confirmed {
            error = String(localized: "Signed out here. Remote revocation could not be confirmed. Check ChatGPT Settings.")
        }
    }

    func accessToken() async throws -> String {
        guard let profile = active, let tokens = profile.tokens else { throw AppError.signedOut }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        let generation = epoch
        if let refresh {
            let refreshed = try await refresh.value
            guard epoch == generation else { throw CancellationError() }
            return refreshed.accessToken
        }
        let task = Task {
            let response = try await Self.tokenResponse([
                "grant_type": "refresh_token", "client_id": profile.id,
                "refresh_token": tokens.refreshToken, "resource": OpenAI.resource
            ])
            let refreshed = try Tokens(response, retainedIDToken: tokens.idToken)
            guard epoch == generation,
                  let index = saved.profiles.firstIndex(where: { $0.id == profile.id }) else {
                throw CancellationError()
            }
            var next = saved
            next.profiles[index].tokens = refreshed
            try AccountStore.local.save(next)
            saved = next
            return refreshed
        }
        refresh = task
        defer { refresh = nil }
        return try await task.value.accessToken
    }

    private func updateModels() async throws {
        let token = try await accessToken()
        let options = try await OpenAI.models(token: token)
        let preferred = saved.active.flatMap { UserDefaults.standard.string(forKey: "model." + $0) }
        models = options
        selectedModel = options.first(where: { $0.slug == preferred })?.slug ?? options[0].slug
    }

    private static func tokenResponse(_ fields: [String: String]) async throws -> TokenResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try await OpenAI.data(OpenAI.form("/api/accounts/oauth/token", fields))
        return try decoder.decode(TokenResponse.self, from: data)
    }
}

func displayError(_ error: Error) -> String {
    if let error = error as? AppError { return error.localizedDescription }
    if let error = error as? ResponseFailure { return error.localizedDescription }
    if let error = error as? RetryAfter { return error.localizedDescription }
    if let error = error as? URLError {
        if error.code == .timedOut { return String(localized: "The request timed out.") }
        return String(localized: "Could not connect to OpenAI.")
    }
    return AppError.badResponse.localizedDescription
}

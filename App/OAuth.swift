import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security
import UIKit

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
    }

    static func secureRandom() throws -> Data {
        var data = Data(count: 32)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard result == errSecSuccess else { throw AppError.security }
        return data
    }
}

struct OAuthAttempt {
    struct Grant {
        let client: String
        let code: String
    }

    let state: String
    let nonce: String
    let verifier: String
    let redirect: String
    let authorizationURL: URL
    private let previous: String?

    init(port: UInt16, host: String, previous: Profile?) throws {
        state = try Data.secureRandom().base64URL
        nonce = try Data.secureRandom().base64URL
        verifier = try Data.secureRandom().base64URL
        redirect = "http://127.0.0.1:\(port)/auth/callback"
        self.previous = previous?.id
        var fields = [
            "client_id": previous?.id ?? "dynamic_agent_client", "ext_agent_host_id": host,
            "response_type": "code", "redirect_uri": redirect, "scope": OpenAI.scopes,
            "resource": OpenAI.resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        ]
        if let previous {
            if let identity = previous.tokens?.idToken { fields["id_token_hint"] = identity }
            if let email = previous.email { fields["login_hint"] = email }
        } else {
            fields["agent_name_hint"] = "ianautomat"
        }
        guard let url = URL(string: OpenAI.issuer + "/api/accounts/authorize?" + OpenAI.encoded(fields)) else {
            throw AppError.security
        }
        authorizationURL = url
    }

    func parse(_ target: String) throws -> Grant? {
        guard target.hasPrefix("/auth/callback?"),
              let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/auth/callback",
              url.fragment == nil, let items = url.queryItems else { return nil }
        var parameters: [String: String] = [:]
        for item in items {
            guard parameters[item.name] == nil, let value = item.value else { return nil }
            parameters[item.name] = value
        }
        guard parameters["state"] == state else { return nil }
        if parameters["error"] != nil { throw AppError.denied }
        guard let client = parameters["client_id"] ?? previous,
              client.hasPrefix("oaiapp_"), client.utf8.count <= 512,
              previous == nil || previous == client,
              let code = parameters["code"], !code.isEmpty, code.utf8.count <= 4_096 else { return nil }
        return Grant(client: client, code: code)
    }
}

struct Tokens: Codable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresAt: Date

    init(_ response: TokenResponse, retainedIDToken: String? = nil) throws {
        guard response.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
              !response.accessToken.isEmpty, !response.refreshToken.isEmpty,
              (1...86_400).contains(response.expiresIn) else { throw AppError.security }
        let scopes = Set(response.scope.split(separator: " "))
        guard scopes.contains("chatgpt.tokens.use.direct"), scopes.contains("resource.invoke") else {
            throw AppError.missingPlan
        }
        accessToken = response.accessToken
        refreshToken = response.refreshToken
        idToken = response.idToken ?? retainedIDToken
        expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresIn: Int
    let tokenType: String
    let scope: String
}

struct Profile: Identifiable, Codable {
    let id: String
    let subject: String
    let email: String?
    var tokens: Tokens?

    var label: String {
        let suffix = String(id.suffix(6))
        return "\(email ?? String(localized: "ChatGPT account")) · \(suffix)"
    }
}

enum TokenVerifier {
    struct Identity: Decodable {
        let iss: String
        let sub: String
        let exp: TimeInterval
        let iat: TimeInterval?
        let nbf: TimeInterval?
        let nonce: String
        let aud: Audience
        let azp: String?
        let email: String?
    }

    struct Audience: Decodable {
        let clients: [String]
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            clients = (try? value.decode(String.self)).map { [$0] } ?? (try? value.decode([String].self)) ?? []
        }
    }

    private struct Header: Decodable { let alg: String; let kid: String }
    private struct KeySet: Decodable { let keys: [Key] }
    private struct Key: Decodable {
        let kty: String
        let kid: String
        let n: String?
        let e: String?
        let alg: String?
        let use: String?
    }

    static func verify(_ jwt: String, jwks: Data, client: String, nonce: String, now: Date = Date()) throws -> Identity {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, jwt.utf8.count <= 32_768,
              let headerData = Data(base64URL: String(parts[0])),
              let claimsData = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2])),
              let header = try? JSONDecoder().decode(Header.self, from: headerData), header.alg == "RS256",
              let set = try? JSONDecoder().decode(KeySet.self, from: jwks) else { throw AppError.security }
        let candidates = set.keys.filter {
            $0.kid == header.kid && $0.kty == "RSA" && ($0.use == nil || $0.use == "sig") &&
                ($0.alg == nil || $0.alg == "RS256")
        }
        guard candidates.count == 1, let key = candidates.first,
              let n = key.n.flatMap(Data.init(base64URL:)), (256...1024).contains(n.count),
              let e = key.e.flatMap(Data.init(base64URL:)), (1...8).contains(e.count) else { throw AppError.security }
        let publicKey = der(0x30, integer(n) + integer(e))
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let rsa = SecKeyCreateWithData(publicKey as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(rsa, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil),
              let identity = try? JSONDecoder().decode(Identity.self, from: claimsData),
              identity.iss == OpenAI.issuer, !identity.sub.isEmpty, identity.nonce == nonce,
              identity.aud.clients.contains(client),
              (identity.aud.clients.count == 1 && identity.azp == nil) || identity.azp == client,
              identity.exp > now.timeIntervalSince1970,
              identity.iat.map({ $0 <= now.timeIntervalSince1970 + 60 }) ?? true,
              identity.nbf.map({ $0 <= now.timeIntervalSince1970 + 60 }) ?? true else { throw AppError.security }
        return identity
    }

    private static func integer(_ data: Data) -> Data {
        let number = Data(data.drop(while: { $0 == 0 }))
        guard let first = number.first else { return der(2, Data([0])) }
        return der(2, first >= 0x80 ? Data([0]) + number : number)
    }

    private static func der(_ tag: UInt8, _ body: Data) -> Data {
        var length = body.count
        if length < 128 { return Data([tag, UInt8(length)]) + body }
        var digits: [UInt8] = []
        while length > 0 {
            digits.append(UInt8(truncatingIfNeeded: length))
            length >>= 8
        }
        return Data([tag, 0x80 | UInt8(digits.count)] + digits.reversed()) + body
    }
}

@MainActor
final class Loopback: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let listener: NWListener
    private var browser: ASWebAuthenticationSession?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var callback: CheckedContinuation<OAuthAttempt.Grant, Error>?
    private var attempt: OAuthAttempt?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var timeout: Task<Void, Never>?
    private var accepted = false

    init(port: NWEndpoint.Port = .any) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        listener = try NWListener(using: parameters)
        super.init()
    }

    func listen() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in self?.changed(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel(); return }
                    self.receive(connection)
                }
            }
            listener.start(queue: .main)
        }
    }

    func awaitGrant(_ attempt: OAuthAttempt, openBrowser: (URL) -> Void) async throws -> OAuthAttempt.Grant {
        try await withCheckedThrowingContinuation { continuation in
            self.attempt = attempt
            callback = continuation
            openBrowser(attempt.authorizationURL)
        }
    }

    func openBrowser(_ url: URL) {
        let browser = ASWebAuthenticationSession(url: url, callback: .customScheme("ianautomat-auth")) {
            [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self, !self.accepted else { return }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    self.stop()
                } else {
                    self.stop(AppError.listener)
                }
            }
        }
        self.browser = browser
        browser.presentationContextProvider = self
        if !browser.start() { stop(AppError.listener) }
    }

    func stop(_ error: Error = CancellationError()) {
        finish(.failure(error))
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
    }

    private func changed(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener.port else { stop(AppError.listener); return }
            ready?.resume(returning: port.rawValue)
            ready = nil
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(600))
                if !Task.isCancelled { self?.stop(AppError.timedOut) }
            }
        case .failed, .waiting: stop(AppError.listener)
        default: break
        }
    }

    private func finish(_ result: Result<OAuthAttempt.Grant, Error>) {
        timeout?.cancel()
        timeout = nil
        listener.cancel()
        ready?.resume(throwing: AppError.listener)
        ready = nil
        if case .success = result { accepted = true }
        callback?.resume(with: result)
        callback = nil
        if !accepted {
            browser?.cancel()
            browser = nil
        }
    }

    private func receive(_ connection: NWConnection) {
        guard clients.count < 8, !accepted else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        clients[id] = connection
        connection.start(queue: .main)
        read(connection, Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.close(id)
        }
    }

    private func read(_ connection: NWConnection, _ accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                guard self.clients[id] != nil else { return }
                let request = accumulated + (data ?? Data())
                guard error == nil, request.count <= 16_384 else { self.close(id); return }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.handle(connection, request)
                } else if complete {
                    self.close(id)
                } else {
                    self.read(connection, request)
                }
            }
        }
    }

    private func handle(_ connection: NWConnection, _ request: Data) {
        let headers = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = headers.first?.split(separator: " ") ?? []
        let host = headers.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        let expected = attempt.flatMap { URL(string: $0.redirect)?.port }.map { "127.0.0.1:\($0)" }
        let actual = host.first.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        let id = ObjectIdentifier(connection)
        var response = "400 Bad Request\r\n"
        if !accepted, parts.count == 3, parts[0] == "GET", host.count == 1, actual == expected {
            do {
                if let grant = try attempt?.parse(String(parts[1])) {
                    response = "302 Found\r\nLocation: ianautomat-auth://complete\r\n"
                    finish(.success(grant))
                }
            } catch {
                finish(.failure(error))
            }
        }
        response = "HTTP/1.1 " + response + "Content-Length: 0\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in self?.close(id) }
        })
    }

    private func close(_ id: ObjectIdentifier) {
        clients.removeValue(forKey: id)?.cancel()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

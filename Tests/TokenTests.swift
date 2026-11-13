import Foundation
import Security
import Testing
@testable import ianautomat

@Test func idTokenChecksRealRSASignatureAndOIDCClaims() throws {
    let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as [CFString: Any]
    let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
    let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
    let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
    // A generated 2048-bit RSA public key has a leading sign byte and a three-byte exponent.
    #expect(der.count == 270)
    #expect(der[8] == 0)
    let jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
        "kty": "RSA", "alg": "RS256", "use": "sig", "kid": "test",
        "n": der[9..<265].base64URL, "e": der[267..<270].base64URL
    ]]])
    let now = Date(timeIntervalSince1970: 1000)
    let header = Data(#"{"alg":"RS256","kid":"test"}"#.utf8).base64URL
    let payload = Data(#"{"iss":"https://auth.openai.com","sub":"subject","exp":1200,"nonce":"nonce","aud":"oaiapp_test"}"#.utf8).base64URL
    let message = "\(header).\(payload)"
    let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                      Data(message.utf8) as CFData, nil) as Data?)
    let jwt = "\(message).\(signature.base64URL)"
    #expect(try TokenVerifier.verify(jwt, jwks: jwks, client: "oaiapp_test", nonce: "nonce", now: now).sub == "subject")
    #expect(throws: AppError.self) {
        try TokenVerifier.verify(jwt, jwks: jwks, client: "wrong", nonce: "nonce", now: now)
    }
    #expect(throws: AppError.self) {
        try TokenVerifier.verify(jwt, jwks: jwks, client: "oaiapp_test", nonce: "wrong", now: now)
    }
    #expect(throws: AppError.self) {
        try TokenVerifier.verify(jwt, jwks: jwks, client: "oaiapp_test", nonce: "nonce", now: now.addingTimeInterval(300))
    }
    var changed = signature
    changed[0] ^= 1
    #expect(throws: AppError.self) {
        try TokenVerifier.verify("\(message).\(changed.base64URL)", jwks: jwks, client: "oaiapp_test", nonce: "nonce", now: now)
    }
}

@Test func credentialsRoundTripThroughSystemKeychain() throws {
    let store = AccountStore(service: "dev.fuba.ianautomat.test." + UUID().uuidString)
    defer { store.delete() }
    #expect(try store.load().profiles.isEmpty)
    let profile = Profile(id: "oaiapp_test", subject: "test", email: nil, tokens: nil)
    try store.save(SavedAccounts(active: profile.id, profiles: [profile]))
    #expect(try store.load().profiles.map(\.id) == [profile.id])
    try store.save(SavedAccounts())
    #expect(try store.load().profiles.isEmpty)
}
